#!/usr/bin/env bun
/**
 * Microsoft Teams channel for Claude Code.
 *
 * Azure Bot Service posts activities to /api/messages. This server gates them
 * with access.json, forwards accepted messages through Claude channel
 * notifications, and exposes reply/fetch tools over MCP.
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from '@modelcontextprotocol/sdk/types.js'
import { BotFrameworkAdapter, TurnContext, ActivityTypes } from 'botbuilder'
import type { ConversationReference, Activity } from 'botbuilder'
import { createServer } from 'http'
import { randomUUID } from 'crypto'
import { spawnSync } from 'child_process'
import {
  appendFileSync,
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from 'fs'
import { homedir } from 'os'
import { join } from 'path'
import { createRecentMessageDeduper } from './dedupe.ts'

type GroupPolicy = {
  requireMention?: boolean
  allowFrom?: string[]
}

type Access = {
  dmPolicy?: 'allowlist' | 'open' | 'disabled'
  allowFrom?: string[]
  groups?: Record<string, GroupPolicy>
  pending?: Record<string, unknown>
  routes?: Record<string, unknown>
}

type StoredMessage = {
  chat_id: string
  message_id: string
  user: string
  user_id: string
  aad_object_id: string
  text: string
  ts: string
}

const STATE_DIR = process.env.TEAMS_STATE_DIR ?? join(homedir(), '.claude', 'channels', 'teams')
const BRIDGE_HOME = process.env.BRIDGE_HOME ?? join(homedir(), '.agent-bridge')
const ACCESS_FILE = join(STATE_DIR, 'access.json')
const ENV_FILE = join(STATE_DIR, '.env')
const REFERENCES_FILE = join(STATE_DIR, 'conversations.json')
const MESSAGES_FILE = join(STATE_DIR, 'messages.jsonl')

try {
  chmodSync(ENV_FILE, 0o600)
  const inheritedEnv = new Set(Object.keys(process.env))
  for (const line of readFileSync(ENV_FILE, 'utf8').split('\n')) {
    const m = line.match(/^(\w+)=(.*)$/)
    if (m && !inheritedEnv.has(m[1])) process.env[m[1]] = m[2]
  }
} catch {}

const HOST = process.env.TEAMS_WEBHOOK_HOST ?? '127.0.0.1'
const PORT = Number(process.env.TEAMS_WEBHOOK_PORT ?? '3978')
const STATIC = process.env.TEAMS_ACCESS_MODE === 'static'

const APP_ID = process.env.TEAMS_APP_ID ?? process.env.MicrosoftAppId
const APP_PASSWORD = process.env.TEAMS_APP_PASSWORD ?? process.env.MicrosoftAppPassword
const TENANT_ID = process.env.TEAMS_TENANT_ID ?? process.env.MicrosoftAppTenantId ?? ''

if (!APP_ID || !APP_PASSWORD) {
  process.stderr.write(
    `teams channel: TEAMS_APP_ID and TEAMS_APP_PASSWORD are required\n` +
    `  set them in ${ENV_FILE}\n`,
  )
  process.exit(1)
}

process.on('unhandledRejection', err => {
  process.stderr.write(`teams channel: unhandled rejection: ${err}\n`)
})
process.on('uncaughtException', err => {
  process.stderr.write(`teams channel: uncaught exception: ${err}\n`)
})

function ensureStateDir(): void {
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 })
}

function loadJson<T>(path: string, fallback: T): T {
  try {
    return JSON.parse(readFileSync(path, 'utf8')) as T
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return fallback
    try { renameSync(path, `${path}.corrupt-${Date.now()}`) } catch {}
    return fallback
  }
}

function saveJson(path: string, payload: unknown): void {
  ensureStateDir()
  const tmp = `${path}.tmp`
  writeFileSync(tmp, JSON.stringify(payload, null, 2) + '\n', { mode: 0o600 })
  renameSync(tmp, path)
  chmodSync(path, 0o600)
}

function defaultAccess(): Access {
  return { dmPolicy: 'allowlist', allowFrom: [], groups: {}, pending: {}, routes: {} }
}

const BOOT_ACCESS = STATIC ? loadJson<Access>(ACCESS_FILE, defaultAccess()) : null

function loadAccess(): Access {
  return BOOT_ACCESS ?? loadJson<Access>(ACCESS_FILE, defaultAccess())
}

function compactText(text: string): string {
  return text.replace(/<at>[^<]+<\/at>/g, '').trim()
}

function idsFor(activity: Activity): string[] {
  const from = activity.from ?? {}
  const aad = String((from as any).aadObjectId ?? '').trim()
  const id = String(from.id ?? '').trim()
  return [aad, id].filter(Boolean)
}

function userAllowed(policyIds: string[] | undefined, userIds: string[]): boolean {
  const allow = policyIds ?? []
  if (allow.length === 0) return true
  return userIds.some(id => allow.includes(id))
}

function activityMentionedBot(activity: Activity): boolean {
  const text = activity.text ?? ''
  if (/<at>[^<]+<\/at>/.test(text)) return true
  const entities = Array.isArray(activity.entities) ? activity.entities : []
  return entities.some(entity => entity.type === 'mention')
}

function gate(activity: Activity): boolean {
  const access = loadAccess()
  if (access.dmPolicy === 'disabled') return false

  const conversationId = String(activity.conversation?.id ?? '').trim()
  const channelId = String((activity.channelData as any)?.channel?.id ?? '').trim()
  const conversationType = String(activity.conversation?.conversationType ?? '').trim()
  const userIds = idsFor(activity)

  for (const key of [conversationId, channelId]) {
    if (!key) continue
    const policy = access.groups?.[key]
    if (!policy) continue
    if (policy.requireMention && !activityMentionedBot(activity)) return false
    return userAllowed(policy.allowFrom, userIds)
  }

  if (conversationType === 'personal') {
    if (access.dmPolicy === 'open') return true
    return userIds.some(id => (access.allowFrom ?? []).includes(id))
  }

  return false
}

function referenceKey(activity: Activity): string {
  return String(activity.conversation?.id ?? '').trim()
}

function storeReference(activity: Activity): void {
  const key = referenceKey(activity)
  if (!key) return
  const refs = loadJson<Record<string, ConversationReference>>(REFERENCES_FILE, {})
  refs[key] = TurnContext.getConversationReference(activity)
  saveJson(REFERENCES_FILE, refs)
}

function appendMessage(message: StoredMessage): void {
  ensureStateDir()
  appendFileSync(MESSAGES_FILE, JSON.stringify(message) + '\n', { mode: 0o600 })
}

function runPromptGuard(command: 'scan' | 'sanitize', text: string): Record<string, unknown> | null {
  const script = join(BRIDGE_HOME, 'bridge-guard.py')
  const result = spawnSync(
    'python3',
    [script, command, '--agent', process.env.BRIDGE_AGENT_ID ?? '', '--surface', command === 'scan' ? 'channel' : 'output', '--format', 'json', text],
    { encoding: 'utf8' },
  )
  if (result.status !== 0 && !result.stdout.trim()) return null
  try {
    return JSON.parse(result.stdout)
  } catch {
    return null
  }
}

function recentMessages(chatId: string, limit: number): StoredMessage[] {
  if (!existsSync(MESSAGES_FILE)) return []
  const lines = readFileSync(MESSAGES_FILE, 'utf8').split('\n').filter(Boolean)
  const rows = lines
    .map(line => {
      try { return JSON.parse(line) as StoredMessage } catch { return null }
    })
    .filter((row): row is StoredMessage => Boolean(row))
    .filter(row => !chatId || row.chat_id === chatId)
  return rows.slice(-Math.max(1, Math.min(limit, 100)))
}

const adapter = new BotFrameworkAdapter({
  appId: APP_ID,
  appPassword: APP_PASSWORD,
  channelAuthTenant: TENANT_ID || undefined,
})
const recentMessageIds = createRecentMessageDeduper(256)
let duplicateDropLogs = 0

const mcp = new Server(
  { name: 'teams', version: '0.1.0' },
  {
    capabilities: {
      tools: {},
      experimental: {
        'claude/channel': {},
        'claude/channel/permission': {},
      },
    },
    instructions: [
      'Microsoft Teams channel for Claude Code.',
      'Messages from Teams arrive as <channel source="teams" chat_id="..." message_id="..." user="..." ts="...">.',
      'Anything the Teams user should see must be sent with the reply tool. Terminal transcript output is not delivered to Teams.',
      'Pass chat_id from the inbound message to reply. Use fetch_messages for recent local message context.',
    ].join('\n'),
  },
)

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'reply',
      description: 'Reply to a Teams conversation. Pass chat_id from the inbound message.',
      inputSchema: {
        type: 'object',
        properties: {
          chat_id: { type: 'string', description: 'Teams conversation id from inbound meta.chat_id.' },
          text: { type: 'string', description: 'Message text to send.' },
        },
        required: ['chat_id', 'text'],
      },
    },
    {
      name: 'fetch_messages',
      description: 'Fetch recent Teams messages captured by this plugin from the local rolling log.',
      inputSchema: {
        type: 'object',
        properties: {
          chat_id: { type: 'string', description: 'Optional Teams conversation id.' },
          limit: { type: 'number', description: 'Maximum number of messages, default 20, max 100.' },
        },
      },
    },
  ],
}))

mcp.setRequestHandler(CallToolRequestSchema, async req => {
  const args = (req.params.arguments ?? {}) as Record<string, unknown>
  switch (req.params.name) {
    case 'reply': {
      const chatId = String(args.chat_id ?? '').trim()
      let text = String(args.text ?? '').trim()
      if (!chatId) throw new Error('chat_id is required')
      if (!text) throw new Error('text is required')
      const guarded = runPromptGuard('sanitize', text)
      if (guarded?.blocked) {
        text = '[Agent Bridge] outbound reply blocked by prompt guard.'
      } else if (guarded?.was_modified && typeof guarded.sanitized_text === 'string') {
        text = guarded.sanitized_text
      }
      const refs = loadJson<Record<string, ConversationReference>>(REFERENCES_FILE, {})
      const ref = refs[chatId]
      if (!ref) throw new Error(`conversation reference not found for ${chatId}; wait for an inbound Teams message first`)
      await adapter.continueConversation(ref, async context => {
        await context.sendActivity(text)
      })
      return { content: [{ type: 'text', text: `sent: ${chatId}` }] }
    }
    case 'fetch_messages': {
      const chatId = String(args.chat_id ?? '').trim()
      const limit = Number(args.limit ?? 20)
      const rows = recentMessages(chatId, Number.isFinite(limit) ? limit : 20)
      return { content: [{ type: 'text', text: JSON.stringify(rows, null, 2) }] }
    }
    default:
      throw new Error(`unknown tool: ${req.params.name}`)
  }
})

async function handleActivity(context: TurnContext): Promise<void> {
  const activity = context.activity
  if (activity.type !== ActivityTypes.Message) return
  if (!gate(activity)) return

  const chatId = referenceKey(activity)
  const messageId = String(activity.id ?? randomUUID())
  if (recentMessageIds.seen(messageId)) {
    if (duplicateDropLogs < 10) {
      process.stderr.write(`teams channel: dropped duplicate message_id=${messageId}\n`)
      duplicateDropLogs += 1
    }
    return
  }

  storeReference(activity)

  const userName = String(activity.from?.name ?? activity.from?.id ?? 'teams-user')
  const userIds = idsFor(activity)
  const aad = userIds[0] ?? ''
  const text = compactText(activity.text ?? '')
  const guarded = runPromptGuard('scan', text)
  if (guarded?.blocked) return
  const ts = activity.timestamp instanceof Date ? activity.timestamp.toISOString() : new Date().toISOString()

  const stored: StoredMessage = {
    chat_id: chatId,
    message_id: messageId,
    user: userName,
    user_id: userIds[userIds.length - 1] ?? '',
    aad_object_id: aad,
    text,
    ts,
  }
  appendMessage(stored)

  void mcp.notification({
    method: 'notifications/claude/channel',
    params: {
      content: text,
      meta: {
        source: 'teams',
        chat_id: chatId,
        conversation_id: chatId,
        message_id: messageId,
        user: userName,
        user_id: stored.user_id,
        aad_object_id: aad,
        tenant_id: String((activity.channelData as any)?.tenant?.id ?? TENANT_ID),
        service_url: String(activity.serviceUrl ?? ''),
        ts,
      },
    },
  })
}

const httpServer = createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    const body = JSON.stringify({ ok: true, channel: 'teams', port: PORT })
    res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) })
    res.end(body)
    return
  }
  if (req.method === 'POST' && req.url === '/api/messages') {
    adapter.processActivity(req, res, async context => {
      await handleActivity(context)
    }).catch(err => {
      process.stderr.write(`teams channel: processActivity failed: ${err}\n`)
      if (!res.headersSent) {
        res.writeHead(500)
        res.end()
      }
    })
    return
  }
  res.writeHead(404)
  res.end()
})

httpServer.on('error', err => {
  process.stderr.write(`teams channel: http listen failed on ${HOST}:${PORT}: ${err}\n`)
  process.exit(1)
})

httpServer.listen(PORT, HOST, () => {
  process.stderr.write(`teams channel: listening on http://${HOST}:${PORT}/api/messages\n`)
})

await mcp.connect(new StdioServerTransport())

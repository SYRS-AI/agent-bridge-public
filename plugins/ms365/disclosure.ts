import {
  chmodSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from 'fs'
import { dirname } from 'path'

type ChatDisclosureEntry = {
  disclosed_at: string
  message_id?: string
}

type ChatDisclosureState = {
  version: 1
  chats: Record<string, Record<string, ChatDisclosureEntry>>
}

const EMPTY_STATE: ChatDisclosureState = { version: 1, chats: {} }

function ensureParent(path: string): void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
}

function loadState(path: string): ChatDisclosureState {
  try {
    const parsed = JSON.parse(readFileSync(path, 'utf8')) as ChatDisclosureState
    if (!parsed || typeof parsed !== 'object' || parsed.version !== 1 || typeof parsed.chats !== 'object') {
      return { ...EMPTY_STATE }
    }
    return parsed
  } catch {
    return { ...EMPTY_STATE }
  }
}

function saveState(path: string, payload: ChatDisclosureState): void {
  ensureParent(path)
  const tmp = `${path}.tmp`
  writeFileSync(tmp, JSON.stringify(payload, null, 2) + '\n', { mode: 0o600 })
  renameSync(tmp, path)
  chmodSync(path, 0o600)
}

function upnKey(upn: string): string {
  return upn.trim().toLowerCase()
}

export function prependHumanOutboundDisclaimer(
  body: string,
  bodyType: string,
  disclaimer: string,
): string {
  if (!disclaimer) return body
  if (body.includes(disclaimer)) return body
  if (bodyType === 'html') {
    const escaped = disclaimer
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/\n/g, '<br>')
    return `<div style="color:#666;font-size:0.9em;border-left:3px solid #ccc;padding-left:8px;margin-bottom:12px">${escaped}</div>\n${body}`
  }
  return `${disclaimer}\n\n${body}`
}

export function hasChatDisclaimerBeenSent(
  statePath: string,
  upn: string,
  chatId: string,
): boolean {
  const state = loadState(statePath)
  return Boolean(state.chats[upnKey(upn)]?.[chatId])
}

export function markChatDisclaimerSent(
  statePath: string,
  upn: string,
  chatId: string,
  messageId?: string,
): void {
  const state = loadState(statePath)
  const key = upnKey(upn)
  if (!state.chats[key]) state.chats[key] = {}
  state.chats[key][chatId] = {
    disclosed_at: new Date().toISOString(),
    ...(messageId ? { message_id: messageId } : {}),
  }
  saveState(statePath, state)
}

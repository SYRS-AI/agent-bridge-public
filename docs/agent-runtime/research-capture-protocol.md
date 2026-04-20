# Research capture protocol

> Canonical. Applies to all research-producing agents (syrs-derm, syrs-trend, syrs-creative, newsbot, syrs-buzz, syrs-production). Symlinked or referenced by each agent's `RESEARCH-CAPTURE.md`.

## Why this exists

Agent raw memory가 wiki 자동 구축 파이프라인(`bridge-knowledge promote --graph-mode`)과 매끄럽게 연결되려면 구조가 일관돼야 한다. 현재 일부 에이전트는 **카테고리별 거대 파일에 섹션 append** 방식이라 섹션 단위 retrieve·그래프 클러스터링·중복 제거가 불가능하다.

규칙 한 줄: **1 리서치 단위 = 1 파일. 파일 내부 append 금지. 메타데이터는 YAML frontmatter로.**

## Directory layout

각 에이전트 홈에 다음 구조:

```
<agent-home>/memory/
├── 2026-04-19.md                 # daily note (그대로)
├── research/                     # NEW: research raw store
│   ├── papers/
│   ├── ingredients/              # 성분 (syrs-derm) / keyword (syrs-trend)
│   ├── products/                 # SKU (syrs-derm, syrs-production)
│   ├── frameworks/
│   ├── regulations/              # syrs-derm, syrs-production
│   ├── competitors/              # syrs-derm, syrs-buzz
│   ├── trends/                   # syrs-trend, newsbot
│   ├── templates/                # syrs-satomi
│   └── reviews/                  # syrs-buzz
└── index/                        # (optional) 레거시 집계 파일, 링크 전용
```

도메인에 맞는 하위 폴더만 생성. 불필요한 폴더 만들 필요 없음.

## File naming

- Papers: `YYYY-<first-author>-<topic>-<journal>.md` (예: `2025-park-cica-ev-cosmetics.md`)
- Ingredients: `<ingredient-slug>.md` (예: `adenosine.md`, `cica-callus-ev.md`)
- Products: `<brand>-<sku>.md` (예: `syrs-repair-cream.md`)
- Trends: `YYYY-MM-<topic>.md` (예: `2026-05-event-research.md`)
- Reviews: `YYYY-MM-DD-<platform>-<product>.md`

slug는 소문자·hyphen·ASCII. 한글 허용하되 graph readability 위해 roman 권장.

## Frontmatter schema

### 공통 (모든 타입)

```yaml
---
type: paper | ingredient | product | framework | regulation | competitor | trend | review | template
slug: <file-slug>
title: "Human-readable title"
date_captured: YYYY-MM-DD
date_updated: YYYY-MM-DD
agent: <agent-id>
tags: [tag1, tag2]
related_papers: [slug1, slug2]       # optional, cross-ref
related_ingredients: [slug1]
related_products: [slug1]
related_frameworks: [slug1]
confidence: high | medium | low      # optional
relevance: 1-5                       # optional
---
```

### 타입별 추가 필드

**paper**:
```yaml
authors: ["Park J", "Kim S"]
journal: Cosmetics
year: 2025
doi: 10.3390/...                     # 있으면
sample_size: 20
duration: 2w
outcome: "한 줄 핵심 결과"
mechanism: [pore-reduction]
```

**ingredient**:
```yaml
inci: Centella Asiatica Callus Extract
cas: 84696-21-9                       # 있으면
concentration_range: "0.5% ~ 2%"
mechanism: [...]
safety_profile: medium
cost_index: high
supplier: ["VT Cosmetics", "..."]
```

**product**:
```yaml
brand: SYRS
sku: SYRS-REPAIR-CREAM-30ML
target_skin: [sensitive, aging]
price_jpy: 7800
launch_date: 2026-05
ingredients_key: [cica-callus-ev, niacinamide]
```

**framework / regulation / competitor**: 도메인에 맞는 필드. 지나치게 엄격하지 않게.

## Body template

```markdown
---
<frontmatter>
---

# {{title}}

## Summary
(2~3 문장, 핵심만)

## Key findings / data
(수치, 사실, 그래프 결과)

## Methodology
(연구 방법 / 샘플 / 기간 / 측정 도구)

## Limitations
(한계·주의점)

## {{Domain-specific}}
- paper: "SYRS application" (우리 제품에 어떻게 쓰이나)
- ingredient: "제형 호환성" + "경쟁 성분 대비"
- trend: "다음 action"
- review: "inquire target"

## Related
- Papers: [[2024-chang-scalp-ev]]
- Ingredients: [[cica-callus-ev]]
- Products: [[syrs-repair-cream]]
```

## Update vs new-file

- **새 논문·새 성분·새 제품 신규 발견** → **새 파일 생성**
- **기존 성분에 새 데이터 추가** (예: 새 농도 시험 결과) → 기존 파일 update + `date_updated` 갱신 + `Key findings` 섹션에 `(updated YYYY-MM-DD)` prefix로 항목 추가. 전체 rewrite 금지, append만.
- **기존 논문에 correction/retraction** → 새 파일 (correction) + 기존 파일의 Summary에 `**CORRECTED by [[...]]**` 주석.

## Daily note와의 관계

- Daily note = 그날의 **대화·결정·체크** 로그 (유지).
- 당일 새 리서치 발견 시:
  1. 별도 파일 `research/<type>/<slug>.md` 생성.
  2. Daily note 본문에 한 줄 요약 + `[[research/<type>/<slug>]]` link.
- 이렇게 하면 wiki build가 daily → research 자동 mapping.

## Legacy file migration

기존 집계 파일(`ev-exosome-research.md` 등)이 있으면:

1. `agb knowledge split-legacy --agent <name> --source <path> --type <t> --llm` 실행
2. 각 섹션이 individual file로 쪼개짐. LLM이 frontmatter 자동 생성.
3. 원본은 `index/<filename>` 로 이동. 본문은 `[[<slug1>]] · [[<slug2>]] · ...` 링크 리스트만.
4. 사람 검토 후 apply.

## Wiki build가 하는 일 (참고)

`bridge-knowledge promote --graph-mode` 실행 시:

1. 각 `research/<type>/<slug>.md` frontmatter 파싱
2. `shared/wiki/agents/<agent>/<type>/<slug>.md`로 복사
3. frontmatter `related_*` 배열을 자동 `[[<slug>]]` link로 변환 (본문 하단 Related 섹션에 배치)
4. 같은 ingredient가 여러 에이전트에 있으면 canonical 병합 후보로 표기 (admin 수동 승격)

## Minimum required

에이전트가 빠르게 적용하려면:

1. 기존 집계 파일 그대로 두기 (migration은 tool로 처리)
2. **오늘부터 새 리서치는 1 리서치 = 1 파일 원칙** 적용
3. frontmatter 최소 필드(type, slug, title, date_captured, tags)만 지키기
4. 본문은 자유롭되 `## Related` 섹션에 수동으로 관련 slug link

3~4 필드만 일관되면 wiki build가 알아서 처리.

## Changelog

- 2026-04-19: initial version (Sean 지시, 오쌤 리서치 구조 정비 계기)
- 2026-04-19: ratified 2026-04-19. Integrated with the `docs/agent-runtime/` canonical set. Cross-references added — entity lifecycle (merge, aliases, redirect) moved to [`wiki-entity-lifecycle.md`](wiki-entity-lifecycle.md); graph rules to [`wiki-graph-rules.md`](wiki-graph-rules.md); memory layering to [`memory-schema.md`](memory-schema.md). No body change to §§1–9; this file is now one member of the 8-file canonical set.

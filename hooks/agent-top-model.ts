// Pure helpers of the agent-top mod (hooks/agent-top.tsx): parse the `agent-top --json` snapshot, decide what to poll
// and when, find the events worth a toast, and format the text the pane draws. No `$`, no I/O: unit-testable on its own.

export type AgentState = 'live' | 'done' | 'error' | 'dead' | 'unknown' | 'stopped'

export type Agent = {
  stage: string
  role: string
  dir_name: string
  title: string
  tag: string
  state: AgentState
  quiet: boolean
  expired: boolean
  alive: boolean
  kind: string
  parent: string | null
  engine: string
  model: string
  model_id: string | null
  effort: string | null
  age_s: number | null
  runs: number
  turns: number
  run_turns: number
  turns_approx: boolean
  sub_turns: number
  ctx_tokens: number | null
  /** The model's context window (`agent-top --json` derives it: reported, else by model id, else 200k); null from an older CLI. */
  ctx_window: number | null
  cost_usd: number | null
  pid: number | null
  cwd: string | null
  archived: boolean
  action: { tool: string; text: string; elapsed_s: number } | null
  last_text: string
  unread: unknown[]
  result: { subtype: string; is_error: boolean; text: string } | null
}

export type Counts = { live: number; done: number; error: number; dead: number; unknown?: number; stopped?: number }

export type Lock = { kind: string; repo: string; owner_name: string; until: string; active: boolean; why: string }

/**
 * `items` are display lines (the CLI cuts them to 12); `ids` are every open question id of the stage, from the untruncated
 * `ask list`. `ids` is null when the list failed (unknown) or when an older CLI does not send it.
 */
export type StageQuestions = { open: number; overdue: number; line: string; items: string[]; ids: string[] | null }

export type JournalLine = { stage: string; time: string; tag: string; text: string }

/**
 * One stage's row of `agent-top --json` `stage_info`. `idle` is the CLI's word: not closed, no live agent and no activity
 * for longer than `idle_after_s`. `closed` is set under --all (closed stages are left out of `stages` otherwise).
 */
export type StageInfo = {
  goal: string
  closed: { at: string; why: string; by: string } | null
  last_activity_at: string | null
  idle_s: number | null
  idle: boolean
  live: number
}

export type Snapshot = {
  generated_at: string
  stages: string[]
  counts: Counts
  agents: Agent[]
  locks: Lock[]
  questions: Record<string, StageQuestions>
  /** `ask summary` succeeded on this fetch: an empty `questions` then means no registers, not a failed `ask`. */
  questionsOk: boolean
  /** Per stage of `stages`; {} from an older CLI. */
  stage_info: Record<string, StageInfo>
  /** The closed stages the default view leaves out of `stages` (--all shows them); [] from an older CLI. */
  closed_hidden: string[]
  /** The idle threshold in seconds; null from an older CLI. */
  idle_after_s: number | null
  limits: { info: { unifiedWindows?: Record<string, { utilization?: number; resetsAt?: number }> }; seen_at: number } | null
  codex_limits: Record<string, { info: unknown; seen_at: number }>
  journal_tail: JournalLine[]
  fetchedAt: number
}

export type FeedItem = { at: string | null; kind: string; sub: boolean; tool: string | null; text: string; detail: string | null }

export type Card = { agent: Agent | null; feed: FeedItem[]; fetchedAt: number }

/**
 * The line the card draws where its feed has no rows: the CLI's answer still pending, why the last call failed (the
 * mod asks again every tick), or an empty log. `isError` draws it as a warning.
 */
export function feedNote(card: Card | null, cardError: string | null): { text: string; isError: boolean } {
  if (cardError !== null) return { text: `feed unavailable: ${oneLine(cardError)} · retrying`, isError: true }
  if (card !== null) return { text: '(the log is empty)', isError: false }
  return { text: 'loading the feed…', isError: false }
}

export type View = 'list' | 'card' | 'journal' | 'summary'

export type Target = { stage: string; dirName: string; role: string }

/** Whether two card targets name the same agent (a card answer for another one is dropped). */
export const sameTarget = (a: Target | null, b: Target | null): boolean =>
  a !== null && b !== null && a.stage === b.stage && a.dirName === b.dirName

// ---------------------------------------------------------------- parsing

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v)
const str = (v: unknown, d = ''): string => (typeof v === 'string' ? v : d)
const numOr = (v: unknown, d: number): number => (typeof v === 'number' && Number.isFinite(v) ? v : d)
const numOrNull = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null)

export function toAgent(raw: unknown): Agent | null {
  if (!isObject(raw) || typeof raw.role !== 'string' || typeof raw.stage !== 'string') return null
  const state = raw.state === 'live' || raw.state === 'done' || raw.state === 'error' || raw.state === 'dead' || raw.state === 'unknown' || raw.state === 'stopped' ? raw.state : 'unknown'
  const action = isObject(raw.action) ? { tool: str(raw.action.tool), text: str(raw.action.text), elapsed_s: numOr(raw.action.elapsed_s, 0) } : null
  const result = isObject(raw.result)
    ? { subtype: str(raw.result.subtype), is_error: raw.result.is_error === true, text: str(raw.result.text) }
    : null
  return {
    stage: raw.stage,
    role: raw.role,
    dir_name: str(raw.dir_name, raw.role),
    title: str(raw.title),
    tag: str(raw.tag),
    state,
    quiet: raw.quiet === true,
    expired: raw.expired === true,
    alive: raw.alive === true,
    kind: str(raw.kind, 'headless'),
    parent: typeof raw.parent === 'string' ? raw.parent : null,
    engine: str(raw.engine, 'claude'),
    model: str(raw.model),
    model_id: typeof raw.model_id === 'string' ? raw.model_id : null,
    effort: typeof raw.effort === 'string' ? raw.effort : null,
    age_s: numOrNull(raw.age_s),
    runs: numOr(raw.runs, 0),
    turns: numOr(raw.turns, 0),
    run_turns: numOr(raw.run_turns, numOr(raw.turns, 0)),
    turns_approx: raw.turns_approx === true,
    sub_turns: numOr(raw.sub_turns, 0),
    ctx_tokens: numOrNull(raw.ctx_tokens),
    ctx_window: numOrNull(raw.ctx_window) !== null && (raw.ctx_window as number) > 0 ? (raw.ctx_window as number) : null,
    cost_usd: numOrNull(raw.cost_usd),
    pid: numOrNull(raw.pid),
    cwd: typeof raw.cwd === 'string' ? raw.cwd : null,
    archived: raw.archived === true,
    action,
    last_text: str(raw.last_text),
    unread: Array.isArray(raw.unread) ? raw.unread : [],
    result,
  }
}

/** Parses `agent-top --json` stdout. Throws an Error whose message is fit for the pane's one dim line. */
export function parseSnapshot(stdout: string, fetchedAt: number): Snapshot {
  let data: unknown
  try {
    data = JSON.parse(stdout)
  } catch {
    throw new Error('agent-top printed no JSON')
  }
  if (!isObject(data) || !Array.isArray(data.agents) || !isObject(data.counts)) {
    throw new Error('unexpected agent-top output (no agents/counts)')
  }
  const agents = data.agents.map(toAgent).filter((a): a is Agent => a !== null)
  const c = data.counts
  const questions: Record<string, StageQuestions> = {}
  if (isObject(data.questions)) {
    for (const [stage, q] of Object.entries(data.questions)) {
      if (!isObject(q)) continue
      questions[stage] = {
        open: numOr(q.open, 0),
        overdue: numOr(q.overdue, 0),
        line: str(q.line, stage),
        items: Array.isArray(q.items) ? q.items.filter((x): x is string => typeof x === 'string') : [],
        ids: Array.isArray(q.ids) ? q.ids.filter((x): x is string => typeof x === 'string') : null,
      }
    }
  }
  const locks: Lock[] = Array.isArray(data.locks)
    ? data.locks.filter(isObject).map(l => ({
        kind: str(l.kind),
        repo: str(l.repo),
        owner_name: str(l.owner_name),
        until: str(l.until),
        active: l.active === true,
        why: str(l.why),
      }))
    : []
  const journal: JournalLine[] = Array.isArray(data.journal_tail)
    ? data.journal_tail.filter(isObject).map(j => ({ stage: str(j.stage), time: str(j.time), tag: str(j.tag), text: str(j.text) }))
    : []
  const stageInfo: Record<string, StageInfo> = {}
  if (isObject(data.stage_info)) {
    for (const [stage, i] of Object.entries(data.stage_info)) {
      if (!isObject(i)) continue
      stageInfo[stage] = {
        goal: str(i.goal),
        closed: isObject(i.closed) ? { at: str(i.closed.at), why: str(i.closed.why), by: str(i.closed.by) } : null,
        last_activity_at: typeof i.last_activity_at === 'string' ? i.last_activity_at : null,
        idle_s: numOrNull(i.idle_s),
        idle: i.idle === true,
        live: numOr(i.live, 0),
      }
    }
  }
  const limits = isObject(data.limits) && isObject(data.limits.info) ? (data.limits as Snapshot['limits']) : null
  const codex: Snapshot['codex_limits'] = {}
  if (isObject(data.codex_limits)) {
    for (const [id, rec] of Object.entries(data.codex_limits)) {
      if (isObject(rec)) codex[id] = { info: rec.info, seen_at: numOr(rec.seen_at, 0) }
    }
  }
  return {
    generated_at: str(data.generated_at),
    stages: Array.isArray(data.stages) ? data.stages.filter((s): s is string => typeof s === 'string') : [],
    counts: { live: numOr(c.live, 0), done: numOr(c.done, 0), error: numOr(c.error, 0), dead: numOr(c.dead, 0),
      unknown: numOr(c.unknown, 0), stopped: numOr(c.stopped, 0) },
    agents,
    locks,
    questions,
    questionsOk: data.questions_ok === true,
    stage_info: stageInfo,
    closed_hidden: Array.isArray(data.closed_hidden) ? data.closed_hidden.filter((x): x is string => typeof x === 'string') : [],
    idle_after_s: numOrNull(data.idle_after_s),
    limits,
    codex_limits: codex,
    journal_tail: journal,
    fetchedAt,
  }
}

/** Parses the card call: the agent's row (if the CLI listed it) and its feed. Throws like parseSnapshot. */
export function parseCard(stdout: string, dirName: string, fetchedAt: number): Card {
  let data: unknown
  try {
    data = JSON.parse(stdout)
  } catch {
    throw new Error('agent-top printed no JSON')
  }
  if (!isObject(data) || !isObject(data.feed) || !Array.isArray(data.feed.items)) throw new Error('unexpected agent-top output (no feed)')
  const rows = Array.isArray(data.agents) ? data.agents.map(toAgent).filter((a): a is Agent => a !== null) : []
  const feed = data.feed.items.filter(isObject).map(it => ({
    at: typeof it.at === 'string' ? it.at : null,
    kind: str(it.kind),
    sub: it.sub === true,
    tool: typeof it.tool === 'string' ? it.tool : null,
    text: str(it.text),
    detail: typeof it.detail === 'string' ? it.detail : null,
  }))
  const wanted = str(data.feed.agent, dirName)
  return { agent: rows.find(a => a.dir_name === wanted) ?? rows.find(a => a.dir_name === dirName) ?? null, feed, fetchedAt }
}

// ---------------------------------------------------------------- the command's arguments

export type CommandArgs = { role: string | null; stages: string[]; isAll: boolean }

/** `/agent-top [role] [--stage S]... [--all]` (also `--stage=S`). Unknown flags are ignored. */
export function parseArgs(text: string): CommandArgs {
  const words = text.split(/\s+/).filter(Boolean)
  const out: CommandArgs = { role: null, stages: [], isAll: false }
  for (let i = 0; i < words.length; i += 1) {
    const w = words[i] ?? ''
    if (w === '--all') out.isAll = true
    else if (w === '--stage') {
      const next = words[(i += 1)]
      if (next !== undefined) out.stages.push(next)
    } else if (w.startsWith('--stage=')) {
      if (w.length > 8) out.stages.push(w.slice(8))
    } else if (!w.startsWith('-') && out.role === null) out.role = w
  }
  return out
}

/** argv tail of `agent-top --once` for the same arguments (the text fallback where nothing draws). */
export function onceArgs(a: CommandArgs): string[] {
  const out = ['--once', '--width', '100']
  for (const s of a.stages) out.push('--stage', s)
  if (a.isAll) out.push('--all')
  if (a.role) out.push('--agent', a.role)
  return out
}

/**
 * The dev copy of the mod is tested beside the installed plugin, whose own mod then registers the plain name. The
 * installed plugin is `delamain`; its command before the rename, LEGACY_COMMAND, stays answered by it and by the dev copy.
 */
const INSTALLED_PLUGIN = 'delamain'
const DEV_PLUGIN = 'agent-top-dev'
const LEGACY_COMMAND = 'agent-hub:agent-top' // rename:keep rename:transition

/**
 * Whether `/command` is this module's: bare `agent-top`, `<this plugin>:agent-top`, and, in the installed plugin and in
 * the dev copy, `delamain:agent-top` and the command from before the rename. Every other `<x>:agent-top` belongs to
 * another plugin.
 */
export function isOwnCommand(command: string, pluginName: string): boolean {
  if (command === 'agent-top' || command === `${pluginName}:agent-top`) return true

  return (pluginName === INSTALLED_PLUGIN || pluginName === DEV_PLUGIN) && (command === `${INSTALLED_PLUGIN}:agent-top` || command === LEGACY_COMMAND)
}

// ---------------------------------------------------------------- polling plan

export const TICK_MS = 3000
export const IDLE_MS = 15000

export type Plan = { watch: boolean; extra: 'card' | 'all' | null } // 'all': the pane's own list (--all, or named stages)

/**
 * What one refresh runs. The "watch" call (default view, every stage) feeds the status line and the toasts, so it
 * runs every tick while the pane shows it and every IDLE_MS otherwise. The "extra" call feeds only the pane: the
 * card (one agent, its feed) or the pane's own list: --all, or the stages it was opened on (--stage: a closed stage is
 * left out of the watch call, and a named one is shown).
 */
export function planRun(i: { now: number; lastWatchAt: number; isOpen: boolean; view: View; isAll: boolean; hasStages?: boolean; hasTarget: boolean; force: boolean }): Plan {
  const extra: Plan['extra'] = !i.isOpen ? null : i.view === 'card' ? (i.hasTarget ? 'card' : null) : i.isAll || i.hasStages ? 'all' : null
  const isIdleDue = i.now - i.lastWatchAt >= IDLE_MS - TICK_MS / 2
  const watch = (i.isOpen && extra === null) || isIdleDue || (i.force && extra === null)
  return { watch, extra }
}

// ---------------------------------------------------------------- status line and toasts

export function statusText(s: Snapshot | null): string | undefined {
  if (!s || s.agents.length === 0) return undefined
  return `agents ● ${s.counts.live} ✓ ${s.counts.done} ✗ ${s.counts.error + s.counts.dead}` +
    (s.counts.unknown ? ` ? ${s.counts.unknown}` : '') + (s.counts.stopped ? ` ■ ${s.counts.stopped}` : '')
}

/**
 * Where the focus ring goes once a drawing changed the pane's Buttons: the element it was last on (an agent row follows the
 * cursor), or null to leave it. A stage's `close` Button that is gone from the drawing (the stage was closed, or stopped being
 * idle) sends the ring to the Summary tab, which every drawing has.
 */
export function ringTarget(ringKey: string | null, cursorKey: string | null, controls: readonly string[]): string | null {
  let meant = ringKey?.startsWith('open:') && cursorKey !== null ? `open:${cursorKey}` : ringKey
  if (meant?.startsWith('close:') && !controls.includes(meant)) meant = 'view-summary'
  return meant !== null && controls.includes(meant) ? meant : null
}

/** The surfaces that draw the prompt footer (`SessionMode`), where the counts are a Button and not the status line. */
const FOOTER_SURFACES: readonly string[] = ['terminal', 'desktop']

/** True when every surface the session draws on holds the footer Button; none at all (a -p run) is false. */
export const footerHolds = (surfaces: readonly string[]): boolean =>
  surfaces.length > 0 && surfaces.every(s => FOOTER_SURFACES.includes(s))

/** `/agent-top` with no role, stage or --all: the toggle (an open pane closes). */
export const isBare = (a: CommandArgs): boolean => a.role === null && a.stages.length === 0 && !a.isAll

export const agentKey = (a: Pick<Agent, 'stage' | 'dir_name'>): string => `${a.stage}/${a.dir_name}`
/**
 * What the toasts diff against next time. `questions` maps a stage to the set of open question ids last seen there
 * (null: that stage's set is unknown); the whole field is null until the first snapshot whose `ask` data was good, which
 * sets the baseline silently. A snapshot with `questionsOk` false leaves the memory of questions as it was, and a stage
 * whose ids are unknown keeps its previous set. After the baseline, a stage missing from the snapshot counts as empty.
 */
export type Memory = {
  states: Record<string, { state: AgentState; runs: number }>
  questions: Record<string, string[] | null> | null
}

export function remember(s: Snapshot, prev?: Memory): Memory {
  const states: Memory['states'] = {}
  for (const a of s.agents) states[agentKey(a)] = { state: a.state, runs: a.runs }
  if (!s.questionsOk) return { states, questions: prev?.questions ?? null }
  const questions: Record<string, string[] | null> = {}
  for (const [stage, q] of Object.entries(s.questions)) questions[stage] = q.ids ?? prev?.questions?.[stage] ?? null
  return { states, questions }
}

/** Question toasts per stage before the rest fold into one "N more new questions" line. */
const MAX_NEW_QUESTIONS = 3

/** An agent first seen already finished this recently counts as just finished (it ran between two polls). */
const FRESH_S = 30

export function endNotice(a: Agent): string {
  const who = `${a.role} · ${a.stage}`
  if (a.state === 'done') return `✓ ${who} finished`
  if (a.state === 'error') return `✗ ${who} failed` + (a.result?.text ? `: ${clip(oneLine(a.result.text), 60)}` : '')
  if (a.state === 'stopped') return `■ ${who} stopped`
  return `✗ ${who} died`
}

/**
 * Toast texts for what changed since `prev`: an agent that finished, failed or died (also one that was resumed and ended
 * again between two polls: its `runs` grew), and each open owner question id that the stage's remembered set lacks.
 */
export function notices(prev: Memory, s: Snapshot): string[] {
  const out: string[] = []
  for (const a of s.agents) {
    if (a.state === 'live' || a.state === 'unknown') continue
    const was = prev.states[agentKey(a)]
    const isJustEnded =
      was === undefined ? a.age_s !== null && a.age_s <= FRESH_S && !a.archived :
        was.state === 'live' || was.state === 'unknown' || a.runs > was.runs
    if (isJustEnded) out.push(endNotice(a))
  }
  if (prev.questions === null || !s.questionsOk) return out
  for (const [stage, q] of Object.entries(s.questions)) {
    const before = prev.questions[stage]
    if (q.ids === null || before === null) continue // unknown now or before: no baseline to diff against
    const known = new Set(before ?? [])
    const fresh = q.ids.filter(id => !known.has(id))
    for (const id of fresh.slice(0, MAX_NEW_QUESTIONS)) {
      const line = q.items.find(l => l === id || l.startsWith(`${id} `)) ?? id
      out.push(`? ${stage}: new question ${clip(oneLine(line), 80)}`)
    }
    if (fresh.length > MAX_NEW_QUESTIONS) out.push(`? ${stage}: ${fresh.length - MAX_NEW_QUESTIONS} more new questions`)
  }
  return out
}

/** At most `max` toasts per snapshot; the rest fold into one line. */
export function capToasts(texts: string[], max = 3): string[] {
  return texts.length <= max ? texts : [...texts.slice(0, max - 1), `+${texts.length - (max - 1)} more events (open /agent-top)`]
}

// ---------------------------------------------------------------- stage filter (client side)

export function inStages<T extends { stage: string }>(rows: readonly T[], stages: readonly string[]): T[] {
  return stages.length === 0 ? [...rows] : rows.filter(r => stages.includes(r.stage))
}

/** A stage of the snapshot with its `stage_info` row. */
export type StageRow = { stage: string; info: StageInfo }

/** The snapshot's stages (in the pane's stage filter) that have a `stage_info` row, in the CLI's order. */
function stageRows(s: Snapshot, stages: readonly string[]): StageRow[] {
  return inStages(s.stages.map(stage => ({ stage })), stages).flatMap(({ stage }) => {
    const info = s.stage_info[stage]
    return info ? [{ stage, info }] : []
  })
}

/**
 * The stages `close` is offered for: the CLI calls them idle, none of them is closed and none has a live agent. Longest
 * idle first (an unknown idle time last), then by name.
 */
export function idleStages(s: Snapshot, stages: readonly string[]): StageRow[] {
  return stageRows(s, stages)
    .filter(r => r.info.idle && r.info.closed === null && r.info.live === 0)
    .sort((a, b) => (b.info.idle_s ?? -1) - (a.info.idle_s ?? -1) || (a.stage < b.stage ? -1 : 1))
}

/** The closed stages this view shows (--all): the latest closed first. */
export function closedStages(s: Snapshot, stages: readonly string[]): StageRow[] {
  return stageRows(s, stages)
    .filter(r => r.info.closed !== null)
    .sort((a, b) => (b.info.closed?.at ?? '').localeCompare(a.info.closed?.at ?? '') || (a.stage < b.stage ? -1 : 1))
}

/** How many closed stages the default view leaves out (in the pane's stage filter). */
export const closedHiddenCount = (s: Snapshot, stages: readonly string[]): number =>
  inStages(s.closed_hidden.map(stage => ({ stage })), stages).length

export function countsOf(agents: readonly Agent[]): Counts {
  const c: Counts = { live: 0, done: 0, error: 0, dead: 0, unknown: 0, stopped: 0 }
  for (const a of agents) c[a.state] = (c[a.state] ?? 0) + 1
  return c
}

// ---------------------------------------------------------------- formatting

export const oneLine = (s: string): string => s.replace(/\s+/g, ' ').trim()

export function clip(s: string, w: number): string {
  const chars = Array.from(s)
  if (w <= 0) return ''
  if (chars.length <= w) return s
  return w === 1 ? '…' : chars.slice(0, w - 1).join('') + '…'
}

export const padEnd = (s: string, w: number): string => {
  const n = Array.from(s).length
  return n >= w ? s : s + ' '.repeat(w - n)
}

/** Word wrap to `width`, at most `maxLines` lines (the last one clipped with an ellipsis). */
export function wrapLines(text: string, width: number, maxLines = 2): string[] {
  const w = Math.max(1, width) // the caller's width holds: a floor above it overflows a narrow body
  const words = oneLine(text).split(' ').filter(Boolean)
  const lines: string[] = []
  let cur = ''
  for (const word of words) {
    const next = cur ? `${cur} ${word}` : word
    if (Array.from(next).length <= w) cur = next
    else {
      if (cur) lines.push(cur)
      cur = Array.from(word).length > w ? clip(word, w) : word
    }
  }
  if (cur) lines.push(cur)
  if (lines.length > maxLines) {
    const kept = lines.slice(0, maxLines)
    kept[maxLines - 1] = clip(kept[maxLines - 1] + ' …', w)
    return kept
  }
  return lines.length ? lines : ['']
}

export function fmtAge(s: number | null): string {
  if (s === null) return '—'
  const n = Math.max(0, Math.floor(s))
  if (n < 60) return `${n}s`
  if (n < 3600) return `${Math.floor(n / 60)}m`
  if (n < 86400) return `${Math.floor(n / 3600)}h${String(Math.floor((n % 3600) / 60)).padStart(2, '0')}`
  return `${Math.floor(n / 86400)}d`
}

export function fmtK(n: number | null): string {
  if (!n) return '—'
  if (n < 1000) return String(n)
  if (n < 1_000_000) return `${Math.round(n / 1000)}k`
  return `${(n / 1_000_000).toFixed(1)}M`
}

export const fmtCost = (c: number | null): string => (c === null ? '—' : `$${c.toFixed(2)}`)

export function modelLabel(a: Agent): string {
  const m = (a.model_id ?? a.model ?? '?').replace(/^claude-/, '').replace(/-\d{8}$/, '') || '?'
  const eff = ({ low: 'lo', medium: 'md', high: 'hi', xhigh: 'xh', max: 'mx' } as Record<string, string>)[a.effort ?? ''] ?? ''
  return eff ? `${m}/${eff}` : m
}

export function turnsLabel(a: Agent): string {
  const total = `${a.turns}${a.turns_approx ? '+' : ''}`
  return a.run_turns === a.turns ? total : `${a.run_turns}/${total}`
}

/** The agent's title without the trailing "(tag)" that `agent spawn` appends. */
export function taskText(a: Agent): string {
  let t = oneLine(a.title)
  if (a.tag && t.endsWith(`(${a.tag})`)) t = t.slice(0, t.length - a.tag.length - 2).trimEnd()
  return t || '—'
}

export const stateWord = (a: Agent): string => (a.quiet && a.state === 'live' ? 'quiet' : a.state === 'dead' ? 'died' : a.state)

export const glyphOf = (a: Agent): string => (a.state === 'live' ? '●' : a.state === 'done' ? '✓' : a.state === 'unknown' ? '?' : a.state === 'stopped' ? '■' : '✗')

/** The colour the console uses: live green, error/died red, quiet yellow, done dim (undefined = dim, no colour). */
export function colorOf(a: Agent): string | undefined {
  if (a.state === 'live') return a.quiet ? 'yellow' : 'green'
  if (a.state === 'unknown') return 'yellow'
  return a.state === 'done' || a.state === 'stopped' ? undefined : 'red'
}

export function actionText(a: Agent): string {
  if (!a.action) return ''
  const el = a.action.elapsed_s
  return `▸ ${a.action.tool}: ${oneLine(a.action.text)}` + (el >= 10 ? `  (${fmtAge(el)})` : '')
}

/** What the agent is doing now (live) or said last (finished), one line. */
export function nowText(a: Agent): string {
  if (a.alive) return a.action ? actionText(a) : a.last_text ? `⋯ ${oneLine(a.last_text)}` : '⋯ thinking'
  if (a.state === 'unknown') return a.expired ? 'unknown observation expired; no completion notice' : a.last_text ? oneLine(a.last_text) : 'no completion notice; state unknown'
  if (a.state === 'stopped') return oneLine(a.last_text || a.result?.text || 'stopped')
  if (a.result && (a.state === 'done' || a.state === 'error')) return oneLine(a.last_text || a.result.text || a.result.subtype)
  if (a.last_text) return oneLine(a.last_text)
  if (a.kind === 'subagent') return 'no completion notice: its parent session ended or it was stopped'
  return 'no process, no result: died or was killed'
}

export function feedPrefix(it: FeedItem): string {
  const t = it.at ? `${it.at} ` : ''
  return it.sub ? `${t}↳ ` : t
}

export function feedLine(it: FeedItem): { mark: string; text: string; color?: string; dim?: boolean; bold?: boolean } {
  switch (it.kind) {
    case 'thinking':
      return { mark: '✎', text: it.text, dim: true }
    case 'text':
      return { mark: '✎', text: it.text }
    case 'tool':
      return { mark: '▸', text: `${it.tool ?? 'tool'}: ${it.text}` }
    case 'result':
      return { mark: '  ◂', text: it.text, dim: true }
    case 'result_err':
      return { mark: '  ◂', text: it.text, color: 'red' }
    case 'input':
      return { mark: '→', text: it.text, color: 'yellow' }
    case 'end':
      return { mark: '■', text: `end of run: ${it.text}`, bold: true }
    default:
      return { mark: '⚙', text: it.text, dim: true }
  }
}

// ---------------------------------------------------------------- plan limits

export type LimitWindow = { label: string; percent: number; resetsAt: number | null }

const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

export function claudeWindows(s: Snapshot): LimitWindow[] {
  const w = s.limits?.info?.unifiedWindows
  if (!w) return []
  const out: LimitWindow[] = []
  for (const [key, label] of [['five_hour', '5h'], ['seven_day', '7d']] as const) {
    const one = w[key]
    if (one && finite(one.utilization)) out.push({ label, percent: Math.round(100 * one.utilization), resetsAt: finite(one.resetsAt) ? one.resetsAt : null })
  }
  return out
}

export function codexWindows(info: unknown): LimitWindow[] {
  if (!isObject(info)) return []
  const out: LimitWindow[] = []
  for (const key of ['primary', 'secondary']) {
    const w = info[key]
    if (!isObject(w) || !finite(w.used_percent) || w.used_percent < 0) continue
    const m = w.window_minutes
    let label = key
    if (finite(m) && m > 0) label = m % 1440 === 0 ? `${m / 1440}d` : m % 60 === 0 ? `${m / 60}h` : `${m}m`
    out.push({ label, percent: Math.round(w.used_percent * 10) / 10, resetsAt: finite(w.resets_at) ? w.resets_at : null })
  }
  return out
}

/** "10-09 14:30" in the local time zone. */
export function fmtReset(epochSeconds: number): string {
  const d = new Date(epochSeconds * 1000)
  const p = (n: number) => String(n).padStart(2, '0')
  return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`
}

export function limitLine(w: LimitWindow): string {
  return `${w.label}: ${w.percent}% used` + (w.resetsAt !== null ? `, resets ${fmtReset(w.resetsAt)}` : '')
}

/** The role's agent for `/agent-top <role>`: the live one first, else the freshest that is not archived. */
export function findByRole(agents: readonly Agent[], name: string, stages: readonly string[]): Agent | null {
  const rank = (a: Agent) => (a.archived ? 2 : 0) + (a.state === 'live' ? 0 : 1)
  const cands = agents.filter(a => (a.role === name || a.dir_name === name) && (stages.length === 0 || stages.includes(a.stage)))
  cands.sort((x, y) => rank(x) - rank(y) || (x.age_s ?? Infinity) - (y.age_s ?? Infinity))
  return cands[0] ?? null
}

// ---------------------------------------------------------------- drawing helpers (the view: hooks/agent-top-view.tsx)

/** A state's badge: the word on a fill. `fg` is the text colour on that fill; `isDim` draws the whole pill faint. */
export type Badge = { label: string; glyph: string; bg: string; fg: string; isDim: boolean }

export function badgeOf(a: Agent): Badge {
  if (a.state === 'live') {
    return a.quiet ? { label: 'QUIET', glyph: '◐', bg: 'yellow', fg: 'black', isDim: false } : { label: 'LIVE', glyph: '●', bg: 'green', fg: 'black', isDim: false }
  }
  if (a.state === 'done') return { label: 'DONE', glyph: '✓', bg: 'gray', fg: 'black', isDim: false }
  if (a.state === 'unknown') return { label: 'UNKNOWN', glyph: '?', bg: 'yellow', fg: 'black', isDim: false }
  if (a.state === 'stopped') return { label: 'STOPPED', glyph: '■', bg: 'gray', fg: 'black', isDim: false }
  return a.state === 'error'
    ? { label: 'FAIL', glyph: '✗', bg: 'red', fg: 'white', isDim: false }
    : { label: 'DIED', glyph: '✗', bg: 'red', fg: 'white', isDim: false }
}

/** The colour of a fill level (limits, context): below 60 % green, below 85 % yellow, else red. */
export const levelColor = (percent: number): string => (percent < 60 ? 'green' : percent < 85 ? 'yellow' : 'red')

/** A text bar of `width` cells for `percent`: the filled and the empty part (`█` / `░`). */
export function barCells(percent: number, width: number): { full: string; empty: string } {
  const w = Math.max(1, Math.floor(width))
  const p = Math.min(100, Math.max(0, Number.isFinite(percent) ? percent : 0))
  const n = p > 0 ? Math.max(1, Math.round((p / 100) * w)) : 0
  return { full: '█'.repeat(n), empty: '░'.repeat(w - n) }
}

/** How full the agent's context is, in percent; null when the size or the window is unknown. */
export function ctxPercent(a: Agent): number | null {
  if (!a.ctx_tokens || !a.ctx_window) return null
  return Math.min(100, Math.round((100 * a.ctx_tokens) / a.ctx_window))
}

const TAG_COLORS = ['cyan', 'magenta', 'blue', 'green', 'yellow', 'red'] as const

/** A journal tag's stable colour: a hash of the tag over six named colours. */
export function tagColor(tag: string): string {
  let h = 0
  for (const ch of tag) h = (h * 31 + (ch.codePointAt(0) ?? 0)) >>> 0
  return TAG_COLORS[h % TAG_COLORS.length] ?? 'cyan'
}

/** The colour of a journal line by its first word (display only): done green, fail/error red, review magenta, plan cyan. */
export function journalColor(text: string): string | undefined {
  const w = /^\s*([A-Za-z@-]+)/.exec(text)?.[1]?.toLowerCase() ?? ''
  if (/^(done|merged|green)$/.test(w)) return 'green'
  if (/^(fail|failed|error|blocked|stop)$/.test(w)) return 'red'
  if (/^(review|question|@hub)$/.test(w)) return 'magenta'
  if (/^(plan|start|started|wave)$/.test(w)) return 'cyan'
  return undefined
}

/**
 * The slice of a list a window of `budget` rows shows around the item at `cursor`: items have their own heights (an
 * agent two rows, a stage rule one). The cursor's item is always in, with one item of margin on each side where the
 * list has one, so the arrow key that leaves the window lands on a drawn row and the window follows it.
 */
export function windowAround(heights: readonly number[], cursor: number, budget: number): { start: number; end: number } {
  const n = heights.length
  if (n === 0) return { start: 0, end: 0 }
  const at = (i: number): number => heights[i] ?? 1
  const c = Math.min(n - 1, Math.max(0, cursor))
  let start = c
  let end = c + 1
  let used = at(c)
  // grow down first by one (the margin below), then alternate, preferring to keep the cursor away from both edges
  let isDown = true
  for (;;) {
    const canDown = end < n && used + at(end) <= budget
    const canUp = start > 0 && used + at(start - 1) <= budget
    if (!canDown && !canUp) break
    if ((isDown && canDown) || !canUp) {
      used += at(end)
      end += 1
    } else {
      start -= 1
      used += at(start)
    }
    isDown = !isDown
  }
  return { start, end }
}

/** "14:30" for a reset today, "Fri 09:00" within a week, else "10-09 14:30" (local time). */
export function fmtResetShort(epochSeconds: number, nowMs: number): string {
  const d = new Date(epochSeconds * 1000)
  const now = new Date(nowMs)
  const p = (n: number) => String(n).padStart(2, '0')
  const hm = `${p(d.getHours())}:${p(d.getMinutes())}`
  if (d.toDateString() === now.toDateString()) return hm
  if (d.getTime() > now.getTime() && d.getTime() - now.getTime() < 6 * 86400000) return `${['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][d.getDay()]} ${hm}`
  return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${hm}`
}

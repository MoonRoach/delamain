// The drawing of the agent-top pane (hooks/agent-top.tsx owns the data, the polling and the focus): pure tree builders,
// no `$`. One tree for every surface: only Box, Text and Button, which both the terminal and the desktop table hold.
//
//   dock (beside a fullscreen transcript): a rounded cyan frame; the card in its state's colour; Summary sections framed
//   inline (above the prompt, the engine draws the frame) and narrow bodies: no frames, sections under `──` rules
//
// Summary's first section lists the idle stages, each with a `close` Button (two presses: the module arms it, then runs it).
//
// The agent list is a window around the cursor that always fits the pane's body: then the arrows walk the rows (the
// engine scrolls only a drawing taller than the body), and `ui.focus` tells the module where the ring went.
import type { Elements, RenderChildren, RenderElement } from 'claude-code'

import {
  actionText,
  agentKey,
  badgeOf,
  barCells,
  claudeWindows,
  clip,
  closedHiddenCount,
  closedStages,
  codexWindows,
  colorOf,
  ctxPercent,
  feedLine,
  feedNote,
  fmtAge,
  fmtCost,
  fmtK,
  fmtResetShort,
  idleStages,
  journalColor,
  levelColor,
  modelLabel,
  nowText,
  oneLine,
  padEnd,
  tagColor,
  taskText,
  turnsLabel,
  windowAround,
  wrapLines,
} from './agent-top-model'
import type { Agent, Card, Counts, FeedItem, LimitWindow, Snapshot, StageRow, Target, View } from './agent-top-model'

export type Els = Pick<Elements['terminal'], 'Box' | 'Text' | 'Button'>

/** Below this many body columns the pane drops its frames and the list's meta column. */
export const COMPACT_COLS = 44

export type PaneModel = {
  view: View
  /** The pane body's columns and rows (`e.props.bodyColumns`, `e.props.scroll.bodyRows`). */
  cols: number
  rows: number
  placement: 'dock' | 'inline'
  shown: Snapshot | null
  /** `shown.agents` after the stage filter, in the CLI's order. */
  agents: Agent[]
  counts: Counts | null
  stages: string[]
  isAll: boolean
  error: string | null
  card: Card | null
  /** Why the last card call failed (cleared by the next good one); the feed area says so instead of "loading". */
  cardError: string | null
  target: Target | null
  /** agentKey of the list row the cursor is on (the focus ring's, or the last one it was on). */
  cursorKey: string | null
  /** The list row drawn `autoFocus`: the ring starts there when the pane takes the keyboard. */
  isAutoFocus: boolean
  nowMs: number
  /** The Stages section's close flow: the stage armed by a first press, the one being closed, the last result. */
  closing: { armed: string | null; running: string | null; note: { text: string; isError: boolean } | null }
}

export type PaneActions = {
  go: (view: View) => void
  refresh: () => void
  toggleAll: () => void
  open: (a: Agent) => void
  back: () => void
  /** Moves the cursor one agent past the window's edge (-1 up, 1 down): the `↑ more` / `↓ more` Buttons. */
  step: (dir: -1 | 1) => void
  /** A press of a stage's `close` Button: arms it, or (armed) runs the close. */
  close: (stage: string) => void
}

type Style = { color?: string; bg?: string; dim?: boolean; bold?: boolean; italic?: boolean; strike?: boolean }

// Raw colors and Box/Text background/border props are supported by the installed mod API.
// Keep semantic badges on the engine's named colors and Buttons on its own focus treatment.
const BRAND = { ice: '#77dce8', amber: '#eeb34e', navy: '#0b1422' } as const

const len = (s: string): number => Array.from(s).length

// Summary's Stages section shows this many rows of each kind and counts the rest
const MAX_IDLE_ROWS = 8
const MAX_CLOSED_ROWS = 5

/** The feed's kind column: a tool's name, else what the event is. */
function feedKind(it: FeedItem): string {
  if (it.sub && it.kind !== 'tool') return 'sub'
  switch (it.kind) {
    case 'tool':
      return it.tool ?? 'tool'
    case 'text':
      return 'says'
    case 'thinking':
      return 'thinks'
    case 'result':
      return 'output'
    case 'result_err':
      return 'error'
    case 'input':
      return 'input'
    case 'end':
      return 'end'
    case 'init':
      return 'start'
    default:
      return 'system'
  }
}
const padStart = (s: string, w: number): string => ' '.repeat(Math.max(0, w - len(s))) + s

/** The tree, and the keys of its Buttons in document order: the pane's focus ring walks them by position. */
/**
 * The tree; the keys of its Buttons in document order (the pane's focus ring walks them by position); and the agents
 * just outside the list's window, which the `↑ more` / `↓ more` Buttons stand for.
 */
export type Drawn = { tree: RenderElement; controls: string[]; edges: { prev: string | null; next: string | null } }

export function drawPane(els: Els, m: PaneModel, act: PaneActions): Drawn {
  const { Box, Text } = els
  const controls: string[] = []
  const edges: Drawn['edges'] = { prev: null, next: null }
  const Button = (p: Parameters<Els['Button']>[0]): RenderElement => {
    if (p.key) controls.push(p.key)
    return els.Button(p)
  }
  const isCompact = m.cols < COMPACT_COLS
  const isFramed = m.placement === 'dock' && !isCompact
  const w = Math.max(20, m.cols - (isFramed ? 4 : 0)) // the frame's two borders and paddingX 1
  const failed = m.counts ? m.counts.error + m.counts.dead : 0

  const t = (s: string, o: Style = {}): RenderChildren => (
    <Text
      wrap="truncate-end"
      color={o.color}
      backgroundColor={o.bg}
      dimColor={o.dim}
      bold={o.bold}
      italic={o.italic}
      strikethrough={o.strike}
    >
      {s}
    </Text>
  )
  const row = (key: string | undefined, kids: RenderChildren[], between = false): RenderChildren => (
    <Box key={key} flexDirection="row" justifyContent={between ? 'space-between' : 'flex-start'}>
      {kids}
    </Box>
  )
  const rule = (label: string, width: number, right = ''): RenderChildren => {
    const head = label ? `── ${clip(label, Math.max(1, width - 8 - len(right)))} ` : ''
    const tail = right ? ` ${right} ──` : ''
    // Unbacked labels inherit the host foreground at full strength on light and dark themes.
    return t(head + '─'.repeat(Math.max(2, width - len(head) - len(tail))) + tail)
  }
  const pill = (s: string, bg: string, fg = 'black', dim = false): RenderChildren => t(` ${s} `, { bg, color: fg, bold: true, dim })

  // ---------------------------------------------------------------- header: title, counters, stage and time
  // The brand drops first, then the title; counters keep their space at wide widths.
  const sp = w < 40 ? '' : ' '
  const counters: { text: string; node: RenderChildren }[] = []
  const live = m.counts?.live ?? 0
  const done = m.counts?.done ?? 0
  counters.push({ text: ` ●${sp}${live} `, node: live ? pill(`●${sp}${live}`, 'green') : t(` ●${sp}0 `, { dim: true }) })
  counters.push({ text: ` ✓${sp}${done} `, node: t(` ✓${sp}${done} `, { dim: true }) })
  counters.push({ text: ` ✗${sp}${failed} `, node: failed ? pill(`✗${sp}${failed}`, 'red', 'white') : t(` ✗${sp}0 `, { dim: true }) })
  const titleRoom = w - 1 - counters.reduce((n, c) => n + len(c.text), 0)
  const title = ['Delamain · agent-top', 'agent-top', '◆'].find(s => len(s) <= titleRoom) ?? '◆'
  const leftLen = len(title) + 1 + counters.reduce((n, c) => n + len(c.text), 0)
  const where = `${m.stages.length ? m.stages.join('/') : 'all stages'}${m.shown ? ` · ${m.shown.generated_at.slice(11, 16)}` : ''}`
  const room = w - leftLen - 1
  const header = row(
    'header',
    [
      <Box flexDirection="row">
        {t(title, { color: BRAND.ice, bg: BRAND.navy, bold: true })}
        {t(' ')}
        {counters.map(c => c.node)}
      </Box>,
      room >= 6 ? t(clip(where, room), { dim: true }) : null,
    ],
    true,
  )

  // ---------------------------------------------------------------- tabs: the active one filled, the rest buttons
  // the active tab stays a Button (on a filled Box): a focused element that vanished would leave the ring nowhere
  const tab = (key: string, label: string, hotkey: string, view: View, isActive: boolean): RenderChildren =>
    isActive ? (
      <Box key={`tab:${view}`} backgroundColor={BRAND.ice}>
        <Button key={key} label={` ${label} `} plain onPress={() => act.go(view)} />
      </Box>
    ) : (
      <Button key={key} label={label} hotkey={hotkey} plain dimColor onPress={() => act.go(view)} />
    )
  // narrower: `↻` for refresh, then short tab names, then the two groups on two lines
  const isNarrow = w < 52
  const names = w < 41 ? { list: 'Agents', journal: 'Log', summary: 'Sum' } : { list: 'Agents', journal: 'Journal', summary: 'Summary' }
  const isActive = (v: View) => m.view === v || (v === 'list' && m.view === 'card')
  const tabW = (['list', 'journal', 'summary'] as const).reduce((n, v) => n + len(names[v]) + (isActive(v) ? 2 : 3), 2)
  const toggleLabel = m.isAll ? 'recent' : 'old'
  const hasToggle = m.view === 'list' || m.view === 'summary' // `l`: closed stages and old agents are only in --all
  const rightW = 3 + (isNarrow ? 1 : 7) + (hasToggle ? 1 + 3 + len(toggleLabel) : 0)
  const isTabsWrapped = tabW + 1 + rightW > w
  const tabs = (
    <Box key="tabs" flexDirection={isTabsWrapped ? 'column' : 'row'} justifyContent="space-between">
      <Box flexDirection="row" columnGap={1}>
        {tab('view-agents', names.list, 'a', 'list', isActive('list'))}
        {tab('view-journal', names.journal, 'j', 'journal', isActive('journal'))}
        {tab('view-summary', names.summary, 's', 'summary', isActive('summary'))}
      </Box>
      <Box flexDirection="row" columnGap={1} justifyContent="flex-end">
        <Button key="refresh" label={isNarrow ? '↻' : 'refresh'} hotkey="r" plain dimColor onPress={act.refresh} />
        {hasToggle ? <Button key="toggle-all" label={toggleLabel} hotkey="l" plain dimColor onPress={act.toggleAll} /> : null}
      </Box>
    </Box>
  )
  const errorLine = m.error ? row('error', [pill('!', 'yellow'), t(' '), t(clip(m.error, w - 4), { color: 'yellow' })]) : null
  const topRule = isFramed ? null : rule('', w)

  // rows the view may fill: the body less the frame, the header, the tabs, the error and the rule under the tabs
  const chrome = (isFramed ? 2 : 0) + (isTabsWrapped ? 3 : 2) + (errorLine ? 1 : 0) + (topRule ? 1 : 0)
  const budget = Math.max(3, m.rows - chrome)

  let body: RenderChildren[]
  if (m.view === 'list') body = listView()
  else if (m.view === 'card') body = cardView()
  else if (m.view === 'journal') body = journalView()
  else body = summaryView()

  const content = (
    <Box flexDirection="column">
      {header}
      {tabs}
      {topRule}
      {errorLine}
      {body}
    </Box>
  )
  const tree = isFramed ? (
    <Box key="frame" flexDirection="column" borderStyle="round" borderColor={BRAND.ice} paddingX={1}>
      {content}
    </Box>
  ) : (
    content
  )
  return { tree, controls, edges }

  // ---------------------------------------------------------------- Agents: a window of rows around the cursor
  // Above and below the window sit `↑ N more` / `↓ N more` Buttons: the ring always has a drawn neighbour on each side,
  // and landing on one moves the cursor one agent past the window's edge (the module's ui.focus hook).
  function listView(): RenderChildren[] {
    if (!m.shown) return [t(m.error ? '' : 'loading agents…', { dim: true })]
    if (m.agents.length === 0) {
      return [t(`no agents${m.stages.length ? ` in ${m.stages.join(', ')}` : ''}${m.isAll ? '' : ' (l: include finished agents older than 24 h)'}`, { dim: true })]
    }
    const isMulti = new Set(m.agents.map(a => a.stage)).size > 1
    // items: a stage rule before the first agent of each stage (when several), then the agent
    type Item = { kind: 'rule'; stage: string } | { kind: 'agent'; agent: Agent; index: number }
    const items: Item[] = []
    let lastStage = ''
    m.agents.forEach((a, index) => {
      if (isMulti && a.stage !== lastStage) items.push({ kind: 'rule', stage: a.stage })
      lastStage = a.stage
      items.push({ kind: 'agent', agent: a, index })
    })
    const cursorIndex = Math.max(0, m.agents.findIndex(a => agentKey(a) === m.cursorKey))
    const cursorItem = items.findIndex(it => it.kind === 'agent' && it.index === cursorIndex)
    // a low pane gives each agent one line, so that its window still holds several
    const perAgent = budget - 1 >= 8 ? 2 : 1
    const heights = items.map(it => (it.kind === 'agent' ? perAgent : 1))
    let win = windowAround(heights, cursorItem, budget - 1) // the footer
    if (win.start > 0) win = windowAround(heights, cursorItem, budget - 2) // and the `↑ more` row
    const shownItems = items.slice(win.start, win.end)
    const agentsShown = shownItems.flatMap(it => (it.kind === 'agent' ? [it.index] : []))
    const first = agentsShown[0] ?? 0
    const last = agentsShown[agentsShown.length - 1] ?? 0
    const above = first
    const below = m.agents.length - 1 - last
    edges.prev = above ? agentKey(m.agents[first - 1] as Agent) : null
    edges.next = below ? agentKey(m.agents[last + 1] as Agent) : null

    // widths: the badge shrinks to its glyph, then the age goes, then the task gives way to the role
    const isTight = w < 34
    const badgeW = isTight ? 3 : 7
    const lead = 2 + badgeW + 1 // cursor, badge, gap
    const ageW = w >= 32 ? 4 : 0
    const avail = w - lead - 3 - 1 - (ageW ? ageW + 1 : 0) // the hotkey's `1: ` (or its blank) and the gap after the role
    const roleWant = Math.min(isCompact ? 10 : 16, Math.max(6, ...m.agents.map(a => len(a.role))))
    let roleW = Math.min(roleWant, Math.max(3, avail - 6))
    let taskW = avail - roleW
    if (taskW < 3) {
      roleW = Math.max(1, avail)
      taskW = 0
    }

    const out: RenderChildren[] = []
    if (above) out.push(row('more-up-row', [<Button key="more-up" label={`↑ ${above} more`} plain dimColor onPress={() => act.step(-1)} />]))
    let n = 0
    for (const it of shownItems) {
      if (it.kind === 'rule') {
        out.push(rule(it.stage, w))
        continue
      }
      const a = it.agent
      const key = agentKey(a)
      const isCursor = it.index === cursorIndex
      const b = badgeOf(a)
      const isDone = a.state === 'done'
      const hotkey = n < 9 ? String(n + 1) : undefined
      n += 1
      out.push(
        row(`row:${key}`, [
          t(isCursor ? '❯ ' : '  ', { color: BRAND.amber, bold: true }),
          pill(isTight ? b.glyph : padEnd(b.label, 5), b.bg, b.fg, b.isDim),
          t(' '),
          <Button
            key={`open:${key}`}
            label={padEnd(clip(a.role, roleW), roleW)}
            plain
            {...(hotkey ? { hotkey } : {})}
            {...(isCursor && m.isAutoFocus ? { autoFocus: true as const } : {})}
            onPress={() => act.open(a)}
          />,
          t(hotkey ? ' ' : '    '),
          taskW ? t(padEnd(clip(taskText(a), taskW), taskW), { dim: isDone, bold: isCursor && !isDone }) : null,
          ageW ? t(' ' + padStart(fmtAge(a.age_s), ageW), { dim: true }) : null,
        ]),
      )
      if (perAgent === 1) continue
      // line 2: what it does now, and on the right model · turns · context
      const pct = ctxPercent(a)
      const meta = `${modelLabel(a)} · ${turnsLabel(a)}t · ${fmtK(a.ctx_tokens)}`
      const metaLen = len(meta) + (pct !== null ? len(` ${pct}%`) : 0)
      const hasMeta = !isCompact && w - lead - metaLen - 1 >= 16
      const nowW = Math.max(1, w - lead - (hasMeta ? metaLen + 1 : 0))
      const nowStyle: Style = a.alive && a.action ? { color: 'green' } : a.state === 'error' ? { color: 'red' } : { dim: true }
      out.push(
        row(
          `now:${key}`,
          [
            <Box flexDirection="row">
              {t(' '.repeat(lead))}
              {t(clip(nowText(a), nowW), nowStyle)}
            </Box>,
            hasMeta ? (
              <Box flexDirection="row">
                {t(meta, { dim: true })}
                {pct !== null ? t(` ${pct}%`, { color: levelColor(pct), dim: pct < 60 }) : null}
              </Box>
            ) : null,
          ],
          true,
        ),
      )
    }
    const down = below ? `↓ ${below} more` : ''
    const keys = '↑↓ select · ⏎ open'
    out.push(
      row(
        'footer',
        [
          down ? <Button key="more-down" label={down} plain dimColor onPress={() => act.step(1)} /> : t(''),
          w - len(down) - 2 >= len(keys) ? t(keys, { dim: true }) : null,
        ],
        true,
      ),
    )
    return out
  }

  // ---------------------------------------------------------------- the agent card and its feed
  function cardView(): RenderChildren[] {
    const tg = m.target
    const a = tg ? (m.card?.agent ?? m.agents.find(x => x.stage === tg.stage && x.dir_name === tg.dirName) ?? null) : null
    const backButton = (
      <Box key="card-actions" flexDirection="row" columnGap={2}>
        <Button key="back" label="‹ Back" hotkey="b" autoFocus onPress={act.back} />
      </Box>
    )
    if (!tg || !a) {
      if (tg && m.cardError !== null) return [...noteRows(feedNote(null, m.cardError)), backButton]
      return [t(m.error ? '' : tg ? `loading ${tg.role}…` : 'no agent selected (Back, then pick one)', { dim: true }), backButton]
    }
    const b = badgeOf(a)
    const stateColor = colorOf(a) ?? 'gray'
    const cw = isFramed ? w - 4 : w // inside the card's own frame
    const lines: RenderChildren[] = []

    // the title line: badge, role, pid and age; the stage on the right
    const who = `${a.alive && a.pid ? ` · pid ${a.pid}` : ''} · ${fmtAge(a.age_s)} ago`
    const stage = cw >= 40 ? clip(a.stage, 16) : ''
    const titleRoom = cw - len(b.label) - 2 - 1 - (stage ? len(stage) + 1 : 0)
    const roleShown = clip(a.role, Math.max(3, Math.min(len(a.role), titleRoom - Math.min(len(who), 8))))
    lines.push(
      row(
        'card-title',
        [
          <Box flexDirection="row">
            {pill(b.label, b.bg, b.fg, b.isDim)}
            {t(' ')}
            {t(roleShown, { bold: true, color: stateColor === 'gray' ? undefined : stateColor })}
            {t(clip(who, Math.max(0, titleRoom - len(roleShown))), { dim: true })}
          </Box>,
          stage ? t(stage, { dim: true }) : null,
        ],
        true,
      ),
    )

    // label / value pairs, two columns when there is room
    const L = 9
    const pair = (label: string, value: RenderChildren, valueLen: number): { node: RenderChildren; len: number } => ({
      node: (
        <Box flexDirection="row">
          {t(padEnd(label, L), { dim: true })}
          {value}
        </Box>
      ),
      len: L + valueLen,
    })
    const val = (s: string, o: Style = { bold: true }) => {
      const v = clip(s, Math.max(1, cw - L))
      return { node: t(v, o), len: len(v) }
    }
    const pct = ctxPercent(a)
    const ctxRow = (): RenderChildren => {
      const tokens = `${fmtK(a.ctx_tokens)}${a.ctx_window ? ` / ${fmtK(a.ctx_window)}` : ''}`
      if (pct === null) return pair('Context', t(clip(tokens, cw - L), { bold: true }), 0).node
      const pctW = len(` ${pct}%`)
      const hasTokens = cw - L - 4 - pctW >= len(tokens) + 1
      const bw = Math.max(4, Math.min(30, cw - L - pctW - (hasTokens ? len(tokens) + 1 : 0)))
      const bar = barCells(pct, bw)
      return pair(
        'Context',
        <Box flexDirection="row">
          {t(bar.full, { color: levelColor(pct) })}
          {t(bar.empty, { dim: true })}
          {t(` ${pct}%`, { color: levelColor(pct), bold: true })}
          {hasTokens ? t(` ${tokens}`, { dim: true }) : null}
        </Box>,
        0,
      ).node
    }
    const turns = `${turnsLabel(a)}${a.sub_turns ? `  (+${a.sub_turns} sub)` : ''}`
    type Cell = { label: string; v: { node: RenderChildren; len: number }; key: string }
    const cells: Cell[] = [
      { label: 'Model', v: val(modelLabel(a)), key: 'card-model' },
      { label: 'Turns', v: val(turns), key: 'card-turns' },
      { label: 'Cost', v: val(fmtCost(a.cost_usd)), key: 'card-cost' },
      { label: 'Runs', v: val(String(a.runs), {}), key: 'card-runs' },
      { label: 'Tag', v: val(a.tag || '—', {}), key: 'card-tag' },
    ]
    const colW = Math.floor(cw / 2)
    const isTwo = cw >= 56 && cells.every(c => L + c.v.len < colW)
    const grid: Cell[][] = isTwo ? [cells.slice(0, 2), cells.slice(2, 4), cells.slice(4)] : cells.map(c => [c])
    grid.forEach((cs, i) => {
      const [l, r] = cs
      if (!l) return
      const left = pair(l.label, l.v.node, l.v.len)
      lines.push(
        <Box key={l.key} flexDirection="row">
          {left.node}
          {r ? t(' '.repeat(Math.max(1, colW - left.len))) : null}
          {r ? pair(r.label, r.v.node, r.v.len).node : null}
        </Box>,
      )
      if (i === 0) lines.push(<Box key="card-context" flexDirection="row">{ctxRow()}</Box>)
    })
    const task = taskText(a)
    wrapLines(task, cw - L, 2).forEach((l, i) => lines.push(row(i === 0 ? 'card-task' : undefined, [t(padEnd(i === 0 ? 'Task' : '', L), { dim: true }), t(l)])))
    if (a.action) lines.push(row('card-now', [t(padEnd('Now', L), { dim: true }), t(clip(actionText(a), cw - L), { color: 'green' })]))
    else if (a.alive) lines.push(row('card-now', [t(padEnd('Now', L), { dim: true }), t('⋯ waiting for the model', { dim: true })]))
    if (a.result && (a.state === 'done' || a.state === 'error')) {
      const isErr = a.result.is_error || a.state === 'error'
      const head = clip(`${isErr ? '✗' : '✓'} ${a.result.subtype}${a.result.is_error ? ', error' : ''}`, Math.max(3, cw - L - 2))
      const textW = cw - L - len(head) - 3
      lines.push(
        row('card-result', [
          t(padEnd('Result', L), { dim: true }),
          pill(head, isErr ? 'red' : 'green', isErr ? 'white' : 'black'),
          t(' '),
          t(clip(a.result.text, Math.max(0, textW)), { color: isErr ? 'red' : undefined, dim: !isErr }),
        ]),
      )
    }
    if (a.kind === 'subagent' || a.kind === 'session') {
      const what = a.kind === 'subagent' ? `sub-agent of ${a.parent ?? '?'}` : 'native Codex session'
      lines.push(row('card-kind', [pill('READ-ONLY', 'gray'), t(' '), t(clip(what, Math.max(0, cw - 12)), { dim: true })]))
    }
    if (a.unread.length) lines.push(row('card-unread', [t(clip(`✉ ${a.unread.length} unread in the inbox`, cw), { color: 'yellow', bold: true })]))
    if (a.state === 'dead') lines.push(row('card-dead', [t(clip('no process, no result: died or was killed', cw), { color: 'red' })]))

    const cardNode = isFramed ? (
      <Box key="card" flexDirection="column" borderStyle="round" borderColor={stateColor} borderDimColor={a.state === 'done'} paddingX={1}>
        {lines}
      </Box>
    ) : (
      <Box key="card" flexDirection="column">
        {lines}
      </Box>
    )
    const cardRows = lines.length + (isFramed ? 2 : 0)

    // the feed: fixed time and tool columns, the newest at the bottom, as many as fit
    const feedRoom = Math.max(2, budget - cardRows - 2) // its rule and the Back row
    const feedRows: RenderChildren[] = []
    const items = m.card?.feed ?? []
    // every row: its time (`--:--:--` where the log has none: a run's start and end), the kind with its glyph, the text
    const timeW = 8
    const toolW = isCompact ? 7 : 10
    const textW = Math.max(1, w - timeW - 1 - toolW - 1) // never wider than the body: at 24 columns 7 cells
    items.forEach((it, i) => {
      const f = feedLine(it)
      const isTool = it.kind === 'tool'
      const isResult = it.kind === 'result' || it.kind === 'result_err'
      const col = `${it.sub ? '⤷' : f.mark.trim()} ${feedKind(it)}`
      const text = isTool ? it.text : f.text.replace(/^end of run: /, '')
      const style: Style = it.sub
        ? { italic: true, dim: true }
        : { color: f.color, dim: f.dim, bold: f.bold }
      const colStyle: Style = isTool ? { bold: true } : it.kind === 'result_err' ? { color: 'red' } : it.kind === 'end' ? { bold: true } : { dim: true }
      wrapLines(text, textW, isResult ? 1 : 2).forEach((l, j) => {
        feedRows.push(
          <Box key={j === 0 ? `feed:${i}` : undefined} flexDirection="row">
            {t(j === 0 ? padEnd(it.at ? it.at.slice(0, timeW) : '--:--:--', timeW) : ' '.repeat(timeW), { dim: true })}
            {t(' ')}
            {t(padEnd(j === 0 ? clip(col, toolW) : '', toolW), colStyle)}
            {t(' ')}
            {t(l, style)}
          </Box>,
        )
      })
    })
    // no rows: still loading, the call failed, or an empty log; rows and a failed refresh: the rows, the failure under them
    const note = feedRows.length === 0 || m.cardError !== null ? noteRows(feedNote(m.card, m.cardError)) : []
    const feedTail = feedRows.slice(-Math.max(1, feedRoom - note.length))
    return [cardNode, rule('Feed', w, items.length ? `last ${items.length}` : ''), ...feedTail, ...note, backButton]
  }

  /** The feed's note (feedNote), wrapped to the body: a warning in yellow, else dim. */
  function noteRows(note: { text: string; isError: boolean }): RenderChildren[] {
    return wrapLines(note.text, w, 2).map((l, i) => row(i === 0 ? 'feed-note' : undefined, [t(l, note.isError ? { color: 'yellow' } : { dim: true })]))
  }

  // ---------------------------------------------------------------- Journal: time, tag pill, the line coloured by its first word
  function journalView(): RenderChildren[] {
    const lines = m.shown ? (m.stages.length ? m.shown.journal_tail.filter(l => m.stages.includes(l.stage)) : m.shown.journal_tail) : []
    if (lines.length === 0) return [t(m.shown ? 'the journal is empty' : 'loading…', { dim: true })]
    const isMulti = new Set(lines.map(l => l.stage)).size > 1
    const tagW = Math.max(3, Math.min(isCompact ? 8 : 12, w - 17, Math.max(4, ...lines.map(l => len(l.tag)))))
    const lead = 5 + 1 + tagW + 2 + 1
    const out: RenderChildren[] = []
    let lastStage = ''
    lines.forEach((l, i) => {
      if (isMulti && l.stage !== lastStage) out.push(rule(l.stage, w))
      lastStage = l.stage
      const color = journalColor(l.text)
      wrapLines(l.text, w - lead, 2).forEach((txt, j) => {
        out.push(
          j === 0 ? (
            <Box key={`journal:${i}`} flexDirection="row">
              {t(padEnd(l.time.slice(0, 5), 5), { dim: true })}
              {t(' ')}
              {pill(padEnd(clip(l.tag, tagW), tagW), tagColor(l.tag))}
              {t(' ')}
              {t(txt, { color })}
            </Box>
          ) : (
            <Box flexDirection="row">
              {t(' '.repeat(lead))}
              {t(txt, { color })}
            </Box>
          ),
        )
      })
    })
    return out.slice(-budget)
  }

  // ---------------------------------------------------------------- Summary: stages, plan limits, owner questions, locks
  function summaryView(): RenderChildren[] {
    const s = m.shown
    if (!s) return [t('loading…', { dim: true })]
    const sw = isFramed ? w - 4 : w // inside a section's frame
    const section = (key: string, label: string, kids: RenderChildren[]): RenderChildren[] =>
      isFramed
        ? [
            <Box key={key} flexDirection="column" borderStyle="round" borderColor={BRAND.ice} borderDimColor paddingX={1}>
              {t(label, { color: BRAND.ice, bg: BRAND.navy, bold: true })}
              {kids}
            </Box>,
          ]
        : [rule(label, w), ...kids]

    // ---- stages: the idle ones with a two-press `close` (the module arms, then runs it); under --all the closed ones, dim
    const stageRows: RenderChildren[] = []
    const idle = idleStages(s, m.stages)
    const closed = closedStages(s, m.stages)
    const shownIdle = idle.slice(0, MAX_IDLE_ROWS)
    const shownClosed = closed.slice(0, MAX_CLOSED_ROWS)
    const { armed, running, note } = m.closing
    const stageW = Math.min(16, Math.max(6, ...shownIdle.map(r => len(r.stage)), ...shownClosed.map(r => len(r.stage))))
    const buttonW = len('confirm close') + 4 // the widest label: the rest of the row does not move with the press
    const isStacked = sw < 40 // the Button under the name when the row has no room beside it
    const leftRoom = sw - buttonW - 1
    const ageOf = (r: StageRow): string => (sw < 28 ? '' : 'idle ') + fmtAge(r.info.idle_s)
    const ageW = Math.max(0, ...shownIdle.map(r => len(ageOf(r))))
    const closeButton = (stage: string): RenderChildren => {
      const label = running === stage ? 'closing…' : armed === stage ? 'confirm close' : 'close'
      // armed: red and bold, the press that closes it; the Button's label still names it
      return (
        <Button key={`close:${stage}`} label={label} onPress={() => act.close(stage)}>
          {label === 'confirm close' ? t(label, { color: 'red', bold: true }) : t(label, { dim: running === stage })}
        </Button>
      )
    }
    if (note) {
      wrapLines(`${note.isError ? '✗' : '✓'} ${note.text}`, sw, 2).forEach((l, i) =>
        stageRows.push(row(i === 0 ? 'close-note' : undefined, [t(l, { color: note.isError ? 'red' : 'green' })])),
      )
    }
    for (const r of shownIdle) {
      const age = ageOf(r)
      // beside the Button: name, age, and the goal when 8 or more cells are left for it; stacked: name and age, then the Button
      const nameW = Math.max(3, Math.min(stageW, (isStacked ? sw : leftRoom) - ageW - 2))
      const goalW = isStacked ? 0 : leftRoom - nameW - 2 - ageW - 2
      const left = (
        <Box flexDirection="row">
          {t(padEnd(clip(r.stage, nameW), nameW), { bold: true })}
          {t('  ')}
          {t(padEnd(age, ageW))}
          {goalW >= 8 && r.info.goal ? t('  ' + clip(oneLine(r.info.goal), goalW), { dim: true }) : null}
        </Box>
      )
      if (isStacked) {
        stageRows.push(row(`stage:${r.stage}`, [left]), row(`act:${r.stage}`, [t('  '), closeButton(r.stage)]))
      } else stageRows.push(row(`stage:${r.stage}`, [left, closeButton(r.stage)], true))
      if (armed === r.stage) {
        const hint = `press again to close ${r.stage}: its hub's locks are released, roles retired, a background hub stopped`
        wrapLines(hint, sw, 3).forEach((l, i) => stageRows.push(row(i === 0 ? 'close-hint' : undefined, [t(l, { dim: true })])))
      }
    }
    if (idle.length > shownIdle.length) stageRows.push(t(`+${idle.length - shownIdle.length} more idle stages`, { dim: true }))
    if (idle.length === 0) {
      const hidden = closedHiddenCount(s, m.stages)
      const none = hidden ? `no idle stages · ${hidden} closed hidden (l shows them)` : 'no idle stages'
      wrapLines(none, sw, 2).forEach(l => stageRows.push(t(l, { dim: true })))
    }
    for (const r of shownClosed) {
      const room = sw - len(' closed ') - 1 // the pill and a gap
      const nameW = Math.max(3, Math.min(stageW, room))
      const whyW = room - nameW - 2
      stageRows.push(
        row(`closed:${r.stage}`, [
          pill('closed', 'gray'),
          t(' '),
          t(whyW >= 6 ? padEnd(clip(r.stage, nameW), nameW) : clip(r.stage, nameW), { dim: true }),
          whyW >= 6 && r.info.closed?.why ? t('  ' + clip(oneLine(r.info.closed.why), whyW), { dim: true }) : null,
        ]),
      )
    }
    if (closed.length > shownClosed.length) stageRows.push(t(`+${closed.length - shownClosed.length} more closed`, { dim: true }))

    // ---- plan limits: one bar per window
    const limitRows: RenderChildren[] = []
    // narrow: the bar shrinks to 6 cells, then the reset time goes
    const provW = sw < 44 ? 7 : 8
    const limitRow = (key: string, provider: string, lw: LimitWindow, note = ''): RenderChildren => {
      const pct = Math.round(lw.percent)
      let reset = lw.resetsAt !== null ? `  ↻ ${fmtResetShort(lw.resetsAt, m.nowMs)}` : ''
      if (sw - provW - 4 - 6 - len(reset) < 6) reset = ''
      const barW = Math.max(4, Math.min(20, sw - provW - 4 - 6 - len(reset)))
      const cells = barCells(pct, barW)
      const used = provW + 4 + barW + 6 + len(reset)
      return row(
        key,
        [
          <Box flexDirection="row">
            {t(padEnd(clip(provider, provW - 1), provW), { bold: true })}
            {t(padEnd(lw.label, 4), { dim: true })}
            {t(cells.full, { color: levelColor(pct) })}
            {t(cells.empty, { dim: true })}
            {t(padStart(`${pct}%`, 6), { color: levelColor(pct), bold: true })}
            {t(reset, { dim: true })}
          </Box>,
          note && sw - used - 2 >= len(note) ? t(note, { dim: true }) : null,
        ],
        true,
      )
    }
    claudeWindows(s).forEach((lw, i) => limitRows.push(limitRow(`limit:claude:${lw.label}`, i === 0 ? 'Claude' : '', lw)))
    for (const [id, rec] of Object.entries(s.codex_limits).sort(([x], [y]) => (x < y ? -1 : 1))) {
      const name = id === 'codex' ? 'Codex' : `Codex ${id}`
      const age = `·${fmtAge(Math.max(0, s.fetchedAt / 1000 - rec.seen_at))} ago`
      codexWindows(rec.info).forEach((lw, i) => limitRows.push(limitRow(`limit:${id}:${lw.label}`, i === 0 ? name : '', lw, i === 0 ? age : '')))
    }
    if (limitRows.length === 0) limitRows.push(t('no limit data yet', { dim: true }))

    // ---- owner questions: per stage, open count and an OVERDUE pill; the first items
    const qRows: RenderChildren[] = []
    const qs = Object.entries(s.questions).filter(([st]) => m.stages.length === 0 || m.stages.includes(st))
    const stW = Math.min(16, Math.max(6, ...qs.map(([st]) => len(st))))
    for (const [st, q] of qs) {
      const open = `  ${q.open} open  `
      const overdue = q.overdue ? (sw < 36 ? `⚠ ${q.overdue}` : `OVERDUE ${q.overdue}`) : ''
      const stShown = Math.max(3, Math.min(stW, sw - len(open) - (overdue ? len(overdue) + 2 : 0)))
      qRows.push(
        row(`q:${st}`, [
          t(padEnd(clip(st, stShown), stShown), { bold: true }),
          t(open, { dim: q.open === 0 }),
          overdue ? pill(overdue, 'red', 'white') : null,
        ]),
      )
      for (const item of q.items.slice(0, 8)) qRows.push(t(clip(`  ${item}`, sw), { dim: true }))
    }
    if (qRows.length === 0) qRows.push(t(s.questionsOk ? 'no open questions' : 'no data (ask is unavailable or there is no register)', { dim: true }))

    // ---- locks: kind pill, repo, until, owner: why; an expired one struck through
    const lockRows: RenderChildren[] = []
    s.locks.forEach((lk, i) => {
      const until = lk.until.slice(5, 16).replace('T', ' ')
      const rest = ` ${lk.repo}  until ${until}  ${lk.owner_name}: ${lk.why}`
      const kind = clip(lk.kind, Math.max(3, Math.floor(sw / 2)))
      lockRows.push(
        row(`lock:${i}`, [
          pill(kind, lk.active ? 'magenta' : 'gray', lk.active ? 'white' : 'black', !lk.active),
          t(clip(rest, Math.max(0, sw - len(kind) - 2)), { dim: !lk.active, strike: !lk.active }),
        ]),
      )
    })
    if (lockRows.length === 0) lockRows.push(t('no locks', { dim: true }))

    return [...section('sum-stages', 'Stages', stageRows), ...section('sum-limits', 'Plan limits', limitRows), ...section('sum-questions', 'Owner questions', qRows), ...section('sum-locks', 'Locks', lockRows)]
  }
}

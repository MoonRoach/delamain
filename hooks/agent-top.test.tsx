// Tests of the agent-top mod (run: `claude plugin test hooks`, a Claude Code with mods). `process.run` is stubbed with
// fixture JSON of `agent-top --json`; nothing reads real agents. Each test loads the module afresh.
import { expect, mock, test } from 'claude-code/testing'
import type { Engine, TestBody } from 'claude-code/testing'

type On = Parameters<TestBody>[1]

import {
  barCells,
  badgeOf,
  capToasts,
  closedHiddenCount,
  closeTarget,
  closedStages,
  colorOf,
  countsOf,
  ctxPercent,
  glyphOf,
  idleStages,
  isOwnCommand,
  journalColor,
  levelColor,
  notices,
  nowText,
  onceArgs,
  parseArgs,
  parseSnapshot,
  planRun,
  remember,
  ringTarget,
  inStages,
  normPath,
  parseSelector,
  splitWords,
  stageCols,
  stageMatches,
  stageSelector,
  statusText,
  tagColor,
  taskText,
  windowAround,
} from './agent-top-model'

// The plugin's name (plugin.json). The dev copy is checked by running this file there with this line set to 'agent-top-dev'.
const PLUGIN: string = 'delamain'
const BIN = /\/bin\/agent-top$/

type Row = Record<string, unknown>

// typed answers of the stubbed engine calls
const REGISTERED = () => ({ value: { command: 'agent-top' } })
const DONE_VOID = () => ({ value: undefined })
const ran = (stdout: string, exitCode = 0, stderr = '') => ({ value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false } })
const run = ($: Engine, args = '', command = 'agent-top') =>
  $.command.run({ command, args, origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 120 } })

const agent = (o: Row = {}): Row => ({
  kind: 'headless', parent: null, engine: 'claude', stage: 'stage-a', role: 'worker', dir_name: 'worker', tag: 'w-1',
  title: 'Build the thing (w-1)', model: 'sonnet', model_id: 'sonnet-5-5', effort: 'high', state: 'live', quiet: false,
  alive: true, pid: 123, age_s: 4, runs: 1, turns: 7, run_turns: 7, turns_approx: false, sub_turns: 0, ctx_tokens: 52000,
  cost_usd: null, cwd: null, archived: false, action: { tool: 'Bash', text: 'run the tests', elapsed_s: 2 }, last_text: '',
  unread: [], result: null, ...o,
})

const snapshot = (agents: Row[], extra: Row = {}): string => {
  const counts = { live: 0, done: 0, error: 0, dead: 0 } as Record<string, number>
  for (const a of agents) counts[a.state as string] = (counts[a.state as string] ?? 0) + 1
  return JSON.stringify({
    generated_at: '2026-10-04T12:00:00+00:00', stages: ['stage-a'], counts, agents, roles: {}, locks: [], questions: {}, questions_ok: true,
    limits: null, codex_limits: {}, journal_tail: [], ...extra,
  })
}

const cardJson = (a: Row, items: Row[]): string =>
  snapshot([a], { feed: { agent: a.dir_name, stage: a.stage, items } })

const PANE = {
  plugin: PLUGIN,
  component: 'Pane',
  requestId: 'agent-top',
  viewport: { columns: 120, rows: 40 },
  props: { title: 'Agents', isFocused: true, bodyColumns: 70, placement: 'inline', scroll: { offset: 0, bodyRows: 20 }, view: {} },
} as const

const DONE = { subtype: 'success', is_error: false, text: 'all green' }

test('unknown and interrupted native actors keep their identity, labels and counts without death toasts', async () => {
  const before = parseSnapshot(snapshot([agent()]), 0)
  const unknown = parseSnapshot(snapshot([agent({ state: 'unknown', alive: false, action: null })]), 0)
  const a = unknown.agents[0]
  expect(a.state).toBe('unknown')
  expect(glyphOf(a)).toBe('?')
  expect(colorOf(a)).toBe('yellow')
  expect(badgeOf(a).label).toBe('UNKNOWN')
  expect(nowText(a)).toBe('no completion notice; state unknown')
  expect(nowText({ ...a, kind: 'subagent' })).toBe('no completion notice; state unknown')
  expect(notices(remember(before), unknown)).toEqual([])
  const stopped = parseSnapshot(snapshot([agent({ state: 'stopped', alive: false, action: null,
    result: { subtype: 'stopped', is_error: false, text: 'user interrupted' } })]), 0)
  const s = stopped.agents[0]
  expect(s.state).toBe('stopped')
  expect(glyphOf(s)).toBe('■')
  expect(badgeOf(s).label).toBe('STOPPED')
  expect(nowText(s)).toBe('user interrupted')
  expect(nowText({ ...s, result: null })).toBe('stopped')
  expect(notices(remember(before), stopped)).toEqual(['■ worker · stage-a stopped'])
  expect(countsOf([a, s])).toEqual({ live: 0, done: 0, error: 0, dead: 0, unknown: 1, stopped: 1 })
  expect(statusText(unknown)).toContain('? 1')
  expect(statusText(stopped)).toContain('■ 1')
  const expired = parseSnapshot(snapshot([agent({ state: 'unknown', expired: true, alive: false, result: null })]), 0)
  expect(expired.agents[0].state).toBe('unknown')
  expect(expired.agents[0].expired).toBe(true)
  expect(expired.agents[0].result).toBeNull()
  expect(nowText(expired.agents[0])).toBe('unknown observation expired; no completion notice')
  expect(notices(remember(unknown), expired)).toEqual([])
  const future = parseSnapshot(snapshot([agent({ state: 'future-native-state', alive: false })]), 0)
  expect(future.agents[0].state).toBe('unknown')
})

test('native actors first seen unknown toast each terminal outcome once without needing a run count', async () => {
  const native = {
    kind: 'native', role: 'native-child', dir_name: 'native-child', runs: 0, alive: false, action: null, age_s: null,
  }
  const before = parseSnapshot(snapshot([agent({ ...native, state: 'unknown' })]), 0)
  expect(notices(remember(before), before)).toEqual([])
  for (const [state, result, notice] of [
    ['done', DONE, '✓ native-child · stage-a finished'],
    ['error', { subtype: 'error', is_error: true, text: 'test failed' }, '✗ native-child · stage-a failed: test failed'],
    ['stopped', { subtype: 'stopped', is_error: false, text: 'user interrupted' }, '■ native-child · stage-a stopped'],
  ] as const) {
    const after = parseSnapshot(snapshot([agent({ ...native, state, result })]), 0)
    expect(notices(remember(before), after)).toEqual([notice])
    expect(notices(remember(after), after)).toEqual([])
  }
})

test('status line has the counts where a phone looks on too; the first snapshot never toasts, a transition toasts once', async ($, on) => {
  const clock = mock.clock(on)
  let json = snapshot([agent(), agent({ role: 'rev', dir_name: 'rev', state: 'done', alive: false, action: null, result: DONE })])
  const toasts: string[] = []
  const statuses: (string | undefined)[] = []
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal', 'mobile'] }))
  on('ui.panes', () => ({ value: [] }))
  on('process.run', () => ran(json))
  on('ui.toast', ($, e) => (toasts.push(e.text), { value: undefined }))
  on('ui.status', ($, e) => (statuses.push(e.text), { value: undefined }))
  on('session.start', () => ({ cwd: '/work' }))
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await clock.advance(3000) // the first poll: a live and a done agent are already there
  expect(statuses).toEqual(['agents ● 1 ✓ 1 ✗ 0'])
  expect(toasts).toEqual([])

  json = snapshot([agent({ state: 'done', alive: false, action: null, result: DONE }), agent({ role: 'rev', dir_name: 'rev', state: 'done', alive: false, result: DONE })])
  await clock.advance(15000)
  expect(statuses.at(-1)).toBe('agents ● 0 ✓ 2 ✗ 0')
  expect(toasts).toEqual(['✓ worker · stage-a finished'])

  await clock.advance(30000) // the same snapshot again: no second toast
  expect(toasts).toHaveLength(1)
})

test('a failed and a died agent toast; a new open owner question toasts once', async ($, on) => {
  const clock = mock.clock(on)
  const q = (...ids: string[]) => withQuestions('stage-a', ids)
  let json = snapshot([agent(), agent({ role: 'b', dir_name: 'b' })], { questions: q('Q-A-001') })
  const toasts: string[] = []
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  on('ui.panes', () => ({ value: [] }))
  on('process.run', () => ran(json))
  on('ui.toast', ($, e) => (toasts.push(e.text), { value: undefined }))
  on('ui.status', DONE_VOID)
  on('session.start', () => ({ cwd: '/work' }))
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await clock.advance(3000)
  expect(toasts).toEqual([]) // Q-A-001 was open before the session looked

  json = snapshot(
    [
      agent({ state: 'error', alive: false, action: null, result: { subtype: 'error_max_turns', is_error: true, text: 'ran out of turns' } }),
      agent({ role: 'b', dir_name: 'b', state: 'dead', alive: false, action: null }),
    ],
    { questions: q('Q-A-002', 'Q-A-001') },
  )
  await clock.advance(15000)
  expect(toasts).toEqual(['✗ worker · stage-a failed: ran out of turns', '✗ b · stage-a died', '? stage-a: new question Q-A-002 [stage-a] open — Question Q-A-002?'])
  await clock.advance(30000)
  expect(toasts).toHaveLength(3)
})

test('no agents in the default view: nothing in the status line', async ($, on) => {
  const clock = mock.clock(on)
  const statuses: (string | undefined)[] = []
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  on('ui.panes', () => ({ value: [] }))
  on('process.run', () => ran(snapshot([])))
  on('ui.toast', DONE_VOID)
  on('ui.status', ($, e) => (statuses.push(e.text), { value: undefined }))
  on('session.start', () => ({ cwd: '/work' }))
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await clock.advance(3000)
  expect(statuses).toEqual([])
})

test('/agent-top opens the pane; rows open the card with the feed, Back returns (terminal and desktop)', async ($, on) => {
  mock.clock(on)
  const calls: string[][] = []
  const list = snapshot([agent(), agent({ role: 'rev', dir_name: 'rev', state: 'done', alive: false, action: null, last_text: 'looks fine', result: DONE })])
  const feed = [
    { at: '12:00:01', kind: 'tool', sub: false, tool: 'Bash', text: 'run the tests', detail: 'pytest' },
    { at: '12:00:02', kind: 'result', sub: false, tool: 'Bash', text: '12 passed', detail: null },
    { at: '12:00:03', kind: 'text', sub: false, tool: null, text: 'all green, writing the report', detail: null },
  ]
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  on('ui.panes', () => ({ value: [] }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.toast', DONE_VOID)
  on('ui.status', DONE_VOID)
  on('process.run', ($, e) => {
    calls.push([...e.argv])
    return ran(e.argv.includes('--agent') ? cardJson(agent(), feed) : list)
  })
  const answer = await run($, '', 'agent-top')
  expect(answer.text).toBe('agent-top pane opened: ● 1 ✓ 1 ✗ 0')
  expect(calls[0]?.slice(1)).toEqual(['--json']) // the plugin's own CLI, JSON only
  expect(calls[0]?.[0]).toMatch(BIN)

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ key: 'header' }))?.text).toMatch(/^Delamain · agent-top +● 1 +✓ 1 +✗ 0 /)
    expect(await ui.find({ key: 'open:stage-a/worker' })).toBeDefined()
    expect(await ui.find({ key: 'open:stage-a/rev' })).toBeDefined()
    expect((await ui.find({ key: 'now:stage-a/worker' }))?.text).toMatch(/▸ Bash: run the tests/)
    expect((await ui.find({ key: 'now:stage-a/rev' }))?.text).toMatch(/looks fine/)
    expect(await ui.find({ key: 'back' })).toBeUndefined()

    await ui.press({ key: 'open:stage-a/worker' })
    const lastCall = calls.at(-1) ?? []
    expect(lastCall.slice(1)).toEqual(['--json', '--agent', 'worker', '--stage', 'stage-a', '--feed', '30'])
    const title = (await ui.find({ key: 'card-title' }))?.text ?? ''
    expect(title).toMatch(/LIVE +worker · pid 123 · 4s ago/)
    expect(title).toMatch(/stage-a$/)
    expect((await ui.find({ key: 'card-model' }))?.text).toMatch(/^Model +sonnet-5-5\/hi/)
    expect((await ui.find({ key: 'card-tag' }))?.text).toMatch(/^Tag +w-1/)
    expect((await ui.find({ key: 'card-now' }))?.text).toMatch(/^Now +▸ Bash: run the tests/)
    expect((await ui.find({ key: 'feed:0' }))?.text).toMatch(/^12:00:01 ▸ Bash +run the tests$/)
    expect((await ui.find({ key: 'feed:1' }))?.text).toMatch(/^12:00:02 ◂ output +12 passed$/)
    expect((await ui.find({ key: 'feed:2' }))?.text).toMatch(/^12:00:03 ✎ says +all green, writing the report$/)
    expect(await ui.find({ key: 'open:stage-a/worker' })).toBeUndefined()

    await ui.press({ key: 'back' })
    expect(await ui.find({ key: 'open:stage-a/worker' })).toBeDefined()
    await ui.unmount()
  }
})

test('an agent opened from the --all list is asked for with --all (old and archived agents are only there)', async ($, on) => {
  mock.clock(on)
  const calls: string[][] = []
  const old = agent({ role: 'old', dir_name: 'old', state: 'done', alive: false, action: null, age_s: 90000, archived: true, result: DONE })
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  on('ui.panes', () => ({ value: [] }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.toast', DONE_VOID)
  on('ui.status', DONE_VOID)
  on('process.run', ($, e) => {
    calls.push([...e.argv])
    const isAll = e.argv.includes('--all')
    if (e.argv.includes('--agent')) return ran(isAll ? cardJson(old, []) : snapshot([], { feed: { agent: 'old', stage: 'stage-a', items: [] } }))
    return ran(snapshot(isAll ? [agent(), old] : [agent()]))
  })
  await run($, '--all', 'agent-top')
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'open:stage-a/old' })
  expect(calls.at(-1)?.slice(1)).toEqual(['--json', '--all', '--agent', 'old', '--stage', 'stage-a', '--feed', '30'])
  expect((await ui.find({ key: 'card-title' }))?.text).toMatch(/^ DONE +old · /)
  await ui.unmount()

  // the role argument of the command itself takes the same path
  calls.length = 0
  await run($, 'old --all', 'agent-top')
  expect(calls.some(c => c.join(' ').endsWith('--json --all --agent old --stage stage-a --feed 30'))).toBe(true)
})

test('Journal and Summary views draw the journal tail, locks, questions and plan limits incl. Codex', async ($, on) => {
  mock.clock(on)
  const json = snapshot([agent()], {
    journal_tail: [{ stage: 'stage-a', time: '12:01', tag: 'hub-1', text: 'plan: ship the mod' }],
    locks: [{ kind: 'main-merge', repo: 'santinel', owner_name: 'Hub core-c #28', until: '2026-10-31T23:59:00+03:00', active: true, why: 'held' }],
    questions: { 'stage-a': { open: 1, overdue: 1, line: 'stage-a — open 1, overdue 1', items: ['Q-9 [stage-a] open OVERDUE — decide?'] } },
    limits: { info: { unifiedWindows: { five_hour: { utilization: 0.42, resetsAt: 1791547735 }, seven_day: { utilization: 0.1 } } }, seen_at: 1790972433 },
    codex_limits: { codex: { info: { primary: { used_percent: 21, window_minutes: 10080, resets_at: 1791547735 }, secondary: null }, seen_at: 1790972433 } },
  })
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  on('ui.panes', () => ({ value: [] }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.toast', DONE_VOID)
  on('ui.status', DONE_VOID)
  on('process.run', () => ran(json))
  await run($, '', 'agent-top')

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    await ui.press({ key: 'view-journal' })
    expect((await ui.find({ key: 'journal:0' }))?.text).toMatch(/^12:01 +hub-1 +plan: ship the mod$/)
    await ui.press({ key: 'view-summary' })
    expect((await ui.find({ key: 'lock:0' }))?.text).toMatch(/^ main-merge +santinel +until 10-31 23:59 +Hub core-c #28: held$/)
    expect((await ui.find({ key: 'q:stage-a' }))?.text).toMatch(/^stage-a +1 open +OVERDUE 1 $/)
    expect(await ui.find({ type: 'Text', text: /Q-9 \[stage-a\] open OVERDUE/ })).toBeDefined()
    expect((await ui.find({ key: 'limit:claude:5h' }))?.text).toMatch(/^Claude +5h +█+░+ +42%/)
    expect((await ui.find({ key: 'limit:claude:7d' }))?.text).toMatch(/^ +7d +█+░+ +10%$/)
    expect((await ui.find({ key: 'limit:codex:7d' }))?.text).toMatch(/^Codex +7d +█+░+ +21% +↻ /)
    await ui.press({ key: 'view-agents' })
    expect(await ui.find({ key: 'open:stage-a/worker' })).toBeDefined()
    await ui.unmount()
  }
})

test('/agent-top <role> --stage S opens that agent card; an unknown role says so', async ($, on) => {
  mock.clock(on)
  const calls: string[][] = []
  const rows = [agent(), agent({ stage: 'stage-b', dir_name: 'worker' })]
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  on('ui.panes', () => ({ value: [] }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.toast', DONE_VOID)
  on('ui.status', DONE_VOID)
  on('process.run', ($, e) => {
    calls.push([...e.argv])
    return ran(e.argv.includes('--agent') ? cardJson(agent({ stage: e.argv[e.argv.indexOf('--stage') + 1] }), []) : snapshot(rows, { stages: ['stage-a', 'stage-b'] }))
  })
  const ok = await run($, 'worker --stage stage-b', 'agent-top')
  expect(ok.text).toMatch(/^agent-top pane opened: /)
  expect(calls.some(c => c.join(' ').endsWith('--agent worker --stage stage-b --feed 30'))).toBe(true)

  const none = await run($, 'ghost', 'agent-top')
  expect(none.text).toBe('agent-top pane opened: no agent "ghost"; ● 2 ✓ 0 ✗ 0')
})

test('/agent-top --stage S reads that stage itself: a closed stage, left out of the default call, is still shown', async ($, on) => {
  mock.clock(on)
  const calls: string[][] = []
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  on('ui.panes', () => ({ value: [] }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.toast', DONE_VOID)
  on('ui.status', DONE_VOID)
  on('process.run', ($, e) => {
    calls.push([...e.argv])
    if (e.argv.includes('--agent')) return ran(cardJson(agent({ stage: 'shop', dir_name: 'worker' }), []))
    return ran(e.argv.includes('--stage')
      ? snapshot([agent({ stage: 'shop', dir_name: 'worker' })], { stages: ['shop'] })
      : snapshot([agent()], { stages: ['stage-a'], closed_hidden: ['shop'] }))
  })
  const ok = await run($, 'worker --stage shop', 'agent-top')
  expect(ok.text).toMatch(/^agent-top pane opened: /)
  expect(calls.some(c => c.slice(1).join(' ') === '--json --stage shop')).toBe(true)
  expect(calls.some(c => c.join(' ').endsWith('--agent worker --stage shop --feed 30'))).toBe(true)
})

test('where no pane can be placed, /agent-top answers with the text picture', async ($, on) => {
  const calls: string[][] = []
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no pane here' } }))
  on('process.run', ($, e) => (calls.push([...e.argv]), ran('agent-top picture\n')))
  const answer = await run($, 'worker --stage s --all', 'agent-top')
  expect(answer.text).toBe('agent-top picture')
  expect(calls.at(-1)?.slice(1)).toEqual(['--once', '--width', '100', '--stage', 's', '--all', '--agent', 'worker'])
})

test("only agent-top and this plugin's own <name>:agent-top are answered; another plugin's command passes through", async ($, on) => {
  mock.clock(on)
  const own = `${PLUGIN}:agent-top`
  const isDev = PLUGIN === 'agent-top-dev'
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: [] }))
  on('process.run', () => ran('picture\n'))
  on('command.run', () => ({ text: 'the engine ran it' }))
  expect((await run($, '', 'agent-top')).text).toBe('picture')
  expect((await run($, '', own)).text).toBe('picture')
  expect((await run($, '', 'delamain:agent-top')).text).toBe(isDev || PLUGIN === 'delamain' ? 'picture' : 'the engine ran it')
  expect((await run($, '', 'agent-hub:agent-top')).text).toBe(isDev || PLUGIN === 'delamain' ? 'picture' : 'the engine ran it') // rename:keep rename:transition
  expect((await run($, '', 'foo:agent-top')).text).toBe('the engine ran it')
  for (const other of ['compact', 'other-plugin:agent-top', 'other-plugin:agent-topic', 'agent-top-dev-x:agent-top']) {
    expect((await run($, '', other)).text).toBe('the engine ran it')
  }
  expect((await run($, '', 'agent-top-dev:agent-top')).text).toBe(isDev ? 'picture' : 'the engine ran it')
})

test('isOwnCommand: the installed plugin and the dev copy also answer the command from before the rename, nobody else does', async () => {
  expect(isOwnCommand('agent-top', 'delamain')).toBe(true)
  expect(isOwnCommand('delamain:agent-top', 'delamain')).toBe(true)
  expect(isOwnCommand('agent-hub:agent-top', 'delamain')).toBe(true) // rename:keep rename:transition  (the installed plugin answers it too)
  expect(isOwnCommand('agent-top-dev:agent-top', 'delamain')).toBe(false) // not an allow-list for the installed plugin
  expect(isOwnCommand('other:agent-top', 'delamain')).toBe(false)
  expect(isOwnCommand('foo:agent-top', 'delamain')).toBe(false)
  expect(isOwnCommand('agent-hub:agent-topic', 'delamain')).toBe(false) // rename:keep rename:transition
  expect(isOwnCommand('other-hub:agent-top', 'delamain')).toBe(false)
  expect(isOwnCommand('agent-top', 'agent-top-dev')).toBe(true)
  expect(isOwnCommand('agent-top-dev:agent-top', 'agent-top-dev')).toBe(true)
  expect(isOwnCommand('delamain:agent-top', 'agent-top-dev')).toBe(true)
  expect(isOwnCommand('agent-hub:agent-top', 'agent-top-dev')).toBe(true) // rename:keep rename:transition
  expect(isOwnCommand('other-hub:agent-top', 'agent-top-dev')).toBe(false)
  expect(isOwnCommand('other:agent-top', 'agent-top-dev')).toBe(false)
  expect(isOwnCommand('foo:agent-top', 'agent-top-dev')).toBe(false)
  expect(isOwnCommand('delamain:agent-topic', 'agent-top-dev')).toBe(false)
  expect(isOwnCommand('agent-hub:agent-top', 'other-plugin')).toBe(false) // rename:keep rename:transition  (a third plugin's mod does not take it)
  expect(isOwnCommand('delamain:agent-top', 'other-plugin')).toBe(false)
})

test('with no surface at all (a -p run) /agent-top answers with the text picture and opens nothing', async ($, on) => {
  let opened = 0
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: [] }))
  on('ui.open', () => (opened += 1, { value: { isPlaced: true } }))
  on('process.run', () => ran('picture\n'))
  const answer = await run($, '', 'agent-top')
  expect(answer.text).toBe('picture')
  expect(opened).toBe(0)
})

test('a failing CLI shows one dim line and keeps the last good snapshot', async ($, on) => {
  const clock = mock.clock(on)
  let isBroken = false
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  stubPaneRecord(on)
  on('ui.toast', DONE_VOID)
  on('ui.status', DONE_VOID)
  on('process.run', () =>
    isBroken
      ? ran('', 2, 'FAILED: hub home is unreadable\nmore\n')
      : ran(snapshot([agent()])),
  )
  await run($, '', 'agent-top')
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  isBroken = true
  await clock.advance(3000) // the pane is open: polls every 3 s
  expect((await ui.find({ key: 'error' }))?.text).toBe(' !  FAILED: hub home is unreadable')
  expect(await ui.find({ key: 'open:stage-a/worker' })).toBeDefined() // the last good snapshot is still drawn
  isBroken = false
  await clock.advance(3000)
  expect(await ui.find({ key: 'error' })).toBeUndefined()
})

test('a missing agent-top stops the polling: status cleared, no toasts, no more calls', async ($, on) => {
  const clock = mock.clock(on)
  let runs = 0
  let isGone = false
  const statuses: (string | undefined)[] = []
  const toasts: string[] = []
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal', 'vscode'] }))
  on('ui.panes', () => ({ value: [] }))
  on('process.run', () => {
    runs += 1
    if (isGone) return { deny: 'spawn ENOENT: no such file or directory' }
    return ran(snapshot([agent()]))
  })
  on('ui.toast', ($, e) => (toasts.push(e.text), { value: undefined }))
  on('ui.status', ($, e) => (statuses.push(e.text), { value: undefined }))
  on('session.start', () => ({ cwd: '/work' }))
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await clock.advance(3000)
  expect(statuses).toEqual(['agents ● 1 ✓ 0 ✗ 0'])

  isGone = true
  await clock.advance(15000)
  expect(statuses).toEqual(['agents ● 1 ✓ 0 ✗ 0', undefined])
  const seen = runs
  await clock.advance(60000)
  expect(runs).toBe(seen)
  expect(toasts).toEqual([])
})

test('never two runs in flight', async ($, on) => {
  const clock = mock.clock(on)
  let active = 0
  let most = 0
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  stubPaneRecord(on)
  on('ui.toast', DONE_VOID)
  on('ui.status', DONE_VOID)
  on('process.run', async () => {
    active += 1
    most = Math.max(most, active)
    await clock.sleep(7000) // slower than two ticks
    active -= 1
    return ran(snapshot([agent()]))
  })
  const opening = run($, '', 'agent-top')
  await clock.advance(60000)
  await opening
  expect(most).toBe(1)
})

/** `ui.open` / `ui.close` / `ui.panes` as the engine keeps its record: the pane is listed from its open to its close. */
function stubPaneRecord(on: On, log: string[] = []): void {
  let isUp = false
  on('ui.panes', () => ({ value: isUp ? [{ id: 'agent-top', title: 'Agents', isShown: true, isFocused: true, isPlaced: true }] : [] }))
  on('ui.open', ($, e) => ((isUp = true), log.push(`open ${e.id}`), { value: { isPlaced: true } }))
  on('ui.close', ($, e) => ((isUp = false), log.push(`close ${e.id}`), { value: undefined }))
}

const FOOTER = (modes: string[]) => ({ plugin: PLUGIN, component: 'SessionMode', props: { modes } }) as const

for (const surface of ['terminal', 'desktop'] as const) {
  test(`the footer Button on ${surface}: the counts, the engine modes kept, a press opens then closes the pane, no status line`, async ($, on) => {
    const clock = mock.clock(on)
    const panes: string[] = []
    const statuses: (string | undefined)[] = []
    on('command.register', REGISTERED)
    on('session.surfaces', () => ({ value: [surface] }))
    stubPaneRecord(on, panes)
    on('process.run', () => ran(snapshot([agent(), agent({ role: 'rev', dir_name: 'rev', state: 'error', alive: false, action: null })])))
    on('ui.toast', DONE_VOID)
    on('ui.status', ($, e) => (statuses.push(e.text), { value: undefined }))
    on('session.start', () => ({ cwd: '/work' }))
    await $.session.start({ surface, isInteractive: true, cwd: '/work' })
    await clock.advance(3000)
    expect(statuses).toEqual([]) // the Button holds the counts: never both

    const ui = await $.ui.mount({ ...FOOTER(['focus', 'memory paused']), surface })
    const button = await ui.find({ key: 'agent-top-toggle' })
    expect(button?.type).toBe('Button')
    expect(button?.props?.label).toBe('agents ● 1 ✓ 0 ✗ 1')
    expect(await ui.find({ type: 'Text', text: /^focus & memory paused/ })).toBeDefined()

    await ui.press({ key: 'agent-top-toggle' })
    expect(panes).toEqual(['open agent-top'])
    const pane = await $.ui.mount({ ...PANE, surface })
    expect(await pane.find({ key: 'open:stage-a/worker' })).toBeDefined()
    await pane.unmount()
    await ui.press({ key: 'agent-top-toggle' })
    expect(panes).toEqual(['open agent-top', 'close agent-top'])
    await ui.press({ key: 'agent-top-toggle' })
    expect(panes).toEqual(['open agent-top', 'close agent-top', 'open agent-top'])
    await ui.unmount()

    // no engine modes: the Button alone
    const bare = await $.ui.mount({ ...FOOTER([]), surface })
    expect(await bare.find({ key: 'agent-top-toggle' })).toBeDefined()
    expect(await bare.find({ type: 'Text', text: /&|·/ })).toBeUndefined()
    await bare.unmount()
  })
}

test('where a surface without the footer looks on, the counts are the status line and the footer is left to the engine', async ($, on) => {
  const clock = mock.clock(on)
  let surfaces: string[] = ['terminal']
  const statuses: (string | undefined)[] = []
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: surfaces as ('terminal' | 'mobile')[] }))
  stubPaneRecord(on)
  on('process.run', () => ran(snapshot([agent()])))
  on('ui.toast', DONE_VOID)
  on('ui.status', ($, e) => (statuses.push(e.text), { value: undefined }))
  on('ui.render', { component: 'SessionMode' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>{`engine: ${e.props.modes.join(' & ')}`}</Text>
  })
  on('session.start', () => ({ cwd: '/work' }))
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await clock.advance(3000)
  expect(statuses).toEqual([])
  let ui = await $.ui.mount({ ...FOOTER(['focus']), surface: 'terminal' })
  expect(await ui.find({ key: 'agent-top-toggle' })).toBeDefined()
  await ui.unmount()

  surfaces = ['terminal', 'mobile'] // a phone attached: from the next poll on, the status line
  await clock.advance(15000)
  expect(statuses).toEqual(['agents ● 1 ✓ 0 ✗ 0'])
  ui = await $.ui.mount({ ...FOOTER(['focus']), surface: 'terminal' })
  expect(await ui.find({ key: 'agent-top-toggle' })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /^engine: focus$/ })).toBeDefined() // the engine's own footer, untouched
  await ui.unmount()

  surfaces = ['terminal'] // it left: the Button again, the status line cleared
  await clock.advance(15000)
  expect(statuses).toEqual(['agents ● 1 ✓ 0 ✗ 0', undefined])
  ui = await $.ui.mount({ ...FOOTER([]), surface: 'terminal' })
  expect(await ui.find({ key: 'agent-top-toggle' })).toBeDefined()
  await ui.unmount()
})

test('/agent-top toggles as the Button does: a bare second one closes the pane; with a role it stays open on the card', async ($, on) => {
  mock.clock(on)
  const panes: string[] = []
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  stubPaneRecord(on, panes)
  on('ui.toast', DONE_VOID)
  on('ui.status', DONE_VOID)
  on('ui.focus', () => ({}))
  on('process.run', ($, e) => ran(e.argv.includes('--agent') ? cardJson(agent(), []) : snapshot([agent()])))
  expect((await run($)).text).toBe('agent-top pane opened: ● 1 ✓ 0 ✗ 0')
  expect((await run($)).text).toBe('agent-top pane closed')
  expect((await run($, '', `${PLUGIN}:agent-top`)).text).toBe('agent-top pane opened: ● 1 ✓ 0 ✗ 0')
  expect((await run($, 'worker')).text).toBe('agent-top pane opened: ● 1 ✓ 0 ✗ 0')
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ key: 'card-title' })).toBeDefined()
  await ui.unmount()
  expect((await run($, '', `${PLUGIN}:agent-top`)).text).toBe('agent-top pane closed')
  expect(panes).toEqual(['open agent-top', 'close agent-top', 'open agent-top', 'open agent-top', 'close agent-top'])
})

// ---------------------------------------------------------------- the pure helpers

test('parseArgs and onceArgs', async () => {
  expect(parseArgs('')).toEqual({ role: null, stages: [], isAll: false })
  expect(parseArgs('hub --stage a --stage=b --all')).toEqual({ role: 'hub', stages: ['a', 'b'], isAll: true })
  expect(onceArgs(parseArgs('hub --stage a'))).toEqual(['--once', '--width', '100', '--stage', 'a', '--agent', 'hub'])
})

test('planRun: every tick while the pane shows the list, every 15 s otherwise, the card is an extra call', async () => {
  const base = { now: 100000, lastWatchAt: 99000, isOpen: false, view: 'list', isAll: false, hasTarget: false, force: false } as const
  expect(planRun(base)).toEqual({ watch: false, extra: null })
  expect(planRun({ ...base, lastWatchAt: 85000 })).toEqual({ watch: true, extra: null })
  expect(planRun({ ...base, isOpen: true })).toEqual({ watch: true, extra: null })
  expect(planRun({ ...base, isOpen: true, isAll: true })).toEqual({ watch: false, extra: 'all' })
  expect(planRun({ ...base, isOpen: true, hasStages: true })).toEqual({ watch: false, extra: 'all' })
  expect(planRun({ ...base, hasStages: true })).toEqual({ watch: false, extra: null })
  expect(planRun({ ...base, isOpen: true, view: 'card', hasTarget: true })).toEqual({ watch: false, extra: 'card' })
  expect(planRun({ ...base, isOpen: true, view: 'card', hasTarget: true, lastWatchAt: 85000 })).toEqual({ watch: true, extra: 'card' })
  expect(planRun({ ...base, isOpen: true, view: 'journal' })).toEqual({ watch: true, extra: null })
})

test('notices, status text and toast cap on parsed snapshots', async () => {
  const before = parseSnapshot(snapshot([agent(), agent({ role: 'x', dir_name: 'x' })]), 0)
  const after = parseSnapshot(snapshot([agent({ state: 'done', alive: false, result: DONE }), agent({ role: 'x', dir_name: 'x' }), agent({ role: 'n', dir_name: 'n', state: 'done', alive: false, age_s: 5, result: DONE }), agent({ role: 'old', dir_name: 'old', state: 'done', alive: false, age_s: 90000 })]), 0)
  expect(notices(remember(before), after)).toEqual(['✓ worker · stage-a finished', '✓ n · stage-a finished'])
  expect(statusText(after)).toBe('agents ● 1 ✓ 3 ✗ 0')
  expect(statusText(parseSnapshot(snapshot([]), 0))).toBeUndefined()
  expect(capToasts(['a', 'b', 'c', 'd', 'e'])).toEqual(['a', 'b', '+3 more events (open /agent-top)'])
  expect(parseSnapshot(snapshot([agent()]), 0).agents.map(taskText)).toEqual(['Build the thing'])
  expect(() => parseSnapshot('not json', 0)).toThrow('agent-top printed no JSON')
  expect(() => parseSnapshot('{"x":1}', 0)).toThrow('unexpected agent-top output')
})

// ---------------------------------------------------------------- owner questions and finishes: real `ask list --open` format

// Generated by `bin/ask add ... ; bin/ask list --stage stage-a --open`, one entry per three lines (header, blocks, asked);
// bin/agent-top keeps each non-empty line as an item (at most 12).
const askItems = (...ids: string[]): string[] =>
  ids.flatMap(id => [
    `${id} [stage-a] open — Question ${id}?`,
    '    blocks: stage B; default by 2026-10-10: keep Claude',
    '    asked 2026-10-03 (hub); source: brief',
  ])

// `items` are cut to 12 display lines like bin/agent-top does; `ids` carry every open id.
const withQuestions = (stage: string, ids: string[], open = ids.length): Row => ({
  [stage]: { open, overdue: 0, line: `${stage} — open ${open}, overdue 0`, items: askItems(...ids).slice(0, 12), ids },
})

const qids = (...nums: number[]): string[] => nums.map(n => `Q-A-${String(n).padStart(3, '0')}`)
const toast = (id: string): string => `? stage-a: new question ${id} [stage-a] open — Question ${id}?`
const bare = (id: string): string => `? stage-a: new question ${id}` // past the 12 display lines: only the id is known

const snapQ = (questions: Row, agents: Row[] = [agent()]): ReturnType<typeof parseSnapshot> => parseSnapshot(snapshot(agents, { questions }), 0)

test('one new question toasts once, not once per display line (id, blocks:, asked)', async () => {
  const empty = snapQ(withQuestions('stage-a', [])) // a register that exists but holds no open question yet
  const one = snapQ(withQuestions('stage-a', ['Q-A-001']))
  const two = snapQ(withQuestions('stage-a', ['Q-A-002', 'Q-A-001']))
  expect(notices(remember(empty), one)).toEqual(['? stage-a: new question Q-A-001 [stage-a] open — Question Q-A-001?'])
  expect(notices(remember(one), two)).toEqual(['? stage-a: new question Q-A-002 [stage-a] open — Question Q-A-002?'])
  expect(notices(remember(two), two)).toEqual([])
})

test('open ids past the 12 display lines are diffed too: 3 -> 8 shows 3 toasts and a count line', async () => {
  const out = notices(remember(snapQ(withQuestions('stage-a', qids(1, 2, 3)))), snapQ(withQuestions('stage-a', qids(1, 2, 3, 4, 5, 6, 7, 8))))
  expect(out).toEqual([toast('Q-A-004'), bare('Q-A-005'), bare('Q-A-006'), '? stage-a: 2 more new questions'])
})

test('5 open (4 visible): close 001/002 and add 006 toasts 006 only', async () => {
  const before = snapQ(withQuestions('stage-a', qids(1, 2, 3, 4, 5)))
  const after = snapQ(withQuestions('stage-a', qids(3, 4, 5, 6)))
  expect(notices(remember(before), after)).toEqual([toast('Q-A-006')])
})

test('5 open (4 visible): close 001 and add 006/007 toasts 006 and 007, never 005', async () => {
  const before = snapQ(withQuestions('stage-a', qids(1, 2, 3, 4, 5)))
  const after = snapQ(withQuestions('stage-a', qids(2, 3, 4, 5, 6, 7)))
  expect(notices(remember(before), after)).toEqual([bare('Q-A-006'), bare('Q-A-007')])
})

test('a failed first ask summary is not a baseline: the next good snapshot toasts nothing for existing questions', async () => {
  const failed = parseSnapshot(snapshot([agent()], { questions: {}, questions_ok: false }), 0)
  const good = snapQ(withQuestions('stage-a', qids(1)))
  const next = snapQ(withQuestions('stage-a', qids(1, 2)))
  expect(notices(remember(failed), good)).toEqual([])
  expect(notices(remember(good, remember(failed)), next)).toEqual([toast('Q-A-002')])
})

test('a failed ask in the middle keeps the memory; a stage with ids null keeps its set; older JSON never toasts', async () => {
  const good = snapQ(withQuestions('stage-a', qids(1, 2)))
  const failed = parseSnapshot(snapshot([agent()], { questions: {}, questions_ok: false }), 0)
  const mem = remember(failed, remember(good))
  expect(notices(mem, snapQ(withQuestions('stage-a', qids(1, 2))))).toEqual([]) // nothing looks new after the hiccup
  expect(notices(mem, snapQ(withQuestions('stage-a', qids(1, 2, 3))))).toEqual([toast('Q-A-003')])
  const listFailed = parseSnapshot(snapshot([agent()], { questions: { 'stage-a': { open: 2, overdue: 0, line: 'stage-a — open 2, overdue 0', items: [], ids: null } } }), 0)
  expect(notices(remember(good), listFailed)).toEqual([])
  const kept = remember(listFailed, remember(good))
  expect(notices(kept, snapQ(withQuestions('stage-a', qids(1, 2, 3))))).toEqual([toast('Q-A-003')])
  const older = parseSnapshot(JSON.stringify({ ...JSON.parse(snapshot([agent()])), questions_ok: undefined, questions: { 'stage-a': { open: 1, overdue: 0, line: 'x', items: askItems('Q-A-009') } } }), 0)
  expect(notices(remember(good), older)).toEqual([])
})

test('the first question of a stage that had no register at the first snapshot toasts', async () => {
  const before = snapQ({}) // `ask summary` lists only stages that already have a register
  const after = snapQ(withQuestions('stage-a', ['Q-A-001']))
  expect(notices(remember(before), after)).toEqual(['? stage-a: new question Q-A-001 [stage-a] open — Question Q-A-001?'])
})

test('a resumed agent that finishes again between two polls (done, runs 1 -> 2) toasts', async () => {
  const done = (runs: number) => parseSnapshot(snapshot([agent({ state: 'done', alive: false, action: null, age_s: 600, runs, result: DONE })]), 0)
  expect(notices(remember(done(1)), done(2))).toEqual(['✓ worker · stage-a finished'])
  expect(notices(remember(done(2)), done(2))).toEqual([])
})

// ---------------------------------------------------------------- the drawing: cursor, window, badges, bars, layouts

const paneProps = (o: { placement?: 'dock' | 'inline'; cols?: number; rows?: number } = {}) => ({
  ...PANE,
  props: { ...PANE.props, placement: o.placement ?? 'inline', bodyColumns: o.cols ?? 70, scroll: { offset: 0, bodyRows: o.rows ?? 20 } },
})

/** The stubs every pane test needs; `json` answers every CLI call, `focus` the bottom of `ui.focus`. */
function stubPane(on: On, json: () => string, focus: () => { deny?: string } = () => ({}), moves: string[] = [], feed: Row[] = []): void {
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  on('ui.panes', () => ({ value: [] }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.toast', DONE_VOID)
  on('ui.status', DONE_VOID)
  on('ui.focus', ($, e) => {
    const deny = focus().deny
    if (!deny) moves.push(`${e.origin.kind}:${e.element ?? ''}`)
    return deny ? { deny } : {}
  })
  on('process.run', ($, e) => ran(e.argv.includes('--agent') ? cardJson(JSON.parse(json()).agents[0], feed) : json()))
}

/** The person moving the pane's focus ring onto `element` (as Tab or an arrow does): the `ui.focus` chain. */
const focus = ($: Engine, element: string, requestId = 'agent-top') =>
  $.ui.focus({ component: 'Pane', requestId, element, origin: { kind: 'person' } })

const rowKeys = async (ui: { findAll: (q: { type: string }) => Promise<{ key: string | undefined }[]> }): Promise<string[]> =>
  (await ui.findAll({ type: 'Box' })).map(b => b.key ?? '').filter(k => k.startsWith('row:'))

test('the cursor follows the focus ring: ❯ on that row; the first row is autoFocus at open; another pane and a denied move change nothing', async ($, on) => {
  mock.clock(on)
  let deny: string | undefined
  stubPane(on, () => snapshot([agent(), agent({ role: 'rev', dir_name: 'rev' })]), () => ({ deny }))
  await run($)
  const ui = await $.ui.mount({ ...paneProps(), surface: 'terminal' })
  expect((await ui.find({ key: 'open:stage-a/worker' }))?.props.autoFocus).toBe(true)
  expect((await ui.find({ key: 'row:stage-a/worker' }))?.text).toMatch(/^❯ /)
  expect((await ui.find({ key: 'row:stage-a/rev' }))?.text).not.toMatch(/^❯/)

  expect(await focus($, 'open:stage-a/rev', 'agent-top')).toEqual({})
  expect((await ui.find({ key: 'row:stage-a/rev' }))?.text).toMatch(/^❯ /)
  expect((await ui.find({ key: 'row:stage-a/worker' }))?.text).not.toMatch(/^❯/)
  expect((await ui.find({ key: 'open:stage-a/worker' }))?.props.autoFocus).toBeUndefined() // the ring has been placed

  await focus($, 'open:stage-a/worker', 'another-pane')
  expect((await ui.find({ key: 'row:stage-a/rev' }))?.text).toMatch(/^❯ /)
  deny = 'the site does not hold the keyboard'
  expect((await focus($, 'open:stage-a/worker', 'agent-top')).deny).toBe(deny)
  expect((await ui.find({ key: 'row:stage-a/rev' }))?.text).toMatch(/^❯ /)

  // a tab keeps the cursor where it was; Back from a card puts it on that agent's row
  await focus($, 'refresh', 'agent-top')
  expect((await ui.find({ key: 'row:stage-a/rev' }))?.text).toMatch(/^❯ /)
  await ui.unmount()
})

test('the list is a window around the cursor that fits the body: 30 agents in 12 rows, "↓ N more", the window follows the ring', async ($, on) => {
  const clock = mock.clock(on)
  const moves: string[] = []
  const many = Array.from({ length: 30 }, (_, i) => agent({ role: `w${i}`, dir_name: `w${i}` }))
  stubPane(on, () => snapshot(many), undefined, moves)
  await run($)
  const ui = await $.ui.mount({ ...paneProps({ rows: 12 }), surface: 'terminal' })
  let rows = await rowKeys(ui)
  expect(rows).toEqual(['row:stage-a/w0', 'row:stage-a/w1', 'row:stage-a/w2', 'row:stage-a/w3'])
  expect(rows.length * 2 + 4).toBeLessThanOrEqual(12) // header, tabs, the rule, two lines per agent, the footer
  expect((await ui.find({ key: 'footer' }))?.text).toMatch(/^↓ 26 more/)
  expect((await ui.find({ key: 'open:stage-a/w0' }))?.props.hotkey).toBe('1')
  moves.length = 0

  await focus($, 'open:stage-a/w3', 'agent-top') // the last drawn row: the next one comes in
  rows = await rowKeys(ui)
  expect(rows).toEqual(['row:stage-a/w2', 'row:stage-a/w3', 'row:stage-a/w4'])
  expect((await ui.find({ key: 'more-up' }))?.props.label).toBe('↑ 2 more') // a Button: the ring can always go up
  expect((await ui.find({ key: 'more-down' }))?.props.label).toBe('↓ 25 more')
  expect((await ui.find({ key: 'open:stage-a/w2' }))?.props.hotkey).toBe('1') // hotkeys number the window's rows
  // The module then puts the ring back on w3 with $.ui.focus (the ring keeps its place among the Buttons, not its
  // element). The kit does not route a module's own $.ui.focus to a test's ui.focus hook ("no implementation for
  // ui.focus"), so that step is checked in the live pty run (inline, where the window moves), not here.
  await clock.advance(3000) // a poll with the same rows: the window stays where the cursor put it
  expect(await rowKeys(ui)).toEqual(['row:stage-a/w2', 'row:stage-a/w3', 'row:stage-a/w4'])
  expect(moves).toEqual(['person:open:stage-a/w3'])

  await focus($, 'more-up', 'agent-top') // the ring onto `↑ 2 more`: the cursor goes to w1
  expect((await ui.find({ key: 'row:stage-a/w1' }))?.text).toMatch(/^❯ /)
  await ui.press({ key: 'more-down' }) // Enter on `↓ N more` moves it past the bottom edge
  expect((await rowKeys(ui)).length).toBeGreaterThan(0)
  expect((await ui.find({ key: 'row:stage-a/w1' }))?.text ?? '').not.toMatch(/^❯ /)
  await ui.unmount()
})

/** The person's ↑ / ↓: the ring onto the drawn Button before / after the cursor row's, as the engine walks them. */
async function arrow($: Engine, ui: { findAll: (q: { type: string }) => Promise<{ key: string | undefined }[]> }, cursor: string, dir: -1 | 1): Promise<void> {
  const keys = (await ui.findAll({ type: 'Button' })).map(b => b.key ?? '')
  const next = keys[keys.indexOf(`open:${cursor}`) + dir]
  if (next !== undefined) await focus($, next)
}

test('↑ and ↓ reach every agent and come back, docked and inline, two-line and one-line rows', async ($, on) => {
  mock.clock(on)
  const many = Array.from({ length: 12 }, (_, i) => agent({ role: `w${i}`, dir_name: `w${i}`, stage: i < 6 ? 'stage-a' : 'stage-b' }))
  stubPane(on, () => snapshot(many, { stages: ['stage-a', 'stage-b'] }))
  await run($)
  for (const props of [paneProps({ rows: 8 }), paneProps({ rows: 12 }), paneProps({ placement: 'dock', cols: 76, rows: 14 })]) {
    const ui = await $.ui.mount({ ...props, surface: 'terminal' })
    const cursor = async () => {
      const rows = (await ui.findAll({ type: 'Box' })).filter(b => (b.key ?? '').startsWith('row:'))
      return rows.find(r => r.text.startsWith('❯'))?.key?.slice(4) ?? ''
    }
    const seen: string[] = [await cursor()]
    for (let i = 0; i < 11; i += 1) {
      await arrow($, ui, seen[seen.length - 1] ?? '', 1)
      seen.push(await cursor())
    }
    expect(seen).toEqual(many.map(a => `${a.stage}/${a.dir_name}`))
    for (let i = 0; i < 11; i += 1) {
      await arrow($, ui, seen[seen.length - 1] ?? '', -1)
      seen.push(await cursor())
    }
    expect(seen.at(-1)).toBe('stage-a/w0')
    await ui.unmount()
  }
})

/** Cells a found element takes on one line: text, a plain Button's `1: ` and a framed one's `[ ]`. */
function cells(node: unknown): number {
  if (typeof node === 'string') return Array.from(node).length
  if (typeof node === 'number') return String(node).length
  if (!node || typeof node !== 'object') return 0
  const n = node as { type?: string; props?: Record<string, unknown>; children?: unknown[] }
  if (n.type === 'Button') return Array.from(String(n.props?.label ?? '')).length + (n.props?.plain ? (n.props?.hotkey ? 3 : 0) : 4)
  const kids = Array.isArray(n.children) ? n.children : []
  if (n.type === 'Box' && n.props?.flexDirection === 'column') return Math.max(0, ...kids.map(cells))
  return kids.reduce((sum: number, k) => sum + cells(k), 0)
}

test('no row is wider than the body: every view at 23, 24, 25, 30, 40, 44, 60 and 76 columns, inline and docked', async ($, on) => {
  mock.clock(on)
  const rows = [
    agent({ role: 'a-rather-long-role-name', dir_name: 'a', title: 'A task title long enough to need clipping everywhere (w-1)', ctx_window: 200000 }),
    agent({ role: 'q', dir_name: 'q', quiet: true, stage: 'a-very-long-stage-name' }),
    agent({ role: 'e', dir_name: 'e', state: 'error', alive: false, action: null, result: { subtype: 'error_max_turns', is_error: true, text: 'ran out of turns after a long while' } }),
  ]
  const json = snapshot(rows, {
    stages: ['stage-a', 'a-very-long-stage-name'],
    journal_tail: [{ stage: 'stage-a', time: '12:01', tag: 'a-long-journal-tag', text: 'done: a journal line long enough to wrap twice in a narrow pane' }],
    locks: [{ kind: 'main-merge-and-more', repo: 'santinel', owner_name: 'Hub core-c #28', until: '2026-10-31T23:59:00+03:00', active: true, why: 'held' }],
    questions: { 'a-very-long-stage-name': { open: 12, overdue: 3, line: 'x', items: ['Q-9 [a-very-long-stage-name] open OVERDUE — decide this long question?'] } },
    limits: { info: { unifiedWindows: { five_hour: { utilization: 0.42, resetsAt: 1791547735 } } }, seen_at: 1790972433 },
    codex_limits: { 'codex-second': { info: { primary: { used_percent: 21, window_minutes: 10080, resets_at: 1791547735 } }, seen_at: 1790972433 } },
  })
  stubPane(on, () => json, undefined, [], [{ at: '12:00:01', kind: 'tool', sub: false, tool: 'MultiEditorTool', text: 'a long tool call text', detail: null }])
  await run($)
  const wide: string[] = []
  for (const placement of ['inline', 'dock'] as const) {
    for (const cols of [23, 24, 25, 30, 40, 44, 60, 76]) {
      const ui = await $.ui.mount({ ...paneProps({ placement, cols, rows: 40 }), surface: 'terminal' })
      const framed = placement === 'dock' && cols >= 44
      const w = cols - (framed ? 4 : 0)
      for (const view of ['view-agents', 'card', 'view-journal', 'view-summary']) {
        if (view === 'card') await ui.press({ key: 'open:stage-a/a' })
        else await ui.press({ key: view })
        for (const b of await ui.findAll({ type: 'Box' })) {
          const k = b.key ?? ''
          if (!k || k === 'frame' || k === 'card' || k.startsWith('sum-') || k.startsWith('tab:')) continue
          const inner = framed && (k.startsWith('card-') || k.startsWith('limit:') || k.startsWith('q:') || k.startsWith('lock:')) ? w - 4 : w
          const used = cells(b)
          if (used > inner) wide.push(`${placement} ${cols}: ${k} takes ${used} > ${inner}`)
        }
        if (view === 'card') await ui.press({ key: 'back' })
      }
      await ui.unmount()
    }
  }
  expect(wide).toEqual([])
  // the measure sees whole rows: an agent row fills the body exactly, and a row too wide for a body is caught
  const ui = await $.ui.mount({ ...paneProps({ cols: 76 }), surface: 'terminal' })
  await ui.press({ key: 'view-agents' })
  const agentRow = await ui.find({ key: 'row:stage-a/a' })
  expect(cells(agentRow)).toBe(76)
  expect(cells(agentRow) > 60).toBe(true)
  await ui.unmount()
})

test('state badges: LIVE green, QUIET yellow, DONE grey, FAIL and DIED red', async ($, on) => {
  mock.clock(on)
  const rows = [
    agent({ role: 'a', dir_name: 'a' }),
    agent({ role: 'q', dir_name: 'q', quiet: true }),
    agent({ role: 'd', dir_name: 'd', state: 'done', alive: false, action: null, result: DONE }),
    agent({ role: 'e', dir_name: 'e', state: 'error', alive: false, action: null, result: { subtype: 'error_max_turns', is_error: true, text: 'x' } }),
    agent({ role: 'x', dir_name: 'x', state: 'dead', alive: false, action: null }),
  ]
  stubPane(on, () => snapshot(rows))
  await run($)
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...paneProps({ rows: 30 }), surface })
    const badge = async (label: string) => (await ui.find({ type: 'Text', text: new RegExp(`^ ${label} *$`) }))?.props
    expect(await badge('LIVE')).toMatchObject({ backgroundColor: 'green', color: 'black', bold: true })
    expect(await badge('QUIET')).toMatchObject({ backgroundColor: 'yellow', color: 'black' })
    expect(await badge('DONE')).toMatchObject({ backgroundColor: 'gray', color: 'black', bold: true })
    expect(await badge('FAIL')).toMatchObject({ backgroundColor: 'red', color: 'white' })
    expect(await badge('DIED')).toMatchObject({ backgroundColor: 'red', color: 'white' })
    expect((await ui.find({ key: 'header' }))?.text).toMatch(/● 2 +✓ 1 +✗ 2/)
    expect((await ui.find({ type: 'Text', text: ' ✗ 2 ' }))?.props.backgroundColor).toBe('red')
    expect(await ui.findAll({ type: 'Raster' })).toEqual([])
    expect(await ui.findAll({ type: 'Svg' })).toEqual([])
    await ui.unmount()
  }
})

test('limit bars: 20 cells, coloured by level (42% green, 91% red); the context bar uses ctx_window', async ($, on) => {
  mock.clock(on)
  const json = snapshot([agent({ ctx_tokens: 52000, ctx_window: 200000 })], {
    limits: { info: { unifiedWindows: { five_hour: { utilization: 0.42 } } }, seen_at: 1790972433 },
    codex_limits: { codex: { info: { primary: { used_percent: 91, window_minutes: 300 } }, seen_at: 1790972433 } },
  })
  stubPane(on, () => json)
  await run($)
  const ui = await $.ui.mount({ ...paneProps({ rows: 30 }), surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: ' 26%' }))?.props.dimColor).toBe(true) // the list's context column: low, so quiet
  await ui.press({ key: 'view-summary' })
  expect((await ui.find({ type: 'Text', text: /^█{8}$/ }))?.props.color).toBe('green')
  expect((await ui.find({ type: 'Text', text: /^░{12}$/ }))?.props.dimColor).toBe(true)
  expect((await ui.find({ type: 'Text', text: /^█{18}$/ }))?.props.color).toBe('red')
  await ui.press({ key: 'view-agents' })
  await ui.press({ key: 'open:stage-a/worker' })
  expect((await ui.find({ key: 'card-context' }))?.text).toMatch(/^Context +█+░+ 26% 52k \/ 200k/)
  await ui.unmount()
})

test('a context near its window is red in the list; an older CLI without ctx_window shows the size alone', async ($, on) => {
  mock.clock(on)
  let json = snapshot([agent({ ctx_tokens: 170000, ctx_window: 200000 })])
  stubPane(on, () => json)
  await run($)
  let ui = await $.ui.mount({ ...paneProps(), surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: ' 85%' }))?.props.color).toBe('red')
  await ui.unmount()

  const older = agent()
  delete older.ctx_window
  json = snapshot([older])
  await run($)
  ui = await $.ui.mount({ ...paneProps(), surface: 'terminal' })
  expect((await ui.find({ key: 'now:stage-a/worker' }))?.text).toMatch(/· 52k$/)
  await ui.press({ key: 'open:stage-a/worker' })
  expect((await ui.find({ key: 'card-context' }))?.text).toMatch(/^Context +52k/)
  expect((await ui.find({ key: 'card-context' }))?.text).not.toMatch(/%/)
  await ui.unmount()
})

test('layouts: dock has the cyan frame, a card framed in its state colour and framed Summary sections; inline and narrow have none', async ($, on) => {
  mock.clock(on)
  stubPane(on, () => snapshot([agent()], { locks: [{ kind: 'main-merge', repo: 'r', owner_name: 'o', until: '2026-10-31T23:59:00+03:00', active: false, why: 'w' }] }))
  await run($)
  for (const surface of ['terminal', 'desktop'] as const) {
    let ui = await $.ui.mount({ ...paneProps({ placement: 'dock', cols: 76, rows: 40 }), surface })
    expect((await ui.find({ key: 'frame' }))?.props).toMatchObject({ borderStyle: 'round', borderColor: '#77dce8' })
    expect((await ui.find({ key: 'now:stage-a/worker' }))?.text).toMatch(/sonnet-5-5\/hi · 7t · 52k$/)
    await ui.press({ key: 'view-summary' })
    expect((await ui.find({ key: 'sum-limits' }))?.props).toMatchObject({ borderStyle: 'round', borderDimColor: true })
    expect((await ui.find({ key: 'lock:0' }))?.text).toMatch(/main-merge/)
    expect((await ui.find({ type: 'Text', text: / r +until/ }))?.props.strikethrough).toBe(true) // the expired lock
    await ui.press({ key: 'view-agents' })
    await ui.press({ key: 'open:stage-a/worker' })
    expect((await ui.find({ key: 'card' }))?.props).toMatchObject({ borderStyle: 'round', borderColor: 'green' })
    expect((await ui.find({ key: 'back' }))?.props.autoFocus).toBe(true)
    await ui.press({ key: 'back' })
    await ui.unmount()

    ui = await $.ui.mount({ ...paneProps({ placement: 'inline', cols: 76 }), surface })
    expect(await ui.find({ key: 'frame' })).toBeUndefined()
    await ui.press({ key: 'view-summary' })
    expect(await ui.find({ key: 'sum-limits' })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /^── Plan limits ─+$/ })).toBeDefined()
    await ui.press({ key: 'view-agents' })
    await ui.press({ key: 'open:stage-a/worker' })
    expect((await ui.find({ key: 'card' }))?.props.borderStyle).toBeUndefined()
    await ui.press({ key: 'back' })
    await ui.unmount()

    ui = await $.ui.mount({ ...paneProps({ placement: 'dock', cols: 40 }), surface }) // narrow: compact even in the dock
    expect(await ui.find({ key: 'frame' })).toBeUndefined()
    expect((await ui.find({ key: 'now:stage-a/worker' }))?.text).not.toMatch(/sonnet/)
    expect((await ui.find({ key: 'refresh' }))?.props.label).toBe('↻')
    await ui.unmount()
  }
})

test('unbacked section labels and feed tools inherit host text; ice titles keep contrasting backing', async ($, on) => {
  mock.clock(on)
  const feed = [
    { at: '12:00:01', kind: 'tool', sub: false, tool: 'Bash', text: 'run tests', detail: null },
    { at: '12:00:02', kind: 'result_err', sub: false, tool: 'Bash', text: 'bad command', detail: null },
  ]
  stubPane(on, () => snapshot([agent()]), undefined, [], feed)
  await run($)
  for (const surface of ['terminal', 'desktop'] as const) {
    for (const props of [
      paneProps({ placement: 'inline', cols: 76 }),
      paneProps({ placement: 'inline', cols: 30 }),
      paneProps({ placement: 'dock', cols: 40 }),
      paneProps({ placement: 'dock', cols: 76 }),
    ]) {
      const ui = await $.ui.mount({ ...props, surface })
      await ui.press({ key: 'view-summary' })
      // Inline/compact sections are unbacked Text, so the host controls contrast on light and dark themes.
      const rules = await ui.findAll({ type: 'Text', text: /^──/ })
      if (props.props.placement === 'inline' || props.props.bodyColumns < 44) expect(rules.length).toBeGreaterThan(0)
      for (const label of rules) {
        expect(label.props.color).toBeUndefined()
        expect(label.props.backgroundColor).toBeUndefined()
        expect(label.props.dimColor).not.toBe(true)
      }
      const title = await ui.find({ type: 'Text', text: /^(Delamain · )?agent-top$/ })
      expect(title).toBeDefined()
      expect(title?.props.color).toBeDefined()
      expect(title?.props.backgroundColor).toBeDefined()
      expect(title?.props.color).not.toBe(title?.props.backgroundColor)
      await ui.press({ key: 'view-agents' })
      await ui.press({ key: 'open:stage-a/worker' })
      const tool = await ui.find({ type: 'Text', text: /^▸ Bash +$/ })
      expect(tool).toBeDefined()
      expect(tool?.props.color).toBeUndefined()
      expect(tool?.props.backgroundColor).toBeUndefined()
      expect(tool?.props.dimColor).not.toBe(true)
      // Host-adaptive tool labels must not erase the feed's semantic error distinction.
      expect((await ui.find({ type: 'Text', text: /^◂ error *$/ }))?.props.color).toBe('red')
      await ui.press({ key: 'back' })
      await ui.unmount()
    }
  }
})

test('the branded header shrinks before controls; severity badges and engine focus remain distinct', async ($, on) => {
  mock.clock(on)
  stubPane(on, () => snapshot([agent(), agent({ role: 'quiet', dir_name: 'quiet', quiet: true })]))
  await run($)
  for (const surface of ['terminal', 'desktop'] as const) {
    for (const cols of [23, 30, 44, 76]) {
      const ui = await $.ui.mount({ ...paneProps({ cols }), surface })
      await ui.press({ key: 'view-agents' })
      const header = await ui.find({ key: 'header' })
      expect(cells(header)).toBeLessThanOrEqual(cols)
      expect(header?.text).toMatch(cols >= 44 ? /^Delamain · agent-top/ : /^agent-top/)
      expect((await ui.find({ type: 'Text', text: cols >= 44 ? 'Delamain · agent-top' : 'agent-top' }))?.props.bold).toBe(true)
      expect(await ui.find({ key: 'open:stage-a/worker' })).toBeDefined()
      expect((await ui.find({ key: 'open:stage-a/worker' }))?.props.autoFocus).toBe(true)
      expect((await ui.find({ type: 'Text', text: /QUIET|◐/ }))?.props.backgroundColor).toBe('yellow')
      await ui.press({ key: 'view-journal' })
      expect(await ui.find({ key: 'view-journal' })).toBeDefined() // selected tab keeps its address
      await ui.unmount()
    }
  }
})

test('the journal: a tag pill in a stable colour, the line coloured by its first word, a rule per stage', async ($, on) => {
  mock.clock(on)
  stubPane(on, () =>
    snapshot([agent()], {
      journal_tail: [
        { stage: 'stage-a', time: '12:01', tag: 'w-1', text: 'DONE: tests green' },
        { stage: 'stage-b', time: '12:02', tag: 'rev', text: 'FAIL lint' },
      ],
    }),
  )
  await run($)
  const ui = await $.ui.mount({ ...paneProps(), surface: 'terminal' })
  await ui.press({ key: 'view-journal' })
  expect((await ui.find({ type: 'Text', text: /^ w-1 +$/ }))?.props).toMatchObject({ backgroundColor: tagColor('w-1'), color: 'black' })
  expect((await ui.find({ type: 'Text', text: 'DONE: tests green' }))?.props.color).toBe('green')
  expect((await ui.find({ type: 'Text', text: 'FAIL lint' }))?.props.color).toBe('red')
  expect(await ui.find({ type: 'Text', text: /^── stage-b ─+$/ })).toBeDefined()
  expect((await ui.find({ key: 'tab:journal' }))?.props.backgroundColor).toBe('#77dce8') // the active tab: filled
  expect((await ui.find({ key: 'view-journal' }))?.props.label).toBe(' Journal ') // and still a Button: the ring never loses it
  expect((await ui.find({ key: 'view-summary' }))?.props).toMatchObject({ label: 'Summary', hotkey: 's', dimColor: true })
  await ui.unmount()
})

test('windowAround, barCells, levelColor, tagColor, journalColor, ctxPercent', async () => {
  const two = (n: number) => Array.from({ length: n }, () => 2)
  expect(windowAround([], 0, 10)).toEqual({ start: 0, end: 0 })
  expect(windowAround(two(3), 0, 100)).toEqual({ start: 0, end: 3 })
  expect(windowAround(two(30), 0, 8)).toEqual({ start: 0, end: 4 })
  expect(windowAround(two(30), 3, 8)).toEqual({ start: 2, end: 6 })
  expect(windowAround(two(30), 29, 8)).toEqual({ start: 26, end: 30 })
  expect(windowAround(two(30), 15, 1)).toEqual({ start: 15, end: 16 }) // the cursor's row even when nothing fits
  expect(windowAround([1, 2, 2, 1, 2], 4, 5)).toEqual({ start: 2, end: 5 })
  expect(barCells(42, 20)).toEqual({ full: '█'.repeat(8), empty: '░'.repeat(12) })
  expect(barCells(0, 4)).toEqual({ full: '', empty: '░░░░' })
  expect(barCells(1, 20).full).toBe('█') // any use shows one cell
  expect(barCells(250, 5)).toEqual({ full: '█████', empty: '' })
  expect([levelColor(0), levelColor(59), levelColor(60), levelColor(84), levelColor(85), levelColor(100)]).toEqual(['green', 'green', 'yellow', 'yellow', 'red', 'red'])
  expect(tagColor('hub-1')).toBe(tagColor('hub-1'))
  expect(new Set(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'].map(tagColor)).size).toBeGreaterThan(2)
  expect([journalColor('done: x'), journalColor('FAIL y'), journalColor('review: z'), journalColor('plan: w'), journalColor('just text')]).toEqual(['green', 'red', 'magenta', 'cyan', undefined])
  const [a] = parseSnapshot(snapshot([agent({ ctx_tokens: 52000, ctx_window: 200000 })]), 0).agents
  const [b] = parseSnapshot(snapshot([agent({ ctx_window: 0 })]), 0).agents
  expect(a && ctxPercent(a)).toBe(26)
  expect(b?.ctx_window).toBeNull()
  expect(b && ctxPercent(b)).toBeNull()
})

test('the card fits a pane 23, 24 and 25 columns wide: the Feed rows too (time, kind, text)', async ($, on) => {
  mock.clock(on)
  const feed = [
    { at: '12:00:01', kind: 'tool', sub: false, tool: 'MultiEditorTool', text: 'abcdefgh ijklmnopq rstuvwxyz', detail: null },
    { at: '12:00:02', kind: 'text', sub: false, tool: null, text: 'abcdefghij klmnopqrst', detail: null },
    { at: '12:00:03', kind: 'result', sub: false, tool: 'Bash', text: 'abcdefghijklmnop', detail: null },
    { at: null, kind: 'end', sub: true, tool: null, text: 'end of run: abcdefghijkl', detail: null },
  ]
  stubPane(on, () => snapshot([agent()]), undefined, [], feed)
  await run($)
  const wide: string[] = []
  for (const placement of ['inline', 'dock'] as const) {
    for (const cols of [23, 24, 25]) {
      const ui = await $.ui.mount({ ...paneProps({ placement, cols, rows: 40 }), surface: 'terminal' })
      await ui.press({ key: 'open:stage-a/worker' })
      expect(await ui.find({ key: 'feed:0' })).toBeDefined()
      for (const b of await ui.findAll({ type: 'Box' })) {
        const k = b.key ?? ''
        if (k === 'frame' || k === 'card') continue
        const used = cells(b)
        if (used > cols) wide.push(`${placement} ${cols}: ${k || 'a row'} takes ${used}`)
      }
      for (const key of ['feed:0', 'feed:1', 'feed:2', 'feed:3']) {
        const used = cells(await ui.find({ key }))
        if (used > cols) wide.push(`${placement} ${cols}: ${key} takes ${used}`)
      }
      await ui.press({ key: 'back' })
      await ui.unmount()
    }
  }
  expect(wide).toEqual([])
})

// ---------------------------------------------------------------- the card's feed: loading → shown / error (the endless
// "loading the feed…" of 0.8.2: a failed or slow card call left the feed area saying "loading" for good)

const FEED = [
  { at: '12:00:01', kind: 'tool', sub: false, tool: 'Bash', text: 'run the tests', detail: 'pytest' },
  { at: '12:00:02', kind: 'result', sub: false, tool: 'Bash', text: '12 passed', detail: null },
]

/** The pane's usual stubs; `card` answers every `--agent` call, everything else gets the list of a worker and a reviewer. */
function stubCardCalls(on: On, card: (argv: readonly string[]) => Promise<ReturnType<typeof ran>> | ReturnType<typeof ran> | { deny: string }): void {
  const list = snapshot([agent(), agent({ role: 'rev', dir_name: 'rev', state: 'done', alive: false, action: null, result: DONE })])
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  stubPaneRecord(on)
  on('ui.toast', DONE_VOID)
  on('ui.status', DONE_VOID)
  on('process.run', ($, e) => (e.argv.includes('--agent') ? card(e.argv) : ran(list)))
}

test('the card feed: "loading" only while its call runs, then the rows; a failed call says why there; the next good one shows the rows', async ($, on) => {
  const clock = mock.clock(on)
  let mode: 'slow' | 'fail' | 'ok' = 'slow'
  stubCardCalls(on, async () => {
    if (mode === 'fail') return ran('', 1, "FAILED: no agent 'worker'\n")
    if (mode === 'slow') await clock.sleep(5000)
    return ran(cardJson(agent(), FEED))
  })
  await run($, '', 'agent-top')
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })

  await ui.press({ key: 'open:stage-a/worker' })
  expect(await ui.find({ text: 'loading the feed…' })).toBeDefined() // the call is still running
  await clock.advance(5000)
  expect((await ui.find({ key: 'feed:0' }))?.text).toMatch(/run the tests/)
  expect(await ui.find({ key: 'feed-note' })).toBeUndefined()

  mode = 'fail'
  await clock.advance(3000) // a refresh of the open card fails: the rows stay, the failure is said under them
  expect((await ui.find({ key: 'feed:0' }))?.text).toMatch(/run the tests/)
  expect((await ui.find({ key: 'feed-note' }))?.text).toBe("feed unavailable: FAILED: no agent 'worker' · retrying")
  expect(await ui.find({ key: 'error' })).toBeUndefined() // the card's own failure, not the pane's error line

  await ui.press({ key: 'back' })
  await ui.press({ key: 'open:stage-a/worker' }) // opened afresh while the CLI fails: the reason, never "loading"
  expect(await ui.find({ text: /loading/ })).toBeUndefined()
  expect((await ui.find({ key: 'feed-note' }))?.text).toBe("feed unavailable: FAILED: no agent 'worker' · retrying")

  mode = 'ok'
  await clock.advance(3000) // the next tick asks again and the rows come
  expect((await ui.find({ key: 'feed:1' }))?.text).toMatch(/12 passed/)
  expect(await ui.find({ key: 'feed-note' })).toBeUndefined()
  await ui.unmount()
})

test("a card answer that comes after the person opened another agent is dropped: never one agent's feed under another's title", async ($, on) => {
  const clock = mock.clock(on)
  let revCalls = 0
  stubCardCalls(on, async argv => {
    if (argv.includes('worker')) {
      await clock.sleep(5000)
      return ran(cardJson(agent(), [{ at: '12:00:01', kind: 'text', sub: false, tool: null, text: 'WORKER FEED', detail: null }]))
    }
    revCalls += 1
    if (revCalls === 1) return ran('', 1, 'FAILED: hub home is busy\n') // the reviewer's first call fails
    const rev = agent({ role: 'rev', dir_name: 'rev', state: 'done', alive: false, action: null, result: DONE })
    return ran(cardJson(rev, [{ at: '12:00:09', kind: 'text', sub: false, tool: null, text: 'REVIEW FEED', detail: null }]))
  })
  await run($, '', 'agent-top')
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'open:stage-a/worker' }) // its call takes 5 s
  await ui.press({ key: 'back' })
  await ui.press({ key: 'open:stage-a/rev' })
  expect((await ui.find({ key: 'card-title' }))?.text).toMatch(/rev/)
  expect(await ui.find({ text: 'loading the feed…' })).toBeDefined()
  await clock.advance(5000) // the worker's answer arrives: dropped; the reviewer's call runs right after it and fails
  expect((await ui.find({ key: 'card-title' }))?.text).toMatch(/DONE +rev/)
  expect(await ui.find({ text: /WORKER FEED/ })).toBeUndefined()
  expect((await ui.find({ key: 'feed-note' }))?.text).toBe('feed unavailable: FAILED: hub home is busy · retrying')
  await clock.advance(3000)
  expect((await ui.find({ key: 'feed:0' }))?.text).toMatch(/REVIEW FEED/)
  await ui.unmount()
})

test('/agent-top answers without waiting for a slow first snapshot; the pane says "loading" and fills when it comes', async ($, on) => {
  const clock = mock.clock(on)
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  stubPaneRecord(on)
  on('ui.toast', DONE_VOID)
  on('ui.status', DONE_VOID)
  on('process.run', async () => {
    await clock.sleep(20000) // a first run after an update reads every log once
    return ran(snapshot([agent()]))
  })
  const opening = run($, '', 'agent-top')
  await clock.advance(4000)
  expect((await opening).text).toBe('agent-top pane opened: no data yet')
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ text: /loading agents…/ })).toBeDefined()
  await ui.press({ key: 'view-journal' }) // the pane takes keys while the data loads
  expect(await ui.find({ text: /^loading…$/ })).toBeDefined()
  await ui.press({ key: 'view-agents' })
  await clock.advance(16000)
  expect(await ui.find({ key: 'open:stage-a/worker' })).toBeDefined()
  await ui.unmount()
})

test('a card call the engine kills on its timeout says so in one short line', async ($, on) => {
  mock.clock(on)
  stubCardCalls(on, () => ({ deny: 'delamain: $.process.run(/very/long/path/bin/agent-top) aborted: still running after 60000 ms' }))
  await run($, '', 'agent-top')
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'open:stage-a/worker' })
  expect((await ui.find({ key: 'feed-note' }))?.text).toBe('feed unavailable: agent-top gave no answer in 60 s · retrying')
  await ui.unmount()
})

// ---------------------------------------------------------------- Summary's Stages section: idle stages and the two-press close

const HUB = /\/bin\/hub$/
const CLOSE_ARGV = (stage: string): string[] => ['close', '--stage', stage, '--why', 'closed from the agent-top pane']

/** One stage's `stage_info` row of `agent-top --json`; idle for 3 h 20 m unless said otherwise. */
const stageInfo = (o: Row = {}): Row => ({
  goal: 'Ship the retro fixes', closed: null, last_activity_at: '2026-10-04T08:40:00+00:00', idle_s: 12000, idle: true, live: 0, ...o,
})
const CLOSED = { at: '2026-10-04T11:00:00+00:00', why: 'closed from the agent-top pane', by: 'hub' }

/** A snapshot of a live `stage-a` and the given other stages (idle unless their info says otherwise). */
const withStages = (info: Record<string, Row>, extra: Row = {}): string =>
  snapshot([agent()], {
    stages: ['stage-a', ...Object.keys(info)],
    stage_info: { 'stage-a': stageInfo({ idle: false, live: 1, idle_s: 4, goal: 'Build the thing' }), ...info },
    closed_hidden: [],
    idle_after_s: 7200,
    ...extra,
  })

/** The pane's stubs; `hub` answers `bin/hub`, `json` every `agent-top` call. Every argv is logged in `calls`. */
function stubStages(on: On, json: (argv: readonly string[]) => string, hub: (argv: readonly string[]) => unknown, calls: string[][] = [], moves: string[] = []): void {
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  on('ui.panes', () => ({ value: [] }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.toast', DONE_VOID)
  on('ui.status', DONE_VOID)
  on('ui.focus', ($, e) => (moves.push(`${e.origin.kind}:${e.element ?? ''}`), {}))
  on('process.run', ($, e) => {
    calls.push([...e.argv])
    return (HUB.test(e.argv[0] ?? '') ? hub(e.argv) : ran(json(e.argv))) as ReturnType<typeof ran>
  })
}

const hubCalls = (calls: string[][]): string[][] => calls.filter(c => HUB.test(c[0] ?? '')).map(c => c.slice(1))

test('parseSnapshot reads stage_info, closed_hidden and idle_after_s; an older CLI or a malformed row leaves them empty', async () => {
  const s = parseSnapshot(
    snapshot([agent()], {
      stage_info: { 'stage-a': stageInfo({ closed: CLOSED, idle: false }), b: stageInfo({ goal: 'G', idle_s: null, last_activity_at: null, live: 2 }) },
      closed_hidden: ['x', 'y'],
      idle_after_s: 7200,
    }),
    0,
  )
  expect(s.stage_info['stage-a']).toEqual({ goal: 'Ship the retro fixes', closed: CLOSED, last_activity_at: '2026-10-04T08:40:00+00:00', idle_s: 12000, idle: false, live: 0 })
  expect(s.stage_info.b).toEqual({ goal: 'G', closed: null, last_activity_at: null, idle_s: null, idle: true, live: 2 })
  expect(s.closed_hidden).toEqual(['x', 'y'])
  expect(s.idle_after_s).toBe(7200)

  const older = parseSnapshot(snapshot([agent()]), 0) // none of the three fields
  expect([older.stage_info, older.closed_hidden, older.idle_after_s]).toEqual([{}, [], null])

  const odd = parseSnapshot(snapshot([agent()], { stage_info: { a: 5, b: { closed: 'yes', idle_s: 'x', idle: 'true', live: null } }, closed_hidden: ['x', 7, null], idle_after_s: 'soon' }), 0)
  expect(odd.stage_info).toEqual({ b: { goal: '', closed: null, last_activity_at: null, idle_s: null, idle: false, live: 0 } })
  expect([odd.closed_hidden, odd.idle_after_s]).toEqual([['x'], null])
})

test('idleStages: only idle, open stages without live agents, the longest idle first, in the stage filter; closedStages, closedHiddenCount', async () => {
  const snap = parseSnapshot(
    snapshot([agent()], {
      stages: ['a', 'b', 'c', 'd', 'e', 'f', 'gone'],
      stage_info: {
        a: stageInfo({ idle_s: 100 }),
        b: stageInfo({ idle_s: 9000 }),
        c: stageInfo({ idle_s: null }),
        d: stageInfo({ idle: false }),
        e: stageInfo({ closed: CLOSED, idle: false }),
        f: stageInfo({ live: 1 }), // the CLI would not call it idle; a stage with a live agent is never offered anyway
        stray: stageInfo(), // not in `stages`
      },
      closed_hidden: ['old', 'a'],
    }),
    0,
  )
  expect(idleStages(snap, []).map(r => r.stage)).toEqual(['b', 'a', 'c'])
  expect(idleStages(snap, ['a', 'c', 'e']).map(r => r.stage)).toEqual(['a', 'c'])
  expect(closedStages(snap, []).map(r => r.stage)).toEqual(['e'])
  expect(closedStages(snap, ['a'])).toEqual([])
  expect([closedHiddenCount(snap, []), closedHiddenCount(snap, ['a']), closedHiddenCount(snap, ['b'])]).toEqual([2, 1, 0])
  expect(idleStages(parseSnapshot(snapshot([agent()]), 0), [])).toEqual([]) // an older CLI: nothing to offer
})

test('Summary: an idle stage has a close Button, the first press only arms it, the second runs `hub close` with exactly the agreed argv and refreshes', async ($, on) => {
  mock.clock(on)
  const calls: string[][] = []
  let isClosed = false
  stubStages(
    on,
    () => (isClosed ? withStages({}, { closed_hidden: ['retro'] }) : withStages({ retro: stageInfo() })),
    () => ((isClosed = true), ran('closed stage retro: 0 roles retired\nmore\n')),
    calls,
  )
  await run($)
  for (const surface of ['terminal', 'desktop'] as const) {
    isClosed = false
    calls.length = 0
    const ui = await $.ui.mount({ ...paneProps({ rows: 40 }), surface })
    await ui.press({ key: 'view-summary' })
    expect((await ui.find({ key: 'stage:retro' }))?.text).toMatch(/^retro +idle 3h20 +Ship the retro fixes ?close$/)
    expect(await ui.find({ key: 'stage:stage-a' })).toBeUndefined() // it has a live agent
    const button = await ui.find({ key: 'close:retro' })
    expect(button?.type).toBe('Button')
    expect(button?.props.label).toBe('close')
    expect(await ui.find({ key: 'sum-stages' })).toBeUndefined() // inline: a rule, not a frame
    expect(await ui.find({ type: 'Text', text: /^── Stages ─+$/ })).toBeDefined()

    await ui.press({ key: 'close:retro' }) // the first press: armed, nothing runs
    expect(hubCalls(calls)).toEqual([])
    expect((await ui.find({ key: 'close:retro' }))?.props.label).toBe('confirm close')
    expect((await ui.find({ type: 'Text', text: 'confirm close' }))?.props).toMatchObject({ color: 'red', bold: true })
    expect((await ui.find({ key: 'close-hint' }))?.text).toMatch(/^press again to close retro: its hub's locks are released, roles/)
    expect(calls.some(c => c.includes('--force'))).toBe(false)

    await ui.press({ key: 'close:retro' }) // the second one: the command
    expect(hubCalls(calls)).toEqual([CLOSE_ARGV('retro')])
    expect(calls.find(c => HUB.test(c[0] ?? ''))?.[0]).toMatch(/\/bin\/hub$/)
    expect(calls.at(-1)?.slice(1)).toEqual(['--json']) // refreshed at once: the stage is gone from the list
    expect(await ui.find({ key: 'close:retro' })).toBeUndefined()
    expect(await ui.find({ key: 'close-hint' })).toBeUndefined()
    const note = await ui.find({ key: 'close-note' })
    expect(note?.text).toBe('✓ closed stage retro: 0 roles retired')
    expect((await ui.find({ type: 'Text', text: /^✓ closed stage retro/ }))?.props.color).toBe('green')
    expect((await ui.find({ type: 'Text', text: /^no idle stages · 1 closed hidden \(l shows them\)$/ }))?.props.dimColor).toBe(true)
    expect(calls.some(c => c.includes('--force'))).toBe(false)
    await ui.unmount()
  }
})

test('a refused close (exit 2) shows the first stderr line in red and keeps the stage; a failed step (exit 1), a missing hub and a timeout say so too; never --force', async ($, on) => {
  mock.clock(on)
  const calls: string[][] = []
  let answer: () => unknown = () => ran('', 2, 'refused: retro has 1 live agent (worker)\nstop it first\n')
  stubStages(on, () => withStages({ retro: stageInfo() }), () => answer(), calls)
  await run($)
  const ui = await $.ui.mount({ ...paneProps({ rows: 40 }), surface: 'terminal' })
  await ui.press({ key: 'view-summary' })
  const closeOnce = async () => {
    await ui.press({ key: 'close:retro' })
    await ui.press({ key: 'close:retro' })
  }

  await closeOnce()
  expect((await ui.find({ key: 'close-note' }))?.text).toBe('✗ retro: refused: retro has 1 live agent (worker)')
  expect((await ui.find({ type: 'Text', text: /^✗ retro: refused/ }))?.props.color).toBe('red')
  expect((await ui.find({ key: 'close:retro' }))?.props.label).toBe('close') // still there, disarmed: a retry needs two presses again
  expect(await ui.find({ text: /stop it first/ })).toBeUndefined()

  answer = () => ran('partial\n', 1, 'FAILED: could not stop the background hub\n')
  await closeOnce()
  expect((await ui.find({ key: 'close-note' }))?.text).toBe('✗ retro: FAILED: could not stop the background hub')
  answer = () => ran('', 1, '') // nothing said
  await closeOnce()
  expect((await ui.find({ key: 'close-note' }))?.text).toBe('✗ retro: hub exited with 1')
  answer = () => ran('', 127, '')
  await closeOnce()
  expect((await ui.find({ key: 'close-note' }))?.text).toMatch(/^✗ retro: hub cannot run/)
  answer = () => ({ deny: 'spawn ENOENT: no such file or directory' })
  await closeOnce()
  expect((await ui.find({ key: 'close-note' }))?.text).toMatch(/^✗ retro: hub is missing/)
  answer = () => ({ deny: 'delamain: $.process.run(/p/bin/hub) aborted: still running after 60000 ms' })
  await closeOnce()
  expect((await ui.find({ key: 'close-note' }))?.text).toMatch(/^✗ retro: hub gave no answer in 60 s; look at the stage/)

  expect(hubCalls(calls)).toEqual(Array.from({ length: 6 }, () => CLOSE_ARGV('retro')))
  expect(calls.some(c => c.includes('--force'))).toBe(false)
  await ui.unmount()
})

test('a close whose hub session still runs shows the ATTENTION in yellow, whole, how to end it included', async ($, on) => {
  mock.clock(on)
  const calls: string[][] = []
  const attention =
    'closed stage retro: done. ATTENTION: the stage\'s hub "Hub retro #4" (hub-4, sid 11111111) still runs: other hubs can still message it by name and it answers — archive it in Desktop (local_abc). Hidden from agent-top.'
  stubStages(on, () => withStages({ retro: stageInfo() }), () => ran(`${attention}\nmore\n`), calls)
  await run($)
  const ui = await $.ui.mount({ ...paneProps({ rows: 40 }), surface: 'terminal' })
  await ui.press({ key: 'view-summary' })
  await ui.press({ key: 'close:retro' })
  await ui.press({ key: 'close:retro' })
  const note = await ui.find({ key: 'close-note' })
  expect(note?.text).toMatch(/^⚠ closed stage retro: done\. ATTENTION/)
  expect((await ui.find({ type: 'Text', text: /^⚠ closed stage retro/ }))?.props).toMatchObject({ color: 'yellow' })
  expect((await ui.findAll({ type: 'Text', text: /archive it in Desktop \(local_abc\)/ })).length).toBe(1)
  await ui.unmount()
})

test('a first press expires after 10 s, and arming another stage drops the first: only a second press on the same Button closes', async ($, on) => {
  const clock = mock.clock(on)
  const calls: string[][] = []
  stubStages(on, () => withStages({ retro: stageInfo(), spike: stageInfo({ idle_s: 9000 }) }), () => ran('closed\n'), calls)
  await run($)
  const ui = await $.ui.mount({ ...paneProps({ rows: 40 }), surface: 'terminal' })
  await ui.press({ key: 'view-summary' })
  const labels = async () => [(await ui.find({ key: 'close:spike' }))?.props.label, (await ui.find({ key: 'close:retro' }))?.props.label]
  expect(await labels()).toEqual(['close', 'close'])
  expect((await ui.findAll({ type: 'Button' })).map(b => b.key).filter(k => k?.startsWith('close:'))).toEqual(['close:retro', 'close:spike']) // the longest idle first

  await ui.press({ key: 'close:retro' })
  expect(await labels()).toEqual(['close', 'confirm close'])
  await clock.advance(9000)
  expect(await labels()).toEqual(['close', 'confirm close'])
  await clock.advance(1500) // 10 s since the press
  expect(await labels()).toEqual(['close', 'close'])
  expect(await ui.find({ key: 'close-hint' })).toBeUndefined()
  await ui.press({ key: 'close:retro' }) // a press after the expiry is a first press again
  expect(await labels()).toEqual(['close', 'confirm close'])

  await ui.press({ key: 'close:spike' }) // another stage armed: retro is dropped
  expect(await labels()).toEqual(['confirm close', 'close'])
  await ui.press({ key: 'close:retro' }) // so this arms retro again and runs nothing
  expect(await labels()).toEqual(['close', 'confirm close'])
  expect(hubCalls(calls)).toEqual([])

  await ui.press({ key: 'view-journal' }) // leaving the view drops an armed stage as well
  await ui.press({ key: 'view-summary' })
  expect(await labels()).toEqual(['close', 'close'])
  await ui.unmount()
})

test('one close at a time: while it runs the Button says closing… and presses are ignored; the result comes with the refresh', async ($, on) => {
  const clock = mock.clock(on)
  const calls: string[][] = []
  let isClosed = false
  stubStages(
    on,
    () => (isClosed ? withStages({ spike: stageInfo() }) : withStages({ retro: stageInfo(), spike: stageInfo({ idle_s: 9000 }) })),
    async () => {
      await clock.sleep(5000)
      isClosed = true
      return ran('closed stage retro\n')
    },
    calls,
  )
  await run($)
  const ui = await $.ui.mount({ ...paneProps({ rows: 40 }), surface: 'terminal' })
  await ui.press({ key: 'view-summary' })
  await ui.press({ key: 'close:retro' })
  await ui.press({ key: 'close:retro' })
  expect((await ui.find({ key: 'close:retro' }))?.props.label).toBe('closing…')
  expect(hubCalls(calls)).toEqual([CLOSE_ARGV('retro')])

  await ui.press({ key: 'close:retro' }) // ignored: no second command, no arming
  await ui.press({ key: 'close:spike' })
  await ui.press({ key: 'close:spike' })
  expect(hubCalls(calls)).toEqual([CLOSE_ARGV('retro')])
  expect((await ui.find({ key: 'close:spike' }))?.props.label).toBe('close')
  expect(await ui.find({ key: 'close-hint' })).toBeUndefined()

  await clock.advance(5000)
  expect((await ui.find({ key: 'close-note' }))?.text).toBe('✓ closed stage retro')
  expect(await ui.find({ key: 'close:retro' })).toBeUndefined() // refreshed: gone
  expect((await ui.find({ key: 'close:spike' }))?.props.label).toBe('close')
  await ui.press({ key: 'close:spike' }) // idle again: the next one is a normal first press
  expect((await ui.find({ key: 'close:spike' }))?.props.label).toBe('confirm close')
  expect(hubCalls(calls)).toEqual([CLOSE_ARGV('retro')])
  await ui.unmount()
})

test('with nothing idle the Stages section says so and counts the closed stages the default view hides; `l` shows them (dim, no button)', async ($, on) => {
  mock.clock(on)
  const calls: string[][] = []
  stubStages(
    on,
    argv =>
      argv.includes('--all')
        ? withStages({ old: stageInfo({ closed: CLOSED, idle: false, goal: 'Done long ago' }), other: stageInfo({ closed: { ...CLOSED, at: '2026-10-03T11:00:00+00:00', why: 'wrapped up' }, idle: false }) })
        : withStages({ busy: stageInfo({ idle: false, live: 1 }) }, { closed_hidden: ['old', 'other'] }),
    () => ran('closed\n'),
    calls,
  )
  await run($)
  const ui = await $.ui.mount({ ...paneProps({ rows: 40 }), surface: 'terminal' })
  await ui.press({ key: 'view-summary' })
  expect((await ui.find({ type: 'Text', text: /no idle stages/ }))?.text).toBe('no idle stages · 2 closed hidden (l shows them)')
  expect(await ui.findAll({ type: 'Button', text: /close/ })).toEqual([])
  expect((await ui.find({ key: 'toggle-all' }))?.props).toMatchObject({ hotkey: 'l', label: 'old' }) // `l` works in Summary too

  await ui.press({ key: 'toggle-all' })
  expect(calls.at(-1)?.slice(1)).toEqual(['--json', '--all'])
  expect(await ui.find({ type: 'Text', text: /^── Stages ─+$/ })).toBeDefined() // still in Summary
  expect((await ui.find({ key: 'closed:old' }))?.text).toMatch(/^ closed +old +closed from the agent-top pane$/)
  expect((await ui.find({ key: 'closed:other' }))?.text).toMatch(/^ closed +other +wrapped up$/)
  const pill = await ui.find({ type: 'Text', text: ' closed ' })
  expect(pill?.props).toMatchObject({ backgroundColor: 'gray', color: 'black' })
  expect((await ui.find({ type: 'Text', text: 'old' }))?.props.dimColor).toBe(true)
  expect((await ui.find({ type: 'Text', text: /no idle stages$/ }))?.text).toBe('no idle stages') // nothing hidden any more
  expect((await ui.findAll({ type: 'Button' })).filter(b => b.key?.startsWith('close:'))).toEqual([])
  const rows = (await ui.findAll({ type: 'Box' })).map(b => b.key ?? '').filter(k => k.startsWith('closed:'))
  expect(rows).toEqual(['closed:old', 'closed:other']) // the latest closed first
  await ui.unmount()
})

test('Stages rows fit the body at 23 to 76 columns, inline and docked, idle, armed, refused and closed', async ($, on) => {
  mock.clock(on)
  const long = 'a-very-long-stage-name-indeed'
  const goal = 'A goal long enough to need clipping on every width of the pane'
  stubStages(
    on,
    () =>
      withStages({
        [long]: stageInfo({ goal, idle_s: 400000 }),
        retro: stageInfo({ goal: '' }),
        [`${long}-closed`]: stageInfo({ closed: { ...CLOSED, why: 'a reason long enough to need clipping too' }, idle: false }),
        shut: stageInfo({ closed: CLOSED, idle: false }),
      }),
    () => ran('', 2, 'refused: a stage with a long name has live agents, open owner questions and more besides\n'),
  )
  await run($)
  const wide: string[] = []
  const prefixes = ['stage:', 'act:', 'closed:', 'close-']
  const measure = async (ui: Awaited<ReturnType<typeof $.ui.mount>>, tag: string, inner: number) => {
    for (const b of await ui.findAll({ type: 'Box' })) {
      const k = b.key ?? ''
      if (prefixes.some(p => k.startsWith(p)) && cells(b) > inner) wide.push(`${tag}: ${k} takes ${cells(b)} > ${inner}`)
    }
  }
  for (const placement of ['inline', 'dock'] as const) {
    for (const cols of [23, 24, 25, 30, 40, 44, 60, 76]) {
      const ui = await $.ui.mount({ ...paneProps({ placement, cols, rows: 60 }), surface: 'terminal' })
      const inner = cols - (placement === 'dock' && cols >= 44 ? 8 : 0)
      await ui.press({ key: 'view-summary' })
      expect((await ui.findAll({ type: 'Box' })).filter(b => (b.key ?? '').startsWith('stage:')).length).toBe(2)
      await measure(ui, `${placement} ${cols} idle`, inner)
      await ui.press({ key: `close:${long}` })
      expect((await ui.find({ key: 'close-hint' }))?.text).toMatch(/^press again/)
      await measure(ui, `${placement} ${cols} armed`, inner)
      await ui.press({ key: `close:${long}` })
      expect((await ui.find({ key: 'close-note' }))?.text).toMatch(/^✗/)
      await measure(ui, `${placement} ${cols} refused`, inner)
      await ui.unmount()
    }
  }
  expect(wide).toEqual([])
})

test('ringTarget: an agent row follows the cursor; a close Button gone from the drawing sends the ring to the Summary tab', async () => {
  const tabs = ['view-agents', 'view-journal', 'view-summary', 'refresh']
  expect(ringTarget('close:retro', null, [...tabs, 'close:retro', 'close:spike'])).toBe('close:retro') // still there: stays
  expect(ringTarget('close:retro', null, [...tabs, 'close:spike'])).toBe('view-summary') // closed, or no longer idle
  expect(ringTarget('close:retro', null, tabs)).toBe('view-summary')
  expect(ringTarget('close:retro', null, ['refresh'])).toBeNull() // not drawn at all (another view): the ring is left alone
  expect(ringTarget('open:s/a', 's/b', [...tabs, 'open:s/a', 'open:s/b'])).toBe('open:s/b')
  expect(ringTarget('open:s/a', null, [...tabs, 'open:s/a'])).toBe('open:s/a')
  expect(ringTarget('view-journal', 's/b', tabs)).toBe('view-journal')
  expect(ringTarget(null, 's/b', tabs)).toBeNull()
})

// ---------------------------------------------------------------- stages of several hub homes

const PROJ_HOME = '/work/proj/.agent-hub/local'
const HOMES = [
  { path: '/home/u/agent-hub', label: '', layer: 'default', repo: null, stages: ['alpha'] },
  { path: PROJ_HOME, label: 'proj', layer: 'project', repo: '/work/proj', stages: ['alpha · proj', 'retro · proj'] },
]
/** A snapshot of two homes: `alpha` in each (the project's is `alpha · proj`) and an idle `retro` in the project's. */
const twoHomes = (extra: Row = {}): string =>
  snapshot([agent(), agent({ stage: 'alpha · proj', role: 'rev', dir_name: 'rev', tag: 'r-1', stage_name: 'alpha', home: PROJ_HOME, home_label: 'proj' })], {
    stages: ['stage-a', 'alpha · proj', 'retro · proj'],
    homes: HOMES,
    multi_home: true,
    stage_info: {
      'stage-a': stageInfo({ idle: false, live: 1, idle_s: 4, name: 'stage-a', home: '/home/u/agent-hub', home_label: '' }),
      'alpha · proj': stageInfo({ idle: false, live: 1, idle_s: 4, name: 'alpha', home: PROJ_HOME, home_label: 'proj' }),
      'retro · proj': stageInfo({ name: 'retro', home: PROJ_HOME, home_label: 'proj' }),
    },
    ...extra,
  })

test('parseSnapshot reads homes, multi_home and where a stage lives; an older CLI leaves them empty; closeTarget and stageCols', async () => {
  const s = parseSnapshot(twoHomes(), 0)
  expect(s.homes).toEqual(HOMES)
  expect(s.multi_home).toBe(true)
  expect(s.stage_info['retro · proj']).toMatchObject({ name: 'retro', home: PROJ_HOME, home_label: 'proj' })
  expect(closeTarget(s, 'retro · proj')).toEqual({ name: 'retro', home: PROJ_HOME, key: `${PROJ_HOME}\u0000retro` })
  expect(closeTarget(s, 'stage-a')).toEqual({ name: 'stage-a', home: '/home/u/agent-hub', key: '/home/u/agent-hub\u0000stage-a' })
  expect([stageCols(s), stageCols(null)]).toEqual([28, 16])

  const older = parseSnapshot(withStages({ retro: stageInfo() }), 0) // an older CLI: no home fields at all
  expect([older.homes, older.multi_home]).toEqual([[], false])
  expect(older.stage_info.retro).toEqual({ goal: 'Ship the retro fixes', closed: null, last_activity_at: '2026-10-04T08:40:00+00:00', idle_s: 12000, idle: true, live: 0 })
  expect(closeTarget(older, 'retro')).toEqual({ name: 'retro', home: null, key: 'retro' }) // the old call, unchanged
  expect(stageCols(older)).toBe(16)

  const odd = parseSnapshot(snapshot([agent()], { homes: [5, { label: 'x' }, { path: '/p', stages: ['a', 7], repo: 3 }], multi_home: 'yes' }), 0)
  expect(odd.homes).toEqual([{ path: '/p', label: '', layer: '', repo: null, stages: ['a'] }])
  expect(odd.multi_home).toBe(false)
})

test('two homes: the list names a stage of another home `stage · label`, a same-named stage is a second one, the Summary names it too', async ($, on) => {
  mock.clock(on)
  stubPane(on, () => twoHomes())
  await run($)
  const ui = await $.ui.mount({ ...paneProps({ cols: 76 }), surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /^── stage-a ─+$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^── alpha · proj ─+$/ })).toBeDefined()
  expect(await ui.find({ key: 'open:alpha · proj/rev' })).toBeDefined() // the agent key carries the id: two homes never collide
  await ui.press({ key: 'view-summary' })
  expect((await ui.find({ key: 'stage:retro · proj' }))?.text).toMatch(/^retro · proj +idle 3h20 +Ship the retro fixes ?close$/)
  await ui.unmount()
})

test('closing a stage of another home runs `hub close` with the stage\'s own name in that home (AGENT_HUB_HOME); a stage of an older CLI keeps the old call', async ($, on) => {
  mock.clock(on)
  const calls: { argv: string[]; env: Record<string, string> }[] = []
  let json = twoHomes()
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  on('ui.panes', () => ({ value: [] }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.toast', DONE_VOID)
  on('ui.status', DONE_VOID)
  on('ui.focus', () => ({}))
  on('process.run', ($, e) => {
    calls.push({ argv: [...e.argv], env: { ...(e.init?.env ?? {}) } })
    return (HUB.test(e.argv[0] ?? '') ? ran('closed stage retro\n') : ran(json)) as ReturnType<typeof ran>
  })
  await run($)
  const ui = await $.ui.mount({ ...paneProps({ rows: 40 }), surface: 'terminal' })
  await ui.press({ key: 'view-summary' })
  await ui.press({ key: 'close:retro · proj' })
  await ui.press({ key: 'close:retro · proj' })
  const hub = calls.filter(c => HUB.test(c.argv[0] ?? ''))
  expect(hub.map(c => c.argv.slice(1))).toEqual([CLOSE_ARGV('retro')]) // not 'retro · proj': that is no stage name
  expect(hub[0]?.env.AGENT_HUB_HOME).toBe(PROJ_HOME)
  await ui.unmount()

  calls.length = 0 // an older CLI: no home fields, the stage id is the name, no environment is added
  json = withStages({ retro: stageInfo() })
  const old = await $.ui.mount({ ...paneProps({ rows: 40 }), surface: 'terminal' })
  await old.press({ key: 'view-summary' })
  await old.press({ key: 'close:retro' })
  await old.press({ key: 'close:retro' })
  const oldHub = calls.filter(c => HUB.test(c.argv[0] ?? ''))
  expect(oldHub.map(c => c.argv.slice(1))).toEqual([CLOSE_ARGV('retro')])
  expect(oldHub[0]?.env.AGENT_HUB_HOME).toBeUndefined()
  await old.unmount()
})

const DEFAULT_HOME = '/home/u/agent-hub'
/** One home's `alpha` (the project's) idle beside the live `stage-a`: what the pane sees while only that home has an `alpha`. */
const onlyProjectAlpha = (): string =>
  snapshot([agent()], {
    stages: ['stage-a', 'alpha'],
    multi_home: false,
    stage_info: {
      'stage-a': stageInfo({ idle: false, live: 1, idle_s: 4, name: 'stage-a', home: DEFAULT_HOME, home_label: '' }),
      alpha: stageInfo({ name: 'alpha', home: PROJ_HOME, home_label: 'proj' }),
    },
  })
/** The same after ~/agent-hub gained an `alpha` too: the id `alpha` is now the default home's, the project's is `alpha · proj`. */
const bothAlphas = (): string =>
  snapshot([agent()], {
    stages: ['stage-a', 'alpha', 'alpha · proj'],
    multi_home: true,
    stage_info: {
      'stage-a': stageInfo({ idle: false, live: 1, idle_s: 4, name: 'stage-a', home: DEFAULT_HOME, home_label: '' }),
      alpha: stageInfo({ name: 'alpha', home: DEFAULT_HOME, home_label: '' }),
      'alpha · proj': stageInfo({ name: 'alpha', home: PROJ_HOME, home_label: 'proj' }),
    },
  })

test('an armed close belongs to the stage (home, name), not to the id on its Button: another home gaining an `alpha` moves the id, never the confirmation', async ($, on) => {
  mock.clock(on)
  const calls: { argv: string[]; env: Record<string, string> }[] = []
  let json = onlyProjectAlpha()
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  on('ui.panes', () => ({ value: [] }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.toast', DONE_VOID)
  on('ui.status', DONE_VOID)
  on('ui.focus', () => ({}))
  on('process.run', ($, e) => {
    calls.push({ argv: [...e.argv], env: { ...(e.init?.env ?? {}) } })
    return (HUB.test(e.argv[0] ?? '') ? ran('closed stage alpha\n') : ran(json)) as ReturnType<typeof ran>
  })
  await run($)
  const ui = await $.ui.mount({ ...paneProps({ rows: 40 }), surface: 'terminal' })
  await ui.press({ key: 'view-summary' })
  await ui.press({ key: 'close:alpha' }) // armed on the project home's `alpha`
  expect((await ui.find({ key: 'close:alpha' }))?.props.label).toBe('confirm close')

  json = bothAlphas() // ~/agent-hub gains an `alpha`: the id `alpha` now names the default home's stage
  await ui.press({ key: 'refresh' })
  expect((await ui.find({ key: 'close:alpha' }))?.props.label).toBe('close') // the other stage is not armed
  expect((await ui.find({ key: 'close:alpha · proj' }))?.props.label).toBe('confirm close') // the armed one moved with its identity
  calls.length = 0
  await ui.press({ key: 'close:alpha' }) // the press that would have confirmed on the old id
  expect(calls.filter(c => HUB.test(c.argv[0] ?? ''))).toEqual([]) // …runs nothing: it arms the default home's stage instead
  expect((await ui.find({ key: 'close:alpha' }))?.props.label).toBe('confirm close')
  expect((await ui.find({ key: 'close:alpha · proj' }))?.props.label).toBe('close')

  await ui.press({ key: 'close:alpha · proj' }) // arms the project home's again…
  await ui.press({ key: 'close:alpha · proj' }) // …and confirms it
  const hub = calls.filter(c => HUB.test(c.argv[0] ?? ''))
  expect(hub.map(c => c.argv.slice(1))).toEqual([CLOSE_ARGV('alpha')])
  expect(hub[0]?.env.AGENT_HUB_HOME).toBe(PROJ_HOME)

  // and the other way: armed on the id as it is when the confirming press comes, even if the id changed in between
  calls.length = 0
  json = onlyProjectAlpha()
  await ui.press({ key: 'refresh' })
  await ui.press({ key: 'close:alpha' })
  json = bothAlphas()
  await ui.press({ key: 'refresh' })
  await ui.press({ key: 'close:alpha · proj' })
  expect(calls.filter(c => HUB.test(c.argv[0] ?? '')).map(c => c.env.AGENT_HUB_HOME)).toEqual([PROJ_HOME]) // acts on the armed stage's home
  await ui.unmount()
})

test('--stage NAME keeps that stage of every home, NAME@label (or @path, or the displayed `name · label`) one home\'s; the pane, journal, questions and /agent-top <role> agree', async ($, on) => {
  mock.clock(on)
  const two = snapshot(
    [
      agent({ stage: 'alpha', role: 'a-w', dir_name: 'a-w', stage_name: 'alpha', home: DEFAULT_HOME, home_label: '' }),
      agent({ stage: 'alpha · proj', role: 'p-w', dir_name: 'p-w', stage_name: 'alpha', home: PROJ_HOME, home_label: 'proj' }),
      agent({ stage: 'beta · proj', role: 'b-w', dir_name: 'b-w', stage_name: 'beta', home: PROJ_HOME, home_label: 'proj' }),
    ],
    {
      stages: ['alpha', 'alpha · proj', 'beta · proj'],
      multi_home: true,
      homes: HOMES,
      stage_info: {
        alpha: stageInfo({ idle: false, name: 'alpha', home: DEFAULT_HOME, home_label: '' }),
        'alpha · proj': stageInfo({ idle: false, name: 'alpha', home: PROJ_HOME, home_label: 'proj' }),
        'beta · proj': stageInfo({ idle: false, name: 'beta', home: PROJ_HOME, home_label: 'proj' }),
      },
      questions: { 'alpha · proj': { open: 1, overdue: 0, line: 'alpha · proj — open 1', items: ['Q-A-001 ?'], ids: ['Q-A-001'] }, 'beta · proj': { open: 1, overdue: 0, line: 'beta · proj — open 1', items: ['Q-B-001 ?'], ids: ['Q-B-001'] } },
      journal_tail: [
        { stage: 'alpha', time: '12:01', tag: 'a-w', text: 'default home line' },
        { stage: 'alpha · proj', time: '12:02', tag: 'p-w', text: 'project home line' },
        { stage: 'beta · proj', time: '12:03', tag: 'b-w', text: 'beta line' },
      ],
    },
  )
  const snap = parseSnapshot(two, 0)
  const ids = (sel: string[]) => inStages(snap.agents, sel, snap).map(a => a.stage)
  expect(ids([])).toEqual(['alpha', 'alpha · proj', 'beta · proj'])
  expect(ids(['alpha'])).toEqual(['alpha', 'alpha · proj']) // a bare name: that stage in every home
  expect(ids(['alpha@proj'])).toEqual(['alpha · proj'])
  expect(ids([`alpha@${PROJ_HOME}`])).toEqual(['alpha · proj'])
  expect(ids(['alpha@'])).toEqual(['alpha']) // the default home's label is empty
  expect(ids(['alpha · proj'])).toEqual(['alpha · proj']) // as displayed
  expect(ids(['beta@elsewhere', 'gamma'])).toEqual([])
  expect(inStages([{ stage: 'x' }, { stage: 'y · r' }], ['y'], null).map(r => r.stage)).toEqual(['y · r']) // no stage_info: the id's own words
  expect(stageMatches('a@b', { name: 'a', home: '/h', label: 'b' })).toBe(true)
  expect(stageSelector({ stage: 'alpha · proj', stage_name: 'alpha', home: PROJ_HOME })).toBe(`alpha@${PROJ_HOME}`)
  expect(stageSelector({ stage: 'old' })).toBe('old')

  const calls: string[][] = []
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  on('ui.panes', () => ({ value: [] }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.toast', DONE_VOID)
  on('ui.status', DONE_VOID)
  on('ui.focus', () => ({}))
  on('process.run', ($, e) => (calls.push([...e.argv]), ran(two)))
  await run($, '--stage alpha')
  const ui = await $.ui.mount({ ...paneProps({ rows: 40, cols: 76 }), surface: 'terminal' })
  expect(await ui.find({ key: 'open:alpha/a-w' })).toBeDefined()
  expect(await ui.find({ key: 'open:alpha · proj/p-w' })).toBeDefined() // `--stage alpha` does not hide the project home's
  expect(await ui.find({ key: 'open:beta · proj/b-w' })).toBeUndefined()
  await ui.press({ key: 'view-journal' })
  expect(await ui.find({ type: 'Text', text: 'project home line' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'default home line' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'beta line' })).toBeUndefined()
  await ui.press({ key: 'view-summary' })
  expect(await ui.find({ key: 'q:alpha · proj' })).toBeDefined()
  expect(await ui.find({ key: 'q:beta · proj' })).toBeUndefined()
  await ui.unmount()
  expect(calls.some(c => c.includes('--stage') && c[c.indexOf('--stage') + 1] === 'alpha')).toBe(true)
})

test('a card is asked for by `name@home`, so its stage is the one that was opened whatever its id is called by the next refresh', async ($, on) => {
  mock.clock(on)
  const a = agent({ stage: 'alpha · proj', role: 'p-w', dir_name: 'p-w', stage_name: 'alpha', home: PROJ_HOME, home_label: 'proj' })
  const calls: string[][] = []
  on('command.register', REGISTERED)
  on('session.surfaces', () => ({ value: ['terminal'] }))
  on('ui.panes', () => ({ value: [] }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.toast', DONE_VOID)
  on('ui.status', DONE_VOID)
  on('ui.focus', () => ({}))
  on('process.run', ($, e) => (calls.push([...e.argv]), ran(e.argv.includes('--feed') ? cardJson(a, []) : snapshot([a], { stages: ['alpha · proj'], multi_home: true }))))
  await run($)
  const ui = await $.ui.mount({ ...paneProps({ rows: 40 }), surface: 'terminal' })
  await ui.press({ key: 'open:alpha · proj/p-w' })
  const feed = calls.find(c => c.includes('--feed'))
  expect(feed?.[feed.indexOf('--stage') + 1]).toBe(`alpha@${PROJ_HOME}`)
  await ui.unmount()
})

test('parseArgs takes a qualified selector without spaces: --stage alpha@proj', async () => {
  expect(parseArgs('--stage alpha@proj --stage=beta@/work/p worker')).toEqual({ role: 'worker', stages: ['alpha@proj', 'beta@/work/p'], isAll: false })
  expect(onceArgs(parseArgs('--stage alpha@proj'))).toContain('alpha@proj')
})

test('parseArgs reads quotes and backslash-spaces like a shell: a label or a path with spaces stays one selector', async () => {
  expect(splitWords(`a "b c" 'd e' f\\ g "h\\"i" ''`)).toEqual(['a', 'b c', 'd e', 'f g', 'h"i', ''])
  expect(parseArgs('--stage "alpha@space repo" worker')).toEqual({ role: 'worker', stages: ['alpha@space repo'], isAll: false })
  expect(parseArgs("--stage 'alpha@/work/my repo/.agent-hub/local' --all").stages).toEqual(['alpha@/work/my repo/.agent-hub/local'])
  expect(parseArgs('--stage=alpha@"my repo" worker')).toEqual({ role: 'worker', stages: ['alpha@my repo'], isAll: false })
  expect(parseArgs('--stage alpha@my\\ repo').stages).toEqual(['alpha@my repo'])
  expect(parseArgs('--stage "alpha@unclosed repo').stages).toEqual(['alpha@unclosed repo'])
  expect(parseArgs('--stage alpha@proj worker').role).toBe('worker') // unquoted words split as before
  expect(onceArgs(parseArgs('--stage "alpha@space repo"'))).toContain('alpha@space repo') // and reach the CLI as one argument
})

test('a path selector matches the way the CLI normalises it (trailing slash, ., .., //); a label or path with @ is split at the first @ or " · "', async () => {
  const id = { name: 'alpha', home: '/work/repo/.agent-hub/local', label: 'repo' }
  for (const q of ['/work/repo/.agent-hub/local', '/work/repo/.agent-hub/local/', '/work//repo/./.agent-hub/local', '/work/x/../repo/.agent-hub/local/'])
    expect(stageMatches(`alpha@${q}`, id)).toBe(true)
  expect(stageMatches('alpha@/work/other/.agent-hub/local/', id)).toBe(false)
  expect(normPath('/a//b/./c/../d/')).toBe('/a/b/d')
  expect(normPath('/')).toBe('/')

  expect(parseSelector('alpha@repo@branch')).toEqual({ name: 'alpha', qual: 'repo@branch' })
  expect(parseSelector('alpha · repo@branch')).toEqual({ name: 'alpha', qual: 'repo@branch' }) // the displayed form, with an '@' in its label
  expect(parseSelector('alpha@a · b')).toEqual({ name: 'alpha', qual: 'a · b' })
  expect(parseSelector('alpha')).toEqual({ name: 'alpha', qual: null })
  const at = { name: 'alpha', home: '/w/repo@branch/.agent-hub/local', label: 'repo@branch' }
  expect(stageMatches('alpha · repo@branch', at)).toBe(true)
  expect(stageMatches('alpha@repo@branch', at)).toBe(true)
  expect(stageMatches('alpha@/w/repo@branch/.agent-hub/local/', at)).toBe(true)
  expect(stageMatches('alpha@repo', at)).toBe(false)
  const rows = [{ stage: 'alpha · repo@branch', stage_name: 'alpha', home: at.home, home_label: 'repo@branch' }, { stage: 'alpha', stage_name: 'alpha', home: '/h', home_label: '' }]
  expect(inStages(rows, ['alpha · repo@branch'], null).map(r => r.stage)).toEqual(['alpha · repo@branch'])
  expect(inStages(rows, ['alpha@/w/repo@branch/.agent-hub/local/'], null).map(r => r.stage)).toEqual(['alpha · repo@branch'])
})

test('a lock keeps its home and label from the CLI, and the Summary shows the label only while stages come from several homes', async ($, on) => {
  mock.clock(on)
  const locks = [
    { kind: 'main-merge', repo: 'demo', owner_name: 'hub-a', until: '2099-01-01T00:00', active: true, why: 'merging', home: DEFAULT_HOME, home_label: '' },
    { kind: 'main-merge', repo: 'demo', owner_name: 'hub-b', until: '2099-01-01T00:00', active: true, why: 'merging', home: PROJ_HOME, home_label: 'proj' },
  ]
  const parsed = parseSnapshot(snapshot([agent()], { locks, multi_home: true }), 0)
  expect(parsed.locks.map(l => [l.home, l.home_label])).toEqual([[DEFAULT_HOME, ''], [PROJ_HOME, 'proj']])
  const older = parseSnapshot(snapshot([agent()], { locks: [{ kind: 'k', repo: 'r', owner_name: 'o', until: 'u', active: true, why: 'w' }] }), 0)
  expect(older.locks[0]).toEqual({ kind: 'k', repo: 'r', owner_name: 'o', until: 'u', active: true, why: 'w' }) // an older CLI: no home fields

  let json = snapshot([agent()], { locks, multi_home: true })
  stubPane(on, () => json)
  await run($)
  const ui = await $.ui.mount({ ...paneProps({ rows: 40, cols: 76 }), surface: 'terminal' })
  await ui.press({ key: 'view-summary' })
  expect((await ui.find({ key: 'lock:0' }))?.text).toMatch(/main-merge +demo +until 01-01 00:00 +hub-a: merging/) // the default home's: no label
  expect((await ui.find({ key: 'lock:1' }))?.text).toMatch(/main-merge +demo \(proj\) +until 01-01 00:00 +hub-b: merging/) // another home's: whose it is
  await ui.unmount()

  json = snapshot([agent()], { locks, multi_home: false }) // one home: the rows are as they were
  const one = await $.ui.mount({ ...paneProps({ rows: 40, cols: 76 }), surface: 'terminal' })
  await one.press({ key: 'view-summary' })
  expect((await one.find({ key: 'lock:1' }))?.text).not.toContain('(proj)')
  await one.unmount()
})

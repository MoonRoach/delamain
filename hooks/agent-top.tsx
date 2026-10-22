// agent-top as a Claude Code mod: the headless agents of the Delamain plugin, live in a pane.
//
//   /agent-top [role] [--stage S] [--all]   opens the pane (a role opens that agent's card); a bare one closes it again
//   pane views: Agents (a) · agent card (header + live feed) · Journal (j) · Summary (s: stages, plan limits, owner questions, locks)
//   the drawing: hooks/agent-top-view.tsx; the list's cursor follows the pane's focus ring (ui.focus)
//   footer: a Button `agents ● 2 ✓ 5 ✗ 1` beside the engine's mode labels (SessionMode) opens and closes the pane; where a
//   surface without that footer looks on (a phone, VS Code) the same counts are the status line instead
//   toasts when an agent finishes, fails or dies and when a new owner question opens
//
// Reads only, with one exception. Data comes from the plugin's own CLI, `bin/agent-top --json` (it keeps its read offsets in
// its own cache, <hub home>/.state/agent-top/); the module itself writes nothing. The exception is Summary's Stages section:
// `close` on an idle stage runs `bin/hub close --stage S`, after two presses (the first arms it, 10 s). Calls never overlap, each
// answer is drawn as it comes, and a failed card call says why in the feed area instead of "loading". The module is
// plugin-name-agnostic (no $.state, no hard-coded plugin name): state lives in this closure, and a hot reload starts it over.
// Needs Claude Code with mods (2.1.287+). Older CLIs ignore the module; there, and in Codex, the console `agent-top` stays.
import type { EngineInterface, Register, Timer } from 'claude-code'

import {
  TICK_MS,
  agentKey,
  capToasts,
  clip,
  closeTarget,
  countsOf,
  findByRole,
  footerHolds,
  idleStages,
  inStages,
  isBare,
  isOwnCommand,
  notices,
  oneLine,
  onceArgs,
  parseArgs,
  parseCard,
  parseSnapshot,
  planRun,
  remember,
  ringTarget,
  sameTarget,
  stageSelector,
  statusText,
} from './agent-top-model'
import type { Agent, Card, CommandArgs, Memory, Snapshot, Target, View } from './agent-top-model'
import { drawPane } from './agent-top-view'
import type { PaneModel } from './agent-top-view'

type Api = EngineInterface

const PANE = 'agent-top'
const INLINE_ROWS = 24 // body rows asked for above the prompt (a request: the person's own size wins)
const DOCK_COLUMNS = 76 // body columns asked for beside a fullscreen transcript
// A first call after an update reads every log once (later ones resume from the CLI's cache): give it time, and keep
// the polls apart, never in parallel
const CALL_TIMEOUT_MS = 60000
const OPEN_WAIT_MS = 4000 // how long /agent-top waits for data before it answers; the pane fills when the data comes
const SKILL_HINT = 'agent-top: the mod needs bin/agent-top of the Delamain plugin'
const ARM_MS = 10000 // a first press of `close` waits this long for the second one
const CLOSE_WHY = 'closed from the agent-top pane'

type Called = { ok: true; stdout: string } | { ok: false; error: string; isMissing: boolean }
type HubCalled = { ok: true; line: string } | { ok: false; error: string }

const firstLine = (s: string): string => clip(oneLine(s.split('\n').find(l => l.trim() !== '') ?? ''), 140)

let snap: Snapshot | null = null // the default view, every stage: feeds the status line and the toasts
let allSnap: Snapshot | null = null // the pane's own list (--all, or the named stages), only while the pane shows it
let card: Card | null = null // the card of `target` (an answer for another agent is dropped)
let cardError: string | null = null // why the last card call failed; cleared by the next good one
let view: View = 'list'
let target: Target | null = null
let stages: string[] = []
let isAll = false
let isOpen = false
let isMissing = false
let running: Promise<void> | null = null // the refresh in flight
let isForced = false
let error: string | null = null
let lastWatchAt = -Infinity
let lastStatus: string | undefined
let hasFooter = false // every surface looking on draws the prompt footer: the counts are its Button, not the status line
let lastButton: string | undefined // the Button's label at the last change, to redraw the footer only when it changes
let memory: Memory | null = null // null until the first snapshot of the session: that one never toasts
let timer: Timer | null = null
let cursorKey: string | null = null // agentKey of the list row the cursor is on, kept while the ring is elsewhere
let isAutoFocus = true // until the ring first lands on a row, the cursor row is drawn autoFocus
let ringKey: string | null = null // the element the ring was last moved onto (ui.focus)
let lastControls = '' // the drawn Buttons' keys, in order, at the last drawing
let edges: { prev: string | null; next: string | null } = { prev: null, next: null } // the agents past the list's window
// Summary's `close` flow: a first press arms a stage, a second runs `bin/hub close`; one at a time, whatever the stage
let armed: string | null = null // the identity (closeTarget .key) of the armed stage: its home and name, not the id it shows under
let armedTarget: { name: string; home: string | null } | null = null // what the confirming press runs: taken when armed
let armTimer: Timer | null = null
let closing: string | null = null // the identity of the stage whose close is running
let closeNote: { text: string; isError: boolean; isWarn?: boolean } | null = null // its result, drawn in the Stages section

// ---------------------------------------------------------------- data

async function callCli($: Api, args: string[]): Promise<Called> {
  const bin = `${$.plugin.root}/bin/agent-top`
  try {
    const r = await $.process.run([bin, ...args], { timeoutMs: CALL_TIMEOUT_MS, env: { PYTHONDONTWRITEBYTECODE: '1' } })
    if (r.exitCode === 127) return { ok: false, error: `${SKILL_HINT} (${bin} cannot run)`, isMissing: true }
    if (r.exitCode !== 0) return { ok: false, error: firstLine(r.stderr) || `agent-top exited with ${r.exitCode}`, isMissing: false }
    return { ok: true, stdout: r.stdout }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    const isGone = /ENOENT|no such file|not found|cannot start|spawn/i.test(msg)
    if (isGone) return { ok: false, error: `${SKILL_HINT} (${bin} is missing)`, isMissing: true }
    // the engine's own words name the whole path; the pane has one line for it
    if (/still running|timed? ?out/i.test(msg)) return { ok: false, error: `agent-top gave no answer in ${CALL_TIMEOUT_MS / 1000} s`, isMissing: false }
    return { ok: false, error: `agent-top: ${clip(oneLine(msg), 100)}`, isMissing: false }
  }
}

/** `bin/hub <args>` (close only: the module does nothing else with it). The first line of stdout on success, of stderr on a refusal. */
async function callHub($: Api, args: string[], home: string | null = null): Promise<HubCalled> {
  const bin = `${$.plugin.root}/bin/hub`
  try {
    // a stage of another hub home is closed in that home: the tools resolve their own and would not find it
    const env = { PYTHONDONTWRITEBYTECODE: '1', ...(home ? { AGENT_HUB_HOME: home } : {}) }
    const r = await $.process.run([bin, ...args], { timeoutMs: CALL_TIMEOUT_MS, env })
    if (r.exitCode === 127) return { ok: false, error: `hub cannot run (${bin})` }
    if (r.exitCode !== 0) return { ok: false, error: firstLine(r.stderr) || firstLine(r.stdout) || `hub exited with ${r.exitCode}` }
    // the summary line; when the hub session still runs it carries the ATTENTION with how to end it, so it is kept long
    return { ok: true, line: clip(oneLine(r.stdout.split('\n').find(l => l.trim() !== '') ?? ''), 600) || 'closed' }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    if (/ENOENT|no such file|not found|cannot start|spawn/i.test(msg)) return { ok: false, error: `hub is missing (${bin})` }
    // a killed call may have got part of the way: the pane does not claim it failed whole
    if (/still running|timed? ?out/i.test(msg)) return { ok: false, error: `hub gave no answer in ${CALL_TIMEOUT_MS / 1000} s; look at the stage before closing again` }
    return { ok: false, error: `hub: ${clip(oneLine(msg), 100)}` }
  }
}

const stopPolling = (): void => {
  timer?.cancel()
  timer = null
}

/** The counts where they belong: the footer Button where every surface draws it, else the status line; never both. */
function showCounts($: Api): void {
  const text = isMissing ? undefined : statusText(snap)
  const status = hasFooter ? undefined : text
  if (status !== lastStatus) {
    lastStatus = status
    $.ui.status(status)
  }
  const button = hasFooter ? text : undefined
  if (button !== lastButton) {
    lastButton = button
    $.ui.invalidate('ui.render')
  }
}

/** Which surfaces look on decides Button or status line; a phone attaching or leaving changes it. */
async function syncSurfaces($: Api): Promise<boolean> {
  let surfaces: readonly string[]
  try {
    surfaces = await $.session.surfaces()
  } catch {
    return true // cannot tell: assume somebody looks, and keep the counts where they are
  }
  hasFooter = footerHolds(surfaces)
  showCounts($)
  return surfaces.length > 0
}

function giveUp($: Api, message: string): void {
  isMissing = true
  error = message
  stopPolling()
  showCounts($)
}

/** What the pane shows: its own list (--all, or the named stages, which may include a closed one) once read, else the watch call's. */
const paneSnap = (): Snapshot | null => ((isAll || stages.length > 0) && allSnap ? allSnap : snap)

function applyWatch($: Api, s: Snapshot): void {
  snap = s
  lastWatchAt = s.fetchedAt
  showCounts($)
  if (memory !== null) for (const t of capToasts(notices(memory, s))) $.ui.toast(t)
  memory = remember(s, memory ?? undefined)
}

async function runOnce($: Api, isForce: boolean): Promise<void> {
  const now = await $.clock.now()
  const plan = planRun({ now, lastWatchAt, isOpen, view, isAll, hasStages: stages.length > 0, hasTarget: target !== null, force: isForce })
  if (!plan.watch && plan.extra === null) return
  const errors: string[] = []
  let isGone = false
  const note = (c: Called & { ok: false }): void => {
    errors.push(c.error)
    if (c.isMissing) isGone = true
  }
  // each answer is drawn as it comes, not after the calls that follow it
  if (plan.extra === 'card' && target) {
    const t = target
    const c = await callCli($, ['--json', ...(isAll ? ['--all'] : []), '--agent', t.dirName, '--stage', t.sel ?? t.stage, '--feed', '30'])
    if (c.ok === false && c.isMissing) note(c)
    else if (sameTarget(target, t)) {
      // the card's own failure shows in its feed area (feedNote), not as the pane's error line
      if (c.ok) {
        try {
          card = parseCard(c.stdout, t.dirName, now)
          cardError = null
        } catch (err) {
          cardError = err instanceof Error ? err.message : String(err)
        }
      } else cardError = c.error
    }
    $.ui.invalidate('ui.render')
  } else if (plan.extra === 'all' && !isGone) {
    const c = await callCli($, ['--json', ...(isAll ? ['--all'] : []), ...stages.flatMap(s => ['--stage', s])])
    if (c.ok) {
      try {
        allSnap = parseSnapshot(c.stdout, now)
      } catch (err) {
        errors.push(err instanceof Error ? err.message : String(err))
      }
    } else note(c)
    $.ui.invalidate('ui.render')
  }
  if (plan.watch && !isGone) {
    const c = await callCli($, ['--json'])
    if (c.ok) {
      try {
        applyWatch($, parseSnapshot(c.stdout, now))
      } catch (err) {
        errors.push(err instanceof Error ? err.message : String(err))
      }
    } else note(c)
  }
  if (isGone) giveUp($, errors[0] ?? SKILL_HINT)
  else error = errors[0] ?? null
  $.ui.invalidate('ui.render')
}

async function refreshLoop($: Api, isForce: boolean): Promise<void> {
  try {
    let again = isForce
    do {
      again = again || isForced
      isForced = false
      await runOnce($, again)
      again = false
    } while (isForced)
  } catch (err) {
    error = `agent-top: ${clip(oneLine(err instanceof Error ? err.message : String(err)), 100)}`
    $.ui.invalidate('ui.render')
  }
}

/**
 * One refresh; never two in flight. A forced one asked while another runs makes that one run once more, and the
 * promise returned settles when it is done: the caller then sees the data its press asked for.
 */
function refresh($: Api, isForce: boolean): Promise<void> {
  if (running !== null) {
    if (isForce) isForced = true
    return running
  }
  if (isMissing && !isForce) return Promise.resolve()
  running = refreshLoop($, isForce).finally(() => {
    running = null
  })
  return running
}

async function hasSurface($: Api): Promise<boolean> {
  try {
    return (await $.session.surfaces()).length > 0
  } catch {
    return true // cannot tell: assume somebody looks
  }
}

/** The engine's own record of the pane survives a reload of this module; the flag also follows ui.render / ui.close. */
async function syncPane($: Api): Promise<void> {
  try {
    isOpen = (await $.ui.panes()).some(p => p.id === PANE && p.isPlaced)
  } catch {
    // keep the flag as it is
  }
}

async function tick($: Api): Promise<void> {
  if (running !== null || isMissing) return
  if (!(await syncSurfaces($))) return
  await syncPane($)
  await refresh($, false)
}

function startPolling($: Api): void {
  if (timer === null) timer = $.clock.every(TICK_MS, () => void tick($))
}

/** Moves the ring from a handler (never from a drawing): the element is awaited until the next drawing brings it. */
function focusOn($: Api, key: string): void {
  if (!isOpen) return
  try {
    void $.ui.focus({ requestId: PANE, key }).catch(() => undefined)
  } catch {
    // a host without a focus ring: the cursor stays where it was
  }
}

function openCard($: Api, a: Pick<Agent, 'stage' | 'dir_name' | 'role' | 'stage_name' | 'home'>): Promise<void> {
  const next = { stage: a.stage, dirName: a.dir_name, role: a.role, sel: stageSelector(a) }
  if (!sameTarget(target, next) || view !== 'card') {
    card = null // another agent's feed is not drawn under this one's title
    cardError = null
  }
  target = next
  cursorKey = agentKey(a)
  view = 'card'
  $.ui.invalidate('ui.render')
  focusOn($, 'back')
  return refresh($, true)
}

/** From the card back to the list, the cursor on the agent the card showed. */
function back($: Api): void {
  go($, 'list')
}

function disarm(): void {
  armTimer?.cancel()
  armTimer = null
  armed = null
  armedTarget = null
}

/**
 * The `close` Button of an idle stage: the first press arms it for ARM_MS, the second one runs the close. The Button is
 * known by the stage's identity (its home and name, `closeTarget`), not by the id on it: the id of `alpha` of one home
 * becomes `alpha · repo` when another home gains an `alpha`, and the Button of the other `alpha` must not inherit the arming.
 */
function pressClose($: Api, stage: string): void {
  if (closing !== null) return // one close at a time: presses while one runs are ignored
  ringKey = `close:${stage}` // the ring is on the pressed Button; should it vanish, the drawing moves the ring off it
  const t = closeTarget(paneSnap(), stage)
  if (armed !== t.key) {
    disarm() // another stage armed meanwhile: that one is dropped
    armed = t.key
    armedTarget = { name: t.name, home: t.home }
    closeNote = null
    armTimer = $.clock.after(ARM_MS, () => {
      if (armed !== t.key) return
      armed = null
      armedTarget = null
      armTimer = null
      $.ui.invalidate('ui.render')
    })
    $.ui.invalidate('ui.render')
    return
  }
  const run = armedTarget ?? { name: t.name, home: t.home }
  disarm()
  void closeStage($, stage, t.key, run)
}

/** Runs `hub close` for the armed stage's own name in its home, says how it went in the Stages section, and refreshes at once so a closed stage leaves the list. */
async function closeStage($: Api, stage: string, key: string, t: { name: string; home: string | null }): Promise<void> {
  closing = key
  closeNote = null
  $.ui.invalidate('ui.render')
  try {
    const c = await callHub($, ['close', '--stage', t.name, '--why', CLOSE_WHY], t.home)
    closeNote = c.ok
      ? { text: c.line, isError: false, isWarn: c.line.includes('ATTENTION:') }
      : { text: `${stage}: ${c.error}`, isError: true }
  } finally {
    closing = null
  }
  $.ui.invalidate('ui.render')
  await refresh($, true)
}

function go($: Api, next: View): void {
  disarm() // a first press does not outlive the view it was made in
  closeNote = null
  if (ringKey?.startsWith('close:')) ringKey = null // the ring is leaving the Stages section's Button
  view = next
  $.ui.invalidate('ui.render')
  // the ring onto the new view's own element: the cursor row, or the active tab (its old element may be gone)
  if (next === 'list') {
    if (cursorKey !== null) focusOn($, `open:${cursorKey}`)
  } else if (next === 'journal' || next === 'summary') focusOn($, `view-${next}`)
  void refresh($, true)
}

// ---------------------------------------------------------------- the command and its lifecycle

const countsLine = (s: Snapshot | null): string =>
  s ? `● ${s.counts.live} ✓ ${s.counts.done} ✗ ${s.counts.error + s.counts.dead}` +
    (s.counts.unknown ? ` ? ${s.counts.unknown}` : '') + (s.counts.stopped ? ` ■ ${s.counts.stopped}` : '') : 'no data yet'

async function onceText($: Api, a: CommandArgs): Promise<string> {
  const c = await callCli($, onceArgs(a))
  return c.ok ? c.stdout.trimEnd() : c.error
}

async function openPane($: Api, args: CommandArgs): Promise<string> {
  stages = args.stages
  isAll = args.isAll
  disarm()
  closeNote = null
  isMissing = false
  error = null
  view = 'list'
  target = null
  card = null
  cardError = null
  allSnap = null
  startPolling($)

  isAutoFocus = true
  ringKey = null
  lastControls = ''
  const opened = await $.ui.open({ id: PANE, title: 'Agents', focus: true, closeOnEscape: true, rows: INLINE_ROWS, columns: DOCK_COLUMNS })
  if (!opened.isPlaced) return onceText($, args)
  isOpen = true
  $.ui.invalidate('ui.render')
  // the answer waits for the data a little (its counts); a role waits for it all, it is looked up there
  const loading = refresh($, true)
  await (args.role !== null ? loading : Promise.race([loading, $.clock.sleep(OPEN_WAIT_MS)]))

  let notFound = ''
  if (args.role !== null) {
    const found = findByRole(paneSnap()?.agents ?? [], args.role, stages)
    if (found) {
      await openCard($, found)
    } else if (snap || allSnap) notFound = `no agent "${args.role}"${stages.length ? ` in ${stages.join(', ')}` : ''}; `
  }
  const tail = error ? `${notFound}${error}` : `${notFound}${countsLine(snap)}`

  return `agent-top pane opened: ${tail}`
}

async function closePane($: Api): Promise<string> {
  await $.ui.close({ id: PANE })
  isOpen = false
  $.ui.invalidate('ui.render')

  return 'agent-top pane closed'
}

/**
 * The footer Button's press: opens the pane on the default view when closed, closes it when open. It calls `ui.open`
 * before its first await and hands the promise back to the press: an open the press is not seen behind is "unasked",
 * and below 110 columns such a pane waits unplaced. `isOpen` follows ui.render and ui.close, so no `ui.panes` first.
 */
function toggle($: Api): Promise<unknown> {
  return isOpen ? closePane($) : openPane($, parseArgs(''))
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    try {
      await $.command.register({
        name: 'agent-top',
        description: 'Show the headless agents live in a pane; its Summary can close an idle stage',
        argumentHint: '[role] [--stage S] [--all]',
        immediate: true,
      })
    } catch (err) {
      $.ui.log(`agent-top: could not register /agent-top: ${err instanceof Error ? err.message : String(err)}`, { to: 'debug' })
    }
    await syncPane($)
    await syncSurfaces($)
    startPolling($)

    return next(e)
  })

  // a phone or another client attaching or leaving: Button or status line again
  on('session.attach', async ($, e, next) => {
    const done = await next(e)
    await syncSurfaces($)

    return done
  })
  on('session.detach', async ($, e, next) => {
    const done = await next(e)
    await syncSurfaces($)

    return done
  })

  // Bare `agent-top` is the command this module registers; `<this plugin>:agent-top`, the plugin-qualified name, is answered too,
  // and, in the installed plugin and in the dev copy (plugin `agent-top-dev`, tested beside it), the command from before the
  // rename. Another plugin's command of that name goes on to the engine.
  on('command.run', async ($, e, next) => {
    if (!isOwnCommand(e.command, $.plugin.name)) return next(e)
    const args = parseArgs(e.args)
    if (!(await hasSurface($))) return { text: await onceText($, args) }
    await syncPane($)
    // the same toggle as the footer Button; with a role, a stage or --all it (re)opens on that view instead
    if (isOpen && isBare(args)) return { text: await closePane($) }

    return { text: await openPane($, args) }
  })

  on('ui.close', async ($, e, next) => {
    const done = await next(e)
    if (e.id === PANE) isOpen = false

    return done
  })

  // ---------------------------------------------------------------- the footer Button

  // The engine's mode labels stay, joined as it joins them; the Button sits at the footer's end, where the counts were.
  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    const label = hasFooter && !isMissing ? statusText(snap) : undefined
    if (label === undefined) return next(e)
    const { Box, Text, Button } = $.ui.resolve(e)
    const modes = e.props.modes

    return (
      <Box key="agent-top-footer" flexDirection="row">
        {modes.length > 0 ? <Text dimColor>{`${modes.join(' & ')} · `}</Text> : []}
        <Button key="agent-top-toggle" label={label} dimColor onPress={() => toggle($)} />
      </Box>
    )
  })

  // ---------------------------------------------------------------- the pane

  // The focus ring: the list row it lands on is the cursor (drawn with ❯, and the window follows it). The ring itself
  // is the engine's: this only listens, and never moves it from inside a drawing.
  on('ui.focus', { requestId: PANE }, async ($, e, next) => {
    const done = await next(e)
    if (done.deny) return done
    // the ring on `↑ more` / `↓ more` means the agent just past the window: the cursor goes there, the window follows
    // and the drawing that brings its row puts the ring on it
    const past = e.element === 'more-up' ? edges.prev : e.element === 'more-down' ? edges.next : null
    ringKey = past !== null ? `open:${past}` : (e.element ?? null)
    const row = ringKey?.startsWith('open:') ? ringKey.slice(5) : null
    if (row !== null && (row !== cursorKey || isAutoFocus)) {
      cursorKey = row
      isAutoFocus = false
      $.ui.invalidate('ui.render')
    }

    return done
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    isOpen = true
    const shown = paneSnap()
    const agents = shown ? inStages(shown.agents, stages, shown) : []
    const model: PaneModel = {
      view,
      cols: Math.max(20, e.props.bodyColumns), // the drawing's own floor: below 20 columns rows are cut by the surface
      rows: Math.max(8, e.props.scroll.bodyRows),
      placement: e.props.placement,
      shown,
      agents,
      counts: shown ? (stages.length ? countsOf(agents) : shown.counts) : null,
      stages,
      isAll,
      error,
      card,
      cardError,
      target,
      cursorKey: cursorKey !== null && agents.some(a => agentKey(a) === cursorKey) ? cursorKey : agents[0] ? agentKey(agents[0]) : null,
      isAutoFocus,
      nowMs: shown?.fetchedAt ?? 0,
      // armed only while the stage is still idle: a stage that stopped being so has no Button to confirm on
      // (the view compares ids: those of the stages that now have the armed or the running identity)
      closing: {
        armed: armed !== null && shown ? (idleStages(shown, stages).find(r => closeTarget(shown, r.stage).key === armed)?.stage ?? null) : null,
        running: closing !== null && shown ? (shown.stages.find(st => closeTarget(shown, st).key === closing) ?? closing) : closing,
        note: closeNote,
      },
    }
    const drawn = drawPane($.ui.resolve(e), model, {
      go: next => go($, next),
      refresh: () => void refresh($, true),
      toggleAll: () => {
        isAll = !isAll
        allSnap = null
        go($, view === 'summary' ? 'summary' : 'list')
      },
      open: a => void openCard($, a),
      back: () => back($),
      close: stage => pressClose($, stage),
      step: dir => {
        const to = dir < 0 ? edges.prev : edges.next
        if (to === null) return
        cursorKey = to
        isAutoFocus = false
        ringKey = `open:${to}`
        $.ui.invalidate('ui.render')
        focusOn($, `open:${to}`)
      },
    })
    edges = drawn.edges
    // The ring keeps its place among the Buttons, not its element: when the drawn Buttons change (the window moved, a
    // poll reordered the rows), put it back on the element it means, once this drawing is in (a timer: never from here).
    const sig = drawn.controls.join('\n')
    if (sig !== lastControls) {
      lastControls = sig
      const meant = ringTarget(ringKey, model.cursorKey, drawn.controls)
      if (meant !== null) $.clock.after(0, () => focusOn($, meant))
    }

    return drawn.tree
  })
}

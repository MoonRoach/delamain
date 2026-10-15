# Monitoring agents

## Screens

`agent-top --once` (synthetic demo data, `docs/render_demo.sh`):

```text
 agent-top ● 2 ✓ 1 ✗ 1 stage-a · locks 1 · questions 1 (overdue 1) · limit 5h 34% 7d 52%                       14:01:17
  ROLE      TASK                           STATUS MODEL           AGE TURN  CTX     $ ✉  NOW / LAST
● builder   Rebase payments and get CI gr… live   opus-5-5/hi      0s    6  94k     — ✉1 ▸ Bash: run the full test suit…
● reviewer  Review PR #41 (export to Parq… live   sonnet-5-5/hi    0s    2  62k     —    ▸ Read: /work/webapp/src/expor…
✗ migrator  Rehearse migration 0042 on a … error  opus-5-5/hi     20m    1  62k $1.92    Dry-running the migration on a…
✓ docs      Update the API docs for the e… done   sonnet-5-5/hi   14m    1  62k $0.84    DONE docs updated, report at w…

Locks (lock list)
  main-merge webapp until 2026-10-02 14:01 — Hub stage-a #3: stage hub merges main

Owner questions (ask summary)
  stage-a — open 1, overdue 1
    Q-A-001 [stage-a] open OVERDUE — Turn the new export on by default?
    blocks: the release; default by 2026-09-30T12:01: ship with the flag off

Journal (last 5 lines):
13:09 [hub-3] start: "Hub stage-a #3" took over from "Hub stage-a #2"; locks: main-merge
13:11 [hub-3-builder] started headless agent builder (claude-opus-5-5/high)
13:41 [hub-3-migrator] EXIT migrator: error_max_turns, error; code 1, turns 80 — agent status migrator
13:46 [hub-3-docs] DONE docs updated, report at work/hub-3-docs-REPORT.md
14:00 [hub] @hub-3-builder after the suite, push and open the PR
```

Interactively, `agent-top` adds a live feed per agent (thoughts ✎, commands ▸, results ◂), its brief and inbox, the
journal with a filter, and `m` / `x` to message or stop an agent after a y/N prompt.

### agent-top inside Claude Code: a live pane

Claude Code (mods are on by default) runs the plugin's mod, `hooks/agent-top.tsx`, in the terminal and in the
Desktop Code tab:

- **`/agent-top [role] [--stage S] [--all]` opens a pane**, and so does the `agents ● 4 ✓ 9 ✗ 0` button in the prompt
  footer next to the model picker; a second `/agent-top` or a second press closes it. The mod registers `/agent-top`
  itself and also answers `/delamain:agent-top`. It never opens by itself. Views: **Agents** (`a`; ↑/↓ move
  the `❯` cursor, Enter or the row's digit `1`–`9` opens the agent card), the **agent card** (state, model, turns, a
  context bar against the model's window, cost, result; a live feed of the last 30 events; `b` goes back), **Journal**
  (`j`) and **Summary** (`s`: plan-limit bars including Codex, owner questions, locks). Each agent is two lines with a
  coloured state badge (LIVE, QUIET, DONE, FAIL, DIED); a long list is a window around the cursor. Docked beside a
  fullscreen transcript the pane is framed and the card takes its state's colour; above the prompt and when narrow it
  drops the frames. It refreshes every 3 s while open; a role opens that agent's card; Esc closes it. Claude and Codex
  agents are listed alike, as in the console.
- **A status line and toasts.** The status line reads `agents ● 2 ✓ 5 ✗ 1` (nothing when there are no agents). A toast
  appears when an agent finishes, fails or dies and when a new owner question opens; what was already there when the
  session started is never announced. With the pane closed the mod looks every 15 s.
- **Read-only.** No send, stop or message button. The mod writes nothing: it runs `bin/agent-top --json` and draws the
  result. Messaging and stopping stay in the console (`m` / `x`) and in `agent send` / `agent stop`. `agent-top` itself
  writes one file, its read cache `<hub home>/.state/agent-top/cache.sqlite` (or under `$AGENT_HUB_STATE_DIR`): the
  log offsets of the last run, so the next one reads only what the logs gained. `AGENT_TOP_CACHE=0` turns it off.
- **When data is slow.** Each answer is drawn when it comes. A card whose call failed or took over 60 s says
  `feed unavailable: <reason> · retrying` in its feed area, and the next refresh asks again.
- **Where mods do not draw there is no `/agent-top`:** Codex, VS Code chat, `claude -p`, Remote Control and
  `claude --bg` views, Claude Code older than 2.1.287. Use the console in a shell: `agent-top` (live), `agent-top --once`
  (text picture), `agent-top --json` (scripts). If `bin/agent-top` is missing the mod goes quiet instead of failing.


## Watchdog: a hub that sleeps is woken

`watchdog` is a job that looks at every stage of the hub home every 5 minutes and acts when something waits and nobody
is looking. One run (a *tick*) reads, acts and exits: no daemon, no model call. It is off until `watchdog install`
(launchd on macOS, cron elsewhere; [setup](../skills/setup/SKILL.md) question 9 offers it). It also replaces the Claude
Desktop night nudge: open night-queue items inside `AGENT_HUB_NIGHT` count as waiting work, for every engine and host that
can be woken.

| Rule | Looks at | Does |
|---|---|---|
| R1 | An agent whose process is gone without a result. | The existing line `EXIT <role>: killed (no result)`, written once. |
| R2 | An open owner question past its due time that has a default. | One journal line `[watchdog] @hub OVERDUE Q-… (due …) default: …` per question and due date; a new due date re-arms it. |
| R3 | The hub is silent (not busy, no activity for 15 min), lines addressed to it have waited 15 min (or a night-queue item has, inside `AGENT_HUB_NIGHT`), and no `jwait` of its own runs. | Wakes the hub. |
| R4 | A Claude hub whose last turn ended on an API error, or a confirmed idle Codex app hub whose last own turn ended with explicit `server_overloaded`, 15 min ago or more. | Wakes the same session/thread, whether or not anything waits. |
| R5 | The machine, only when `AGENT_HUB_SPAWN_HOLD_LOAD` is set: the 1-minute load average per core above it. | Writes `<state dir>/spawn-hold.json`; see the load hold below. |
| R6 | Each engine's plan week ([limit pace](reference.md#limit-pace)), for a stage with a hub. | One journal line `[pace] @hub LIMIT …` per forecast crossing, stage, window and level; the owner is notified once per window projected to run out. Forecast context only: each launch compares fresh remaining weekly quota. |

"Addressed to the hub" is what the hub's own digest `jwait` would deliver (its tags, its status words, not its own lines),
that no `jwait` of the hub has consumed (`.jwait-state/<caller>.json`, under its tag or its session id), stamped after
the hub took over. "No `jwait` of its own" is the file `.jwait-state/<stage>/<caller>.armed.json`, which `jwait --journal` writes
while it waits; a file whose process is gone is ignored and deleted. When a live waiter exists but lines still wait, the
watchdog does not wake: it writes one journal line (no status word, no `@`) saying that the waiter does not match them.
The watchdog's record lines (a wake, a failed wake, the mismatch above) carry no status word and no `@`, so they never count as waiting; the R2 line is addressed to the hub on purpose and does. Times are `AGENT_HUB_WATCHDOG_WAKE_AFTER` (15m).

### Which host is woken how

| Hub host | What the watchdog does |
|---|---|
| Headless hub (an agent of `agent spawn`) | `agent send --stage S <role> "<text>"` (resumes the same session). |
| `claude --bg` hub, idle | `claude stop <id>`, wait until the stopped session's process has exited, then `claude --bg --resume <full id> "<text>"`: the same session id, with no other flag. |
| `claude --bg` hub that is no longer listed | The same resume, when the hub was started in the background (`host: bg` in its `roles.json` record, else the pending record of `hub succeed` that started it) and the daemon still holds the session's saved options. |
| `claude --bg` hub that is busy | Nothing: it is not silent. |
| Desktop, terminal, a Claude session not started in the background, a Claude hub whose busy state cannot be read | A notification only. |
| Codex app hub with recorded `host: codex-app`, confirmed idle and rollout activity evidence | `codex queue --thread <registered UUID> --message "<text>"`: starts a turn in the same thread, after another idle check. |
| Codex terminal, unconfirmed/legacy host, unavailable CLI runtime or `notLoaded`/`systemError` state | The standalone tick notifies only. `notLoaded` belongs to one server and does not exclude another writer. An active thread is left alone. |
| Confirmed Codex app hub with a separately installed app-native heartbeat | The native consumer checks idle/actionable work in the actual app, claims the current UUID/fingerprint, sends through the supported native tool and records its receipt. CLI runtime absence is not native idle evidence. |

`hub start` and `hub takeover` record `host: codex-app` only when the registered UUID is the current
`CODEX_THREAD_ID`, both app markers (`CODEX_INTERNAL_ORIGINATOR_OVERRIDE=Codex Desktop` and
`CODEX_APP_TOOLS_PIPE_PATH`) are present, and the session is not a detached `AGENT_ROLE` worker. A rollout's
`source` never establishes the current host. Retaking the same thread from an unconfirmed host clears that provenance.
Existing app hubs must run `hub takeover --session self` from the app once to record it. Reading runtime status uses
the supported `codex app-server proxy` and read-only `thread/read`; it does not start a daemon or load a thread.
Missing CLI/queue support, failed queue or timeout has no resume fallback. The queue boundary was checked on CLI 0.160.0.
The CLI's shared daemon must reach the actual app runtime: Desktop attribution alone does not establish that
transport. Desktop may use a separate app-server; if the shared-daemon proxy is unavailable or does not know the
thread, this path stays notify-only. Fake transport controls do not prove live Desktop wake.

Codex R4 accepts only persisted `task_complete.error.codex_error_info = server_overloaded`: an explicit final
transient API failure, with a matching `task_started.turn_id` and `started_at`, from after this thread's creation.
The bounded tail must be complete. A later user message, started/completed turn or interruption cancels the candidate.
Before queueing, the watchdog rechecks idle and that the same failed turn remains last. It excludes quota, rate-limit,
authentication, `other`/unknown errors, bare completion and user-aborted turns. CLI 0.160.0's runtime
`ErrorNotification.willRetry` is not persisted; runtime error notifications alone are not terminal evidence.

The wake text names the number of lines and the time they have waited since, tells the hub to run its digest `jwait` with
`--since` that time, handle what it shows and keep one waiter, and names `watchdog quiet`. After a stop and resume it adds
that the background commands of the hub's last turn were stopped. It carries no line text. It starts with
`[agent-hub watchdog]` (the name before the rename, still written for one release because a hub on an older plugin copy
knows only that form; `[delamain watchdog]` is read the same), which the context-budget hook (both engines) recognises
as Delamain's own prompt: it does not reset the autopilot's auto-handoff chain the way a prompt typed by the owner does.

### Codex app-native bridge

When Desktop's runtime is separate from the CLI daemon, an existing app-native heartbeat can consume
`watchdog native-plan --json`. This read-only command returns a pure list of `{stage, session, fingerprint, reason,
waiting_since, count, message}` for explicit `codex-app` registrations with real aged unconsumed work or narrow R4.
It honours quiet, pending takeover and live waiter gates, and never asserts idle or returns journal payload text.
The heartbeat must use native `read_thread`, establish current idle and genuinely unfinished business work, then
claim before calling native `send_message_to_thread` on exactly that UUID.

`native-claim --stage S --session UUID --fingerprint F` rechecks eligibility and reserves a receipt. `native-ack`
adds `--attempt TOKEN --outcome sent|failed|unknown|completed-skip` and rechecks identity/quiet/pending before writing
an outcome. Native backoff is separate from standalone notification cooldown; actual standalone delivery attempts
still suppress overlapping dispatch. Claims are serialized and protected across stages sharing a UUID. Unacknowledged
or unknown delivery holds the UUID until verified new own-turn activity, even across new work or re-registration;
expired backoff and file touches do not release it. `completed-skip` suppresses only stale completed
work, without closing a whole stage; a new work fingerprint re-arms.

The [heartbeat prompt](../templates/codex-watchdog-heartbeat.md) defines the native read/check/send/ack procedure,
including timestamp ordering, stale completed work, races and unknown outcomes. The current app coordinator updates
the **same existing automation** with supported `automation_update` after installation. This consumer may be
model-assisted and spend model limits; the CLI planner/attempt protocol makes no model or native API call. Its native
read/check/send interval is bounded, not an atomic transaction across the app API and local files. Live Desktop wake
requires that consumer to be installed and validated; fixture protocol controls alone do not prove it.

### Safety

- **Never a successor.** The watchdog runs `agent send`, same-thread `codex queue`, `claude stop` and `claude --bg --resume` of the hub's own
  session id. It never runs `hub succeed`, `agent spawn` or a `claude --bg` without `--resume`. Right before a resume it
  reads `claude agents --json` again; if the hub is listed busy it does not wake it, and if the CLI starts a copy of the
  session anyway, it stops the copy, counts the wake as failed and notifies; it does not resume a second time in the
  same tick, the next tick (after the backoff) does.
- **Do-not-wake marker.** `watchdog quiet --stage S --reason "…" [--for 8h | --until HH:MM|ISO]` writes
  `<stage>/do-not-wake.json` (who, when, until, reason); `watchdog quiet --stage S --clear` removes it; `watchdog quiet`
  alone lists every stage's marker. A marked stage gets no R3/R4 wake and no notification; R1 and R2 still write. An
  expired marker is removed by the next tick. The `hub takeover` digest shows an active marker.
- **One wake per episode.** An episode starts when the hub needs waking and ends when it shows activity after the last
  action, or nothing waits any more. The first wake is at once; later attempts wait 15, 30, 60, 120, 240 minutes
  (`AGENT_HUB_WATCHDOG_WAKE_AFTER` doubled each time, up to `AGENT_HUB_WATCHDOG_BACKOFF_MAX`, 4h); notifications follow
  the same schedule. A wake after which the hub shows no activity for 5 minutes counts as failed: a journal line, a
  notification `wake failed`. A failed wake has no other fallback and no successor.
- **A pending handoff.** A stage whose `auto-handoff.json` has a pending successor that has not taken over is skipped.
  When that record is older than `AGENT_HUB_SUCCESSOR_TIMEOUT` plus the wake time, the owner is notified once
  (`handoff stuck`) and nothing is started.
- **A replaced hub starts clean:** the state is keyed by the hub's session id.
- **A finished stage retires its hub.** After the finite work and external waits are complete, run
  `roles retire hub --stage S --note "stage complete"` from that stage. The watchdog reads only the active hub
  record and skips a retired one, even if old journal lines remain unconsumed. A `DONE` or `MERGED` line alone does
  not close a multi-item stage; use retirement or a deliberate `watchdog quiet` pause.
- **One tick at a time:** a non-blocking lock on `<state dir>/watchdog/lock`; a second tick prints "another tick is
  running" and exits 0.
- **Dry run.** `watchdog run --dry-run [--stage S] [--json]` evaluates every rule and prints `[plan] …` lines, with
  ids shortened to 8 characters; it writes no journal line, no state, no marker, no `EXIT` and takes no lock, and sends
  no notification.

### The load hold (R5)

Off by default. With `AGENT_HUB_SPAWN_HOLD_LOAD` set (load per core, e.g. `1.5`), a tick whose 1-minute load average
divided by the core count is above it writes `<state dir>/spawn-hold.json` (`since`, `load`, `cores`, `until` = now +
two intervals) and refreshes it while the load stays high; it deletes the file once the load is below 80 % of the
threshold, and also when the setting is unset. `agent spawn` reads the file (ignored once `until` has passed or when it
cannot be read): by `AGENT_HUB_SPAWN_HOLD` it warns and goes on (`warn`, the default) or exits 1 (`refuse`), naming the
load, the cores, the threshold and `--ignore-hold`, which passes. Resumes (`agent send`) are never held: they continue
work that already exists. The job must be installed for the hold to be written; `watchdog run --dry-run` shows what a
tick would do.

### Limit-pace context (R6)

R6 reports forecast changes; it does not schedule work. For each launch, follow
[limit pace](reference.md#limit-pace): compare fresh remaining weekly percentages and advise an equivalent model
class and effort for that launch. Forecasts from the first 6 hours of the week are low-confidence display only:
they produce neither a journal alarm nor an owner notification, and consume no crossing state;
five-hour windows are contextual only. Neither supplies a reason to delay work until reset. Engine locks remain in
force: ask whether to allow the other engine for this launch, with running the locked engine as the default.
The spawn refusal uses the verified weekly quota rules in the reference, not the forecast crossing.

### What leaves the machine

A notification carries the stage name, minutes, counts and an event word, for example `delamain: payments — hub silent 47
min, 3 lines waiting`; the other events are `last turn failed`, `wake failed` and `handoff stuck`, and R6's
`delamain: Codex plan week projected to run out before its reset` (the engine's name, no stage). Never line text,
question text, session ids, tags or paths. Channels: the local one (macOS `osascript`, elsewhere `notify-send` when
present; `AGENT_HUB_NOTIFY_LOCAL`, on by default) and a remote one you configure, `AGENT_HUB_NOTIFY_CMD`, a JSON argv
in the hub home's `config.json` in which `{message}` is replaced and which runs without a shell:

```json
{ "AGENT_HUB_NOTIFY_CMD": ["curl", "-fsS", "-d", "{message}", "https://ntfy.sh/<topic>"] }
```

`watchdog notify-test` sends `delamain: test notification` through every channel and exits 1 when none exists or one fails.

### Install, status, uninstall

```bash
watchdog install [--scheduler launchd|cron]     # the job, and AGENT_HUB_WATCHDOG on in the hub home's config.json
watchdog status                                 # job, last tick, each stage's episode, markers, channels
watchdog run --dry-run                          # what a tick would do now
watchdog uninstall [--scheduler launchd|cron]   # removes the job and sets AGENT_HUB_WATCHDOG off
```

The job is `<state dir>/watchdog/run.sh`, which execs the plugin's `bin/watchdog run` with the hub home and the PATH
recorded at install time, and one launchd job `io.agent-hub.watchdog.<8 hex of the hub home's path hash>` (a plist in
`~/Library/LaunchAgents`) or one crontab line marked `# agent-hub-watchdog <hub home>`; several hub homes have one job each.
The shim records the plugin version that was installed, so **run `watchdog install` again after every plugin update**
(`watchdog status` says "install again" when the job points elsewhere). A change of `AGENT_HUB_WATCHDOG_EVERY` needs the
same. Files, all under `<state dir>/watchdog/` (`<hub home>/.state`, or `$AGENT_HUB_STATE_DIR`): `state.json`, `lock`,
`log.md` (one line per action, trimmed at 1 MB), `run.sh`, `job.log`. Settings:
[reference](reference.md#configuration).

### The probe: why the wake argv is what it is

A live probe on claude 2.1.289 (2026-10-07, a scratch `--bg` session) settled how a background session is woken. A
`--bg` session keeps its own saved options (model, effort, permission mode, remote control). `claude --bg --resume <id>
"<text>"` with the session not listed continued the same id and took the text as the prompt. The same command with any
flag (`--model` was tried) started a copy, and so did the same command while the session was listed idle. Hence the
order, stop the idle session, then resume it with no other flag, and the watchdog's check that nothing listed is
running and that no copy appeared.

A second probe (2026-10-07, 2.1.289) found one more window. After `claude stop` a session with Remote Control drops out of
`claude agents --json` about 1.7 s before its process has exited and the daemon has released it; a resume in that window
started a copy (4 of 4), a resume after the stopped row's pid had exited continued the same id (3 of 3). The watchdog
therefore waits for that process to exit (up to 30 s, polling every 0.2 s) before it resumes. The process is identified
by its pid and its start time (a reused pid is another process). If it is still there after the wait, the watchdog keeps
its identity in the hub's state (`state.json`, `hub.stopped`) and does not resume in this tick, nor in any later tick
(also not when the hub is no longer listed) until that process is seen gone. Once released it reads `claude agents --json`
once more: a hub listed again (the owner resumed it meanwhile) cancels the wake. The identity is saved right after
`claude stop` succeeds, before the listing is read again, so a failed or still-showing re-list does not lose it. A listed
idle row without a pid is not stopped at all (a stop's release cannot be told): the wake fails, is journaled, and the owner
is notified.

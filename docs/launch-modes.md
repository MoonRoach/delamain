# Choosing how to launch work

A hub can hand a piece of work to six kinds of worker. They differ in what kills them, who can talk to them, what lands
in the hub's context and what they cost. This page gives the decision table the `hub` skill applies, the reasoning
behind it, and the experiments (Claude Code CLI 2.1.274, macOS, 2026-10-01). The table rests on what is visible before
the start — what the work does and who must reach it — not on an estimate of how long it takes.

## The modes

| | Foreground sub-agent | Background sub-agent | Headless agent (`agent spawn`) | `claude --bg` session | Cloud session | Desktop session |
|---|---|---|---|---|---|---|
| Started by | Agent tool | Agent tool, `run_in_background: true` | `agent spawn` | `claude --bg "<task>"` | `claude --cloud` | the owner or an app tool |
| Runs in | the hub's process; the hub waits | the hub's process; the hub keeps working | its own detached `claude -p` process | the `claude daemon` supervisor | Anthropic's cloud | Claude Desktop |
| Ends with | its turn | its turn; killed when the hub's process exits (E5) | its turn; survives the hub's exit and handoff | `claude stop`; survives the terminal | its task | the owner |
| Who can talk to it | nobody while it runs | only the parent session: `SendMessage` to its id (E8) | any session: `agent send` (inbox while alive, resume after) | any local session by name (E14); the owner with `claude attach` | nobody | the owner |
| What reaches the hub | its whole result | a ~1 KB launch note, a ~0.7 KB completion notice and its result (E4) | one journal status line; the report is a file | nothing unless it writes the journal | a fetched report | nothing |
| Visible in | the hub's UI, `agent-top` | `agent-top` (rows `<parent role>/<id>`), `/tasks` | `agent-top`, `agent status`, the journal | `claude agents` | the cloud UI | Desktop |
| Starting context | ~16k tokens (E13) | ~16k tokens | ~27k tokens + the brief footer | as a new session | — | — |

A cloud session fits read-only work such as a review (a bundle made from a GitLab checkout cannot push back); a user
who has the credit for it plugs it in as a reviewer skill (`docs/reviewers.md`), it is not a launch mode of its own
here. A `claude --bg` session
works (E14) but is not wired into the hub's tools for executors: it has no stream-json log for `agent-top`, no `EXIT`
line when it dies, and `--dangerously-skip-permissions` needs a one-time interactive acceptance. It is the right shape
for one thing — the hub's own successor under autopilot (`hub succeed`, [Autopilot](reference.md#autopilot-the-hub-hands-over-by-itself)): with `--remote-control`
the owner reaches it from the phone (E20), and its failure modes (E21–E23) each have a fallback.

Claude Code's other parallel mechanisms, and where they sit here:
- **Agent view** (`claude agents`, research preview) is the screen over `claude --bg` sessions: dispatch, watch,
  attach. Same lifetime and limits as the `claude --bg` column.
- **Agent teams** (experimental, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`): a lead session and teammates with their
  own context windows that message each other. Not measured here; the docs warn that token use grows with the number
  of teammates. Use it when the workers must talk to each other, not to the hub.
- **Cross-session messaging** (`SendMessage`/`ListAgents` between sessions on one machine): reaches any running
  session by its name — an interactive one, a busy `claude -p` run (E8), a `claude --bg` session (E14) — but never a
  sub-agent of another session, and nothing once the process is gone. `agent send` keeps working after an agent's
  process ends (it resumes the session) and leaves a journal line; prefer it for headless agents.

## Decision table

Ask the questions in order; the first "yes" decides. Estimated duration is a hint, never the deciding criterion.

| # | Question | Launch as |
|---|---|---|
| 1 | Is it a review of a change? | `hub reviewer --for <class>` — the reviewer the user configured; by default an `agent spawn` ([reviewers](reviewers.md)) |
| 2 | Should the owner talk to it directly? | Desktop session (or `claude --bg` if the owner lives in a terminal) |
| 3 | Does it commit or push, wait on CI, a deploy or another party, or touch production? Must anyone except this hub session talk to it, or must other sessions see its status in the journal? | `agent spawn` |
| 4 | Is the hub near its handoff threshold (see below)? | `agent spawn` |
| 5 | Is it read-only, with a short digest as its answer and nothing external to wait on — and does the hub have nothing else to do until the answer? | foreground sub-agent |
| 6 | The same, but the hub has other work meanwhile | background sub-agent |

What a read-only digest is: read a log, check a fact, probe an environment, summarise a file. If the work is not that
and none of rows 1–4 fit, it is almost always row 3: something is committed, waited for or reached by someone else.

Other axes:
- **Parallelism.** Background sub-agents run in parallel inside the hub's process (20 at once and 3 levels of
  nesting by default, per the docs; not measured here). Long parallel work is several headless agents, each with its
  own process, journal tag and locks.
- **Cost.** Foreground and background cost the same tokens; neither re-reads the hub's context. What a sub-agent
  costs the hub is what it returns, so ask for a short result (≤ 20 lines) and put the details in a file. A headless
  agent starts ~10k tokens heavier and talks only through the journal and its report. The model is chosen per call:
  long routine work goes to Opus or Sonnet, not to a capped judgement model.
- **Visibility.** Headless agents and the sub-agents of the sessions in the role registry (the hub after
  `hub takeover`, every spawned agent) show in `agent-top`; sub-agents read-only. A sub-agent's state comes from its
  parent's transcript (a completion notice for a background one, the Agent call's result for a foreground one, E18)
  and from whether the parent's process still runs (`~/.claude/sessions/<pid>.json`, E19).

Why not by duration: a hub cannot estimate task time reliably, and a wrong guess costs the same whatever the number —
a sub-agent dies with the hub's process and only the hub's own session can resume it (E5, E6, E8). What the hub can see
before the start is what the work does. Work that commits, waits or must be reached by others needs a process of its
own; a read-only digest does not. The one dangerous moment, the hub's session ending while a sub-agent of it still
runs, is closed mechanically: `hub handoff` refuses while one is live (next section).

**A call budget in every sub-agent brief.** Nobody watches a sub-agent, so its brief ends with a limit: "if not done
after N tool calls, stop and return a partial result and what is left". The `hub` skill recommends N = 40 for a probe or
a read and up to 80 for a wide read-only investigation; it is a recommendation, a project sets its own in
`hub-rules.md`. A partial result with "what is left" lets the hub relaunch the rest narrower, instead of paying for a
sub-agent that wandered until its context was full.

## The hub near its threshold

A background sub-agent cannot be handed over: the successor is another session and cannot message it (E8), and when
the old hub closes it dies (E5). Once the context crosses the threshold you fixed in advance, nothing new starts as a
sub-agent that may outlive the hub — it is an `agent spawn`.

`hub handoff --stage S [--session ID]` looks for sub-agents of the hub's own session before it writes the draft: the
session's transcript folder, the parent's completion notices and the running-sessions registry — the same discovery and state
logic as `agent-top` (`bin/subagents.py`; E18, E19). If any is live it exits 2 and lists them (id, description, age).
Per sub-agent, three ways out:
- **wait** for it (its notice is minutes away);
- **stop it and re-launch the remainder with `agent spawn`**, with the brief and the partial result;
- **record it as lost**: `hub handoff --allow-live-subagents` writes the list into the draft's TODO section.

A finished sub-agent (a notice, or a foreground one whose Agent call returned) never blocks. Compaction is not a reason
to hand over: a sub-agent keeps running through it and its notice arrives afterwards (E7).

## Sub-agents inside a headless agent

A headless agent is a `claude -p` run. When its turn ends it waits for its background sub-agents, but only up to the
CLI's ceiling (10 min by default), then kills them (E10); a sub-agent's own activity does not extend the wait (E11).
`agent spawn` therefore starts every run with `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` (wait until they finish —
a 19-minute sub-agent completed, E12; `AGENT_HUB_BG_WAIT_CEILING_MS` sets another value). While they run the agent shows as alive; `agent stop` ends
both. The executor reports for its sub-agents — they do not write the journal, because the hub's `jwait` wakes on any
`DONE` line.

The ceiling covers background sub-agents, not background Bash tasks: in a `claude -p` run a background Bash command
such as `jwait` is killed when the turn ends. A hub run as `claude -p` therefore learns about `DONE` only from its next
message. The hub is an interactive session (Claude Desktop, or a terminal session), where its background `jwait` wakes
it.

## Starting a headless agent from the hub

Run `agent spawn` as a normal (foreground) Bash call: it returns within seconds, once the agent's run has started.
The docs say that when Claude Code stops a background Bash task — at exit or from `/tasks` — processes it detached
with `setsid` stop too. In the experiment (E16) a spawned agent survived both its parent session's exit and the
killing of the background task that launched it, because it had already been reparented; nothing is gained by
running it in the background, so do not rely on that.

## Journal lines from sub-agents

A sub-agent's shell inherits the parent's environment, `HUB_TAG` and `CLAUDE_CODE_SESSION_ID` included (E2), so a
bare `jlog` writes under the parent's tag. The convention:
- the hub's own background sub-agent may write one final line for the record under a sub-tag:
  `jlog --tag hub-<N>/<name> "DONE <report path>"`; the hub's `jwait` drops its own sub-tags, and the completion
  notice is what wakes the hub;
- an executor's sub-agents write nothing to the journal (above).

## Waiting for CI, a merge or a lock

A wait command run as the hub's own background Bash wakes the hub on every exit, and each wake re-reads the hub's whole
context: in the 07–14.10 audit 202 of 913 background wakes were CI, merge or lock waits. The hub should wake once, on
a result it must decide on. `await` does the waiting outside the hub's context:

```bash
# an ordinary foreground call: it returns in a moment with the supervisor's pid and the log path
await --ok MERGED --label "MR !12" --on 2=TIMEOUT -- python -m scripts.ci_wait --mr 12
```

The supervisor runs the command in its own session with its output in a log (`<stage>/coordinator/work/await/`),
journals nothing while it runs and, when it ends, one line:

```
- 14:07 [hub-3-await] @hub MERGED MR !12 — https://gitlab.example/mr/12 (exit 0, 11m, log …/await/….log)
```

The hub's single `jwait` (`--tag hub-<N> --tag hub --hub-events`) wakes on it: `@hub` addresses the hub, and the tag
`<tag>-await` is neither the hub's own tag nor its sub-tag `<tag>/…`, which `jwait` drops. Outcomes: exit 0 → the
`--ok` word (`DONE`, or `MERGED` for a merge); exit 124 or `--timeout` (default 2h; the command's process group is
stopped) → `TIMEOUT`; any other exit code, a command that cannot start, a signal → `FAILED`; `--on RC=WORD` adds
words such as `CONFLICT` for a command that distinguishes them. An executor can use it the same way (its tag becomes
`<its tag>-await`). `kill <supervisor pid>` stops the wait and journals `FAILED … interrupted`; a supervisor killed
with SIGKILL writes nothing, so the hub's `jwait` alarm stays the backstop. A command that is not on `PATH` fails
at once with exit 2 and no line.

## What did not make it into the plugin

- Recording sub-agents in `roles` (kind `subagent`): their id is an address only inside the parent session (E8), no
  other session or a successor hub could use it, and nothing would retire the entry. `agent-top` finds them from the
  transcripts instead.
- `claude --bg` as a backend for `agent spawn`: promising (a supervisor, attach, peers can message it by name), but
  the stream-json log, `EXIT` lines, init check and fixed session id that `agent status`/`agent-top` rely on would need
  a second code path, and a killed session followed by `--resume` started a copy (E14). An open question.

## Experiments

Each run used a headless `claude -p --model haiku` parent in a temp directory that launched one sub-agent through
the Agent tool, with a separate journal root (`AGENT_HUB_HOME` for the plugin's tools); every process and background
session was stopped and removed afterwards.

| # | Behaviour | Evidence |
|---|---|---|
| E1 | A `claude -p` run whose turn ended stays alive until its background sub-agent's turn ends, then runs one more turn on the notice | parent replied `LAUNCHED`, sub-agent ran a 60 s command; process exited after 84 s with two `result` events (`LAUNCHED`, `NOTIFIED`), exit 0 |
| E2 | The sub-agent's shell inherits the parent's environment | its `env` showed the parent's `HUB_TAG`, `HUB_STAGE`, the journal root and `CLAUDE_CODE_SESSION_ID` = the parent's session id; `jlog --tag …` from it wrote the journal, exit 0 |
| E3 | Transcript: `~/.claude/projects/<project>/<session>/subagents/agent-<id>.jsonl` + `agent-<id>.meta.json` | meta: `agentType`, `description`, `model`, `requestShape: "background"`, `spawnDepth`; lines carry `isSidechain: true`, `agentId`, `timestamp`, and `type` after the nested `message` — no `init`/`result` events, so `agent-top` reads them with a JSON parse, not its stream-json fast path |
| E4 | What the parent sees | launch tool result ~1,050 chars (agent id, output file, "do not read the transcript"); completion `<task-notification>` ~700 chars + the result text, with `<usage>` (sub-agent tokens, tool uses, duration); stream-json shows `task_started` / `task_progress` / `task_notification` events |
| E5 | Parent killed (SIGTERM) while the sub-agent works | parent, the sub-agent's shell and its child process all gone within 3 s; no orphan; the work was never done |
| E6 | Parent resumed (`--resume`) after the kill | the resumed parent first receives a notice `status stopped — didn't finish before the previous session ended`; `SendMessage` to the sub-agent's id resumed it with its history; it redid the step and notified `completed` |
| E7 | `/compact` in the parent while the sub-agent runs | compaction succeeded (28.6k tokens before); the sub-agent finished 50 s later and the parent handled the notice |
| E8 | Another session messages the sub-agent | `SendMessage` to its id from a second session: "No transcript found for agent ID"; `ListAgents` there lists sessions, not sub-agents. The busy headless parent itself was listed as a peer and a message to it was delivered as a new turn |
| E9 | Model and effort | per-call `model: "sonnet"` honoured (resolved by the CLI version — 2.1.274 gave `claude-sonnet-5`); `effort: high` pinned by the agent definition recorded on every sub-agent assistant line |
| E10 | The `-p` wait ceiling | with `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=20000` the parent printed "Background tasks still running after 20s; terminating" and exited at 28 s; `subagent_stats.killed.system = 1`; no notice in the transcript |
| E11 | The ceiling counts from the parent's turn end | a sub-agent making a tool call every 12 s was killed at the same 20 s ceiling after its first call |
| E12 | Ceiling 0 | with `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` a sub-agent made two 560 s calls; the parent, whose turn ended at 7 s, waited and exited at 1,139 s after handling the notice, exit 0 |
| E13 | Cost shape | sub-agent's first call: ~16k context tokens (system prompt, CLAUDE.md, tools); a fresh headless parent in the same setup: ~27k |
| E14 | `claude --bg` | returns at once; hosted by `claude daemon` → `bg-pty-host`; `claude agents --json` lists it (`kind: background`, `status`, `state`); inherits the launching shell's environment (`jlog` worked); transcript at the usual `projects/<project>/<session>.jsonl`; a peer's `SendMessage` to its name ran a command in it; `--bg -p` refused; `--dangerously-skip-permissions` refused until accepted interactively; a variadic flag (`--allowedTools Bash "<task>"`) swallowed the prompt; after SIGTERM to its process it was not restarted (`state: blocked`) and `claude --bg --resume <id>` started a copy with the history |
| E15 | A sub-agent that backgrounds its own command | its turn ends at once and the parent gets a `completed` notice with an interim result; the backgrounded command is killed when the `-p` parent exits |
| E16 | `agent spawn` and the parent session's exit | a `claude -p` session ran `agent spawn` once as a foreground and once as a background Bash call, then exited after 10 s: both agents (fake CLI holding 45 s) kept running and wrote their `result`; a third spawn inside a background task that was still running (`agent spawn … && sleep 120`) also survived when the CLI killed that task at exit |
| E17 | Bash timeouts | with `BASH_DEFAULT_TIMEOUT_MS=15000` a foreground 40 s command was moved to the background at 15 s (`is_backgrounded`), and a background `jwait --for 12h` was not stopped at 15 s; both were stopped when the `-p` run exited. The docs give background commands 30 min by default (the Bash call's `timeout` raises it, 2 h at most unless `BASH_MAX_TIMEOUT_MS`), but in a long `claude -p` session (CLI 2.1.284) a background command started without `timeout` was still running at 31 min. The skill's waiting rule passes `timeout: 3600000` with `jwait --for 55m` either way |
| E18 | Foreground sub-agent | `requestShape: "foreground"` in its meta; no `<task-notification>` in the parent; the parent's `tool_result` for the meta's `toolUseId` carries its answer |
| E19 | Which processes run | `~/.claude/sessions/<pid>.json` holds `pid` and `sessionId` for every running CLI process, headless and Desktop-hosted alike; no stale files were left by the runs above |
| E20 | `claude --bg --remote-control <name> -n <title> --model haiku "<prompt>"` from inside a Claude Desktop session (its environment as is), cwd a trusted repository (CLI 2.1.285) | started under `claude daemon`, printed `backgrounded · <id> · <name>`, logged in with the subscription and answered; `claude logs <id>` (ANSI screen text) contains the Remote Control link `claude.ai/code/session_<…>`; `claude agents --json` lists it (`kind: background`, `id`, `sessionId`, `name`, `status`, `state`); a `SendMessage` from another session to its name was not delivered: it was held for the recipient's approval (a different permission mode) and expired — so `hub succeed` puts the takeover instruction in the CLI prompt and the two hubs talk only through the journal; it inherits the launching process's environment (`AGENT_HUB_HOME` reached it); `claude stop <id>` / `claude rm <id>` remove it |
| E21 | The standalone CLI not logged in | the session shows "Not logged in · Run /login" and does nothing: Claude Desktop's own login does not reach `claude --bg`; `claude auth status` (JSON `loggedIn`) detects it beforehand |
| E22 | `--permission-mode bypassPermissions` with `--bg` before the disclaimer was accepted | exit 1: "requires accepting the disclaimer first. Run `claude --dangerously-skip-permissions` once interactively" |
| E23 | An untrusted cwd | exit 1: "Workspace not trusted. Run `claude` in <dir> once and accept the trust prompt"; a Claude Desktop worktree path may be untrusted for the CLI while its main checkout is trusted |
| E24 | A `--bg` successor in the default permission mode (`hub succeed`, Haiku, CLI 2.1.285) | it loaded `/delamain:hub` from the prompt and ran the takeover command, then sat at `state: blocked, waitingFor: permission prompt`; with `--settings '{"permissions":{"allow":["Bash(hub takeover:*)",…]}}'` it still asked, because the command held `"$CLAUDE_CODE_SESSION_ID"` (a probe: `Bash(echo:*)` passed `echo hello` and denied `echo "$VAR"`); with `--session self` the takeover ran, and it then asked to `Read` the handoff outside the project; with `additionalDirectories` and `Edit(/<hub home>/**)` it took over, read the handoff and journaled DONE ~20 s after start, no prompt |
| E25 | Cleaning up | `claude stop <id>` then `claude rm <id>`; with no background session left the transient `claude daemon` exits by itself (`claude daemon status`: not running) |
| E26 | `claude --bg --remote-control <name> -n <name> --model haiku --worktree <name> "<prompt>"` from a trusted repository's main checkout (CLI 2.1.285) | accepted: `backgrounded · <id> · <name>`; the worktree is `<main checkout>/.claude/worktrees/<name>` on a new branch `worktree-<name>` from the main checkout's HEAD, locked by git while the session runs; `claude agents --json` reports that worktree as `cwd`; the Remote Control link appears as without `--worktree`. A second `--bg --worktree <name>` with the same name does not fail: it joins the existing worktree (two sessions, one `cwd`) — so `hub succeed` picks a free name itself. `claude stop` keeps the worktree ("worktree retained"); `claude rm <id>` refuses while the lock names a live process and, once it exits, removes the worktree and its branch |

Docs and experiment: the docs say a `-p` run waits for background sub-agents "until 10 minutes of continuous idle
waiting"; in the experiment the sub-agent's own tool calls did not reset that clock (E11). The docs' limits on
concurrency (20) and nesting depth (3) and the claim that `--bg` sessions survive a reboot were not tested.

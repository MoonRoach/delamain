---
name: hub
description: Tools and recommended rules for a stage hub — the one interactive session that plans a stream of work and runs headless Claude Code or Codex agents. Load it when you are the hub of a stage, when starting a stage, taking over or handing off a hub shift, when closing a stage whose hub is no longer needed, when spawning or messaging a long-running background agent, when you need a review of a change, and when you need to wait for events — journal lines, an agent's status, a script's question, an alarm. Also load it when the user mentions Delamain (formerly agent-hub) or "the hub skill", or asks you to plan work for agents or to run work through agents.
---

# Stage hub: tools and recommended rules

The core: what a hub needs from its first minute. Situational procedures sit in `references/` beside this file, moved
whole; read one when its situation comes up. **A Codex hub reads `codex-hub.md` and `autopilot.md` at start.**

- `references/stage-lifecycle.md` — *Starting a stage*, *Taking over a shift*, leaving, *Closing a stage*, the shared-file table, the watchdog.
- `references/autopilot.md` — *Autopilot* (`AGENT_HUB_AUTO_HANDOFF=on`, automatic successors, Codex Desktop native launch).
- `references/owner-and-planning.md` — *Talking* and *Planning a stage* in full: `ask`, standing permissions, grilling.
- `references/launch-and-executors.md` — *Choosing how to launch work*, *Reviews*, *Executors*, *Locks*, *Project
  configuration*, *Optional modules*, *Watching agents*, `await`, the twelve rules in full with their reasons.
- `references/codex-hub.md` — Codex: engine choice, model/CLI checks, *Terminal follow-through*, waiting, `tell` delivery.

## Host and engine

Run the bundled tools through the host's shell tool. The plugin root is `PLUGIN_ROOT` (Codex), `CLAUDE_PLUGIN_ROOT`
(Claude), or two directories above this skill; use its `bin/<tool>` when a command is missing or shadowed on PATH
(GitHub CLI `hub`, an old `jlog`) and tell the owner in one line. `HUB_BIN` is set in detached workers. Paths below
are relative to that root. Choose the executor engine before the model: offer the owner one choice at stage planning
(Codex, Claude or mixed; the host is the default, an existing explicit choice already answers it), record it in the
stage's `hub-rules.md`, pass `agent spawn --engine claude|codex`. Engine rules in full: `references/codex-hub.md`. For installation assessment or task routing, read
`<plugin-root>/docs/agents/README.md`; this skill owns the stage workflow once the plugin is selected.

## First commands

Do these before anything else, in this order:

1. `hub start --stage <S> --goal "<goal>" --session self` — S names the work in 1–3 words (`retro-fixes`, never
   `hub-09`, `wp3`), the goal is one line in the owner's words. If the task gives no goal, ask the owner for that line
   first, as the first question of the grilling; never invent one. If `hub` answers `invalid choice` or `not a git
   command`, the GitHub CLI is ahead of the plugin on PATH: run `<plugin-root>/bin/hub start …`, tell the owner in one line.
2. `ask search <words of the goal>` — decisions already on record are settled.
3. Establish the Business DoD, then plan and brief (*Planning a stage*). A clear owner request can already supply the
   agreed result and the owner's yes to the plan; ask only about business-material ambiguity. Honor an explicit
   request to approve the plan before starting.

`hub start` runs once per stage: it creates the stage directory, registers you as `hub-1`, writes the start line and
prints the first `jwait`. Offer `delamain:setup` if the project has no `.agent-hub/`. A hub works in a fresh worktree
of its project, never in the main clone and never outside git: on exit 4 with `MOVE <path>` or `NO PROJECT` follow
`references/stage-lifecycle.md` (*Starting a stage*) before anything else. **Minimal mode:** one hub and a few agents
need `hub start` once, then `agent`, `jlog` and `jwait`; `roles`, `ask`, `lock`, `tell` and `hub takeover/handoff`
matter once there is more than one session, shift or shared resource. Each tool has `--help`.

## Taking over a shift

`hub takeover --stage <S> --session self [--handoff <file>]` (`--dry-run` first if unsure; exit 4 as for `hub start`)
takes the previous hub's locks, registers you as the next `hub-<N>`, writes the start line and prints a digest:
§ 0 of the handoff next to the `ask` register — check every "the owner said" against it, the register wins, and ask the owner about the disagreement; the first
`jwait` to start (its `--since` delivers the handover lines); the `hub-rules.md` and `HUB-NOTES.md` to read before
planning. Leaving: `hub handoff --stage <S>`, fill the TODOs (skill `handoff`); it refuses while a sub-agent of your
session runs; locks are not released. Flags and the rest: `references/stage-lifecycle.md`; automatic handover
(`hub succeed`): `references/autopilot.md`.

Closing a stage whose hub is no longer needed (the owner decides; without it, ask): `hub close --stage <S> --why "<one line>"`
(`--dry-run` first; exit 2 while an agent runs or a question waits, `--force` only on the owner's word). Read
`references/stage-lifecycle.md` (*Closing a stage*) before running it.

## Waiting

Waiting is **one** `jwait`, using the shell harness rather than a polling loop.
- **Claude Code:** Bash with `run_in_background: true`, `timeout: 3600000` and the digest's `--for` (50m by default,
  `AGENT_HUB_JWAIT_FOR`). The prompt cache lives one hour: a wake after a longer sleep re-writes the whole context.
  The Bash `timeout` stays at or above `--for`. The completion notification wakes the coordinator.
- **Codex:** `references/codex-hub.md` (*Waiting on a Codex hub*).

A stopped `jwait` loses no lines once its caller has run before: the next one delivers them.
- `jwait --journal --tag hub-<N> --tag hub --hub-events --for 50m` — lines addressed to the hub, agents' status lines
  and script questions echoed into the journal; your own lines (your tag and its sub-tags `hub-<N>/…`) do not wake
  you. Copy it from the digest. With `--caller <session id>` instead of the hub's tag, add `--exclude-tag hub-<N>`.
- `jwait --file <script output> --match 'AWAITING ANSWER'` — a script's question; one asked before `jwait` started is
  delivered too.
- `jwait --until 20:23 --note "check the nightly import"` — an alarm; exit 3 and a line `ALARM …`.
- Sources and filters combine in one command. What was read is remembered.

A CI, merge or lock wait is never a background Bash of the hub itself: run `await --ok MERGED --label "MR !N" --on
2=TIMEOUT -- <the repo's wait command>` (santinel: `python -m scripts.ci_wait --mr N`, which needs `--on 2=TIMEOUT`;
`bin/await`, a foreground call that returns at once; if `command -v await` finds nothing, an executor does the wait). It journals nothing while the command runs and
one line `@hub MERGED|DONE|FAILED|TIMEOUT|<--on word> … <link>` when it ends: that line is the wake, and
FAILED/TIMEOUT/CONFLICT are decisions for the hub, not retries. An executor that waits on CI uses the same `await`.

A message starting `[agent-hub watchdog]` or `[delamain watchdog]` means the watchdog woke you: run the digest `jwait`
with its `--since HH:MM`, handle what it shows, keep one waiter. Going quiet on purpose: `watchdog quiet`
(`references/stage-lifecycle.md`).

## Talking

- `jlog "text"` — a journal line with your tag; append-only, correct with a new line. In another stage's journal `jlog`
  signs `<your stage>-<tag>`, never `hub`.
- To another stage's hub: `tell <stage> "…"` (`--question`); the answer reaches you only in your own journal. A direct
  cross-session message only when the journal cannot do, and only to the address from `tell <stage> --address` /
  `roles --stage <stage> get hub`, never a session chosen by its display name. Codex: `references/codex-hub.md`.
- `roles list | get | set | retire | broadcast` — the role registry. Detached workers of either engine: `agent send`.
- `ask search <words…>` — what the owner already decided; `ask add … --default … --due …` — a question with the action
  you take if nobody answers; `ask decided` — your own decision on a matter the owner normally decides; `ask close`,
  `done`, `digest`, `list`. Standing permissions (`ask allow`, `ask revoke`): `references/owner-and-planning.md`.
- Owner digest: on the owner's first message after a long silence run `ask inbox --if-quiet` and open your reply with
  its output (empty: go straight to the reply). Every question to the owner says what each answer changes — "A: …;
  B: …" — and the default you take if no answer comes.
- Grilling on request (грилинг, погриль, grill me): load the `grilling` skill and run it as written until the topic's
  frontier is empty; the planning limit below and the A/B format do not shorten it. A question recorded with `ask add`
  keeps the recommendation as a recommendation: it waits for the owner, never acts on silence. Over the stage's open
  questions it runs in a session of its own, not in yours: `hub grill --stage <S>` and do what it prints (Desktop:
  `start_session` in the owner's turn; Codex app: `create_thread`; else hand the owner the link); on `@hub GRILLED` act
  on `ask list --pending`. A new topic the owner raises here is grilled here, unless they say otherwise
  (`references/owner-and-planning.md`): `hub grilling start` before the first round, `hub grilling end` when it ends;
  meanwhile automatic handoffs wait.

## Planning a stage: agree the business result before autonomous work

**Business DoD** is a short, ordinary-language description of the expected user or business result, clear enough for
the owner to leave the work to autopilot; detailed UI, scenario and technical design belong to the hub and executor
unless the owner supplied them.

1. `ask search <topic words>` and `ask allow --list --stage <S>` — what is on record is settled. A successor or
   executor preserves the inherited Business DoD and its source. No standing permission for the repository: see
   `<plugin-root>/skills/setup/SKILL.md` § 5, then one grilling round; record answers with `ask allow`.
2. Business result unclear → the companion `grilling` skill, **limited to ambiguity whose answer materially changes
   the business result; stop once that result is clear.** Facts and implementation choices are agent-owned.
3. Owner answers: `ask add`, then `ask close --answer …`; your own choices: `ask decided`. Meaningful unresolved product
   branches go to the owner and the register.
4. Put the agreed Business DoD, with its source, in the plan or brief; a clear owner request can itself be the DoD.
   Before spawning, have a plan the owner said yes to (a clear, detailed request counts; honor an explicit request to
   approve first) and record it: `ask plan --stage <S> "<plan in one line>"`. A proposal that materially changes the
   business scope or result needs the owner's agreement first.
5. Brief executors with that result; keep implementation steps, technical verification and stop/permission
   conditions separate.

Ask the owner nothing about process (agents, worktrees, commits). For a non-technical owner one question is mandatory:
"How will you open the result, and where should it live?", with a recommendation (a static site, not a server on their
Mac). Completion is judged against the business result; green CI alone does not prove it.
Full recipe: `references/owner-and-planning.md`.

## Choosing how to launch work

Decide from what is visible before the start — what the work does and who must reach it; the first "yes" decides
(table: `<plugin-root>/docs/launch-modes.md`). Duration is a hint, never the criterion; the owner is not asked which
launch to use. When no row applies (a small change, nothing to wait on, nobody else to reach it) the hub may write it
itself: one line with the reason, and `ask decided`.

1. **A review** → `hub reviewer --for <class> --author <role>`, then start what it prints (`references/launch-and-executors.md`, *Reviews*).
2. **The owner should talk to it** → an interactive session in their chosen host.
3. **It commits or pushes, waits on CI, a deploy or another party, touches production, or must be reachable by someone
   other than this hub** → `agent spawn`. Always so when the hub is near its handoff threshold.
4. **Read-only, the answer is a short digest, nothing external to wait on** → a sub-agent: **foreground** when the hub
   has nothing else to do until the answer, otherwise **background**.

- **Host session cards and forks are not a launch mode.** The host may offer to start a session or fork (Claude Desktop's
  `start_session` cards, `hand_off_to_session`). A registered hub does not use them for work that commits, pushes or
  waits: autopilot cannot click a card and agent-top cannot see it, so the work goes through `agent spawn`, and an
  owner decision through `ask add`. A hook refuses these calls in a hub; the owner's own request for a session passes.

Every sub-agent brief ends with a call budget: "if not done after N tool calls, stop and return a partial result and
what is left" (N = 40 for a probe or a read, up to 80 for a wide read-only investigation); ask for a result of ≤ 20
lines, details in a file. `hub handoff` refuses while a sub-agent of your session runs. More:
`references/launch-and-executors.md`.

## Executors

- Before each launch, use [limit-pace advice](../../docs/reference.md#limit-pace) for its engine, model and effort;
  keep engine locks (ask about this launch only; default: run locked engine), and keep ready work moving.
- Work that commits, pushes or waits is a headless agent:
  `agent spawn --engine claude|codex --role R --cwd DIR [--model MODEL] [--effort high] --brief FILE [--worktree [BRANCH]]`;
  the role says what the work is (`mainmerge-fix`, never `wp23`). It survives the hub's handoff and any hub can talk to it. Its tag is `hub-<N>-<role>` (a sub-tag `hub-<N>/…` is
  filtered out of your own `jwait`). An abnormal end leaves `EXIT <role>: …` in the journal, a normal one without a
  status word `ENDED <role>: …` (`REVIEWED …` for a review role).
- `agent status [R]`; `agent send R "…"` — into its inbox, or resumes the session if the process is gone; `agent stop R`.
  An agent's question arrives as `@hub QUESTION …`; answer with `agent send`.
- Every agent that writes code gets `--worktree [BRANCH]` (two agents in one checkout overwrite each other's files);
  at handoff remove finished worktrees and stop background processes the project started.
- Model and effort per agent: Claude aliases `opus|sonnet|haiku|fable`, `--effort` on every alias; for a Codex model
  check the selected CLI first (`references/codex-hub.md`). `AGENT_HUB_PERMISSION_MODE=bypassPermissions` is the
  headless default.
- A Claude executor starts with no MCP servers; launch with `--mcp inherit` or `--mcp FILE` only when its task needs
  one (`references/launch-and-executors.md`).
- A brief follows `<plugin-root>/templates/brief-executor-template.md`; the hub fills "Owner decisions — do not
  reopen" from `ask search <topic words>`, and checks that section when an executor's result disagrees with a record.

Reviews, locks, project configuration (`<repo>/.agent-hub/`), the night queue, `agent-top`, base branches and model
maps: `references/launch-and-executors.md`.

## Claude Desktop host

1. A wake with nothing new: restart the `jwait` in the same message as the host's `wrap_up`, without `update_plan`; a
   wake must not cost two calls over the full context.
2. In a worktree that Desktop created, sync with the base through the host's `sync_with_base_branch`, not `git merge`.
3. A PR whose CI an executor runs is not bound to the host's Auto-fix or monitor: two systems would wake the hub on
   one event.
4. Desktop pauses cross-session sends after 10 without the owner typing: `roles sent` after each; at budget 0
   `jlog "@<tag> …"` instead (`references/launch-and-executors.md`, *Optional modules*).

## Recommended hub rules

The plugin author's defaults, each paid for by an incident or a bill (the reasons: `references/launch-and-executors.md`).
Follow them unless `hub-rules.md` says otherwise: a rule there replaces the one below on the same subject and adds
anything new (`<plugin-root>/templates/hub-rules-example.md`). Read `hub-rules.md` from every layer — hub home, then the
repository, then the stage directory, a later file winning — and `HUB-NOTES.md` before planning at all.

1. **Agents stay silent between events.** An executor writes to the hub only `DONE`, `BLOCKED`, `STOP`, `MERGED` or a
   `QUESTION`: the status word, the report path and one sentence; the full report is `work/<tag>-REPORT.md`.
2. **A wake-up with nothing new is a turn of "no action"**, without analysis.
3. **Work that commits or pushes, waits on something external, touches production or must be reachable by others is a
   headless agent.**
4. **A change to a production script is written by an executor and reviewed; the hub does not write it.**
5. **A review of one artifact runs at most 3 rounds.** After that only blockers with a concrete failure scenario are
   accepted; the hub decides and records `ask decided`.
6. **Write the handoff at a context size fixed in advance — about a third of the model's context window** (~350k tokens
   on a 1M window, ~70k on 200k). Put your number in `hub-rules.md` if it differs.
7. **Evidence before claims.** Look a fact about data or systems up (a query, a command, a sub-agent with the schema in
   its brief) before stating it. A negative result counts only with a positive control on the same query.
8. **Money and anything that leaves the team go to the owner** as `ask add` with a default action — unless a standing
   permission in the owner's own words names them (`ask allow --list`).
9. **Agree the business result before you brief** (*Planning a stage*).
10. **A change gets the review its class says** (`hub reviewer --for <class>`): `docs` — documentation, or tooling and
    configuration whose own positive and negative controls ran and are shown in the PR — gets no model review; `code`
    gets one review; `risky` (money, migrations, production, permissions) the same single review, its brief narrowed
    to that risk, not a second reviewer.
11. **The reviewer is a different model from the author.**
12. **A question's due time is no reason to hold ready work while the owner is reachable, and never invent a gate the
    owner did not set.** Before asking about a merge, deploy or release, check `ask allow --list --stage <S>`: a
    permission in force whose words cover the case is the answer.

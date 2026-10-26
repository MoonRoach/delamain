# Launching work, reviews, executors, locks, configuration, rules

Read this when the four rows of *Choosing how to launch work* in `SKILL.md` do not settle a launch, when you need a
review, spawn or steer an executor, choose a model or worktree, take a lock, configure a project, run a night queue or
watch agents. The full text moved from the hub skill follows; the Codex-only model and CLI checks are in
[codex-hub.md](codex-hub.md#engine-models-and-hook-trust).

## Choosing how to launch work, in full

Decide from what is visible before the start — what the work does and who must reach it. The first "yes" decides
(table, modes and the experiments behind them: `<plugin-root>/docs/launch-modes.md`). Estimated duration is a
hint, never the criterion: a hub cannot estimate task time reliably. The owner is not asked which launch to use. When
no row applies — a small change with nothing to wait on and nobody else to reach it — the hub may write it itself: one
line with the reason, and `ask decided` (*Planning a stage* in `SKILL.md`).

1. **A review** → `hub reviewer --for <class>`, then start what it prints (*Reviews*, below).
2. **The owner should talk to it** → an interactive session in their chosen host. Claude additionally supports
   `claude --bg`; Codex detached workers are reached through `agent send` or a separate CLI resume after they stop.
3. **It commits or pushes, waits on CI, a deploy or another party, touches production, or must be reachable by
   someone other than this hub** → `agent spawn`. Always so when the hub is near its handoff threshold.
4. **Read-only, the answer is a short digest, nothing external to wait on** (read a log, check a fact, probe an
   environment, summarise a file) → a sub-agent: **foreground** when the hub has nothing else to do until the answer,
   otherwise **background** (through the host's native subagent API).

- An in-session sub-agent depends on the host's session lifecycle; its native follow-up API is for that session.
  Use a detached executor when a successor must reach or resume it. In Claude, compaction preserves the sub-agent. Ask it for a short result (≤ 20 lines,
  details in a file): its completion notice and result land in your context.
- **Every sub-agent brief ends with a call budget:** "if not done after N tool calls, stop and return a partial result
  and what is left". Recommended N: 40 for a probe or a read, up to 80 for a wide read-only investigation; it is a
  recommendation, set yours in `hub-rules.md`. *Why:* nobody watches a sub-agent; without a bound a confused one runs
  until its context is full, and the hub pays for it.
- **`hub handoff` refuses while a sub-agent of your session still runs** (exit 2; it lists id, description and age).
  Three ways out, per sub-agent: wait for it (its notice is minutes away); stop it and re-launch the rest with
  `agent spawn`, with its brief and the partial result; or record it as lost — `hub handoff --allow-live-subagents`
  writes the list into the draft's TODO section.
- Its shell inherits your `HUB_TAG`: if it journals, one final line `jlog --tag hub-<N>/<name> "DONE <path>"` (your
  `jwait` ignores your sub-tags; the notice wakes you). An executor's sub-agents do not journal — its `DONE` reports
  for them, and any `DONE` line wakes the hub.
- A headless agent may use native sub-agents. For Claude, `agent spawn` lifts its 10-minute wait ceiling
  (`AGENT_HUB_BG_WAIT_CEILING_MS`); Codex uses its own native subagent lifecycle. `agent-top` lists the sub-agents of registered sessions as `<role>/<id>`, read-only.

## Reviews

For Sol-authored code, choose a judgement reviewer: Claude Opus/Fable at high effort when its limits allow,
otherwise an available Codex Astra at high. A different or older Sol is not the default reviewer for Sol.
Reviewer engine choice is separate from the implementation engine; this review policy can select Claude for a
Codex implementation. Check the chosen engine's available models and limits before launch, record the reviewer
choice in stage rules and its brief, and honour the owner's explicit reviewer policy. For a Claude author,
use its configured independent Fable or Codex reviewer. One reviewer is the default.
The hub writes the review brief and launches the reviewer itself; the author of the change does neither (an author
briefing its own reviewer steers it to what the author already checked). For money, masking and permissions the brief
is narrowed to that risk (the template's "Look hardest at") and leaves style out.

`hub reviewer --for <class> --author <role>` walks the configured reviewers (`AGENT_HUB_REVIEWERS`, default one ordinary `agent
spawn`) and prints the first that is available now and exactly how to start it: an `agent spawn --role review-… --brief
<BRIEF>` line, or "load skill `<skill>`" for a reviewer skill the user plugged in. **Always pass `--author`**: the
role of the agent that wrote the change (its engine and model come from its `meta.json`), or `codex/<model>` /
`claude/<model>` for work done elsewhere. Without it the reviewer is chosen as if the hub's own host engine wrote the
change — a Claude hub then gives a Codex-written change a Codex reviewer — and the command says so on stderr. Write the brief from
`<plugin-root>/templates/brief-review.md`, start the reviewer as printed, and **verify each finding against the
code** before acting on it — a review is a colleague's opinion. Classes, the config, the skill reviewer contract:
`<plugin-root>/docs/reviewers.md`.
For a Codex reviewer use the printed `--sandbox workspace-write` with `--cwd` in the stage's `coordinator/work`
under the hub home (create it first); without a stage fill `<HUB_WORK>` with a directory there. Put the absolute
repository path, base and head in the brief for reading. Keep the repository outside the hub home and reviewer cwd,
and never add it as a writable root. A review role receives only its cwd, with temporary-directory writes excluded;
home config and other agents' inboxes remain read-only: report and journal writes work, repository writes are denied. `read-only`
cannot write the report or journal and a Codex review role/tag launched that way gets one warning at spawn.
Claude reviewers keep their repository cwd and must follow the brief's prohibition on repository edits.

**A second opinion** is optional and the hub's call, never a requirement of a class. When a miss would be costly (money,
migrations, permissions, masking) and the other reviewer's quota allows, `hub reviewer --second --for <class> --author
<role>` prints the first available entry other than the primary one: usually an entry marked `"second": true`, such as the
bundled `delamain:agy-review` (Gemini 4 Argon through Antigravity CLI; 6–13 % of a Pro week's Argon quota per review).
Start it beside the primary review with its own role or run name and verify its findings the same way. Exit 1 only means
there is no second opinion: the primary review stands.

Configure the list in this order with availability checks for limited reviewers; if a legacy entry selects a
Sol reviewer for Sol-authored work, bring that entry into line with the approved policy before using its command.

## Executors, in full

- **Per-launch quota choice.** Read [limit pace](../../../docs/reference.md#limit-pace) before choosing this launch's
  engine, model and effort. Compare fresh remaining weekly percentages; propose an equivalent class when the other
  engine has more room and the requested one is short. For an engine lock, ask whether to allow the other engine
  for this launch; default to running the locked engine. Apply the reference's quota refusal rules, keep model
  changes explicit and keep ready work moving; forecast and five-hour context do not schedule work after reset.
- Work that commits, pushes or waits (a merge steward, a rehearsal, a CI wait — see "Choosing how to launch work") is
  a headless agent, not an in-session sub-agent:
  `agent spawn --engine claude|codex --role R --cwd DIR [--model MODEL] [--effort high] --brief FILE [--worktree [BRANCH]]`.
  It survives the hub's handoff and any hub can talk to it. The executor's tag is `hub-<N>-<role>` (a sub-tag
  `hub-<N>/…` would be filtered out of your own `jwait`; `agent spawn` refuses it). A run that ends abnormally leaves
  `EXIT <role>: …` in the journal under its tag; one that ends normally without a status word of its own, `ENDED <role>: …`
  (`REVIEWED <role>: …` for a review role) — the agent stopped, nothing is wrong.
  `agent status [R]` — alive or not, the engine and model it runs on (`codex/<model>`, `claude/<model>`), age of the
  last event, turns (the last run's next to the total after a resume), the last line it said, its worktree.
  `agent send R "…"` — alive: into its inbox and the journal; process gone: the session resumes with this message and
  replays the unread inbox. `agent stop R` — stop it and retire the role. An agent's question arrives as
  `@hub QUESTION …`; answer with `agent send`.
- **Background processes.** An executor lists the processes it started in the background (servers, watchers) in its
  report and stops them before `DONE`. At handoff the hub checks for listening ports left by the project
  (`lsof -iTCP -sTCP:LISTEN`) and stops what the project started and nobody needs.
- **Worktrees.** Two agents writing in one checkout overwrite each other's files. Give every agent that writes code
  `--worktree [BRANCH]` (default branch `agent/<role>`): it runs in an existing worktree of that branch, or in
  `<repo>/.worktrees/<branch>` of the main repository — one place per repository, excluded in `.git/info/exclude`.
  A new branch starts from origin's default branch (fetched first), not from the commit `--cwd` has checked out — which
  may be someone's feature branch; `--base REF` chooses another start (`--base HEAD` for the checked-out commit).
  `agent spawn --worktree` refuses a repository with no commits: in a new, empty one the hub makes the first commit
  itself and says so in one line.
  Nothing removes a worktree by itself; at handoff `agent worktrees` lists them all (who made each, in use, dirty,
  pushed, merged) and `agent worktrees --prune --dry-run` shows the finished ones, which `--prune` then removes (never
  one with unpushed or uncommitted work, or in use).
- Model and effort: choose per agent. Claude supports `opus|sonnet|haiku|fable` aliases and optional
  `AGENT_HUB_MODEL_MAP` pins. Codex supports available model ids and optional `AGENT_HUB_CODEX_MODEL_MAP` aliases;
  omit the model to use `AGENT_HUB_CODEX_DEFAULT_MODEL` or the CLI configuration. Choose effort supported by that model. Every Claude alias takes `--effort`, `haiku` included (Haiku 5.5 from Claude
  Code 2.1.296 has the setting; Haiku 4.5 ignores the flag).

  Codex model and CLI checks before the first detached launch: [codex-hub.md](codex-hub.md#engine-models-and-hook-trust).

  `AGENT_HUB_PERMISSION_MODE=bypassPermissions` is the headless default: Claude uses its bypass mode, Codex uses
  `--dangerously-bypass-approvals-and-sandbox`. For a Codex reviewer, use `--sandbox workspace-write` and cwd under the hub home, as in *Reviews* above.
  Codex hook trust is separate: see `docs/codex.md`; read the returned errors when a restricted operation fails.
- **MCP servers.** A Claude executor loads no MCP server by default (`AGENT_HUB_SPAWN_MCP`, default `none`): every
  server's tool list sits in each turn's context and adds startup time. Decide per task when writing the brief ("Tools"
  line of the template): a task that needs a browser check, a docs lookup or another MCP server (a GitLab or DB server)
  is launched with `--mcp inherit` (the user's servers, plugins and connectors) or `--mcp FILE[,FILE]` (only the servers
  of those MCP config files); any other task gets nothing. A repository whose agents always need them sets `inherit`
  in its `.agent-hub/config.json`. The start line in the journal and `--dry-run` name `MCP inherit` / `MCP only <files>`
  when the default was overridden and say nothing for `none`. A resume keeps the launch choice; the hub's own headless
  successor (autopilot) always inherits. Codex has no equivalent switch.
- A brief follows `<plugin-root>/templates/brief-executor-template.md` (short); the advanced one,
  `brief-executor-advanced.md`, adds production permissions, size limits and evidence rules for teams that need them.
  The hub fills "Owner decisions — do not reopen" from `ask search <topic words>`. When an executor's result disagrees
  with a recorded decision, the hub checks that section before asking the owner.

## Locks

A lock is on a named resource. `main-merge` is built in: merges into, and pushes to, the protected branches are
refused to everyone but its holder. Every other resource — a deploy window, a staging environment, a migration head,
a shared test database — is named by the project in `lock-rules.json` (`<repo>/.agent-hub/` or the hub home), with
the commands that touch it. `lock rules` lists what applies where you are; `lock take <resource> --until … --why …`
refuses a name nobody configured and prints the known ones; `lock rules check "<command>"` shows which lock would
refuse a command. To set the resources up, use the `delamain:setup` skill.

## Project configuration

A repository can carry its own hub conventions in `<repo>/.agent-hub/` (the hub home and `<hub home>/<stage>/` hold
the same files): `config.json` (defaults: model map, effort, permission mode, the lock repo, the reviewers), `lock-rules.json`
(shared resources and their commands), `brief-footer.md` (appended to every brief of an agent spawned with `--cwd` in
that repository), `handoff-facts.sh` (the § 1 rows of `hub handoff`), `takeover.sh` (an extra verified step of
`hub takeover`), `hub-rules.md` (overrides of the recommended rules in `SKILL.md`) and `HUB-NOTES.md` (the team's knowledge).
Read `hub-rules.md` from every layer — hub home, then the repository, then the stage directory; a later file wins on
the same subject — and `HUB-NOTES.md` before planning at all.

## Recommended hub rules, in full

The fuller statement of the twelve rules, with their reasons; `SKILL.md` carries them in short form.

These are the defaults of the plugin's author, each paid for by an incident or a bill. Follow them unless
`hub-rules.md` says otherwise; a rule there replaces the one below on the same subject and adds anything new
(example: `<plugin-root>/templates/hub-rules-example.md`).

1. **Agents stay silent between events.** An executor writes to the hub only `DONE` (finished), `BLOCKED` (cannot go
   on), `STOP` (its brief's stop condition hit), `MERGED` (a merge steward merged a PR) or a `QUESTION`: the status
   word, the report path and one sentence; the full report is `work/<tag>-REPORT.md`. *Why:* every line wakes the hub,
   and every wake-up re-reads the hub's whole context.
2. **A wake-up with nothing new is a turn of "no action"**, without analysis. *Why:* the same — a hub that thinks
   aloud on every wake-up spends its context on nothing.
3. **Work that commits or pushes, waits on something external, touches production or must be reachable by others is a
   headless agent.** *Why:* an in-session sub-agent belongs to its parent session — another session cannot address it
   and it does not carry over to the next hub; a headless one has its own session id, keeps working through a handoff
   and any hub can message it.
4. **A change to a production script is written by an executor and reviewed; the hub does not write it.** *Why:* the
   hub's context is the stage's memory; spending it on code costs the plan, and a hub reviewing its own code is not a
   review.
5. **A review of one artifact runs at most 3 rounds.** After that only blockers with a concrete failure scenario are
   accepted; the hub decides and records `ask decided`. *Why:* later rounds find style, not bugs, and each costs a
   full read.
6. **Write the handoff at a context size fixed in advance — about a third of the model's context window** (~350k
   tokens on a 1M-token window, ~70k on 200k), not when the context is nearly spent. *Why:* the handoff itself and the
   last turns need room, and quality drops well before the window is full. Put your number in `hub-rules.md` if it
   differs.
7. **Evidence before claims.** Before stating a fact about data or systems, look it up (a query, a command, a
   sub-agent with the schema in its brief). A negative result counts only with a positive control on the same query.
   *Why:* a search that cannot find anything reads exactly like "there is none".
8. **Money and anything that leaves the team go to the owner** as `ask add` with a default action, not as the hub's
   decision — unless a standing permission in the owner's own words names them (`ask allow --list`). *Why:* they are the decisions that cannot be undone by the next commit.
9. **Agree the business result before you brief** (*Planning a stage* in `SKILL.md`). *Why:* a silent assumption about the result produces
   confident work on the wrong problem; details the owner left open belong to the hub.
10. **A change gets the review its class says** (`hub reviewer --for <class>`): `docs` — documentation, or tooling and
    configuration whose own positive and negative controls ran and are shown in the PR — gets no model review; `code`
    and `risky` (money, migrations, production, permissions) get one review by default, a `risky` brief narrowed to that
    risk. When a miss would be costly and the quota allows, the hub **may** add one second opinion from another vendor
    (`hub reviewer --second`, *Reviews* above): its decision, never a default. *Why:* a review costs a full read of the
    diff and its context, and a second reviewer of the same vendor on the same risk mostly finds the same thing twice; a
    narrower brief gets more out of one reader. Another vendor misses other things: in a trial on two real merge requests
    Google's Argon and Codex found about as many real defects, and different ones.
11. **The reviewer is a different model from the author.** *Why:* a reader of the author's own model reads the code
    the way it was written and returns a confident summary, which reads like agreement.
12. **A question's due time is no reason to hold ready work while the owner is reachable, and never invent a gate the
    owner did not set** ("after 10:00", "after the owner looks"). Before asking about a merge, deploy or release, check
    `ask allow --list --stage <S>`: a permission in force whose words cover the case is the answer. *Why:* finished work waited overnight for a
    per-item "ok" the owner had already given, and for a time nobody had named.

## Waiting for CI, a merge or a lock (`await`)

Added with the CI-wait tool; the core `SKILL.md` carries the short form.

1. A CI, merge or lock wait is never a background Bash of the hub itself: run it as
   `await --ok MERGED --label "MR !N" --on 2=TIMEOUT -- python -m scripts.ci_wait --mr N` (an ordinary foreground
   call; it returns at once). The hub keeps its single `jwait`.
2. `await` journals nothing while the command runs and exactly one line `@hub MERGED|DONE|FAILED|TIMEOUT|<--on word> …
   <link>` when it ends; that line is the hub's wake. FAILED/TIMEOUT/CONFLICT are decisions for the hub, not retries.
3. An executor that waits on CI uses the same `await` (its line is `<tag>-await`, so it reaches the hub's `jwait`). A
   headless one adds `--wait`, which prints the line and exits 0 only when the command itself succeeded, 3 otherwise
   (FAILED/TIMEOUT/…): trust that exit code or the word, not "it returned". On GitHub the command is
   `gh pr checks N --watch --fail-fast` (see *Waiting for CI* in `docs/launch-modes.md`).
4. `kill <supervisor pid>` (printed by `await`) stops a wait; a missing line after the deadline means the supervisor was
   SIGKILLed — read the log path from the start message.

## Optional modules

- **Night queue** (`<stage>/night-queue.md`, `nightq`, `templates/night-queue-template.md`): work allowed while the
  owner is away, with a permission matrix; open items inside `AGENT_HUB_NIGHT` count as waiting work for the watchdog,
  which wakes a silent hub that can be woken (otherwise it notifies the owner). The queue files work with either engine;
  the Claude Desktop scheduled task `templates/night-nudge-task.md` is deprecated in favour of the watchdog.
  Codex autopilot selects the desktop request or detached CLI surface as described in [autopilot.md](autopilot.md).
- **Send budget** (`roles sent|budget|reset`, `AGENT_HUB_SEND_CAP`): Claude Desktop pauses a session's outgoing
  cross-session messages after 10 sends without the user typing in it. After every send — `roles sent <from> <to>`;
  at budget 0 write `jlog "@<tag> …"` instead. Terminal sessions do not need it.

## Watching agents

`agent-top` is a live console (curses) of every agent: state, current action, last words, unread inbox, locks, owner
questions and plan limits; `agent-top --once` prints the same picture as text; `agent-top --json` is for scripts. In Claude Code (2.1.287 or
later) the person types `/agent-top` for a live read-only side pane. Where mods do not draw (Codex, VS Code chat,
`claude -p`, Remote Control views) there is no `/agent-top`: use the console in a shell.

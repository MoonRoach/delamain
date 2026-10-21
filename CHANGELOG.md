# Changelog

## Unreleased

- **A bundled reviewer skill: Gemini 4 Argon through Antigravity CLI.** `delamain:agy-review` and `bin/agy-review`
  run a read-only review with Google's `agy` as a third vendor beside Claude and Codex, plugged in as a reviewer skill
  (not as an `agent spawn` engine). `agy-review run --cwd <checkout> --brief <file>` starts the review detached and prints
  `run: <dir>` under `<hub home>/agy-runs/`; the directory holds the brief, agy's JSON per attempt, `final.md`,
  `usage.json` and, written last, `rc` (`0` review produced, `2` no answer after two resumes, else agy's exit code).
  With a stage it journals a start line and `REVIEWED <run>/final.md — rc 0`. The review runs under its own HOME
  (`<hub home>/agy-review-home`), whose `settings.json` is rewritten on every run: only commands that cannot start another
  program are allowed, writes, the web, MCP, shells, interpreters, network clients and every program launcher (`awk`,
  `find`, `sed`, `rg`, `sort`, `xargs`, `git grep`, pagers) are denied, and `agy` runs with `--sandbox`, which leaves the
  network open (never `--dangerously-skip-permissions`); the owner's own `~/.gemini/antigravity-cli/settings.json` is not
  touched. A stop (SIGTERM) ends agy's whole process group, with SIGKILL after ten seconds, and still writes the `rc`.
  A headless run that ends without an answer is resumed, at most twice. `agy-review limits` reads the quota from agy's
  `/usage` panel through a pty, and `agy-review check` is the availability test for a reviewer entry (agy installed,
  Argon's weekly quota not known to be below 20 %). New hub-wide settings `AGENT_HUB_AGY_BIN`,
  `AGENT_HUB_AGY_REVIEW_MODEL` and `AGENT_HUB_AGY_REVIEW_MIN_LEFT`. A ready config entry and the design are in
  [docs/reviewers.md](docs/reviewers.md#the-bundled-argon-reviewer-agy-review). Verified on macOS with agy 1.4.0; Linux is
  untested. Tests use a stand-in `agy` (`tests/fake_agy.py`).

- **An optional second opinion from another vendor: `hub reviewer --second`.** The rule "a `risky` change gets the same
  single review, not a second reviewer" is now "one review by default; the hub may add one second opinion from a
  different vendor when a miss would be costly and the quota allows", its decision and never required for a class. In a
  trial on two real merge requests, Argon and a Codex reviewer found about as many real defects and mostly different
  ones. A reviewer entry may carry `"second": true` (a boolean; anything else is rejected): it serves second opinions
  only, and a plain `hub reviewer` walk passes over it without running its `check`. `hub reviewer --second` chooses the
  primary reviewer exactly as before, then prints the first other available entry in list order, ordinary or `second`;
  `--json` adds `second` and `primary`; exit 1 means only that there is no second opinion. Output, exit codes and JSON of
  the plain walk are unchanged for existing configs. The hub skill's rule 10 and
  [docs/reviewers.md](docs/reviewers.md#a-second-opinion) carry the new rule.

- **`agent-top` shows the stages of every hub home on the machine, backed by a registry of homes.** A stage in a
  per-project home (`.agent-hub/config.json` `"AGENT_HUB_HOME": "project"`, i.e. `<main checkout>/.agent-hub/local/`) never
  appeared in the shared `agent-top`, which listed the resolved home only, though its agents run on the same machine. A
  project home lives inside an arbitrary repository, so it cannot be found by scanning: the tools now record a home in
  `${XDG_CONFIG_HOME:-~/.config}/delamain/homes.json` when a stage is registered in it (`roles_save`, `agent spawn`:
  `roles set`, `hub start`, `hub takeover`, …; atomic, under a lock, at most once a day per home, a missing home dropped on
  the next write). `agent-top`, `--once`, `--json`, `--widget` and the pane list the stages of the resolved home,
  `~/agent-hub`, the legacy home, `$AGENT_HUB_HOME` and the registered homes that exist (`hubcore.known_homes()`), each with
  its own cache; while stages come from more than one home a stage outside `~/agent-hub` is `stage · <repo>`, and two
  stages of one name in two homes are two entries. `--json` keeps every field and adds `home`, `home_label`, `name` and
  `stage_name` to the stage and agent records and the top-level `homes` and `multi_home`; with one home the text and
  widget output are byte-identical to before. The console's `c` / `m` / `x` and the pane's `close` act on the selected
  stage in its own home. `tell`, `agent`, `hub` still address the resolved home only, but a "no such stage" error now adds
  *stage S exists in home <path>; run from that project or set `AGENT_HUB_HOME=<path>`*, and the refusal for a stage that
  lives in `~/agent-hub` or the legacy home is unchanged. A registry that cannot be read or written never fails a tool.
  A stage is identified by its home and own name, never by the `stage · label` shown (which depends on how many homes have
  stages): the console's stop/send/close, the pane's `close` and a card are bound to that pair when armed, so another home
  gaining a stage of the same name cannot redirect a pending confirmation. `--stage` takes `NAME` (every home),
  `NAME@label` or `NAME@/path` (one home), also in `/agent-top`, whose filter keeps `alpha · repo` for `--stage alpha`. A
  child tool's registration (its pinned `AGENT_HUB_HOME` reads as `env`) never downgrades a project entry. The limit-pace
  advice reads a stage's settings in its home and the logs of every home. The Locks list reads the board of every home
  whose stages are shown (a lock of another home carries its label). `/agent-top --stage "alpha@my repo"` accepts quotes;
  a label or path may hold `@` or spaces (the name ends at the first `@` or ` · `), and the pane normalises a path selector
  like the CLI. Tests never touch the real HOME, registry or any inherited `AGENT_HUB_*` directory
  (`tests/isolate.sh`, checked by `t_test_isolation.sh`).
  Found by @Cartograf666 in #76.

## 1.0.13 — 2026-10-15

- **Agents start Claude Desktop's own CLI again on Desktop 2.1.29x.** Desktop now keeps its bundled CLI one level
  deeper, under `claude-code/<version>/<build hash>/claude.app`; the lookup read only `claude-code/<version>/claude.app`,
  found nothing and started an older `claude` from PATH instead. A user's worker died on it: Homebrew's 2.1.231 answered
  400 to Opus 5.5, and agent-top showed the error. Both layouts are searched now; the version still comes from the
  directory under `claude-code`.

- **Codex worktree sandboxes grant only the current branch's leaf refs, including nested names.** Sibling branches
  and reflogs are no longer writable through a shared namespace; pruned parent directories fail closed. Git root
  discovery ignores inherited `GIT_*` selectors. Spawn/resume restores pruned leaf parents outside the sandbox;
  the child disables automatic Git maintenance using Git's quoted parameters, compatible with Codex's default
  secret-name environment exclusions. The review brief directs Codex
  temporary copies into its cwd. Existing executors retain their pinned roots: respawn them to apply narrower grants.

- **Limit pace finds older Claude readings, and tests clean their temporary directories.** Claude logs are searched
  backwards in 256 KB chunks up to 8 MiB, so a long tool-result tail no longer hides the latest limit event.
  Parser upgrades invalidate cached readings even for unchanged logs. Standalone tests and the suite harness own
  and remove their temporary files and directories, including on failure.

- **The kill guard catches redirected name lookups and shell kills through `xargs`.** Process substitutions feeding
  `xargs kill` or a `while read` loop, and `pgrep | xargs … sh -c "kill …"`, now receive the same refusal as other
  bulk kills. Desktop's session-card hook and the registry share one session identity matcher, including verified
  Desktop CLI restarts.

- **`hub grill open` can start from an untrusted hub home.** After Claude explicitly refuses workspace trust,
  it tries only the hub's registered worktree, then the project's main checkout. If all refuse trust, the error
  lists every attempted directory and recommends trusting the hub's worktree (or main checkout if none is registered).
  A trusted calling directory stays unchanged; trust records are never modified, and an uncertain launch is never retried.

- **`agent status` shows the engine of each agent.** The line now reads `role [tag] <engine>/<model>: …`
  (`codex/gpt-6.1-sol`, `claude/claude-sonnet-5-5 (asked for sonnet)`), for both engines; a coordinator no longer
  needs `agent-top --json` to confirm that a worker runs on Codex. Nothing else in the line changed. Found by
  @Cartograf666 in #76.

- **`run-python` usage errors no longer block hooks.** A bad `--min-version` value or a missing script exited 2,
  which Claude and Codex hooks treat as "block", so a manifest typo would have blocked every tool call. Both now exit 1
  and fail open. Docs note that a detached `agent` loses its exit journal line if its launch interpreter is removed
  mid-run, while the worker's exit code is still propagated.

## 1.0.12 — 2026-10-15

- **The lock hook no longer stalls on long heredoc-like input with no closing delimiter.** `board_locks` now uses
  the shared `polling_guard.strip_heredocs` scanner instead of the regex that repeatedly scanned blank lines. It
  still treats all closed heredoc bodies as data, including those fed to a shell; ordinary lock decisions are unchanged.

## 1.0.11 — 2026-10-15

- **A walk of the home directory or `/` is refused: it raised the macOS "access data from other apps" prompt.** On 15.10
  the owner got «"claude.app" would like to access data from other apps» five times between 10:00 and 11:03; one cause
  was `find ~ -name hive1.py …` in a background session (Claude Code's shell shows `find` as `bfs`). A walk from `~`
  enters `~/Library` (Mail, Messages, Safari, Containers), which App Data TCC protects, and the consent is not kept
  across agent processes, so the prompt returns. Full Disk Access would end it, but would let every agent that runs
  without questions read mail, messages and cookies. The new PreToolUse hook `scan_guard.py` (Claude and Codex, on for
  all sessions) denies `find`, `bfs`, `fd`, `rg`, `grep -r`, `ag`, `ack`, `du`, `tree` and `ls -R` whose root is `~`,
  `$HOME`, the absolute home path, `/`, `/Users`, `~/Library`, `~/Library/Containers`, `~/Library/Group Containers` or a
  glob over them, and the same with no root while the working directory is the home (the session's, or after `cd ~`);
  likewise the Grep and Glob tools with such a `path`. A named subdirectory, the hub home, a walk that stays on the
  first level and what `ssh`, `docker exec` or `kubectl exec` runs elsewhere are not touched. The refusal says to search the project, `$AGENT_HUB_HOME` or a subdirectory, and names
  `# scan-ok`, the marker for a walk the owner asked for. `AGENT_HUB_SCAN_GUARD=off` (environment or hub home) turns it
  off; a hook error fails open. Not caught: scripts (`python3 -c`), `cp -r`, `rsync`, `tar` and other tools that walk a
  tree on the side. `polling_guard.views` gained an optional `data` list for hooks that read a command's arguments.
  `tests/t_scan_guard.sh` holds both lists, the Grep and Glob cases, the marker, the switch and fail-open.

- **A heredoc opener with no terminator no longer holds `polling_guard` and `kill_guard` for 12 s and more.** Both read
  a command through a regex that looked for the closing delimiter line again from every blank line after the opener
  (50000 blank lines after a `<<EOF` that sits in quotes took 12 s; Claude Code 2.1.299 blocks the call when a hook
  misses its timeout, and the fail-safe's timer cannot interrupt a regex). The terminator is now found in one pass over
  the command's lines (`polling_guard.strip_heredocs`), also for a delimiter with a dash or a dot (`<<'END-NOTES'`),
  which the old pattern did not read at all.

- **Codex reviewers can write reports; sandboxed worktree executors can commit.** `hub reviewer` recommends
  `workspace-write` with cwd in the stage's `coordinator/work` under the hub home, and the repository path in the
  brief outside writable roots. Reviewers receive only their cwd, not home config or other agents' inboxes; wider
  roots are refused. A read-only review role/tag warns that it cannot write its report or journal.
  Linked worktree executors receive individual Git commit/merge state files, their logs, shared objects and their own
  branch refs/reflogs (a namespace directory for nested branches, or the shared reftable store), pinned on spawn and
  reused on resume. The private gitdir, commondir/config.worktree and packed-refs are not granted. The review docs, skill and brief
  template describe the same boundary; macOS sandbox probes cover report/journal writes and Git operations.
  Rebase state roots are excluded: sandboxed worktree rebase is unsupported and can move HEAD before failing with
  `--apply`. Spawn and the worker brief warn about this; use a merge commit from the prepared base ref instead.

- **`hub reviewer --author` chooses the reviewer by who wrote the change, not by the hub's host.** `--author` takes a
  role of the stage (engine and model are read from the agent's `meta.json`) or `claude|codex[/model]`. Every
  reviewer `check` gets `AGENT_HUB_REVIEW_AUTHOR_ENGINE` and `AGENT_HUB_REVIEW_AUTHOR_MODEL` (removed from its
  environment when the author is unknown), and the built-in default reviewer takes the engine other than the author's.
  Without `--author` the host engine is assumed and the command says so, on stderr and in `--json`
  (`author: null`, `assumed_author_engine`). Before, a Claude hub gave a Codex-written change a Codex reviewer, and a
  Codex hub, which has no fresh Claude limit observation, gave it Codex Astra. The hub skill's *Reviews* tells the hub to
  pass `--author`. See [Reviewers](docs/reviewers.md#the-author-of-the-change).

- **Limit-pace advice chooses the engine, model and effort for this launch.** Fresh remaining weekly percentages
  replace projected pace as the room comparison: below 20% remaining prompts an equivalent-class alternative with
  more room; when both are short, prefer the larger remainder and warn it may run out before reset. At least 3%
  remaining allows a launch even with an exhaustion forecast. Below 3% refuses only with fresh verified data on the
  other engine; both below 3% refuse unless `--reason` is supplied. Unknown/stale data never grounds refusal. Engine
  locks get a permission question for this launch, defaulting to the locked engine; models are never swapped silently.
  Below 3% with an unverified alternative, advice warns of practical exhaustion and offers a probe or `--reason`,
  without creating a quota gate. Forecasts from the first 6 hours are displayed without journal alarms, owner
  notifications or crossing-state records; five-hour windows remain context.
  Advice no longer defers or sequences work until reset. See [Limit pace](docs/reference.md#limit-pace).

- **A headless Claude executor starts without MCP servers by default.** `AGENT_HUB_SPAWN_MCP` now defaults to
  `none` (it was `inherit`): an agent started by `agent spawn` no longer carries the tool lists, instructions and
  authentication notes of every server in your config, plugins and claude.ai connectors in each turn (about 3.5k tokens
  and a second of startup). The hub gives a launch servers only when the task needs them — a browser check, a docs
  lookup, a GitLab or DB server: `--mcp inherit` or `--mcp FILE[,FILE]`; the hub skill, its launch reference and the
  executor brief template (a "Tools" line) say so, and `setup` question 10 asks whether the project's agents need
  servers. The journal's `started headless agent …` line and `--dry-run` name `MCP inherit` / `MCP only <files>` and
  stay silent for `none`. **Behaviour change:** to get the old behaviour back, set `"AGENT_HUB_SPAWN_MCP": "inherit"`
  in the hub home's `config.json` (or a repository's `.agent-hub/config.json`), or pass `--mcp inherit`. A resumed
  agent keeps the choice of its launch, the headless hub successor still inherits, Codex has no equivalent switch.

## 1.0.10 — 2026-10-15

- **Grilling over open questions runs in a session of its own (1.0.10).** When the owner asks a hub to grill them over
  the stage's open questions, the hub no longer grills in its own context, where a long grilling filled it and pushed
  the hub into a handoff mid-conversation. `hub grill --stage S` writes a brief over the stage's unresolved owner
  questions (other stages only when the owner names them) and launches a separate interactive session: in Claude
  Desktop it prints `start_session` arguments with `initiation: "user_asked"` for the hub to call in the owner's turn
  (the `session_cards` hook lets that through in a hub, and still refuses cards); in the Codex app `create_thread`
  arguments for the app agent; in a terminal or background Claude hub it starts `claude --bg --remote-control
  <S>-grill` itself and prints the link; in a terminal Codex hub the command for the owner. The session registers as
  role `grill` (`hub grill join`; visible in agent-top, reachable with `tell S --role grill`; one per stage), grills
  with the companion skill, records every answer in `ask` and ends with `hub grill done`: one journal line `@hub
  GRILLED <answered, withdrawn, open, new> — <summary>` counted from the register, then the role is retired. `GRILLED`
  is a wake word of `jwait --hub-events`; the hub acts on `ask list --pending`. A grilling about a new topic the owner
  raises in the hub still runs in the hub. The hub skill, its references and the grilling note of the prompt hook say so.
  Generated commands always carry the absolute hub home. All launches, including manual sessions confirmed by the owner, bind to the joining session's full
  identity (in either order); bg handles resolve to full sessionIds. Administrative registration needs a journaled
  reason; pending cancellation needs its launch id and a reason. Delegation clears the hub's grilling marker so its
  automatic handoff can proceed. Recovery of an uncertain bg launch clears only that launch's original grilling
  marker once it activates, preserving a newer grilling or successor.

## 1.0.9 — 2026-10-15

- **No automatic handoff in the middle of a grilling.** On 15.10 the autopilot handed a hub over while it was grilling
  the owner, and the successor lost the thread of questions and answers. A hub's grilling is now marked when the
  grilling skill loads (a Skill call in Claude Code, a read of its `SKILL.md` in Codex, a prompt invoking it;
  `AGENT_HUB_GRILLING_SKILL`, default `grill`) and by `hub grilling start`, and cleared by `hub grilling end`, a
  takeover, or `AGENT_HUB_GRILLING_STALE_MIN` (240) minutes without an owner prompt. While it holds, the context-budget
  message says to finish the grilling instead of handing over, the autopilot's Bash/Write/Edit gate stays open, and
  `hub succeed`/`hub handoff` refuse (exit 2) unless `--owner-asked`; a successor started before the grilling began does
  not take over automatically. At the context ceiling (`AGENT_HUB_GRILLING_CEILING`, 95% of a Codex window, else 900k)
  the hub writes the handoff with the grilling in its § 0 and asks the owner whether to hand over; the successor resumes
  the grilling. The owner's permission belongs to an accepted successor request and its handoff: a refused request
  grants nothing, and a different handoff cannot use it. The grilling ceiling also takes effect below warn/block.

- **`await` no longer loses its journal line on macOS when it stops the command.** `killpg` on a process group whose
  only members are zombies answers EPERM there (Linux: ESRCH); `await` caught only the second, so a timeout or a
  SIGTERM/SIGINT on the supervisor could end in a traceback (exit 1) and no `TIMEOUT`/`FAILED` line, in about 1% of
  stops. An EPERM is now not an error: the supervisor waits a grace period for the command's leader to exit, and if it
  does not (a signal the kernel refused, e.g. a process of another user), the line says `could not be stopped (EPERM)`
  instead of claiming the command was stopped, and the supervisor does not wait for ever. Any other crash of the
  supervisor's wait is a `FAILED … (await crashed: …)` line. A stop signal that lands between the command's start and
  the supervisor learning its pid is held and acted on instead of leaving the command running.

- **Headless agents can start without the MCP servers they never use.** A Claude agent loaded every server of the
  user's config, enabled plugins and claude.ai connectors; on the owner's machine (a dozen servers, eight of them
  unauthenticated) that is about 3,460 input tokens in every turn's context and about a second of startup per run,
  measured with two otherwise identical `claude -p` runs (37,470 vs 34,010 first-turn tokens). `agent spawn --mcp none`
  starts an agent with no MCP server, `--mcp FILE[,FILE]` with only the servers of those MCP config files, and
  `AGENT_HUB_SPAWN_MCP` (environment, hub home, or a repository's `config.json` for `inherit`/`none`) sets the default.
  The default stays `inherit`: an agent that relies on a GitLab or database server keeps it; the setup skill offers
  `none` (and keeps `inherit` under `--defaults`). `none` drops the project's own `.mcp.json` servers too: a repository
  whose agents need them sets `inherit` in its `.agent-hub/config.json`, which wins over a hub home's `none`. A resume keeps the spawn's choice, a headless autopilot successor inherits, and Codex, which has no switch
  for its plugins' servers, refuses the flag.

- **A kill by name or pattern is refused: it, not the host, killed four agents on 14.10.** Four headless agents and
  Claude Desktop got SIGTERM at 22:56 from one `pkill` run by a fifth agent: `pkill -f "[s]leep 300" -P 1`. macOS (BSD)
  `pkill` reads options only before the first pattern, so `-P` and `1` became two more patterns, and `1` matched
  nearly every process of the user (the unified log shows `sent by pkill[74672]` for widgets and iCloud Drive too); the
  agent that ran it survived because `pkill` skips its own ancestors. Spawning was already detached (own session and
  process group, stdio in files) and no detachment protects a pid from a signal sent to it. The new PreToolUse hook
  `kill_guard.py` (Claude and Codex) denies `pkill`, `killall`, `kill $(pgrep …)` and `pgrep … | xargs kill` and points
  at `kill <pid>`, `kill -- -<pgid>` and `agent stop`; `# kill-ok: <reason>` passes a deliberate one, but never a
  `pkill` with an option or a second pattern after the first. `AGENT_HUB_KILL_GUARD=off` turns it off.
  `tests/t_kill_guard.sh` also pins the detachment: an agent of either engine outlives SIGTERM and SIGHUP to its host's
  process group, the host alone, and the host's group killed while `agent spawn` still waits for the init event.
  The guard reads `pidof` and a `grep` of `ps` output as pid sources like `pgrep` (at any stage of a pipeline), the loop
  and variable forms in one command (`for p in $(pgrep …); do kill $p`, `pgrep … | while read p; do kill $p`,
  `P=$(pgrep …); kill $P`), `eval` and `killall5`; a single `&` separates statements (`pkill -x node &` is an ordinary
  overridable deny); a segment whose command word is `ssh` is not read.

- **Trusted WSL launch and bounded foreground cancellation.** Windows transport resolves
  the system WSL executable, including Sysnative for 32-bit PowerShell. A broken output
  pipeline cancels the owned Linux foreground group and bounds Windows-client cleanup;
  workers that detach into their own session survive.
- **Isolated, owner-bound foreground guardians.** Python ignores repository modules and
  inherited Python settings. Windows-owned temporary-file handles cancel foreground work
  when PowerShell dies, including after the command leader exits. Separate acknowledgement
  files prevent early startup failures from being reported as cleanup timeouts.
- **Configured Windows hub-home fallback.** A fresh repository uses the hub home selected
  during installation, preserving the shared lock board. Explicit environment, project
  and legacy selections retain priority.
- **Windows transport through WSL2.** Native Windows Codex uses a conditional plugin envelope;
  a terminal launcher remains a separate Linux coordinator mode. Argument/environment payloads
  travel in per-call files rather than the Windows command line, preserving large prompts,
  Unicode, stdin, streaming output and child exit status. Payloads may contain sensitive inputs;
  normal completion removes them, while forced termination can bypass cleanup.
- **One Windows proxy helper per Linux worker.** An explicit multiplex mode compiles the helper once,
  bounds connections and flow control, and preserves worker PID/stdin and exact-owned cleanup.
  The legacy raw helper interface remains compatible with existing workers. No global daemon,
  Windows listener or network configuration change is introduced.
  An owned WSL client now keeps the relay's interop stdio alive after the initiating Desktop
  bridge returns; a private Linux descriptor handoff preserves worker stdin/PID and cleanup.
- **Native pipeline guard parity.** Kill-guard escape scope retains actual Bash comments
  without promoting multiline data to comments, and executable stdin retains producer
  context across bridge stages. Native tests also verify the child receives normalized
  Windows system environment paths; owner-loss cleanup latency is documented as best effort.
- **Native Windows hook compatibility.** Recognized literal bridge calls retain independent cwd and
  native Windows role-profile paths. Variable/dynamic paths and other unsupported PowerShell forms
  remain outside exact-source coverage; the hooks are advisory rather than a general security boundary.
  Linux/macOS role-path defaults and shared skill/template/context policies remain unchanged.

## 1.0.8 — 2026-10-15

- **The successor of an automatic handoff starts in the hub's project.** The context-budget hook put the hook input's
  directory into the `hub succeed --cwd` it suggested, and that directory drifts with the hub's shell: a hub that had
  `cd`-ed into the hub home got a successor there, outside git, and when `claude --bg` refused the untrusted folder `hub
  succeed` quietly fell back to a headless hub that Claude Desktop does not list. `hub start`/`hub takeover` now record
  the hub's worktree in `roles.json`; `hub succeed` and the hook take it from there. A `--cwd` outside git, or in another
  repository than the stage's project, exits 2 and starts nothing (a `--no-project` stage excepted). The fall back to a
  headless hub is a `WARNING` in the output and the journal, with the reason and the `--replace --force` that restarts
  it as a visible session. A hub registered before this release has no recorded worktree: `hub succeed` then takes the
  project from `stage.json`, and `--fallback` never needs a directory. A headless successor that is the designed
  outcome (Codex, `--headless`) gets a neutral line, not the warning.

## 1.0.7 — 2026-10-15

- **A registered hub no longer turns executor work into Desktop session cards.** The hook `session_cards.py` refuses,
  in a session registered as a stage's `hub`, `start_session` with `initiation` `own_initiative` or `offer`,
  `hand_off_to_session` and `spawn_task`, and names `agent spawn`, `ask add` and `hub handoff` in the message; the owner's
  own `user_asked` and an accepted `proposal_id` pass, as does every non-hub session. Hubs also get one line saying the
  host's card rules are superseded.
- **Limit pace: how each engine's week is going, before the spend.** On 07.10 the Claude week ran out and cut off four
  agents mid-work; on 08.10 the Codex week went from 0 to 100 % in 11.5 hours; nothing compared spend with the
  window's pace, so hubs found out when agents died. `agent spawn`, the `hub start`/`takeover` digest and
  `agent-top --once` now show each engine's week against its pace (usage vs the elapsed share, the last 6 hours' burn
  and the window average, when it runs out) and advise in the owner's order: lower an effort above the task class's
  default, move to the other engine at an equivalent class (Opus ↔ Astra, Sonnet ↔ Sol medium, Haiku ↔ Luna), defer
  non-urgent work to the reset, then ask the owner. A stage locked to an engine (`AGENT_HUB_STAGE_ENGINES`) gets an
  `ask add` with the numbers, never a switch. `agent spawn` refuses only when the week runs out before its reset by
  every rate, half of it is used, the work is not mechanical and no engine with fresh data and headroom can take it
  (an unknown or stale other engine gets the advice and a ready `ask add`, not a refusal); `--reason`
  passes and is journalled. The watchdog (R6) writes one `@hub LIMIT …` line per crossing. New: `agent spawn
  --task-class`, `agent spawn --dry-run`, `AGENT_HUB_LIMIT_PACE`. See [Limit pace](docs/reference.md#limit-pace).

- **The hub skill is a 17 KB core plus references.** `skills/hub/SKILL.md` was 49 KB (about 17,700 tokens) that every
  hub loaded and re-read on every call, and about half of it was procedure for a Codex hub or for a situation that
  comes up once a shift. It is now a 17,409-byte core (about 6,700 tokens, measured by input tokens): first commands, starting
  and taking over, waiting (with `await` for CI, merge and lock waits), talking, planning, launch choice, executors, a
  short Claude Desktop host block and the twelve recommended rules. The rest sits in
  `skills/hub/references/` — `stage-lifecycle.md`, `autopilot.md`, `owner-and-planning.md`,
  `launch-and-executors.md`, `codex-hub.md` — moved word for word, each with a "read … when …" line in the core;
  a Codex hub reads `codex-hub.md` and `autopilot.md` at start. Pointers to *Terminal follow-through* (the handoff
  template and skill, the Codex successor briefs) name the new file. The tests that read the Autopilot paragraphs
  read `references/autopilot.md`, and `tests/t_hub_skill_layout.sh` holds the core's size budget and every pointer.
  `docs/proposals/hub-rules-slim.md` proposes the same cut for the owner's `hub-rules.md`.
- **Hooks stay safe on Claude Code 2.1.299.** From 2.1.299 a plugin hook that cannot hand back its answer (it crashes,
  runs past its `timeout`, prints half a JSON document) blocks the user's call instead of letting it through. All seven
  hook scripts now start with `hooks/failsafe.py`: stdout is delivered only if it is one complete JSON document, the
  exit status is always 0 (a missing or broken sibling module used to end in exit 1 for `context_budget`,
  `handoff_size` and `delegation`), and a timer answers "no decision" 1.5 s before the configured `timeout` (all hooks now have 10 s; `board_locks` and
  `polling_guard` had 5) and says so on stderr.
  `tests/t_hook_failsafe.sh` feeds every hook malformed input, breaks a module on purpose, stalls stdin, and checks the
  deadlines against `hooks.json` and `codex-hooks.json`.
- **`jwait` waits 50 minutes by default (was 55).** Claude Code compacts a 200K+ conversation left idle about 54 minutes;
  a 55-minute wait always ended after that point for a hub that did not set `"idleCompaction": false`. Hubs of
  `hub start`/`takeover`/`succeed` already get the setting or the warning (1.0.5); `setup` now offers the setting too, and
  detached `agent spawn`/`agent send` workers get `CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS=100000000` unless the caller sets
  it. `AGENT_HUB_JWAIT_FOR` still overrides the default.
- **A hub in Claude Desktop is told the handoff threshold must come first.** Desktop runs its own bundled Claude Code
  (2.1.295 against the terminal's 2.1.299 on 14.10), and nothing documented or observable says whether that session reads
  `"idleCompaction": false`. `hub start`/`takeover` of a Desktop hub now say so and name the context budget's warn
  threshold against the 200K at which idle compaction starts (`AGENT_HUB_CONTEXT_WARN` is the knob).
- **`await`: a hub no longer wakes for CI, merge or lock progress.** `await [--ok MERGED] [--on RC=WORD] -- <wait
  command>` runs the wait detached from the hub's context (a supervisor in its own session, output in a log) and
  journals exactly one line, `@hub WORD LABEL — LINK (exit N, …)`, when the command ends: `DONE`/`MERGED`, `FAILED`,
  `TIMEOUT` or a word of the caller's choice. Nothing is written on progress. The hub keeps its single `jwait`. In the
  token audit of 07–14.10, 202 of a week's 913 background wakes were such waits, each re-reading ~130k tokens of hub
  context. [Waiting for CI](docs/launch-modes.md#waiting-for-ci-a-merge-or-a-lock).

## 1.0.6 — 2026-10-14

- **A stage whose hub is no longer needed can be closed.** Finished stages stayed in agent-top, the watchdog, the night
  queue and the question summaries for good (31 stages on the owner's home, most of them long done), and their hubs kept
  locks and roles. `hub close --stage S --why "…"` refuses while an agent runs or an owner question waits (`--force`
  stops the agents, leaves the questions), then stops an idle background hub, releases the stage's locks, retires its
  roles, journals the close and marks `stage.json`; the stage drops out of those views, `agent spawn` refuses it, and
  its files stay. A hub session or lock that another open stage still holds (or may: a registry unread) is left
  alone. `hub start` or `hub takeover` reopens it and continues the hub numbering. agent-top's Summary lists the stages, marks the idle ones
  (open, no live agent, quiet for 48 h, `AGENT_TOP_IDLE_S`) and closes one with `c` in the console or the `close` button
  (pressed twice) in the `/agent-top` pane; `--json` carries `stage_info`, `closed_hidden` and `idle_after_s`. The hub
  skill has a *Closing a stage* procedure, the status skill names idle stages.

## 1.0.5 — 2026-10-14

- **Hubs are not compacted when idle.** Claude Code 2.1.290+ compacts a conversation over 200K tokens left idle about
  54 minutes (on by default since 2.1.299). A hub waiting on a long `jwait` is such a conversation: compacted, the
  context budget reads the smaller size and the hub goes on from a summary instead of handing over. The background
  successor of `hub succeed` now starts with `"idleCompaction": false` in its `--settings`, in bypass mode too, and
  `hub start`/`hub takeover` of a Claude hub warn unless the settings file that decides it, in Claude Code's order
  (managed, the project's `settings.local.json`, its `settings.json`, the user's), turns it off.

- **Portable Python selection.** `bin/run-python` chooses a compatible interpreter on `PATH`, or validates an
  explicit `DELAMAIN_PYTHON` override. Native Codex hooks require 3.11+ through this launcher; terminal tools can
  request 3.10+ or 3.11+ without editing installed files. Claude hooks and CLI shebangs are unchanged. Detached
  agents write their exit journal with the interpreter that launched them, preserving their original exit code.

## 1.0.4 — 2026-10-14

- **Hubs grill when the owner asks.** On 14.10 two of two hubs answered «грилинг» with one batch of A/B questions with
  defaults (and one with an "accept all three?" popup), not the companion `grilling` skill: free-text Russian did not
  load the skill, and the hub skill capped grilling at "stop once the business result is clear". The prompt hook
  (`delegation.py prompt`, both engines) now names the skill when the owner's prompt asks for grilling (грилинг,
  грилл ми, погриль, grill me, grilling; not «гриль», «грили», "grilled" or a skills/grilling/ path), and the hub
  skill says an owner-requested grilling runs as written until the topic's frontier is empty, open owner questions
  included; its questions wait for the owner's answers instead of taking the recommendation on silence.

## 1.0.3 — 2026-10-14

- **The watchdog wakes Claude background hubs again.** `watchdog install` copied `CLAUDE_CONFIG_DIR` from the
  installing shell into the job's `run.sh`, and a Codex shell sets it to `~/.claude`. That value is not neutral: with
  it the claude CLI reads `~/.claude/.claude.json` instead of `~/.claude.json`, with no trusted folders and no login,
  so from 09.10 every `claude --bg --resume` of a wake failed with "Workspace not trusted" (49 times in one hub home).
  `install` now unsets a `CLAUDE_CONFIG_DIR` that names `~/.claude` while `~/.claude.json` exists (another directory,
  or `~/.claude` without `~/.claude.json`, is still exported), and `watchdog status` says `install again` for a job
  written before the fix. Every claude CLI call of the tools (`agent spawn`, a manual `watchdog run`, `hub succeed`)
  drops the same value from its environment.
- **A hub that takes over in a Desktop session under "No folder" lands in its project's folder.** `change_directory`
  straight to the hub's worktree waited for the owner's folder-trust prompt (dropped after 5 minutes unanswered) and,
  once applied, filed the session in the sidebar under a folder of its own named after the worktree. The `MOVE`
  instructions of `hub takeover` and the hub skill now go through the main clone: `change_directory` to it (trusted,
  filed under the project), end the turn with no background command, next turn `EnterWorktree` into the worktree.
  Probed 14.10 on the Dolya hub.

- **Haiku takes an effort like every other model.** Claude Haiku 5.5 has an effort setting (`low` to `max`), and
  Claude Code 2.1.296 resolves the alias `haiku` to it (2.1.287 to 2.1.295 still give Haiku 4.5; the minimum supported
  version is unchanged). `agent spawn` no longer drops the effort of a haiku model: `--effort`, else the
  `AGENT_HUB_EFFORT_DEFAULTS` entry, else `AGENT_HUB_DEFAULT_EFFORT`, else `high` goes to the CLI, is recorded in
  `meta.json` and the journal start line, counts for `--reason` and is seen by `AGENT_HUB_EFFORT_RULES`. The same for a
  haiku `agent` reviewer in `hub reviewer` and for a Haiku successor of `hub succeed` (the hub's own effort is inherited,
  or the call is refused when it cannot be read). Probed: Haiku 4.5 also accepts `--effort` and ignores it, so the flag
  is safe on every supported CLI. `hub effort` reads a Haiku 5.5 session like any other (its record, hook input and
  `$CLAUDE_EFFORT` carry the turn's effort); only a Haiku turn that recorded no effort (Haiku 4.5) is still treated as
  having none. A resume (`agent send`) of a Haiku agent spawned before this change, with no effort on record, gets the
  effort a spawn would (same defaults and `AGENT_HUB_EFFORT_RULES` check) and records it. The example subagent policy keeps Haiku free at any type but denies it at `low` (Haiku runs at high, medium
  allowed); the docs add no low default for Haiku.

## 1.0.2 — 2026-10-08

- **Codex `tell` supports immediate delivery through the public app-server proxy.** A verified active turn uses
  exact-turn steer. For a recipient observed loaded idle, a `turn/start` acknowledgement records `accepted` with
  `delivery_mode: "unverified"`; another client can activate after the final read, so a new turn is not guaranteed.
  One signed journal line and the matching acknowledgement record the result. An unavailable runtime returns a pending native-caller handoff,
  which the Codex hub handles immediately under verified human communication authority and the current registry.
  Native tool acceptance does not establish active same-turn steer; unknown outcomes forbid retry. Claude delivery
  and detached recipients retain their existing behavior. In an owned Desktop control, native input arrived during
  the existing active turn; native idle delivery remains unverified.
- **Codex hub terminal results trigger follow-through against Business DoD.** Hub, handoff and emitted Codex CLI/native
  successor instructions consume reports, verify ownership, continue independent authorized ready work, or record
  a concrete blocker and expected event. Executor brief stops and empty queue snapshots preserve the hub's remaining
  goal and explicit owner boundaries; preparation dependencies stay separate from final publication and resource gates.
  Claude successor instructions retain their existing behavior.
- **Canonical hub waits use `jwait --hub-events`.** Standard terminal/question events and configured extra wake
  words resolve inside the waiter, removing regex quoting from generated digest commands. Custom filters, default
  file/non-hub waits, tags, exclusions and replay semantics remain compatible.

## 1.0.1 — 2026-10-08

- **Автоматический native handoff учитывает уже данное разрешение владельца.** Перед `create_thread` агент
  проверяет исходную инструкцию человека, унаследованный handoff/план, ответ в реестре и standing permission;
  разрешение на автоматическую передачу контекста той же стадии действует до отзыва без повторного вопроса.
  Native prep и brief передают ссылки на источники и границы разрешения. При отсутствии/отзыве разрешения
  или новом бизнес-scope сохраняются запрос и предыдущий хаб; агент спрашивает один раз. Независимый CLI
  исполнитель начинает разрешённую работу без ожидания чужой передачи контекста.

- **Desktop-передача Codex сохраняет нативную поверхность.** Агентские `--surface cli` и `--headless`
  требуют явного выбора владельца через `AGENT_HUB_DESKTOP_CLI_HANDOFF` в конфигурации hub home;
  репозиторий и окружение не могут дать это разрешение. Без разрешения на native create_thread запрос остаётся
  pending, предыдущий хаб работает до проверенного takeover. Terminal/detached-передача сохраняет CLI-путь.

- **Verified Codex native requests survive the current hub's same-shift host refresh.** Full thread UUID,
  native kind, request/chain and original registration/takeover boundary remain intact. Self-only
  `hub desktop-recover` repairs a proven legacy refresh using the original full registration identity,
  exact shift/cwd and unchanged observed policy; ambiguous evidence and later/manual hubs fail without
  mutation. Exact native self-refresh validates under one locked minimal path, without resource/queue/project
  takeover side effects; incompatible resource instructions are rejected. Recovery creates no thread, reservation
  or shift and changes no settings.

- **The watchdog can wake a confirmed idle Codex app hub in its own thread.** `hub start`/`takeover` record app
  provenance only for the current UUID with both app markers and no detached worker identity. Runtime status is
  rechecked before `codex queue`; terminal/unknown hosts notify only, with no native resume fallback. The takeover
  digest now describes host-specific support. Codex API-error recovery retries only a final own-turn
  `server_overloaded` with matching start and no later user/turn boundary; quota/auth/unknown errors and interruption
  remain excluded, and the failed turn is rechecked before queueing.
  A fenced `native-plan`/`native-claim`/`native-ack` protocol supports a separately installed app-native heartbeat
  when Desktop cannot be reached through the CLI daemon. It requires native idle/actionability checks, preserves
  unknown delivery, deduplicates shared UUIDs across stages, and does not spend model calls itself; the native
  automation consumer may be model-assisted. UUID receipts survive replacement by a different stage actor; both
  native claims and CLI queues consult the same local fence. Unknown CLI outcomes also prevent native fallback,
  and only verified recipient own-turn progress releases an uncertain delivery.

- **Codex native delegation guards recognize CLI 0.160.0 namespace concatenation.** Spawn, followup and
  messaging now reach the configured policies; level 0 blocks task reactivation without blocking pure messages.
  Real CLI controls cover the declared manifest, nested shell/patch calls, native TOML effort and stdin limits.

- **agent-top follows Delamain’s visual identity** in the terminal, Claude Code pane and HTML widget, with
  navy panels, ice-blue navigation and amber accents. Status colors, monochrome and limited-color terminals,
  narrow layouts and the pane’s focus controls remain supported.

- **Delamain's visual identity now follows the AI dispatcher and autonomous fleet metaphor.** New pixel-art
  illustrations show task dispatch, shared records and coordinator handoff; the workflow sketch uses the same
  navy, ice-blue and taxi-amber palette. The README and repository About describe coordination for both Claude Code
  and Codex. Generation prompts and the character reference are in `docs/assets/illustration-prompts.md`.

## 1.0.0 — 2026-10-07

- **BREAKING: agent-hub is now Delamain.** New plugin id `delamain` (Claude Code `delamain@delamain`, Codex
  `delamain@delamain-codex`) in the repository `ilya-kozyrev/delamain`. The slash commands and skills are
  `/delamain:hub`, `/delamain:setup`, `/delamain:status`, `/delamain:handoff`, `/delamain:delegation` and
  `/delamain:agent-top`; the worker subagents are `delamain:worker-low`, `delamain:worker-medium`,
  `delamain:worker-high` and `delamain:worker-xhigh`. The messages the tools print start with `delamain:` (stderr,
  hook text, watchdog notifications and `watchdog notify-test`), and the dispatcher marker they write is
  `# delamain: dispatcher`. The name comes from the AI that runs the cab fleet in Cyberpunk 2077.
  `docs/a-day-with-agent-hub.md` is now `docs/a-day-with-delamain.md`.
- **Two markers are still written under the old name in this release.** The auto-handoff marker stays
  `[agent-hub auto-handoff k/N]` and the watchdog wake prefix stays `[agent-hub watchdog]`: a hub that keeps running on
  an older plugin copy after the update has the older hooks, which know only these forms (its autopilot hook would take a
  successor's prompt for the owner speaking and reset the automatic-handoff chain). Both forms are read everywhere
  (`[delamain auto-handoff k/N]` and `[delamain watchdog]` too; the exemption of the watchdog's wake prompt from "the
  owner spoke", added in 0.9.2, holds for both forms); the switch to the new forms comes in a later release.
- **For one release the hook texts name this plugin's skills in both forms.** A session started before the update (its
  plugin still registered as `agent-hub`, for example one that runs the plugin straight from the folder that has just
  been updated) knows `agent-hub:handoff`, not `delamain:handoff`. So the texts that the hooks and tools inject, the
  context budget's "what to do" sentence and its deny reason, the `lock` message about an unknown resource and the note
  for a prompt that starts with `/agent-hub:<skill>`, give the name as `delamain:<name>` and, in a short parenthesis,
  `agent-hub:<name>` in a session started before the rename. The single new form comes in a later release.
- **What did not change, so stages, agents and configurations keep working:** the `AGENT_HUB_*` environment variables,
  the project directory `.agent-hub/` (`config.json`, `lock-rules.json`, `local/`), the default hub home `~/agent-hub`
  (and the older `~/.claude/agent-hub`, `hub home migrate`), the command names in `bin/` (`hub`, `agent`, `agent-top`,
  `tell`, …) and the watchdog's entries (the `# agent-hub-watchdog` cron marker and the `io.agent-hub.watchdog.*`
  launchd labels, so an installed job is still found). Data and project configurations need nothing.
- **The old forms are still read.** A successor started by the previous version keeps its chain
  (`[agent-hub auto-handoff k/N]` and `[delamain auto-handoff k/N]` both count as the marker), a successor that an older
  hub started with the prompt `/agent-hub:hub take over stage …` still takes over (it is a new session that has only
  `/delamain:hub`, and the model gets the unknown command as plain text: the prompt hook `hooks/delegation.py prompt`
  adds a note that `/agent-hub:<skill>` is the former name of this plugin's skill `/delamain:<skill>`, to invoke it and
  carry out the rest of the prompt as its arguments; any other prompt, including a different plugin's command or an
  unknown skill, gets nothing), a personal dispatcher with `# agent-hub: dispatcher` is still
  the plugin's own, `cache/*/agent-hub/*/bin` of a Claude or Codex install made before the rename is still recognised,
  a subagent rule written with the prefix `agent-hub:` applies to the same agent under `delamain:`, and the dev copy of
  the agent-top mod also answers `/agent-hub:agent-top`. Names you wrote by hand are not rewritten: personal settings,
  CLAUDE.md or AGENTS.md instructions and aliases that name `agent-hub:worker-*` or `/agent-hub:hub` must be changed
  to the new names, because the old names no longer resolve to an agent or a skill.
- **Migration, Claude Code.** Existing installs move through the new `renames` map in `.claude-plugin/marketplace.json`
  (`agent-hub` → `delamain`): the marketplace keeps the name it was registered under (`claude-agent-hub`), so there is
  nothing to uninstall or add again. Update the marketplace (`/plugin marketplace update claude-agent-hub`, in a shell
  `claude plugin marketplace update claude-agent-hub`; auto-update does it too), then run
  `/plugin install delamain@claude-agent-hub` once (`claude plugin install delamain@claude-agent-hub`): a marketplace
  added from a git repository reports the plugin as not cached until that install. Restart the sessions. The cache
  folder becomes `~/.claude/plugins/cache/claude-agent-hub/delamain/<version>/`. If the watchdog is installed, run
  `watchdog install` again from the new plugin: its job still points at the old `bin/`, which is removed later
  (`watchdog status` reports it). A new install is `/plugin marketplace add ilya-kozyrev/delamain` and
  `/plugin install delamain@delamain`.
- **Migration, Codex.** Codex has no rename map: replace the plugin, between sessions (removing the old plugin deletes
  its cache, and a Codex session still running on it loses its hooks). Remove the old plugin first, so the hooks do not
  run twice: `codex plugin remove agent-hub@agent-hub-codex`, `codex plugin marketplace remove agent-hub-codex`; update
  your checkout (`git -C /absolute/path/to/checkout pull`); then `codex plugin marketplace add /absolute/path/to/checkout`
  and `codex plugin add delamain@delamain-codex`. Restart the Codex chat and review and trust the new plugin's hooks
  ([Codex setup](docs/codex.md#install-in-codex)). If the watchdog is installed, run `watchdog install` again from the new
  plugin: the job still points at the `bin/` that `codex plugin remove` deleted.

## 0.9.2 — 2026-10-07

- **The watchdog no longer starts a copy of a hub it has just stopped, and its wake prompt no longer resets the
  autopilot's handoff chain.** A live probe on claude 2.1.289 showed that after `claude stop` a Remote Control session
  leaves `claude agents --json` about 1.7 s before its process has exited, and a resume in that window starts a copy
  (4 of 4); `watchdog` now waits for the stopped process (pid and start time) to exit (up to 30 s) before `claude --bg
  --resume`, resumes the same id (3 of 3 in the probe) and, if the process is still there, resumes in no later tick
  until it is seen gone (the identity is kept in the hub's state, saved right after `claude stop` succeeds, even when the
  re-list fails or still shows the row); a listed idle row without a pid is not stopped at all (the wake fails and the
  owner is notified), and a hub listed again after the wait (the owner resumed it) cancels the wake. A
  wake prompt that starts with `[agent-hub watchdog]` is recognised as agent-hub's own and does not reset the chain
  (`owner_spoke` in `bin/autopilot.py`, used by the Claude and the Codex hook path alike); a prompt typed by the owner
  still does. Tests: `tests/t_watchdog.sh` (a stand-in `claude` whose stopped process lingers; fails on 0.9.1),
  `tests/t_autopilot.sh`.

## 0.9.1 — 2026-10-07

- **An optional machine-load hold makes `agent spawn` warn or refuse while the machine is busy.** Off by default: with
  `AGENT_HUB_SPAWN_HOLD_LOAD` set (1-minute load per core, e.g. `1.5`) the `watchdog` tick writes
  `<state dir>/spawn-hold.json` while the load is above it and deletes it below 80 % of it (R5; unset removes a leftover
  file; `--dry-run` writes nothing). `agent spawn`, for both engines, then warns (`AGENT_HUB_SPAWN_HOLD=warn`, the
  default) or exits 1 (`refuse`), naming the load, the cores, the threshold and the new `--ignore-hold`; an expired or
  unreadable file is ignored and resumes (`agent send`) are never held. Both settings are hub-wide; an invalid value
  warns and counts as unset (threshold) or `warn` (action). Tests: `tests/t_load_hold.sh` (fake load through
  `AGENT_HUB_WATCHDOG_LOAD`, test-only).
- **Codex hubs are notify-only in 0.9.1: the watchdog notifies the owner.** The queue path is inert until a host producer lands (nothing records `host: codex-app` yet); `watchdog_codex.py` reads runtime state and rollout activity, keeps Desktop, terminal, unknown and notLoaded threads notify-only, and never runs native `exec resume`; Codex API-error detection remains disabled (R4 is Claude-only in 0.9.1), with positive and negative controls for queue decoding, unknown timeout outcomes, hanging proxies and missing CLIs in `t_watchdog_codex.sh`.
- **Codex handoffs resolve `--session self`, and runtime versions identify the tools actually in use.** Handoff drafts use the wait procedure printed in the takeover digest, which follows the reader's host; status and takeover warn about a newer cache for that engine. Reviewers use no judgement-helper team below the configurable 300 changed-line threshold; bounded extraction stays available. Controls: `tests/t_codex_parity.sh` (both hosts, fake caches, registry identity and threshold layers).
- **Codex Desktop autopilot prepares a native successor in the same saved project and verifies its actual takeover.** Request, bind and failure commands preserve retries without an invisible CLI fallback; console hubs keep detached CLI successors. Native APIs cannot set sandbox/approval policy. Current effort, goal titles, replacement rules and completed-handoff checks are retained. Replacement checks precede stopping; late CLI results cannot alter another reservation. Desktop transitions journal their state, takeover hooks run outside the autopilot mutex, and successors replay the first digest waiter before conditional waiting. Controls: `tests/t_codex_desktop_autopilot.sh`, `tests/t_codex_autopilot.sh`, `tests/t_autopilot.sh`, `tests/t_pr20_reservations.sh`, `tests/t_pr20_takeover_wait.sh`.
- **The hub agrees a Business DoD before autonomous work and preserves it across handoffs.** Clear requests supply the agreed result and plan authorization; questions address ambiguity that changes that result. Standing permissions and explicit plan approvals still apply. Briefs, handoffs and night queues inherit the result; technical checks remain the executor's responsibility. Controls: `tests/t_hub.sh`, `tests/t_ask_nightq.sh`, `tests/t_codex_agent.sh`.
- **A hub that sleeps while lines wait for it is woken by a new `watchdog` job, and night support no longer needs Claude
  Desktop.** `watchdog install` sets up a job every 5 minutes (launchd on macOS, cron elsewhere; no daemon, no model) that
  does four things per stage: writes `EXIT <role>: killed (no result)` for an agent whose process is gone (R1), journals
  one `[watchdog] @hub OVERDUE Q-…` line for an open question past its due time that has a default (R2), wakes a hub that
  is silent for 15 minutes while lines addressed to it have waited that long, or an open night-queue item has inside
  `AGENT_HUB_NIGHT`, and no `jwait` of its own runs (R3), and wakes a Claude hub whose last turn ended on an API error (R4); a live `jwait` of the hub holds both back.
  A headless hub gets `agent send`; an idle `claude --bg` hub gets `claude stop` and `claude --bg --resume <same id>` with
  no other flag (a live probe on claude 2.1.289: any flag, or a session still listed, makes the CLI start a copy, the watchdog stops only the copy the CLI itself names, checks that it left `claude agents` and otherwise tells the owner; a session that merely appears is never stopped); a Desktop, a terminal or a not-background Claude hub only gets a notification, and a
  Codex hub is notify-only in this release (its queue path in `bin/watchdog_codex.py` stays off until a hub record says `host: codex-app`). It never starts a successor, honours `watchdog quiet --stage S
  --reason "…" [--for 8h]` (`<stage>/do-not-wake.json`), wakes once per episode with a backoff of 15, 30, 60, 120, 240
  minutes, skips a stage with a pending handoff, runs one tick at a time and has `watchdog run --dry-run`. A notification
  (local, and `AGENT_HUB_NOTIFY_CMD` for a phone push) carries only the stage name, minutes, counts and an event word. New
  hub-wide settings: `AGENT_HUB_WATCHDOG`, `_EVERY`, `_WAKE_AFTER`, `_BACKOFF_MAX`, `_NIGHT_QUEUE`, `_API_ERROR`,
  `AGENT_HUB_NOTIFY_LOCAL`, `AGENT_HUB_NOTIFY_CMD`; setup asks about it as question 9. Supporting changes: `jwait
  --journal` writes `.jwait-state/<stage>/<caller>.armed.json` while it waits, `hub takeover` records `host:` in the hub's
  `roles.json` record and prints the watchdog line in its digest, and `agent.dead_candidates` lists what `observe_dead`
  would write without writing it. The Desktop night-nudge task (`templates/night-nudge-task.md`) is deprecated; the docs
  no longer call night support macOS-and-Desktop only. **Release note:** update both engines (the Claude and the Codex
  plugin copies) and run `watchdog install` again after every plugin update, because the job points at the plugin version
  that was installed (`watchdog status` says so); an owner of the Desktop night-nudge task may delete it. Tests:
  `tests/t_watchdog.sh`, `tests/t_watchdog_install.sh`.

- **One digest for the owner across all stages: `ask inbox`.** In the morning the owner asked four hubs one by one for
  status and read about ten minutes of long replies before the first decision. `ask inbox [--since T] [--stage S …]
  [--json] [--if-quiet]` reads every stage's register, journal and agents and prints, outcome first and under 2 000
  characters, what finished since the owner's last recorded answer (journal `DONE` / `MERGED` / `released` lines, counted,
  the latest quoted), the questions waiting for the owner with default and due time (overdue first), the `D-` decisions the
  hubs took, and blocked and live agents; quiet stages are one closing line (with live counts), an overflow is "K more: ask inbox --stage S"
  (overdue questions of the most urgent stages first); a register that cannot be read is named, never quiet.
  It is read-only. New setting `AGENT_HUB_OWNER_DIGEST_AFTER` (hub home, default `3h`): `ask inbox --if-quiet` prints
  nothing while the owner answered within it; the hub skill opens its reply with the digest on the owner's first message
  after that silence and puts into every question what each answer changes. Tests: `tests/t_owner_digest.sh` (fixture
  with three stages, exact content, the cap, `--since`, `--if-quiet` on both sides of the threshold, `--json`; it fails
  on the old `bin/`).

## 0.9.0 — 2026-10-06

- **`hub start` now insists on a stage name that says what the work is, and the goal travels with the hub.** A stage
  called `hub-09` showed as "Hub hub-09 #1" and signed `hub-09-hub-1` in other journals; nothing said what it did.
  `hub start` exits 2 for a name made only of generic words (hub, stage, wave, wp, task, work, test, tmp, new, default,
  stream, sprint — the hub-wide `AGENT_HUB_GENERIC_STAGE_WORDS` replaces the list), numbers and single letters, and for a
  start without `--goal "<one line>"`. The goal is kept in `stage.json`; the hub's registered title is
  `Hub <stage> #N — <goal>`, and `takeover`, `succeed`, the handoff draft, the digest and `agent-top`'s hub row show it
  (`takeover --goal` sets one for an older stage, which `takeover` never refuses on its name; a stage without a goal keeps
  today's title). New `hub rename --stage OLD --to NEW [--dry-run]` renames a stage none of whose agents is alive: directory,
  `roles.json`, agent metas, the question register's heading and the board's lock notes; otherwise it exits 2 and lists
  the live agents; it reads and checks every file before the first write and rolls back a failed write. The skill tells the hub to name the stage and the roles after the work. The suite and scripts opt
  out with `AGENT_HUB_NO_NAMING=1`. Tests: `tests/t_naming.sh` (its checks fail without the change).
- **A run that ended normally no longer looks like an alarm, a hub's own lines stop waking it after a Desktop restart, and
  an unfinished handoff is refused.** An agent that ends with code 0 and a result but no status word of its own (a
  read-only reviewer cannot journal at all) now leaves `ENDED <role>: …`, or `REVIEWED <role>: …` for a role whose name has
  `review`/`reviewer` in it; `EXIT` stays for a non-zero code, an error result, no result and `killed (no result)`, on both
  engines. The hub's default `jwait` wakes on `ENDED` and `REVIEWED` too (the agent stopped), and the brief footer asks
  for `PROGRESS` lines, which no wake pattern matches, instead of milestone `DONE`/`QUESTION` lines. `hub handoff --finish`
  refuses (exit 2, lines listed) a draft whose § 0–2 still hold `TODO`, `--allow-todo` overrides it, `hub succeed` makes
  the same check and `hub takeover` warns about such a handoff. After a Claude Desktop session's CLI restarts (a new
  `$CLAUDE_CODE_SESSION_ID` under the same `local_…` id) `jlog`, `jwait` and `agent send` still resolve the caller to the
  hub's tag through `$CLAUDE_CODE_HOST_SESSION_ID` — only when Desktop's record of that session names this CLI session —
  and refresh the registry's CLI id, so the hub's own `agent send "… report DONE"` echo is signed with its tag and no
  longer wakes it. `docs/reference.md` shows how a project separates a CI retry from a deploy in `lock-rules.json`, and
  `docs/codex.md` gets an update procedure that keeps the older plugin cache directories, which `codex plugin add` deletes
  and live Codex sessions still need for their hooks. Tests:
  `t_agent_ended.sh`, `t_handoff_todo.sh` and `t_caller_host.sh` fail on 0.8.6's code; `t_lock_retry_doc.sh` runs the
  example of `docs/reference.md` itself.
- **Agents are spawned at the effort the work needs, old agents are not resumed on top of huge contexts, and an agent's
  name says what it does.** `agent spawn` takes its effort per model from the new `AGENT_HUB_EFFORT_DEFAULTS` (else
  `AGENT_HUB_DEFAULT_EFFORT`, else `high`), for Claude and Codex alike; an effort above the model's default, or a model
  listed in `AGENT_HUB_REASON_MODELS`, needs `--reason "…"` — a stderr warning, or a refusal with
  `AGENT_HUB_REASON_POLICY=refuse` — and the reason is kept in the journal's start line and `meta.json`. `agent send`
  to a stopped agent whose context is above `AGENT_HUB_RESUME_MAX_CTX` (default 250k tokens) is refused with the advice
  to spawn a fresh agent from a handoff file; `--resume-anyway` overrides, `agent status` shows the size (`ctx 300k`;
  a Codex log carries none, so Codex resumes are not limited). The registered title is `<role> — <the brief's first
  heading> (<stage>)`, not "agent wp23 (hub-09)". The no-plan warning now says to show the plan to the owner and record
  `ask plan` only after the owner's yes. A Codex spawn without `--model` has an unknown model: with `AGENT_HUB_REASON_MODELS` set it is refused
  (`refuse`, "pass --model") or warned about (`warn`); `hub succeed` passes its own reason, so `AGENT_HUB_REASON_POLICY=refuse` does not stop the autopilot chain.
  Tests: `t_spawn_policy.sh` (many of its checks fail without the change), `t_autopilot.sh`, `t_codex_autopilot.sh`.

- **A hub no longer asks the owner again for what the owner already allowed, even in another stage.** `ask allow`
  records a standing permission (`A-<prefix>-NNN`: the class of action, keywords, the owner's words, scope, optional
  `--until`) bound to the repository the action touches; `ask allow --list` and `ask revoke` manage them, and every
  stage's register is read. `ask add --class … [--repo …]` refuses a question a permission in force covers (exit 3,
  "covered by A-… (<source>)") unless `--override "why"` is given, and warns on a keyword found only in the text. The
  `hub start` / `hub takeover` digest lists the permissions for the stage's repository from every stage, or says there
  are none. A question is covered only when every class keyword it names, as written, (and, on top, money,
  migrations or permissions/RBAC mentioned anywhere in it, `AGENT_HUB_SENSITIVE_CLASSES`) is covered on every
  repository it touches, and the refusal prints the owner's words in full; a repository is its normalized `origin`
  URL with an explicit port and IPv6 brackets, else its main clone's path, so two checkouts named `shop` stay apart; an entry without
  the owner's words, with an `until` that is not exactly a date or date and time, or without a `repo-id` covers
  nothing and is listed as `INVALID`. `skills/setup` reads the project and the person and proposes permissions by grilling; `skills/hub` checks
  them before a merge, deploy or release question and forbids invented gates. Design: `docs/standing-permissions.md`.
  Tests: `tests/t_permissions.sh` (same stage, another stage on the same repository, another repository's stage
  naming `--repo`, two repositories of one name, every class and every repository, sensitive classes, invalid entries,
  scopes, expiry, revocation, refusal and override, the digest after § 0 with "K more"; 86 of its 97 checks fail on
  0.8.6).

## 0.8.6 — 2026-10-06

- **A hub's wait is now shorter than the prompt cache's life, and the plugin's own service lines no longer wake it.**
  `jwait` waited 2 h by default; the cache lives 1 h, so every wake after a long sleep re-wrote the hub's whole context
  into it. The default is now `55m`, set by the new hub-wide `AGENT_HUB_JWAIT_FOR` (environment or the hub home's
  `config.json`; a bad value warns and falls back); the digest's `jwait` line, the skill, the docs and `--help` carry
  it, and the skill keeps the Bash `timeout` at or above `--for`. The autopilot's `auto-handoff chain reset` line,
  which was tagged `hub` and woke every hub's `--tag hub` wait, is now tagged `autopilot`: still in the journal, wakes
  nobody. The review brief template and the skill say the hub writes the brief and launches the reviewer, never the
  author; money, masking and permissions narrow it to that risk, and the reviewer caps its reading by the diff size.
  Tests: `t_jwait.sh` (default, setting layers, a real run's deadline, a service line next to a `DONE`), `t_hardening.sh`
  (the digest's printed command).
- **agent-top shows what the logs say: cost, Codex tokens and the hub's journal age are no longer inflated, and the
  hub's share of the stage's spend is on screen.** A Claude `result` carries the session's cumulative
  `total_cost_usd` (also across `--resume`: 64 multi-result logs on the owner's home never step back, none changes
  session id), and agent-top had added every result up — $72.22 shown against $3.61 real. It now takes each session's
  latest total. A Codex `turn.completed` carries the thread's cumulative count, again logged after each resume; the
  count of each thread is now the latest one (`usage_scope` is `session`, `sessions` for several threads, or `partial` — shown as ≈ — when a count
  read before any `init` of a log scanned from its tail sits beside known threads; it was `logged_runs`). The hub's "journal" age is its newest line across yesterday's and today's journal (today's was
  shadowed by yesterday's when the tag wrote on both days). `agent-top --json` carries `spend` per stage — the agents'
  logged dollars (every agent folder of the stage, whatever the list hides), the hub's dollars (logged for a headless hub, else estimated from the tokens of its transcript at
  the per-model price the agents' results show, flagged `hub_basis: "estimate"`), and `hub_share`; `--once` prints it.
  Tests: `tests/t_agent_top_honest.sh` (a resumed Claude log, a resumed Codex log, a two-day journal, the share, a
  hub transcript read in pieces; it fails on 0.8.4's code) and a hub with a 5 MB transcript in `tests/t_agent_top_perf.sh`.
- **A hub's `pkill -f "<words>"` can no longer kill agents, and an agent that died without a trace wakes the hub.**
  `agent spawn`, a resume and `agent send` to a stopped agent pass the brief and the messages to the CLI on stdin
  (`claude -p`, `codex exec -` / `exec resume <id> -`; the prompt is `prompt-<run>.txt` in the agent's directory), so no
  command line holds brief text, the exit-note wrapper included; the brief footer gains two rules: stop only
  processes you started and never `pkill -f` / `killall` with free text; never print environment variables or secret
  files, and remove a secret the task needed before DONE. When an agent's process is gone without a result (`kill -9`
  of the whole group takes the wrapper with it), the first observer — `agent status` or the poll of `jwait --journal`
  (every 10 s) — journals `EXIT <role>: killed (no result)` once per run, which the hub's default `jwait` match wakes on.
  The run's pid is now recorded when the process starts, not after its init event, so a resumed agent is never seen as
  dead; `agent stop` is never reported. The observer decides from the log and meta read after the process is confirmed gone, under a per-agent lock (`.agent.lock`); where nothing can be written (a read-only sandbox running `agent status`) the observation is skipped and the status is still printed; `agent send` holds the same lock from reading the meta to saving it, so concurrent sends resume once and no queued message is overwritten, and each run reads its own `prompt-<run>.txt`. `agent-top` stays a pure viewer and does not observe. Tests:
  `tests/t_prompt_argv.sh` (`ps -ww` shows no prompt text and `pkill -f` leaves the agent alive, both engines, spawn
  and resume), `tests/t_agent_dead.sh` (three concurrent observers write one line; the wrapper's own EXIT is not
  doubled; a result written just before the exit is not "killed"), `tests/t_agent_send_race.sh`; all fail on 0.8.4.

## 0.8.5 — 2026-10-06

- **`hub start` and `hub takeover` no longer take the main-merge lock from a live hub of another stage.** With
  `AGENT_HUB_TAKE_MAIN_MERGE=true` in a repository's config, every new stage's `hub start` and every takeover took the
  lock from whoever held it (06.10: sentinel-yc-move from core-c in the middle of its merge). The setting now applies
  only to a free (absent or expired) lock and, on `takeover`, to one held by an earlier `hub` of the same stage (found
  in the stage's `roles.json`, live or retired; a live role in another stage wins over a retired record here, and a
  holder that cannot be placed for sure — two stages, an unreadable registry — counts as foreign; a predecessor's main-merge too, unless its record here is the `hub` role); on `start`, for
  an agent of this stage such as a merge steward, and for a holder of another stage or of none, the lock is left alone with "take it with --take-main-merge". An explicit `--take-main-merge` still takes it, now with an
  `ATTENTION` line naming the holder's stage and the age of its latest journal line (or "no journal line"), and
  `hub start` accepts `--skip-lock <resource>` like `takeover`. Tests: `tests/t_hub_main_merge.sh`; against 0.8.4's
  `bin/hub` it fails on the start and takeover cases that steal the lock.

## 0.8.4 — 2026-10-06

- **The agent-top mod is quick again, and its Feed no longer hangs on "loading the feed…".** `agent-top --json`
  (the mod runs a new one every few seconds) keeps its log offsets and what it read up to them in a cache,
  `<state dir>/agent-top/cache.sqlite` (`$AGENT_HUB_STATE_DIR`, else `<hub home>/.state`), so a run reads only what the
  logs gained since the last one. Rows belong to a generation (a hash of the reader code and the scan cap), a log is
  resumed only while its first bytes and the bytes before the offset are unchanged, `AGENT_TOP_CACHE=0` reads
  everything afresh, and the agents' own files are still never written. Owner questions come from `ask` in-process,
  `ps` runs while the files are read, sub-agent folders come from one listing of the projects folder instead of a glob
  per session, a finished sub-agent's parent transcript is not read at all, and Codex sub-agents are looked up by
  parent. On the owner's home: `--json` 1.08 → 0.22 s CPU (1.09 → 0.21 s wall at the same load; 22.6 s wall at load
  80 before), `--json --all` 1.74 → 0.22 s CPU, one agent's `--feed` 0.31 → 0.18 s CPU. In the mod, each answer is
  drawn as soon as it comes (the card no longer waits for the list call behind it), a card answer for an agent the
  person has left is dropped, a failed or timed-out card call shows its reason in the feed area and is retried on the
  next tick instead of leaving "loading the feed…" for good, the call timeout is 60 s (a first run after an update
  reads every log once and saves as it goes), and `/agent-top` answers after at most 4 s while the pane fills when the
  data comes. Tests: the feed's loading → shown / error states and a dropped stale answer in `hooks/agent-top.test.tsx`;
  `tests/t_agent_top_perf.sh` runs `--json` on a generated 90 MB home and fails when a repeated run costs over 35 %
  of the first's CPU beyond the fixed cost of a run (0.8.2: 97 %).

## 0.8.3 — 2026-10-06

- **The autopilot successor starts at the hub's own effort, or not at all.** `hub succeed` used to pass `--effort high`
  when neither `--effort` nor `AGENT_HUB_SUCCESSOR_EFFORT` said otherwise, so a hub at `xhigh` handed over to one at
  `high`. It now reads the effort the hub runs at *now* and passes that; if no source answers it exits 1 naming every
  source it tried and starts nothing (there is no default; a Haiku successor, which has no effort setting, needs none).
  `--effort` and `AGENT_HUB_SUCCESSOR_EFFORT` still win. The budget message's ready command carries the hook input's
  `effort.level`; `--again` keeps the previous attempt's effort. New `hub effort [--session ID] [--json]` prints the
  effort and its source. Sources, most current first (each proved with a throw-away session, also after an in-session
  `/effort`): the hook input's `effort.level`, `$CLAUDE_EFFORT` of the Bash tool (not in a `claude --bg` session, whose
  environment is the daemon's), the last assistant record of the
  transcript, `--effort` in a `claude --bg` session's `~/.claude/jobs/<id>/state.json`, the Desktop session record, the
  process argv — the last is fixed at launch and lags `/effort`, and a `--bg` session's process has none. `$CLAUDE_JOB_DIR`
  and `$CLAUDE_CODE_HOST_SESSION_ID` are not used: a session's children inherit its ancestor's. A session whose last turn
  ran on Haiku has no effort: the CLI leaves `$CLAUDE_EFFORT` as inherited there, so it and the flags are no answer.
- **Codex hubs use registry addresses and warn about a live predecessor.** `hub takeover` checks a detached worker's
  PID/process token (including a worker registered as `hub`) or native runtime status through the existing Codex
  daemon's read-only proxy. Native detection is verified only with a fake transport; without a running app-server
  daemon it stays silent. Failures are silent and nothing is stopped. The warning gives `agent stop` for a worker
  or asks to close the native Codex session. `tell --address` resolves promoted workers to their original role and
  prints `codex queue --thread <UUID> --message "…"` for native targets on CLIs with queue support, without Claude
  name discovery. Codex instructions require `tell` first and direct messages only to the registry address.

- **Ask what is running in Claude Code or Codex.** The shared `status` skill answers agent, task, stage,
  owner-question and lock questions in plain text from a fresh read-only snapshot. The Claude Code live pane
  remains `/agent-top`; the removed chat-widget skill stays removed.
- **`tell <stage> "text"` writes to another stage's hub.** It reads the holder of the role (default `hub`, `--role`) from
  that stage's registry, appends `@hub text` (`@hub QUESTION text` with `--question`) to its journal signed with the
  caller's stage-qualified tag, and prints the registered direct address: session id, kind, title, the name for a
  cross-session message (from `claude agents --json` by session id; skipped when the CLI does not answer), or
  `agent send --stage <stage> <role>`, which `tell` runs itself for a headless agent. `--address` prints only the address and writes nothing.
  A headless holder gets the text through `agent send` (it reads its inbox, not a journal). An answer comes back in the
  asker's own journal (`tell <asker's stage>`). `--address` takes no text. An unknown stage or no holder exits 1 and lists the stages that have one. The hub skill now says: the journal first,
  a direct message only to the registry address, never to a session picked by its name in a list.
- **A background session no longer runs an old plugin's tools.** `claude --bg` sessions inherit the environment of the
  long-running Claude Code daemon, including the `HUB_BIN` of the plugin version that was current when the daemon
  started, so `"$HUB_BIN/jlog"` and `"$HUB_BIN/jwait"` ran an older copy. The SessionStart hook now appends
  `export HUB_BIN=<this plugin's bin/>` to `$CLAUDE_ENV_FILE` when `HUB_BIN` is unset or points elsewhere (a symlink to
  this `bin/` counts as the same) and says so in one line when it replaced a stale value. The `bin/` is that of the plugin
  copy the hook belongs to; an inherited `PLUGIN_ROOT` (a Claude worker started from a Codex host) is ignored.
- **Hub-to-hub addressing no longer loses requests.** `jwait --tag hub-30` on stage `core-c` also wakes on the
  stage-qualified address `@core-c-hub-30` (and `--tag hub` on `@core-c-hub`); `@hub-300`, `@xcore-c-hub-30` and another
  stage's `@dolya-hub-30` still do not match. `jlog` writing into another stage's journal signs a derived tag
  (`$HUB_TAG` or the registry) with the caller's own stage — `[core-c-hub-30]` in the Dolya journal — so the answer
  `@core-c-hub-30` is heard; an explicit `--tag` is written as given, and an own stage that cannot be told leaves the tag as before.
- **`hub start` and `hub takeover` run only in a fresh worktree of the project.** In the project's main clone (whatever
  branch it has checked out), in a directory outside git (a Desktop session started under "No folder") or in a worktree
  without the `.agent-hub/` that `origin`'s default branch has, they create `<repo>/.claude/worktrees/<stage>-hub-<n>`
  from `origin`'s default branch, print `MOVE <path>` with how to move (`EnterWorktree`, else
  `mcp__ccd_directory__change_directory`; Codex: the workdir) and the command to re-run, and exit 4 before anything is
  registered, journaled or locked; a clean worktree behind `origin` is fast-forwarded ("refreshed to origin/main abc1234").
  New `--repo PATH` names the project when the directory is not in one; the stage's project is remembered in
  `<stage>/stage.json`. Nothing that names a project exits 4 with `NO PROJECT:`; `--no-project` is for a stage that has no repository.
- **`agent spawn --worktree` branches from `origin`'s default branch**, after a bounded `git fetch`, not from the commit
  `--cwd` has checked out (a foreign feature branch in the owner's clone). New `--base REF` chooses another start
  (`--base HEAD`: the old behaviour); the "worktree … created" line names the base.
- **`hub takeover` stops the hub it replaces** when that is a background session that is not busy (`claude stop`,
  history kept, never `claude rm`) and says so in the output, the digest and the journal start line; a busy one, a
  Desktop session and a stop that failed are only named in one `ATTENTION:` line (a failing CLI is silent). A takeover by
  the registered hub's own number writes "re-took shift #N (replaces <id8>), handoff by #M" and keeps one link in a
  lock's reason instead of nesting every earlier takeover's.
- **`hub succeed --replace` swaps a successor that already took over.** It stops it (`claude stop`; a busy one only with
  `--force`) and starts a new one from the same handoff with the same number, model, mode and chain position; a takeover
  by hand of the shift the pending successor took over keeps the autopilot chain instead of resetting it (the record
  then names that session, kind `manual`, and `--replace` refuses to act on it).
- **`agent spawn --cwd` warns about a missing project folder.** An `ATTENTION:` line (never a refusal) when the
  directory is not inside a git repository, or the checkout has no `.agent-hub/` while the remote default branch
  (`origin/HEAD`, else `origin/main`) has it. (`hub start` and `hub takeover` relocate instead, see above.)
- The hub skill says how to reach another stage's hub: `@hub` or `@<stage>-hub-<N>` in its journal, or the session
  from `roles --stage <X> get hub`, never a session picked by name in `ListAgents`.

- **Pixel-art illustrations explain worker coordination and hub handoff.** The README shows distinct worker tasks
  feeding a shared journal; the handoff scene shows OLD HUB → FRESH HUB, with all continuing workers under the fresh hub.
  Original generation and owner-directed edit prompts, including the historical reference, are recorded beside the PNGs; the precise SVG remains in the reference.

- **A shorter starting page for humans and a task router for agents.** README now gives fit criteria and a small
  installation/start recipe. The agent guide routes installation assessment, operation and contribution separately;
  comparison, monitoring, installation and command/configuration detail remain available behind links.

## 0.8.2 — 2026-10-05

- **The agent-top pane has a button in the prompt footer.** The counts `agents ● 4 ✓ 9 ✗ 0` are now a Button beside the
  engine's mode labels (Claude Code terminal and Desktop): a press opens the pane, the next closes it. A bare `/agent-top`
  toggles the same way; with a role, `--stage` or `--all` it opens on that view. Where a surface without that footer looks
  on (a phone, VS Code) the counts stay the status line instead, never both.
- **The `agent-top` skill is removed.** The mod registers `/agent-top` itself and still answers `/agent-hub:agent-top`.
  Where mods do not draw (Codex, VS Code chat, `claude -p`, Remote Control and `claude --bg` views, Claude Code before
  2.1.287) there is no `/agent-top` any more: the console `agent-top` / `agent-top --once` in a shell shows the same.
  The chat-widget demo files are gone; `agent-top --widget` stays for scripts.
- **The agent card fits a pane 23–25 columns wide:** its Feed rows took a column more than the body at 24.
- **`tests/run_all.sh` prints what failed:** for each failing script its `FAIL` lines with the detail under them and the last 20
  log lines, so a CI run shows the failed checks without downloading the logs. The pty scenarios of `t_agent_top` wait until
  the screen stops changing instead of fixed pauses, which flaked on a loaded machine.

## 0.8.1 — 2026-10-05

- **`jwait` prints its `waiting for …` line after the baseline read of the journal**, so the line means "armed": whatever is
  written after it is news. A script that starts the writer once it sees that line no longer loses a line to a slow start
  (`t_jwait` flaked under the parallel test run that way).
- **The hub skill grills before it plans.** First-commands step 3 now reads in order: the `grilling` skill (by hand when it is
  not installed), `ask add`/`ask close` for each answer, then the plan and the owner's yes.
- **`ask plan` records the plan the owner approved** (kind `P-…`, status `approved`; not an unresolved entry). `agent
  spawn` prints one warning line, never a refusal, while its stage has none (the implicit `default` stage is exempt).
- **`ask add|decided|plan --print-id`** prints only the new id, so a script can capture it.
- **`lock take` guards the repository you run in.** Without `--repo`, `AGENT_HUB_DEFAULT_REPO` or `.agent-hub/config.json`
  the lock took the repository `*` and held up merges everywhere; now it takes the enclosing git repository's name (a
  worktree resolves to its main repository, the way the board hook reads it). `*` only with an explicit `--repo '*'` or
  outside any git checkout. The name is the checkout directory's; give `--repo` when the remote's differs. `hub takeover
  --take-main-merge` follows the same default.
- **The PATH shadow check knows a dispatcher.** A command that resolves into an installed agent-hub plugin's `bin/` (the
  Claude or Codex plugin cache, a marketplace folder; not an older copy than the running plugin), or into a file carrying the line `# agent-hub: dispatcher` among its
  first ten lines (symlinks followed), is no longer reported as a foreign tool; GitHub CLI's `hub` still is.
- **Every `hub` subcommand takes `--stage`** (default `$HUB_STAGE`); `hub reviewer --stage S` puts it into the `agent spawn`
  line it prints.
- **Claude Code 2.1.287 is the minimum** (was 2.1.285): `agent spawn` and `hub start` warn below it. Older versions are
  unsupported.
- **Review brief:** a read-only reviewer returns the review as its final answer and the caller saves it; the brief lists
  the author's test commands with their exit codes and asks the reviewer not to rerun them unless a finding needs it.
- **`jwait --until` takes seconds:** `HH:MM:SS` and ISO `YYYY-MM-DDTHH:MM:SS` next to `HH:MM` (unchanged: the start of that
  minute, a past time means tomorrow).
- **The test suite runs in parallel:** `tests/run_all.sh` runs the `t_*.sh` scripts concurrently (`TEST_JOBS`, default twice
  the CPU count, at least 8), each with its own `HOME`, `AGENT_HUB_HOME` and `TMPDIR`, and prints the summaries in sorted order; CI wall time
  drops from about 5.5 minutes to about 1.5 (a laptop: 7 minutes to 1).
- **`hub succeed --effort`** (`low`…`max`) and `AGENT_HUB_SUCCESSOR_EFFORT`: the automatic successor starts with an explicit
  effort (default `high`; it used to get the CLI default, medium) — in `claude --bg`, in the headless fallback and in the
  command the context-budget message prints. Codex successors keep inheriting the hub's effort; `--effort` overrides it.
- `AGENTS.md` at the repository root (Claude Code reads it through `.claude/CLAUDE.md`): how to run the tests and where things live.
- **The agent-top pane is redrawn as a mod, not a text dump** (`hooks/agent-top-view.tsx`): a `❯` cursor that follows
  the pane's focus ring (↑/↓, Enter opens the card) over a list windowed to the pane's height, two lines per agent with
  a filled state badge; tabs with the active one filled and the stage and time on the right; a rounded cyan frame when
  docked, the card framed in its state's colour, framed Summary sections (no frames above the prompt or below 44
  columns); label/value columns in the card and fixed time/tool columns in the feed; `█░` bars for plan limits and the
  context, coloured by level. `bin/agent-top --json` gains `ctx_window` per agent: the window the log reported (the
  result's `modelUsage`, Codex's rollout), else by model id, else 200k.

## 0.8.0 — 2026-10-04

Codex support and agent-top as a Claude Code mod: one file protocol for Claude and Codex hubs and executors, and a
live agents pane inside Claude Code.

- Support Claude Code and Codex coordinators and detached executors in one file protocol.
  Select `--engine`; raw Codex JSONL, assigned thread IDs, resume, inbox replay and process-group stop are supported.
- Port unattended full access: `bypassPermissions` maps to Codex approval/sandbox bypass;
  restricted workers retain their sandbox, network and temporary-directory settings on resume.
  Hook trust is a separate explicit policy; full access retains the bundled guards.
- Add Codex plugin packaging, native worker configuration resources, shared skills and installation guidance.
- Port lifecycle guards, apply_patch handoff checks, context-window budgets, monitoring and headless autopilot.
  Keep cumulative usage separate from context size and do not invent costs or model metadata.
- Add lifecycle/permission/installation controls and Linux/macOS CI.
- **agent-top inside Claude Code as a mod** (needs Claude Code ≥ 2.1.287, the minimum supported version).
  `hooks/hooks.json` gains `"modules": ["./agent-top.tsx"]` beside the unchanged settings hooks. `/agent-top [role]
  [--stage S] [--all]` opens a read-only pane (Agents, agent card with a live feed, Journal, Summary with locks, owner
  questions and Claude/Codex plan limits), refreshed every 3 s while open; a status line `agents ● 2 ✓ 5 ✗ 1`; toasts
  when an agent finishes, fails or dies and when a new owner question opens (never on a session's first look). Data comes
  only from `bin/agent-top --json`; nothing is written. The `agent-top` skill stays the fallback for Codex, VS Code chat
  and `claude -p`, and now says so. Tests: `hooks/agent-top.test.tsx` (`claude plugin test .`) and `tests/t_mod.sh`.

## 0.7.1 — 2026-10-02

Autopilot fixes: the successor hub no longer lives in a directory that can disappear under it, and legacy `хаб-N`
tags number the chain correctly.

- **The autopilot successor starts in its own worktree, from the main checkout.** `hub succeed` starts `claude --bg`
  from the main checkout of the hub's directory with `--worktree <stage>-hub-<n>` (`<main checkout>/.claude/worktrees/`,
  branch `worktree-<stage>-hub-<n>`), the way a Claude Desktop session does; the headless fallback runs
  `agent spawn --cwd <main checkout> --worktree <stage>-hub-<n>`. Before, the successor started in the hub's own
  directory — for a hub in a Desktop session, that session's worktree, which Desktop removes when it archives the
  session, taking the live hub's directory with it. A taken name gets `-2`, `-3`… (`claude --bg --worktree` with a
  taken name joins the existing worktree instead of failing, launch modes E26). The journal line names the root and the
  worktree. An untrusted main checkout now falls back to the headless hub instead of retrying elsewhere. Outside git:
  unchanged, in the hub's directory.
- **Legacy hub tags count.** The hub's number is read from any roles tag ending in `-N` (`hub-N`, a legacy `хаб-N`).
  Before, `хаб-25` read as no number, so `hub succeed` took the successor number of the latest handoff (26) as its own,
  named its successor #27 while the takeover registered #26, and the chain was reset as a takeover by hand. `hub succeed`
  now takes its number from the registry, else from the outgoing number of `--handoff`; the successor's number comes
  from the function `hub takeover` numbers by; and a takeover with `--auto-handoff` takes the pending successor's number.
- Docs: the hub itself must run in bypass mode, not only its agents — `auto` refuses merges and pushes, `default` and
  `acceptEdits` wait on every tool call (README § Install, getting-started "Ignoring the permissions mode").
- Tests: `tests/lib.sh` also unsets `AGENT_SESSION_ID`, so the suite passes when run from an `agent spawn` session.

## 0.7.0 — 2026-10-01

The hub's files move out of `~/.claude`, which Claude Code protects, and where they live becomes a setting. The
default changes to `~/agent-hub`; an existing `~/.claude/agent-hub` keeps working with a warning until
`hub home migrate --apply` moves it.

- **The hub home is a setting.** Resolved in this order: `AGENT_HUB_HOME` in the environment (any path); a repository's
  `.agent-hub/config.json` key `AGENT_HUB_HOME`, only `"project"` (`<main checkout>/.agent-hub/local/`, shared by all
  worktrees of the repository, added once to `.git/info/exclude`; `git clean -fdx` deletes it) or `"user"` — any other
  value is ignored with a one-line warning, a cloned repository must not choose paths the tools write to; the user
  default. A user sets another default with `{"env": {"AGENT_HUB_HOME": "…"}}` in their Claude Code settings, or in the
  shell. README § Where the hub's files live.
- **The default is `~/agent-hub`**, not `~/.claude/agent-hub`. Claude Code treats `.claude` as a protected directory
  ([permission modes § Protected paths](https://code.claude.com/docs/en/permission-modes.md)): a Write or Edit there is
  prompted in `default` and `acceptEdits`, routed to the classifier in `auto`, denied in `dontAsk`, and
  `permissions.allow` rules cannot pre-approve it; only `bypassPermissions` passes. The Bash sandbox
  ([§ Protected paths](https://code.claude.com/docs/en/sandboxing.md)) denies writes to most of `~/.claude` with no
  `allowWrite` exemption, so under `/sandbox` `jlog`, `ask` and `hub` could not write at all. A plain directory granted
  with `--add-dir`, `/add-dir` or `permissions.additionalDirectories` is writable by the sandbox and needs no prompt for
  edits in `acceptEdits`.
- **The legacy home still works, with a warning.** While `~/agent-hub` does not exist and `~/.claude/agent-hub` does, the
  legacy home is used and the SessionStart hook, `hub start` (an ATTENTION line) and `hub home` say so.
- **`hub home [--cwd DIR] [--json]`** prints the resolved home, the layer that chose it, whether it is under a `.claude`
  directory (then it points to `hub home migrate`) and the grant lines: `/add-dir <home>`,
  `{"permissions": {"additionalDirectories": ["<home>"]}}` for `~/.claude/settings.json`, `claude --add-dir <home>`.
- **`hub home migrate [--from DIR] [--to DIR] [--apply]`** moves the legacy home (default `--from`) to the resolved one.
  A dry run by default (files, bytes, JSON files to rewrite; exits 1 when `--apply` would refuse). `--apply` refuses
  while any agent of any stage of the source is alive or a background hub of one of its stages runs, and when a source
  path already exists in the target; it copies into a staging directory (modes kept), verifies the count and the bytes,
  moves the copy into place only then (a failed copy leaves nothing at the target), rewrites the old absolute path in every `*.json` under the new home
  (roles, agents' meta, `.jwait-state`, `.state`, autopilot state), leaves the `.md` history as written and renames the
  source to `<source>.migrated-YYYYMMDD`. It never deletes; a second run says there is nothing to migrate.
- **Hooks resolve the home for the session's directory** (the hook input's `cwd`); the tools for their working
  directory.
- **Children are pinned to the parent's home.** `agent spawn`, a resume (`agent send` to a finished agent), the autopilot
  successor (`claude --bg`) and the headless successor get `AGENT_HUB_HOME=<the parent's resolved home>` and
  `--add-dir <home>` when the home is not under the agent's directory (the successor also keeps the
  `additionalDirectories` of its `--settings`), so a child never writes to another home than its parent.
- **A stage in another home is an error, not a silent split.** A stage that is not in the resolved home but exists in
  `~/agent-hub` or the legacy home makes the tools refuse, naming where it is: migrate the legacy home (or `mv` that one
  stage when the home is another one), set `AGENT_HUB_HOME` to that place, or `mkdir -p <home>/<stage>` to start afresh.
- **`AGENT_SESSION_ID` is stripped from the autopilot successor's environment** (a review follow-up of #13): a headless
  hub's own id, inherited, would make the successor's `hub takeover --session self` name the old hub.

## 0.6.0 — 2026-10-01

The hub can hand its shift to a successor by itself (autopilot, off by default), agents run on the latest models
through the CLI, and a newcomer's first message loads the hub skill. Two newcomer tests (a Haiku hub and a Sonnet 5.5
hub) drove the first two groups.

A newcomer test showed that a smaller model given "Use the agent-hub hub skill. …" never loaded the `hub` skill and
wrote the code itself, while a first message starting with `/agent-hub:hub` loaded it. The first group of changes below
is docs and skill text only.

- **The first message starts with `/agent-hub:hub`** in `docs/getting-started.md` (step 1, the takeover line, the
  sample session) and the README Quickstart, with the reason: the slash command always loads the skill, a
  plain-language mention may be ignored by a smaller model.
- **Getting started says what you should see** after the first message: the stage start line (`hub-1`) and a round of
  questions Q1, Q2 … each with a recommendation; if they are missing, the skill did not load.
- **Setup may be skipped in a new, empty project** (getting-started and README say so; the hub offers
  `agent-hub:setup` when it is needed). The README names the order: install, first message, setup per repository.
- **The `hub` skill describes more triggers**: the user mentions agent-hub or "the hub skill", or asks to plan work for
  agents or to run work through agents.
- **The `hub` skill opens with "First commands"**: `hub start`, `ask search`, one round of questions with a
  recommendation each, then a plan; no code and no agents before the owner approves it.
- **Grilling a non-technical owner** now has a mandatory question, "How will you open the result, and where should it
  live?", with a recommendation for a static site (GitHub Pages or an Artifact) over a server on the owner's machine.
- **Background processes.** The hub skill (§ Executors) and the executor brief template tell an executor to list the
  servers and watchers it started in its report and stop them before DONE; at handoff the hub checks for listening
  ports left by the project (`lsof -iTCP -sTCP:LISTEN`).
- **Writing into another stage's journal** takes your own tag, not `hub`: that stage's `jwait --tag hub` treats `hub`
  lines as its own and does not wake.

A second newcomer test took a Sonnet 5.5 hub through the whole flow (grilling, `hub start`, an agent in a worktree, an
Opus review, a fix round, a merge). It found agents running on old models, tools shadowed by same-named commands, and
a hub that talked the owner out of using agents.

- **Agents run on the latest models by default, through the CLI.** An alias (`opus`, `sonnet`, `haiku`, `fable`) is
  resolved by the Claude Code CLI; the plugin pins no ids (they go stale with the next model release), and
  `AGENT_HUB_MODEL_MAP` stays an opt-in pin. Claude Code 2.1.285 resolves them to `claude-sonnet-5-5`,
  `claude-opus-5-5`, `claude-haiku-4-5-20251001` and `claude-fable-5-1`; 2.1.274 resolved `sonnet` to `claude-sonnet-5`.
  - Without `CLAUDE_BIN`, `agent spawn` starts the newer of `claude` on `PATH` and the CLI bundled with Claude Desktop
    (a tie or an unreadable version keeps `PATH`) and prints which one it took and why.
  - The model id the run reports in its init event is recorded in the agent's meta (`resolved_model`) and shown by the
    `started headless agent` journal line (`claude-sonnet-5-5/high, asked for sonnet`), `agent status`, and `agent-top`
    (screen, `--once`, the widget, `--json` as `model_id`): `sonnet-5-5`, not `sonnet`.
  - `agent spawn` and `hub start` warn once when the CLI is older than 2.1.285: update Claude Code, an older CLI
    resolves the aliases to older models. The version is read from the `<version> (Claude Code)` line of
    `claude --version` (a shim's other lines are ignored), with a 5 s limit, and remembered by path, size and
    modification time in `<hub home>/.state/cli-version/`; `hub start --dry-run` writes nothing.
  - `fable` is accepted wherever `opus`, `sonnet` and `haiku` are: `agent spawn --model`, `hub reviewer`
    (`AGENT_HUB_REVIEW_MODEL`, a reviewer's `model`), the effort rules, the docs.
- **Tool isolation.** An agent's brief footer names `jlog` as `"$HUB_BIN/jlog"`: a shell may put an old `jlog` ahead of
  the plugin's, and its `DONE` would go to a journal the hub never reads. `HUB_BIN` is the plugin's `bin/`, exported in
  the agent's environment and rebuilt at every spawn and resume, so a resumed agent follows a plugin update (a path
  written into the brief would point into a version directory that is removed later). The agent already started with the
  plugin's `bin/` first on its `PATH`; a test now holds that. `hub start` and a new SessionStart hook
  (`hooks/path_shadow.py`) warn once when any command of the plugin (every executable in its `bin/`) resolves outside
  it, naming the path and the fix. The hook does nothing until a hub home exists, then speaks every time inside the
  hub's scope and once per distinct set of paths elsewhere. The usual cause is GitHub CLI `hub` from Homebrew (README).
- **`agent send` signs its journal line with the caller's tag**: `HUB_TAG`, else the roles-registry entry of the calling
  session (the hub keeps `hub-<N>`), else `cli`; it was `hub` for everyone, so a hub did not recognise a line written by
  someone else and a newcomer was alarmed.
- **Turns per run.** `agent status` and `agent-top` show the last run's turns next to the total once an agent was resumed
  (`turns 31 (total 60)`; `31/60` in the agent-top list), and so does the `EXIT` line.
- **`agent spawn --worktree` in a repository with no commits** fails with "the repository has no commits yet — make a
  first commit" and leaves nothing behind (it used to fail inside `git worktree add`). The check applies only where a
  new branch is made from `HEAD`: an existing branch works beside an unborn `HEAD`. The hub skill makes the first
  commit itself and says so in one line.
- **The `hub` skill, § Planning and § Choosing how to launch work:** the owner is asked nothing about process (agents or
  not, worktrees, commits); the hub picks the launch by the section's criteria and, when it writes a small change itself,
  says so in one line with the reason and records `ask decided`. Questions to the owner are in the owner's words; purely
  technical choices (canvas, localStorage, branch names) are the hub's, recorded with `ask decided` so they stay
  contestable. For a non-technical owner the hub opens the result (`open <path>`) or gives a `file://` link, never a
  long hidden path. Getting started: "A small change the hub may make itself; say 'through agents' if you want
  otherwise" and a short "A new, empty project" section that also holds the setup-skip sentence.
- **Limitations.** In `claude -p` the hub's background Bash `jwait` is killed when the turn ends;
  `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` keeps background sub-agents alive, not background Bash tasks, so a headless hub
  learns about `DONE` only from its next message (README, `docs/launch-modes.md`, getting started).

### Autopilot: the hub hands its shift to a background successor

- **`AGENT_HUB_AUTO_HANDOFF=on`** (hub home only, default off; `agent-hub:setup` asks). At the context budget's warn
  threshold a stage hub is told to hand over at its next quiet point — `hub handoff`, fill the TODOs, `hub succeed`
  with its model, permission mode and directory filled in by the hook. At the block threshold the hub is told to hand
  over now: Bash, Write, Edit and NotebookEdit are denied too — Bash passes only when every command of the line is
  `hub handoff`, `hub succeed`, `jlog` or `jwait`, a file tool only on a HANDOFF file. Without the setting nothing
  changes.
- **`hub succeed`** starts the successor as `claude --bg --remote-control <stage>-hub-<n+1>` with the prompt
  `/agent-hub:hub take over stage … [agent-hub auto-handoff k/N]`, journals its id, Remote Control link and
  `claude attach <id>`, and prints the `jwait` that waits for the successor's start line
  (`AGENT_HUB_SUCCESSOR_TIMEOUT`, 600 s). Fallbacks, each journaled with its reason: bypass mode without the accepted
  disclaimer → `auto` (`acceptEdits` for Haiku); an untrusted worktree → the main checkout once; the CLI not logged in
  or the directory still untrusted → a headless hub via `agent spawn`; no takeover by the deadline →
  `hub succeed --fallback` (log tail journaled, the session stopped, a headless hub started).
- **One successor per shift**: `hub succeed` reserves the shift under a lock before anything starts, so a retry or a
  parallel call is refused; only the registered hub may run it; the successor's `hub takeover --auto-handoff` keeps
  the chain.
- **No stuck shift** (review round 2): `hub succeed --fallback` reserves under the lock too, and an `agent spawn`
  "already running" counts as the successor being there; a reservation blocks for the start budget (4 min) only, and
  every refusal prints the retry time and a ready `jwait`; `hub succeed --again` drops the record of a successor that
  did not take over and is not running, and the owner's prompt drops it after the takeover timeout; `hub succeed`
  refuses (exit 2) with autopilot off, `--force` for the owner; a hung `claude --bg` takes only a session started
  since, and stops a late one; `agent spawn` exports `AGENT_SESSION_ID`, which `--session self` falls back to;
  `--fallback` re-reads the registry before it stops the session; the block escape allows output only to
  `/dev/null`, a descriptor or a HANDOFF file.
- **Chain limit** `AGENT_HUB_AUTO_HANDOFF_CHAIN` (10): at the limit the hub writes its handoff, starts no successor and
  waits for the owner. The owner's own prompt in the hub's session, or a takeover started by hand, resets it.
- **A successor not in bypass mode** starts with the hub's own commands and the hub home allowed (`--settings`), so
  its takeover needs no prompt; everything else asks and the owner answers over Remote Control (smoke test: in the
  default mode it stopped at the takeover's permission prompt before this).
- **`hub takeover --session self`** reads `$CLAUDE_CODE_SESSION_ID` itself: a command with a shell expansion asks for
  permission even under an allow rule.
- **The successor runs on the newest CLI** (`find_claude`: `$CLAUDE_BIN`, else the newer of `claude` on PATH and
  Claude Desktop's; an old CLI is named in the journal line), and every command autopilot writes — the successor's
  takeover, the hook's `hub handoff` / `hub succeed`, the printed `jwait` — calls the plugin's tool by absolute path:
  a same-named `hub` earlier on PATH cannot answer, and the line holds no expansion an allow rule would not match.
- Settings `AGENT_HUB_SUCCESSOR_MODEL` and `AGENT_HUB_SUCCESSOR_PERMISSION_MODE` (default: the hub's own).
  `docs/launch-modes.md` gains E20–E25 (`claude --bg --remote-control` and its failure modes).

## 0.5.0 — 2026-10-01

Reviewers become a setting, the launch choice rests on what is visible before the start instead of an estimated
duration, and the polling guard stops denying quoted text that no shell runs (`git commit -m "… sleep 5m …"`,
`grep "sleep 5m"`) while catching more ways of feeding a loop to a shell.

- **Configurable reviewers.** New setting `AGENT_HUB_REVIEWERS` (environment, a repository's `.agent-hub/config.json`
  or the hub home's): an ordered JSON list, the first available entry wins. An entry is an `agent` (an ordinary
  `agent spawn`, model and effort from the new `AGENT_HUB_REVIEW_MODEL` / `AGENT_HUB_REVIEW_EFFORT`, default
  `opus` / `high`) or a `skill` (a reviewer skill the user plugs in), with an optional `check` command (exit 0 =
  available now, 10 s timeout, run in the hub home), `until` date and `for` change classes. A `check` from a
  repository's config is never run — the entry is skipped with a warning (the refusal covers the hub's own config
  files; a trusted repository's `.claude/settings.json` `env` block can still set the list). `name`, `skill`
  (`plugin:skill` allowed), `model`, `effort` and the change classes must match strict patterns from every layer, and
  every value of the printed `agent spawn` line is shell-quoted, so a repository's config cannot put commands or
  instructions into what the hub runs or reads. A broken entry is reported and skipped; a list with no valid entry gives
  the built-in default, one `agent` reviewer. The hub skill and `docs/launch-modes.md` no longer route reviews to a
  cloud session: a review is `hub reviewer`, and a cloud service is a reviewer skill if the user has one.
- **`agent spawn --model` is validated more strictly**, by the rule `hub reviewer` shares with it: `opus`, `sonnet`,
  `haiku`, an alias of `AGENT_HUB_MODEL_MAP`, or a full id `claude-…` made of letters, digits and `. _ : @ [ ] -` (a
  Vertex id `claude-sonnet-4-5@20250929` is fine) (it used to take anything starting with `claude-`). A mapped value
  of `AGENT_HUB_MODEL_MAP` must be a model id of the same characters plus `/` (a Bedrock id or an ARN is fine); a pair
  outside that is reported and left out. `--json` no longer repeats a `check` that was not run, and echoed keys and
  values are cut to 30 characters.
- **`hub reviewer [--for CLASS] [--json] [--all]`** walks the list and prints the chosen reviewer and exactly how to
  start it (the full `agent spawn` line with `<REPO>` / `<BRIEF>` placeholders and no `--worktree`, or "load skill …");
  `--all` lists every entry with why it was skipped; exit 1 when none is available.
- **`templates/brief-review.md`** (a self-contained review brief with a round-N variant) and **`docs/reviewers.md`**
  (the config, the choice order, the change classes `docs` / `code` / `risky`, the skill reviewer contract, how to
  write one). New recommended hub rules: a change gets the review its class says, and the reviewer is a different
  model from the author.
- **Launch choice by observable criteria.** The hub skill's "Choosing how to launch work" and the decision table of
  `docs/launch-modes.md` choose by what the work does: read-only with a short digest and nothing external to wait on
  is a sub-agent (foreground when the hub has nothing else to do, else background); anything that commits or pushes,
  waits on CI / a deploy / another party, touches production or must be reachable by someone else is `agent spawn`;
  estimated duration is a hint only. Every sub-agent brief ends with a call budget (a recommended N in the skill).
- **`hub handoff` guard.** Before writing the draft it looks for live sub-agents of the hub's own session
  (`--session`, else the registered hub's and the calling session when it is another one); if any runs it exits 2 and
  lists them (id, description, age) with the three ways out. `--allow-live-subagents` goes on and writes them into the
  draft's TODO. The discovery and state logic `agent-top` used for sub-agents moved to the shared `bin/subagents.py`;
  `agent-top` behaves as before.
- **`jwait` default `--for` is now 2h** (was 12h): a background Bash task is not guaranteed to live longer. The hub
  skill also says to add `--exclude-tag <hub tag>` when `jwait` is called with `--caller <session id>` instead of as
  the hub's tag, or the hub's own `@agent` messages wake it.
- **Polling guard: quoted text is data until a shell runs it.** Since 0.4.0 `git commit -m "… sleep 5m …"`,
  `grep "sleep 5m"` and the body of a `gh api` call were denied: a quote counted as the start of a command, so any
  quoted `sleep` or `while` looked like a wait (and `sleep 5m` now reads as 300 s). The guard now looks inside a quoted
  string only when a shell executes it — the argument of `bash|sh|zsh|dash|ksh -c` (also after `timeout`, `env`, `sudo`,
  `time`, or in `xargs sh -c`), of `eval` or `ssh`, a here-string to a shell, the text of `echo` / `printf` / `cat`
  piped to a shell, and `$(…)` inside double quotes. Every other quoted argument is data, and a `;` or `|` inside it no
  longer splits the command. **Not denied any more**, on purpose — 0.4.0 denied these only because every quote
  counted as a command: the `-c` / `-e` strings of interpreters (`python3 -c "import os; os.system('sleep 300')"`,
  `perl -e 'sleep 300'`, `node -e "execSync('sleep 300')"`) and the forms the guard does not look into, being no shell
  parser — `bash -c "$(echo '…')"`, `eval "$(…)"`, `bash <(echo '…')`, `VAR='until …'; bash -c "$VAR"`,
  `echo '…' > w.sh && bash w.sh`. Every other deny of 0.4.0 stays.
- Polling guard, CI-status rules: a quoted string is read only in a `gh` / `glab` command (it carries the API path), so
  `git commit -m 'ci: wrap gh run view in a script'` and `grep 'gh run view' f` are no longer reads of CI status; the text
  of a `gh` / `glab` call's own arguments (`gh issue comment 1 --body 'gh run view'`) still is.
- Polling guard, text fed to a shell: "fed" is decided per pipeline, not for the whole command; `xargs` counts only
  with `sh -c` (`echo "sleep 5m" | xargs echo` is not a wait); a shell behind a wrapper with flags (`sudo -u app bash`,
  `sudo -E bash`, `/usr/bin/env bash`, `time bash`), a heredoc that reaches a shell through an intermediate stage
  (`cat <<EOF | tee f | bash`), a line continuation or a trailing `|` before the shell, `(echo '…') | bash`, a shell
  word glued from several strings (`bash -c 'until … '"$F"' …'`) and shell options before `-c` (`bash -eo pipefail -c`,
  `bash -c --`), a here-string glued to `<<<` (`bash <<<'…'`), printing grouped in `( … )` or `{ …; }` and piped to a
  shell, a group around the consumer (`(bash <<< '…')`, `| (bash)`), blank lines after a `|`, the wrappers `setsid`,
  `command`, `nice`, `ionice`, `stdbuf`, `doas`, `timeout` with flags, and stdin shells behind `ssh host`, `su`,
  `sudo -i|-s` and `. /dev/stdin` are caught; `\$(…)` in double quotes is a literal, and a here-string is no longer
  read as a heredoc.
- Polling guard: only the 300 characters before a quoted string are read to decide whether it runs, so a command with
  tens of thousands of strings is judged in well under a second.

## 0.4.0 — 2026-10-01

A shape for teams other than the author's — generic lock resources, a setup flow, a first-hub start, the author's
hub rules kept as recommended defaults a project can override — and background sub-agents in the hub's toolbox.
**Breaking:** `deploy-window`, `stage` and `migration-head` are no longer built-in lock resources; a project that
uses them declares them in its `lock-rules.json` (same names, no board migration).

- **Choosing how to launch work.** `docs/launch-modes.md` and a section of the `hub` skill: when a piece of work is a
  foreground or background sub-agent of the hub, a headless agent, a cloud or a Desktop session, with defaults
  (~10 min / ~30 min) and the rule for a hub near its handoff threshold, backed by experiments with the CLI.
- `agent spawn` runs wait for their background sub-agents: `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` by default
  (the CLI kills them after 10 min otherwise); new setting `AGENT_HUB_BG_WAIT_CEILING_MS`.
- `agent-top` lists the sub-agents of the sessions in a stage's role registry, read-only, as `<role>/<id>`: state from
  the parent's transcript (completion notices; a foreground sub-agent's Agent-call result) and from whether the parent
  process runs (`~/.claude/sessions/<pid>.json`), current action, model and effort, feed from the sub-agent's
  transcript.
- **Locks on generic named resources.** Only `main-merge` is built in (merges into, and pushes to, the protected
  branches). Every other resource is named by the project in `lock-rules.json`, with an optional
  `"resources": {name: description}` object; when it is present, a rule naming an undeclared resource is refused (a
  typo is an error, not a lock nobody takes). `lock take` refuses a name that is not configured where it runs and
  lists the known ones; a name already on the board stays takeable (a handover); `lock release` takes any name; board
  records of any kind keep parsing. **Breaking:** `deploy-window`, `stage` and `migration-head` are no longer built
  in — a project that uses them declares them in its `lock-rules.json` (same names, no board migration).
- **`lock rules`**: `show [--json]` (resources and the commands each guards, here), `init` (writes
  `.agent-hub/lock-rules.json` and `config.json` with `AGENT_HUB_DEFAULT_REPO`), `add <resource> --about … [--match …
  --action …]` (validated before the file is replaced), `check "<command>" [--expect R | --expect-none]` (the real hook
  against a scratch board where every resource is held by someone else).
- **Skill `agent-hub:setup`**: asks which shared resources the project has and which commands touch each (numbered
  questions with recommended answers), writes the rules with `lock rules`, proves them with positive and negative
  checks. A project with no deployment ends with `main-merge` only.
- **`hub start --stage S --session ID`** registers the first hub of a new stage (stage directory, `hub-1`, start
  line, first `jwait`). `hub takeover` and `hub handoff` derive the shift number from `roles.json` and the latest
  handoff; `--n` is an override. The `jlog` "no tag" error says how the first hub registers.
- **`roles set`** infers the session kind from the id (`local_…` or a uuid Claude Desktop knows = desktop, any other
  uuid = cli) instead of defaulting to desktop.
- **`agent spawn --worktree [BRANCH]`** (default `agent/<role>`): an existing worktree of the branch is reused,
  otherwise `<repo>/.worktrees/<branch>` of the main repository, excluded in `.git/info/exclude`; `agent status` and
  `agent stop` name it.
- **Hook scope.** `handoff_size` and the SessionStart owner-questions line act only in the hub home, in repositories
  with `.agent-hub/`, under the new hub-wide `AGENT_HUB_SCOPE_DIRS`, and (questions) for hub agents. `board_locks`
  stays machine-wide: it acts only on protected-branch merges and pushes and on configured commands.
- **Hub skill**: "Starting a stage" first; a stated minimal mode (`agent` + `jlog` + `jwait`); the author's rules kept
  as recommended defaults with the reason for each, overridable in `hub-rules.md` (hub home → repository → stage,
  later wins; `templates/hub-rules-example.md`); the handoff threshold stated relative to the context window; night
  queue, night nudge and send budget marked as optional macOS + Claude Desktop modules; status words defined.
- A linked worktree without its own `.agent-hub/` uses the main checkout's (lock rules, config, brief footer, hub
  rules): an agent's `--worktree` no longer silently loses the repository's guards. `lock rules init` from a worktree
  configures the main checkout; `lock rules add` extends a file without `resources` by declaring the names its rules
  use; a relative `AGENT_HUB_SCOPE_DIRS` entry is ignored with a warning.
- **Templates**: a short `brief-executor-template.md`; the previous one is `brief-executor-advanced.md`. The handoff
  draft marks the night-queue section optional and points at worktrees to clean up.

## 0.3.0 — 2026-10-01

Agent discipline: the hooks that keep long agent work cheap ship with the plugin, every rule configurable.

- **Context budget** (`hooks/context_budget.py`, on by default): measures the session's context from its transcript
  (a subagent from its own), warns once per step above `AGENT_HUB_CONTEXT_WARN` and points at `agent-hub:handoff`;
  above `AGENT_HUB_CONTEXT_BLOCK` denies the tools in `AGENT_HUB_CONTEXT_BLOCK_TOOLS` unless the call hands work over
  (`AGENT_HUB_CONTEXT_ESCAPE`: a `HANDOFF-*.md` path or `handoff-ok`).
- **Polling guard** (`hooks/polling_guard.py`, on by default, switchable per repository): denies foreground wait loops
  (also inside `bash -c "…"` and text fed to a shell), long bare `sleep` (with `s/m/h/d` units), self-matching `pgrep -f`, and one-off CI status reads from configurable `gh`/`glab` pattern lists
  (`AGENT_HUB_CI_STATUS_DENY` / `_ALLOW`; logs, traces, write calls incl. `-f`/`--field` and a pipeline lookup by sha
  pass; a list whose every pattern is broken falls back to the defaults). Background
  commands, printed text and heredocs are exempt; `# poll-ok: <reason>` passes deliberately. The message names
  `run_in_background`, `jwait` and the project's own wait command (`AGENT_HUB_WAIT_HINT`). Every `jwait` form the hub
  prints passes it (tested, including extra wake words).
- **Delegation dial** (`hooks/delegation.py`, `/delegation` skill, `delegation` CLI; off by default): levels 0-5 per
  session, globally or from the environment; policy text per level from `AGENT_HUB_DELEGATION_LEVELS`; level rules
  from `AGENT_HUB_DELEGATION_RULES` (default: level 0 denies `Agent`, `Task`, `Workflow`).
- **Subagent effort rules** (`AGENT_HUB_EFFORT_RULES`, `bin/subagent_rules.py`): one rule format for the in-session
  `Agent`/`Task` tool and for `agent spawn` (refused with exit 2, the rule named); a shorthand `{"model": "high|xhigh"}`;
  agent definitions are found in the project, `~/.claude/agents` and installed plugins (`agent-hub:worker-high`).
  No model name is built in; `docs/examples/subagent-policy.json` is a complete example.
- Effort rules are read from the user (environment, else hub home) **and** the repository; each set is evaluated on its
  own and any deny wins, so a repository can only add restrictions.
- **Worker subagents** `agent-hub:worker-low|medium|high|xhigh`: pinned effort, model chosen per call.
- `config.json` accepts JSON lists and objects for the list-valued settings; `hubcore.setting_json`.

## 0.2.0 — 2026-10-01

Project configuration: a team's own conventions live in its repository, not in a fork of the plugin.

- **Configuration layers.** The same files are read from `<hub home>/<stage>/`, `<repo>/.agent-hub/` (found from the
  working directory up to the git root) and `<hub home>/`:
  - `config.json` — defaults for the existing settings (`AGENT_HUB_MODEL_MAP`, `AGENT_HUB_DEFAULT_EFFORT`,
    `AGENT_HUB_PERMISSION_MODE`, `CLAUDE_BIN`, `AGENT_INIT_TIMEOUT`, new `AGENT_HUB_DEFAULT_REPO`; hub-wide
    `AGENT_HUB_TZ`, `AGENT_HUB_SEND_CAP`, `AGENT_HUB_NIGHT`, `AGENT_HUB_HANDOFF_MAX_BYTES` from the hub home only).
    Environment variables still win. Unknown keys and broken files are reported on stderr and ignored.
  - `lock-rules.json` — the repository's rules apply to commands run in it (cwd, `cd`, `git -C`), together with the
    hub home's.
  - `brief-footer.md` — appended to the footer of every brief of an agent spawned in that repository.
  - `handoff-facts.sh` — now also found in the repository and the hub home, not only in the stage directory.
  - `takeover.sh` — a project step of `hub takeover`, run as `check` / `apply` and verified like the built-in steps.
- `agent spawn` takes model map, effort, permission mode and CLI settings from the agent's `--cwd` repository.
- `lock take/release --repo` defaults to `AGENT_HUB_DEFAULT_REPO` (else `*`).
- `hub takeover` looks at the `main-merge` lock of every repository: `--take-main-merge` takes the hub repository's,
  the others are reported (0.1.0 looked only at the first one found).
- Review hardening:
  - The lock hook no longer goes quiet on a broken `lock-rules.json`: the file (bad JSON, a bad regex, `kinds` that
    is not a non-empty list of known kinds, a symlink to a missing file, a missing `$AGENT_HUB_LOCK_RULES`) is skipped
    with a warning on stderr and to the user on every command, and the built-in merge guards and the other file
    keep applying. Before, any such error made the hook fail open for every rule, built-ins included.
  - `AGENT_HUB_SEND_CAP` is read when used; a bad value is reported and replaced by 10 instead of breaking every
    tool (and both hooks) at import. `AGENT_HUB_HANDOFF_MAX_BYTES` likewise warns.
  - `hub takeover --take-main-merge` run outside the hub repository no longer adds a second, wildcard `main-merge`
    next to the one taken over from the previous hub (that lock refused merges in every other repository).
  - `lock release` without `--repo`, run from another directory, finds this session's only lock of that kind;
    with several it names them and exits 1.
  - Takeover: a main-merge the previous hub held in another repository no longer hides the hub repository's free
    one; a main-merge that was wanted but could not be taken is reported. `AGENT_HUB_TAKE_MAIN_MERGE` accepts a JSON
    boolean.
  - `hub takeover` says when it finds no `takeover.sh` in the config layers of its working directory.
- New settings: `AGENT_HUB_TAKE_MAIN_MERGE` (repository: takeover takes the hub repository's main-merge by default;
  without it a free main-merge of a configured hub repository is reported in the digest), `AGENT_HUB_JWAIT_MATCH`
  (hub-wide: extra wake words for the digest's `jwait` and for an agent's status word), `CLAUDE_BIN=desktop` (the
  newest CLI bundled with Claude Desktop, following Desktop updates).
- `HUB-NOTES.md` in the config layers: the team's own hub rules; the takeover digest points at it and the `hub`
  skill reads it before planning. The skill also states that the journal is append-only.
- Night nudge prompt: loads the deferred session tools, takes the time from `date`, calls `nightq` by absolute path.
- Night queue: `request_keep_awake` before `caffeinate`. `hub` skill: the `AWAITING ANSWER` wait pattern, the
  production-script rule, a fixed handoff threshold, a "Project configuration" section. Board and night-queue texts no
  longer claim that `deploy-window` holds merges.

## 0.1.0 — 2026-09-30

First public release.

- `agent spawn / status / send / stop`: detached headless `claude -p` agents with a brief, an inbox, resume after
  exit with unread-message replay, an `EXIT` journal line for runs that end without a status word.
- `jlog` and `jwait`: the stage journal and the single background waiter (journal and file sources, filters,
  `--since` replay, alarms).
- `roles`: role registry by full session id (Claude Desktop, headless and terminal sessions), send budget, broadcast.
- `ask`: owner-question register with default actions, due times, answers, agents' decisions and execution evidence.
- `lock` and the `board_locks` hook: a lock board for merges to main, deploy windows and shared environments, with
  custom rules in `lock-rules.json`.
- `hub takeover / handoff`: one-command hub shift handover.
- `nightq`: a night queue with a permission matrix; optional night-nudge task template.
- `agent-top`: curses console, `--once`, `--json` and the `--widget` HTML for the `/agent-top` chat skill.
- Skills: `hub`, `handoff`, `agent-top`. Hooks: lock guard, owner-question summary at session start, handoff size cap.

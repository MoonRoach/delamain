# Stage lifecycle: files, starting, taking over, leaving, waiting, watchdog

Read this when `hub start` or `hub takeover` exits 4 (`MOVE <path>` / `NO PROJECT`) or warns about the legacy hub home,
when a stage needs a better name, when you take over or leave a shift, or when the takeover digest says the watchdog is
on, or when you need the full `jwait` forms. The core `SKILL.md` keeps the commands; this is the full text moved from it.

## The stage, the hub and the shared files

A **stage** is one stream of work (a release, a migration, a sprint) with its own directory under the hub home
(`$AGENT_HUB_HOME`, else a repository's `.agent-hub/config.json` `"project"` / `"user"`, else `~/agent-hub`; `hub home`
prints where it is and why, and how to grant a session access to it; if `hub start` warns that it is the legacy
`~/.claude/agent-hub`, tell the owner in one line — `hub home migrate` moves it, a dry run first). The **hub** is the
one interactive session that plans the stage, writes briefs, spawns headless agents and answers them. The **owner** is
the person the hub works for. Everything they share is a file:

| File | Written by | Read by |
|---|---|---|
| `<stage>/coordinator/work/journal-YYYY-MM-DD.md` — one line per event, `- HH:MM [tag] text` | `jlog`, `tell`, `agent`, `hub`, `roles broadcast` | `jwait`, `agent-top`, humans |
| `<stage>/agents/<role>/` — `brief.md`, `inbox.md`, `log.jsonl`, `meta.json` | `agent spawn/send` and the selected CLI run | `agent status`, `agent-top` |
| `<stage>/roles.json` — who plays which role, by full session id | `roles`, `agent`, `hub start/takeover` | `roles`, `jlog` (tag lookup) |
| `<stage>/questions.md` — owner questions and agents' own decisions | `ask` | `ask`, SessionStart hook, `hub` digest |
| `board.md` — locks on shared resources (merges to main and whatever the project names) | `lock`, `hub takeover` | the `board_locks` hook |

The hooks add `<plugin-root>/bin` to PATH when enabled and trusted. An older
command of the same name — GitHub CLI `hub` from Homebrew, an old `jlog` — can answer instead; if `hub start` or the
session start says so, call the tools as `<plugin-root>/bin/<tool>` and tell the owner in one line. Each has
`--help` with the full syntax. Stage: `--stage`, else `$HUB_STAGE`, else `default`. The hub's tag is `hub-<N>` (N = shift number, derived).

**Minimal mode.** One hub and a few agents need `hub start` once (it gives the hub its journal tag) and then three
tools: `agent` (spawn, status, send, stop), `jlog` and `jwait`. `roles`, `ask`, `lock`, `tell` (a line to another stage's hub), `hub takeover/handoff` and the
handoff skill matter once you have more than one interactive session, more than one shift, or a shared resource;
leave them until then.

## Starting a stage

`hub start --stage <S> --goal "<goal>" --session <your full session id>` — once, by the first hub of a new stage: creates
the stage directory, registers you as `hub-1`, writes the start line and prints the first `jwait`. Use `--session self`;
the tool resolves the current host's session identity (`CODEX_THREAD_ID` in Codex, `CLAUDE_CODE_SESSION_ID`
in Claude, or `AGENT_SESSION_ID` in a detached worker). In Claude Desktop you may pass the `local_…` id.
An ordinary shell must pass an actual full session id. Offer `delamain:setup` if the project has no `.agent-hub/` yet.
Follow warnings about shadowed tools or an outdated CLI.

**Names say what the work is.** The stage name is the goal in 1–3 words (`retro-fixes`, `yc-move`), never `hub-09`,
`stage-2`, `wave-a` or `wp3`: `hub start` refuses a name made only of generic words (hub, stage, wave, wp, task, work,
test, tmp, new, default, stream, sprint — `AGENT_HUB_GENERIC_STAGE_WORDS` sets the list), numbers and single letters
(exit 2), and refuses a start without `--goal`. The goal line goes into your title (`Hub <stage> #N — <goal>`), the
takeover digest, the handoff and `agent-top`. Agent roles follow the same rule: `--role mainmerge-fix`, `argv-off`,
never a number or a package id (`wp23`), so the journal, `agent-top` and other stages' hubs read what each one does.
A stage that already carries a poor name is renamed with `hub rename --stage OLD --to NEW` (`--dry-run` first) once none
of its agents is alive; `hub takeover --goal "…"` gives an older stage a goal line.

A hub works in a fresh worktree of its project, never in the project's main clone and never outside git. When the
command exits 4 with `MOVE <path>`, move as it prints — Claude Code: `EnterWorktree` with `path=<path>`, and if it refuses
(the session was launched outside the repository, e.g. a Desktop session under "No folder")
`mcp__ccd_directory__change_directory` with the project's main clone, not the worktree (Desktop files the session in
the sidebar under the folder it moved to, and the main clone is usually trusted already, while a new worktree waits for
the owner's trust prompt that expires in 5 minutes); it applies when the turn ends, so start no background command and
end the turn at once, then next turn check `pwd`, `EnterWorktree` with that path, and make no edits in the main clone;
Codex: run every later command with that workdir — then run the command line it prints again. `NO PROJECT`: find the
project the task is about (its main clone under `~/repos/`, or where the brief points) and re-run with
`--repo <main clone>`; `--no-project` is only for a stage that has no repository at all.

## Taking over a shift

1. `hub takeover --stage <S> --session <your full session id | self> [--handoff <file>]` — one command (`self` = this
   session's host identity, read by the tool): the previous hub's
   locks (`--skip-lock <resource>` if its executor still works under that lock; `--take-main-merge` to take the merge
   role too, from anyone; `AGENT_HUB_TAKE_MAIN_MERGE=true` in the repository's config takes it only when it is free or
   held by an earlier hub of your own stage — never from another stage's hub, and never on `hub start`), `roles set hub`, a
   start line in the journal (and `coordinator:` of the night queue, if the stage has one). Your number is the
   registered hub's + 1 (or the successor named in the handoff); `--n` overrides. A step that does not verify stops
   the command and names the step; a re-run finishes the rest. `--dry-run` first if unsure.
2. The takeover digest (≤ 3 KB) puts § 0 of the handoff next to the `ask` register. Check every "the owner said" in the
   handoff against the register. If they disagree, the register wins; ask the owner.
3. Start the first `jwait` — the ready command is in the digest; its `--since` (the handoff time) delivers the lines
   written during the handover.
4. Read the project's hub rules and notes before planning (the digest names them): `hub-rules.md` (overrides of the
   recommended rules in `SKILL.md`) and `HUB-NOTES.md` (what the team knows: what goes to the owner, how data claims are
   checked). `hub takeover` has the same location rule as `hub start` (the paragraph under *Starting a stage*): exit 4
   with `MOVE <path>` or `NO PROJECT` means move or add `--repo`, then run it again — nothing was registered before.
   When the replaced hub is a background session that is not busy, the command stops it (`claude stop`, history kept) and
   says so; if it names a Desktop hub that still runs and you have `mcp__ccd_session_mgmt__archive_session`, archive that
   session with it (a busy one or a terminal one is only named: leave it to the owner).

Leaving: `hub handoff --stage <S>` writes a `HANDOFF-hub-*.md` draft with the facts filled in and TODOs; fill the TODOs
(skill `handoff`; `hub handoff --finish` refuses a draft with TODO left in § 0–2, and `hub succeed` checks the same). Locks are not released — the successor's `hub takeover` takes them. It first looks for sub-agents of
your own session (`--session`, else the registered hub's and the session you run it in) that still run and refuses —
exit 2, listing id, description and age — because they die with you and the successor cannot message them; the ways out
are under *Choosing how to launch work* in `SKILL.md` and [launch-and-executors.md](launch-and-executors.md).

## Waiting, in full

Waiting is **one** `jwait`, using the shell harness rather than a polling loop.
- **Claude Code:** run Bash with `run_in_background: true`, `timeout: 3600000` and the digest's `--for` (55m by
  default, `AGENT_HUB_JWAIT_FOR`). The prompt cache lives one hour: a wake after a longer sleep re-writes the whole
  context into it, so a longer wait costs more than it saves. The Bash `timeout` stays at or above `--for`. Its
  completion notification wakes the coordinator.

A stopped `jwait` loses no lines once its caller has run before: the next one delivers them.
- `jwait --journal --tag hub-<N> --tag hub --hub-events --for 55m` —
  lines addressed to the hub, agents' status lines and script questions echoed into the journal. Your own lines (your
  tag and its sub-tags `hub-<N>/…`) do not wake you. The digest prints this command with the team's extra wake words
  (`AGENT_HUB_JWAIT_MATCH`) resolved internally by `--hub-events`; copy it from there. `--for` defaults to 55m (`AGENT_HUB_JWAIT_FOR`; wait again after the alarm). Called with
  `--caller <session id>` instead of as the hub's tag (no `HUB_TAG`, no registry entry for the session), `jwait` does not know your tag: add `--exclude-tag hub-<N>`, or your own `@agent` messages
  wake you.
- `jwait --file <script output> --match 'AWAITING ANSWER'` — a script's question; one asked before `jwait` started is
  delivered too.
- `jwait --until 20:23 --note "check the nightly import"` — an alarm; exit 3 and a line `ALARM …`. `--until` also takes
  `HH:MM:SS` and an ISO time with seconds (`2026-10-04T20:23:30`); `HH:MM` still means that minute's start.
- Sources and filters combine in one command. What was read is remembered: lines that arrived while you worked come
  with the next `jwait`.

## Watchdog

**With the watchdog on** (the takeover digest says so; `docs/monitoring.md`): a hub that sleeps without a waiter is fine, the
watchdog wakes it when lines addressed to it have waited 15 min — but keep one `jwait` anyway, it is the faster path. A
wake arrives as a message that starts `[agent-hub watchdog]` (the name before the rename, still written for one
release; `[delamain watchdog]` means the same), then `<stage>: N journal lines addressed to you have waited since
HH:MM …`: run the digest `jwait` with `--since HH:MM`, handle what it shows, keep one waiter. An idle `claude --bg` hub is
woken by `claude stop` and a resume of the same session, so background commands of its last turn are gone: re-arm what
you need. When you go quiet on purpose (a long wait for the owner, a pause), say so: `watchdog quiet --stage <S> --reason
"…" [--for 8h]`, and `watchdog quiet --stage <S> --clear` when you are back.

# Installation and setup

**Platform.** macOS and Linux; Python and the selected CLI on `PATH` (standard library only).
Windows is unsupported: the tools need `fcntl`, `setsid`, `ps` and `curses`. Claude Code itself runs natively on
Windows ([setup](https://code.claude.com/docs/en/setup)); the limit is Delamain's. WSL is untested.

Follow the [README's three-step recipe](../README.md#start): install, set up the project, then give the hub a job.
If you start the hub first, it offers `delamain:setup` when the repository has no `.agent-hub/`.

**Claude Code:** Python 3.10+ and Claude Code 2.1.287+; older CLI versions are unsupported. The alias `haiku` is Haiku 5.5 from Claude Code 2.1.296 (Haiku 4.5 before).

```text
/plugin marketplace add ilya-kozyrev/delamain
/plugin install delamain@delamain
```

After Claude installation, follow the activation instruction in the install summary and confirm
`/delamain:hub` appears. See [official installation instructions](https://code.claude.com/docs/en/discover-plugins)
(checked 2026-10-05).

> **Permissions.** Headless agents run with `--permission-mode bypassPermissions` by default: a `claude -p` run has
> nobody to approve a prompt, and any other mode silently stalls on the first blocked tool. Treat every agent as a
> process with your user's rights — say in its brief what it must not touch, run it in a worktree or sandbox, or set
> `AGENT_HUB_PERMISSION_MODE` (for example `acceptEdits`) and accept that some tools will be refused.
>
> **Run the hub in bypass mode too** (start it with `claude --dangerously-skip-permissions`). The plugin
> is built for a hub that works while nobody watches it, and only `bypassPermissions` lets it: in `default` and
> `acceptEdits` every `agent`, `jlog` or `gh` call waits for your click; in `auto` the classifier refuses actions that
> leave the machine or touch shared branches — a hub in `auto` had its `gh pr merge` refused and stopped until the
> owner restarted it in bypass. Other modes work only with you at the keyboard approving each step. The autopilot
> successor inherits the mode (`AGENT_HUB_SUCCESSOR_PERMISSION_MODE`); bypass needs its disclaimer accepted once in a
> terminal (`claude --dangerously-skip-permissions`), otherwise the successor falls back to `auto`.

**Codex:** follow [Install in Codex](codex.md#install-in-codex) for its commands and prerequisites (to move to a new version, [Update to a new version](codex.md#update-to-a-new-version): the update removes the older cache directories that live sessions still use), then
[Full access and hook trust](codex.md#full-access-and-hook-trust) before launching workers. That page owns
Codex permission mappings, detached defaults and restricted reviewer settings. Full access and hook trust
are separate controls.

### Selecting Python for terminal tools

The optional `bin/run-python` launcher runs a tool with Python 3.10+ without changing your system Python:

```sh
/absolute/path/to/delamain/bin/run-python /absolute/path/to/delamain/bin/agent-top --json
```

It tries `python3`, then versioned executables from `python3.15` down to `python3.10`, then `python`, on the
caller's `PATH`, using the first compatible interpreter. Set `DELAMAIN_PYTHON` to an executable path or command
name to choose one explicitly; an unavailable or incompatible override fails instead of falling back.
Paths with spaces are supported. Nothing is downloaded or installed.
Use `--min-version 3.11` before the script for Codex tools. Native Codex hooks use this minimum automatically;
the Claude hook manifest and direct CLI shebangs remain unchanged and still use `python3` on `PATH`.
An agent's exit journal uses the interpreter that launched `agent`, even if the child's `PATH` differs.

### What installing changes

- **Tools on `PATH`.** While the plugin is enabled its `bin/` is on the Bash tool's `PATH`, so Claude can call `agent`,
  `jlog`, `jwait` and the rest directly. To use them in your own terminal too, add `bin/` to your `PATH` or symlink the
  tools. A Claude Code session's id is in `$CLAUDE_CODE_SESSION_ID` (`echo` it in the session). When it is empty, for
  example in a plain shell outside Claude Code, `lock take` refuses unless you pass `--force`: the lock would have no
  owner the hook could recognise. The plugin's `bin/` comes after your own `PATH` entries, so an older command of the
  same name wins — in practice the GitHub CLI `hub` from Homebrew, or an old copy of `jlog` in `~/.local/bin`. `hub start`
  and a SessionStart hook warn once when any command of the plugin (every executable in its `bin/`: `hub`, `jlog`,
  `jwait`, `agent`, `ask`, `roles`, `lock`, `agent-spawn`, …) resolves outside it; the fix is to put the plugin's `bin/`
  first on `PATH` or remove the old tool. A command that resolves into an installed plugin's `bin/` (the Claude or Codex
  plugin cache, the marketplace folder) is not reported. To keep a personal shim that dispatches into the plugin (say
  `~/.local/bin/hub` linked to a script that execs the newest installed `bin/`), put the line `# delamain: dispatcher`
  among the first ten lines of the script (right after the shebang; symlinks are followed): the warning skips it.
  A shim written before the rename may keep its `# agent-hub: dispatcher` line: it is still recognised.
- **Four skills.** `hub` (the workflow), `handoff`, `setup` (`delamain:setup`) and `delegation`; four pinned-effort
  Claude worker subagents. `/agent-top` is not a skill: in Claude Code the mod answers it (see [Monitoring agents](monitoring.md#agent-top-inside-claude-code-a-live-pane)).
  Codex worker TOML resources are copied by setup; they are not automatically registered by the plugin manifest.
- **Hooks**, each with its own reach (the [agent-discipline](reference.md#agent-discipline) hooks — context budget, polling guard,
  delegation dial and subagent rules — are described in their own section):
  - `board_locks` (before every Bash call) runs in every Claude Code session on the machine, but acts only on merges
    and pushes to protected branches and on commands your `lock-rules.json` names. Any error of its own lets the
    command through.
  - `handoff_size` (Write or Edit of `HANDOFF-*.md`) and `questions` (the owner-questions line at session start) act
    only in the hub home, in repositories that have `.agent-hub/`, under the directories of the hub-wide setting
    `AGENT_HUB_SCOPE_DIRS`, and, for `questions`, in agents started by `agent spawn`. A session in an unrelated
    project hears nothing from them.
  - `session_cards` (before Claude Desktop's `start_session` / `hand_off_to_session`, and at session start) acts only in
    a session registered as a stage's `hub`: it refuses cards (`initiation` `own_initiative` or `offer`) and forks, and
    names `agent spawn`, `ask add` and `hub handoff` instead; a session the owner asked for (`user_asked`) and an
    accepted card (`proposal_id`) pass. Any other session, and any error of its own, is let through.
  - `path_shadow` (session start) warns when a command of the same name as one of the plugin's tools comes first on
    `PATH`. It does nothing, and writes nothing, until a hub home exists (`hub start` creates it). Then it speaks every
    time in the same places as `questions`, and once per distinct set of paths elsewhere.
- Nothing else: no daemon, and nothing is written to your repositories until you run `delamain:setup`. The hub's own
  files go to `~/agent-hub` (created by `hub start`; see [Where the hub's files live](reference.md#where-the-hubs-files-live)).

### After install: run `delamain:setup` in each repository

Ask your coordinator to use the `delamain:setup` skill in the repository's checkout. A new, empty project may skip it for now:
the hub offers it when it is needed. It looks at the repository, then asks one round of numbered questions with a
recommended answer for each: which branches are protected, which environments two sessions must not change at once,
which commands touch each. It writes `.agent-hub/lock-rules.json` and `.agent-hub/config.json` and proves the rules
with positive and negative checks (`lock rules check`). A project with no deployment ends with `main-merge` only, and
that is a complete setup. Commit `.agent-hub/`: it is the team's shared convention (see [Team use](reference.md#team-use)).

### Recommended companion: grilling

The hub agrees a Business DoD before autonomous work, using the
[planning recipe](../skills/hub/SKILL.md#planning-a-stage-agree-the-business-result-before-autonomous-work).
A clear request already supplies it; otherwise clarify business-material ambiguity with the `grilling` skill from
[mattpocock/skills](https://github.com/mattpocock/skills) (MIT): rounds of numbered questions, each with a recommended
answer, stopping once the business result is clear. Delamain does not bundle it; install it next to this plugin:

```text
/plugin marketplace add mattpocock/skills
/plugin install mattpocock-skills@mattpocock
```

Without it the `hub` skill grills by hand in the same format; the answers go to the question register either way.


# Claude Code and Codex

Workers default to the coordinator's current host: a Codex hub uses Codex workers and a Claude hub uses Claude
workers. At the initial planning step the hub offers the engine choice once, using that default; an explicit choice
is preserved in the stage rules, briefs and handoffs. Mixed teams are an explicit choice. Model and effort are
chosen after the engine, within its available models.

Review is a separate engine/model choice. For Sol-authored code, prefer a high-effort Claude Opus/Fable reviewer
when its limits allow; otherwise use an available Codex Astra at high. An older Sol is not the default reviewer
for Sol. Configure `AGENT_HUB_REVIEWERS` in that priority order with trusted availability checks; explicit reviewer
entries take precedence. The built-in Codex reviewer defaults to Astra and does not inherit the implementation
model from `AGENT_HUB_CODEX_DEFAULT_MODEL` or the CLI configuration. See [reviewer selection](reviewers.md).

The coordinator and its workers can use different engines. The shared journal, inbox, role registry, question
register, lock board and handoff files remain the protocol. Select an executor with `agent spawn --engine claude`
or `--engine codex`; sending, status and stopping use the engine recorded at spawn.

For a native Windows Codex coordinator, follow the [Windows workflow](windows-workflow.md).
Its conditional transport runs the original core and detached workers in WSL2; the generic installation below
is for the selected runtime host. Native Windows Claude integration is not established.

## Install in Codex

Codex support requires Python 3.11+ on PATH, including for native hook execution: native agent definitions and
configuration use the standard-library TOML parser. Native hooks use `bin/run-python --min-version 3.11` to find
a compatible runtime even when `python3` is older. Set `DELAMAIN_PYTHON` to an executable path or command name
to select it explicitly. See [Python selection](install.md#selecting-python-for-terminal-tools) for lookup order
and terminal CLI usage. The Claude engine continues to support Python 3.10+ with its existing hook commands.

Clone the repository if you do not have a local checkout yet:

```sh
git clone https://github.com/ilya-kozyrev/delamain.git
cd delamain
```

Use that checkout's absolute path in the marketplace command:

```sh
codex plugin marketplace add /absolute/path/to/delamain
codex plugin add delamain@delamain-codex
codex plugin list --marketplace delamain-codex
```

Restart the Codex chat so it loads the installed skills, then ask for `delamain:setup` in the project.
Ask the session what is running; the `status` skill answers in words from fresh `agent-top` data.
`.codex-plugin/plugin.json` packages `./skills/` and explicitly selects `./hooks/codex-hooks.json`;
it does not load the Claude hook configuration. Installation and enabling do not grant hook trust: review
and trust the installed hooks in Codex before using them interactively. Untrusted hooks are skipped.
See [official plugin packaging](https://developers.openai.com/plugins/build/plugins) and
[hook trust](https://learn.chatgpt.com/docs/hooks).

Codex's SessionStart hook selects the Codex engine for that session. In a plain terminal, or when hooks are
untrusted, pass `--engine codex` or set `AGENT_HUB_ENGINE=codex`. In a plain terminal with no configured engine or detected Codex host, the default is `claude`.
Use the installed plugin's `bin/` directory explicitly if a command is absent or shadowed on PATH.

### Update to a new version

`codex plugin add` for a new version deletes every older version directory under the plugin cache,
`~/.codex/plugins/cache/<marketplace>/delamain/` (`$CODEX_HOME` moves it; the marketplace here is `delamain-codex`).
A Codex session that is still running on an older version loses its hooks the moment its directory is gone: the lock
guard and the other hooks stop applying to it. Before updating, copy the version directories aside; right after the
`add`, put back every one that vanished and check with `diff -rq` against the copy:

```sh
CACHE="${CODEX_HOME:-$HOME/.codex}/plugins/cache/delamain-codex/delamain"
SAVE="$(mktemp -d)"
cp -a "$CACHE/." "$SAVE/"                      # every version directory installed now

git -C /absolute/path/to/delamain pull
codex plugin add delamain@delamain-codex

for dir in "$SAVE"/*/; do                      # put back each one the add removed
  v="$(basename "$dir")"
  [ -d "$CACHE/$v" ] || cp -a "$dir" "$CACHE/$v"
done
diff -rq "$SAVE" "$CACHE"                      # only the new version may be listed ("Only in …"), nothing else
```

Restart the Codex chat to load the new version. Remove an older version directory yourself once no session or
background worker runs on it.

### Terminal monitor and older installations

Plugin installation does not replace personal commands or wrappers in `~/.local/bin`, or upgrade an already
running `agent-top`. A wrapper that searches only the Claude cache can keep launching 0.7.x after installing
Codex support. That monitor does not understand Codex process tokens or JSON events: a living Codex worker can
appear dead, with zero turns and an empty feed. Run the new installed plugin's `bin/agent-top` directly, or update
your terminal PATH/symlinks to that directory, then quit and restart the old monitor.

For a version-resolving personal wrapper, search both `~/.claude/plugins/cache/*/delamain/*/bin` and
`~/.codex/plugins/cache/*/delamain/*/bin` (honour `CLAUDE_CONFIG_DIR` / `CODEX_HOME` overrides). Compare the numeric
version component, not the full path, and use the newest shared runtime.
A copy installed before the rename sits under the folder `agent-hub` instead of `delamain` until it is reinstalled:
search that name too. The runtime supports both engines;
choosing its installation directory does not choose the worker engine. Check the selected monitor with
`<installed-plugin>/bin/agent-top --json --agent <role> --feed 10`, using the same hub home and stage as the UI.

The header labels Claude and Codex usage separately. Codex account limits come from the newest timestamped
observations in the last 256 KB of up to 32 recently modified local rollouts, refreshed every 30 seconds. These
are logged snapshots, without a network request or model call; the summary shows observation age and reset time.
Window labels use the reported duration (including plans with only a weekly window). Missing data is omitted,
not shown as zero, and separate `limit_id` buckets remain separate in the header and JSON `codex_limits` field.

## Spawn, message and resume

```sh
agent spawn --engine codex --role builder --cwd /absolute/path/to/project \
  --brief /absolute/path/to/brief.md --worktree
agent status builder
agent send builder "Continue with the next item in the brief"
agent stop builder
```

For Codex, leaving out `--model` uses `AGENT_HUB_CODEX_DEFAULT_MODEL` if configured, otherwise the CLI's configured
model. Pass an available model id when you need a pin; `AGENT_HUB_CODEX_MODEL_MAP` provides explicit aliases.
The plugin does not silently translate Claude model aliases into GPT ids. `CODEX_BIN` chooses the executable.
Choose an effort supported by the selected model with `--effort`.

Before a stage's first detached launch for a CLI/model, check the selected CLI with `codex --version` and
`codex debug models` (substitute `CODEX_BIN` when configured). The desktop app and standalone CLI can have different
model availability. Ordinary implementation uses an available Sol-family model, or the owner's explicit choice.
An unavailable Sol version calls for a CLI compatibility check or an available Sol peer, with the fallback reported;
Astra needs a task-based judgement reason. A model startup error alone does not justify that model class change.

Codex launches with `codex exec --json`; its `thread.started` event supplies the actual thread id saved in
`meta.json`. A message to a finished worker uses `codex exec resume` with that id. A message to a running worker
is appended to its inbox, which the brief tells it to read after each major step. No Claude cross-session API is
needed. See [non-interactive Codex](https://learn.chatgpt.com/docs/non-interactive-mode).

### Immediate Codex tell delivery

To another stage's hub, use `tell <stage> "…"`. For a non-detached Codex recipient, it retains one signed journal
line as audit and attempts immediate delivery through `codex app-server proxy` to the existing runtime only.
After public `initialize`/`initialized`, `thread/read` must return the exact full registry UUID. An active thread
with one known in-progress turn receives `turn/steer` with that exact `expectedTurnId`; a thread observed loaded idle
receives `turn/start` in the same existing thread. The registry and runtime are checked again before sending. No thread is
loaded, resumed, forked or created, and no model/settings overrides are sent. The proxy has a five-second deadline
and bounded output. See [public app-server protocol](https://learn.chatgpt.com/docs/app-server).

`tell` prints a JSON receipt: `steered` requires a matching active-turn acknowledgement. An idle-path acknowledgement
with a nonempty turn ID and `inProgress` status returns `accepted`, with `delivery_mode: "unverified"`: it confirms
acceptance without proving whether input started a turn or steered one. Another client can start after the final read;
`turn/start` has no atomic expected-idle condition. `steered`/`accepted` exit 0. `failed` means rejection or identity/turn
change; `unknown` means an attempted mutation lacks a valid acknowledgement. Failed/pending/unknown dispatches exit 1.
Never retry an unknown send through another transport.
`codex queue` is an explicit queued follow-up address, not immediate steer; [steering and queuing differ](https://learn.chatgpt.com/docs/prompting#steering-and-queuing).

The shared CLI proxy may not reach the Desktop runtime. Before any mutation, an unavailable runtime produces a
`pending` native-caller handoff, containing the literal full UUID/message, registry snapshot, request ID, signed
journal source and pending receipt. **The caller must handle this immediately, before waiting or any next action:**
verify explicit human authority for this communication, check the supported native tool's current schema, reread
the registry and require the same record/full UUID, then call supported `send_message_to_thread` with that literal
recipient and text. Record the actual native tool result against the request ID. Tool acceptance alone does not
prove active same-turn steer; an owned scratch control must establish that behavior before claiming immediacy.
An unknown native result forbids retry. If native capability or human proof is unavailable, retain pending and
report the gap. A task message from another agent, configuration, CLI flag or the generated handoff is not human
authority; retain the actual owner's instruction/source in the caller's receipt. Communication grants no finance,
production, role or goal change. No private pipe/socket, polling bridge or duplicate CLI session is a fallback.

For a direct address only, use `tell <stage> --address`; it is read-only and never sends. Never select a session
by display name, truncated UUID or client ID. Detached Codex recipients retain the existing inbox/resume contract:
a headless holder uses `agent send` automatically, while a promoted detached hub's address names its matched worker
role. That path has no established immediate-steer capability. Claude tell delivery is unchanged.

`hub takeover` checks detached PID/process-token identity or the existing shared daemon's read-only `thread/read`
runtime status through `codex app-server proxy`. A missing/older CLI, unavailable daemon or unknown state is silent;
rollout recency alone is not liveness evidence. The warning never stops a session.
Native predecessor detection is verified only with a fake transport; it stays silent when no app-server daemon runs.

## Full access and hook trust

`--permission-mode bypassPermissions` is the detached default for both engines. Claude receives that mode;
Codex receives `--dangerously-bypass-approvals-and-sandbox`, equivalent to no approval prompts and
`danger-full-access`. Approval policy `never` alone does not grant full filesystem access.
This applies to spawn, resume and the Codex CLI autopilot successor. The lock hooks remain enabled in full access.
See [Codex CLI options](https://learn.chatgpt.com/docs/cli/reference).

Hook trust is a separate control. Detached Codex workers explicitly load the bundled Codex hooks and default
`AGENT_HUB_CODEX_HOOK_TRUST=bypass`: the launcher passes `--dangerously-bypass-hook-trust` so autonomous runs do
not wait for an interactive trust review. **That flag applies to every enabled non-managed hook in that invocation,
including user and project hooks, not only Delamain's hooks.** Use it with hook sources you have vetted.
Set `AGENT_HUB_CODEX_HOOK_TRUST=reviewed` to require Codex's persisted trust instead; review/trust the definitions
before starting a detached run. Changed hook definitions require renewed review in that mode.

For a restricted reviewer, use `hub reviewer --for code --stage S` or the equivalent launch:

```sh
agent spawn --engine codex --role reviewer --cwd /absolute/hub-home/S/coordinator/work \
  --brief /absolute/path/to/review-brief.md --sandbox workspace-write
```

Create the cwd first and put the absolute repository path in the brief for reading. Keep that repository outside the
hub home and reviewer cwd, and do not add it to writable roots. The sandbox selection replaces full access for that
worker: it can write the report and journal under the hub home while repository writes are denied. A `read-only`
worker cannot write either; a review role/tag with that policy gets one warning at spawn.

Workspace-write executors receive the hub home as a writable root. A review role/tag instead receives only its
cwd strictly below the hub home, with temporary-directory writes excluded; wider explicit roots or a cwd outside
that home are refused. Its report, journal and `.journal.lock` fit within the stage's `coordinator/work`; home
configuration and other agents' inboxes stay read-only. Keep that cwd outside any repository.

For linked Git worktrees, executors additionally receive individual operation-state files (HEAD, index and locks,
commit/merge messages and pseudorefs), their own logs and common objects.
`commondir`, `config.worktree`, `gitdir`, `locked` and the private gitdir itself are not writable roots. Files-backend
refs/reflogs are limited to the worktree's initial branch and its lock files. For nested branch names, their first
namespace directory is granted so Git can recreate it after pack-refs; sibling refs in that namespace are also
writable. `packed-refs` and its lock are not granted. These roots are pinned at spawn and reused on resume even if HEAD changes.
A detached HEAD gets no shared branch roots. Reftable uses a shared store, so that backend still grants all refs in
`reftable`. The common Git directory, config, hooks and sibling worktree state are never granted.

These file-root boundaries were verified on macOS seatbelt: commit and non-fast-forward merge succeed.
In a workspace-write linked worktree, rebase is unsupported. No `REBASE_HEAD`, `rebase-merge`, `rebase-apply`,
sequencer or rewritten-ref roots are granted. Spawn prints the limitation and includes it in the worker's brief.
Update the branch with a merge commit from the prepared base ref (for example `git merge origin/main`).
The sandbox refuses creation of rebase state. In the macOS probe, `--merge` refused before HEAD changed, but
`--apply` could move HEAD before failing, although the original branch ref stayed unchanged. A fully early refusal
cannot be guaranteed by this file-root policy; do not run rebase in either mode. Exact Git diagnostics vary by version. Granting a rebase state directory alone is insufficient: deleting that
writable root during cleanup requires access to its private gitdir parent, which this policy does not grant.
Git may emit a nonfatal `packed-refs.lock` denial; commits with loose and packed refs were checked.
Other sandbox implementations (including Linux Landlock) may reject absent file roots or require parent-directory
access; they fail closed rather than receiving the whole Git directory.
The shared objects grant includes `objects/info/alternates`; its object-source pointers remain writable and untrusted.
A sandboxed interactive coordinator may need `--add-dir <hub-home>`; full access needs no directory grant.

See the [capability matrix](codex-parity.md) for verified hook dispatch, setup coverage and platform limits.

## Native Codex subagents

Claude's `agents/worker-*.md` files remain Claude definitions. Codex uses standalone TOML files in
`.codex/agents/` or `~/.codex/agents/`; the plugin manifest does not register them automatically.
The setup skill offers four matching effort-pinned files under
`skills/setup/resources/codex-agents/worker-*.toml`. Copy selected files into the project or personal agent directory
without overwriting an existing definition. Project definitions require a trusted project; verify that the native
spawn tool exposes the installed roles before relying on them. Their `model` is deliberately omitted: choose an available model at spawn.
See [native Codex subagent configuration](https://learn.chatgpt.com/docs/agent-configuration/subagents).

For detached executors, use `agent spawn --effort`; native TOML files govern in-session subagents, not that launcher.
The delegation dial and effort rules apply through trusted Codex hooks to native spawn calls. Verify your configured
rules with `delegation try`; prefer explicit definitions when effort inheritance would waste the coordinator's budget.

## Coordination and platform differences

- Use `hub start --goal "<what the stage delivers>" --session self` and `hub takeover --session self` in either host. An ordinary shell must supply an
  actual session id. The Codex identity is `CODEX_THREAD_ID`; a detached worker also receives `AGENT_SESSION_ID`.
- Run one `jwait` through Codex's shell execution session and continuation tools. Keep individual blocking waits
  bounded so the coordinator can still respond; use its returned exit status. Claude's `run_in_background` and
  completion notifications are specific to Claude.
- `agent-top`, `agent-top --once` and `--json` work with both event streams. Codex values absent from its stream are
  shown as unavailable rather than inferred. Codex has no `/agent-top`: run `agent-top` in a shell. The live pane is a
  Claude Code mod and does not draw in Codex.
- Codex console autopilot (`hub succeed --engine codex --surface cli`, or automatic console detection) starts a detached Codex successor. It inherits the actual
  rollout model, reasoning effort and sandbox policy, or the recorded launch settings when discovery is unavailable. Supported
  workspace policy fields include network access, writable roots and temporary-directory exclusions; unknown
  policy fields are refused explicitly instead of discarded. An unspecified model
  stays with the CLI configuration. Interactive approval policies become `never` for unattended successors: denied
  tools fail, with no fallback to broader access. `--again` keeps a dead successor's recorded model, effort and sandbox policy. An absent effort stays with the launcher
  default; unsupported effort values are refused before launch.
  `AGENT_HUB_SUCCESSOR_ENGINE` selects a hub-wide successor engine; `--engine` overrides it. The chain limit,
  reservations and takeover checks prevent duplicate launches. Reach the successor through `agent send` and the shared registers;
  in Git, it starts from the main checkout in a fresh named worktree so archiving the old coordinator cannot remove its directory.
  Outside Git it keeps the supplied directory.
  The Claude Desktop/Remote Control phone workflow stays Claude-specific.
- Night queue files and permissions work with both engines. The watchdog (`watchdog install`) counts open night-queue
  items as waiting work. A confirmed idle app hub registered by `hub start`/`takeover` as `host: codex-app` is woken
  with `codex queue` in its own UUID; terminal/unknown hosts and unavailable runtime notify only. Registration requires
  the current thread and both app markers described below, excluding detached workers; old records need an app-side
  `hub takeover --session self` (same UUID/tag/shift). Detached hubs use `agent send`. Codex API-error recovery (R4)
  covers only a final own-turn `task_complete.error.codex_error_info = server_overloaded`, with matching turn start
  and no later user/turn boundary, rechecked before wake. Quota/auth/unknown errors and interruption never trigger R4.
  See [host conditions](monitoring.md#which-host-is-woken-how).
  The standalone CLI's shared-daemon proxy must reach the same app runtime; app markers and fake queue controls
  alone do not prove live Desktop wake. The standalone tick remains notify-only for an unavailable/separate runtime. Once a finite stage
  has no outstanding work or external waits, retire its active hub with `roles retire hub --stage S --note "stage complete"`.
  An existing app-native heartbeat can bridge a separate runtime with `native-plan`/`native-claim`/`native-ack` and
  supported native read/send tools; [procedure and limits](monitoring.md#codex-app-native-bridge).
  The Claude Desktop scheduled nudge is
  deprecated, and the Claude outgoing-message budget remains platform-specific; neither is installed as a Codex scheduled task.

Only commands observed by enabled, trusted hooks can be guarded. External terminal commands and commands that
match no configured rule remain outside the lock board's enforcement. The files remain local to one person and machine.


## Desktop autopilot

`hub succeed --engine codex --surface auto` detects an actual app hub through both
`CODEX_INTERNAL_ORIGINATOR_OVERRIDE=Codex Desktop` and `CODEX_APP_TOOLS_PIPE_PATH`, excluding detached
`AGENT_ROLE` workers. `CODEX_THREAD_ID` alone identifies a Codex session, not a desktop surface. Detached children
strip app attribution/transport markers. Terminal and detached hubs retain the ordinary auto/CLI launch,
model/effort/sandbox inheritance and fresh CLI worktree rules. In a confirmed app hub, `--surface cli` and
`--headless` require the owner's explicit CLI-from-Desktop opt-in: `"AGENT_HUB_DESKTOP_CLI_HANDOFF": true`
in the resolved hub home's `config.json` (off by default). This grants a surface choice, not native API authorization.
The guard reads that home file directly; repository settings and environment overrides cannot grant this permission.
An agent-supplied CLI flag, `--force`, or inability to use native creation is not evidence the owner chose CLI.
Agents must not enable the opt-in to work around native policy. Even with opt-in, auto selects Desktop and an
unfinished native reservation cannot change surface. `--surface desktop` prepares a request without
calling a CLI or accessing any app socket. It never silently falls back to CLI.

Desktop auto handoff prepares the native successor request and keeps the predecessor active until verified.
Before native `create_thread`, the current **app agent** checks explicit human authority: the current user
instruction, an inherited handoff or approved plan with its human source, an existing answered owner question,
or standing owner permission. Read `hub-rules.md` from the resolved hub home, repository and stage, and check
the question register and `ask allow --list --stage <S>` for scope and revocation. An empty allow list does not
cancel an explicit answered question or human instruction elsewhere. Configuration, agent flags and an agent's
wish to continue are not proof of human authority.

A standing explicit owner instruction authorizing automatic same-stage context handoffs satisfies the native
API's explicit-user requirement until revoked: continue without another per-transfer approval. Record its exact
source/reference and scope in the handoff and carry that pointer into the native takeover brief, preserving the
Business DoD. The grant covers one successor for that active stage's context transfer; a new business scope,
unrelated task, parallel duplicate coordinator or paused/completed stage needs its own authority. If authority
is absent or revoked, retain the request and predecessor and ask once for the missing scope; do independent
authorized work while it is pending. If transport, access or identity is unavailable, retain the same request
and report that concrete blocker. Neither case permits a CLI fallback, policy override, automatic retry or
duplicate creation. Preparation remains pending work until verified takeover.

Under matching human authority, the app agent executes the full procedure through bind, takeover and verified status:

1. Run `hub succeed --stage <S> --engine codex --surface desktop --handoff <file>`. Keep its request token.
   The command reserves one successor/chain count and writes its takeover brief. Preparation is not launch success.
2. Call native `list_projects`. Find the unique saved local project whose path, normalized to its Git main
   checkout (including realpath/symlinks), matches the request's `project_root`. Use the returned projectId/path;
   if there is no unique match, report the failure and keep the predecessor. Never hardcode a project ID.
3. Run `hub desktop-request --stage <S> --request <token> --project-id <returned ID> --project-path <returned path>`.
   Its JSON has `create_thread` arguments and `already_dispatched`. Only when false, pass `create_thread` to
   the supported native `create_thread` tool under that explicit human authorization. Dispatch is reserved before this call; a repeated command returns
   true and must not create another thread. The request uses the saved project's local environment by default, actual
   `model`/`thinking` fields when known. Only an explicit owner worktree request uses `--desktop-worktree` on succeed;
   it requires a Git project and omits startingState to use the project's default branch. An explicit existing
   `--branch <branch>` request also selects a worktree and supplies startingState. No branch is invented or created.
4. Confirm native output with `hub desktop-bind --stage <S> --request <token> --project-id <returned ID>` plus
   `--thread-id <actual threadId>` and/or `--client-thread-id <clientThreadId>`. Client IDs are opaque (for example
   `client-new-thread:…`), stored separately, and cannot become registry identities. If only a client ID returns,
   keep the request pending. Supported app observations or the successor's own registration can supply the actual
   ID. `list_threads` alone is not readiness proof: a newly running task may not appear there yet. Never use a
   client ID with a thread API, or invent an operation/host/thread ID. No operation API is called without a returned ID.
5. Continue the printed `jwait` in the shell harness, preserving its execution session and exit status. The successor
   runs its brief's `hub takeover --session self --auto-handoff --desktop-request <token>` from its actual cwd.
   Its own CODEX_THREAD_ID, main project, persisted rollout settings and stage-home write access are validated
   before role/lock migration. Takeover reconciles actual identity/cwd and retains the original chain count.
   If takeover prints `MOVE <path>`, run the printed command from that fresh worktree, keeping the same
   thread and request. The verified cwd is where takeover completes; a native local thread does not waive
   the hub location rule.
   Confirm `hub desktop-status --stage <S> --request <token> --verified` (exit 0) before stopping the predecessor.
   Status shows requested and observed model/effort/sandbox/approval separately. Report preservation only from
   observed data. Bind/takeover can arrive in either order; repeats retain the same identity/count. A later hub
   invalidates the request, so stale confirmations/takeovers cannot replace it.

A current verified native hub can refresh its host registration with `hub takeover --stage <S> --session self`
from its verified cwd. Repeated same UUID/shift refreshes retain the full native ID, request, chain, observed
settings and original registration/takeover timestamps. The completed native self-refresh is a separate operation
under the state and role locks: it does not transfer resources, update the night queue, run project takeover
callbacks, stop a predecessor or publish a new shift/start line. Explicit resource, metadata or location-changing
flags are rejected on this path; use a separately authorized resource operation for resource work. A completed
refresh requires the original verified cwd; it does not create or move to another worktree.
A different manual session or shift keeps the normal takeover path.

For a legacy self-refresh that shortened the completed request's ID and changed its kind to `manual`, the
**current app hub itself** can run the following from its original verified cwd, using the reviewed plugin's
absolute `bin/hub` path when PATH names an older runtime:

```bash
hub desktop-recover --stage <S> --request <existing-token>
hub desktop-status --stage <S> --request <existing-token> --verified
```

Recovery creates no thread, reservation or shift and reads no handoff. It requires this app's full
CODEX_THREAD_ID, matching current role/CLI UUID, native host/engine, original shift, cwd/main project, saved
project ID, persisted observed settings and writable stage-home policy. New bindings retain the original
actual UUID and registration evidence separately. Legacy requests additionally require an unambiguous original
full-UUID `start:` registration in the takeover day's journal, the exact original request preparation
line and an exact match between current `set_at` and
original `taken_over`. A later timestamp, missing/ambiguous proof, different UUID (including the same eight-character
prefix), stale token or changed observed policy fails before mutation. Do not edit JSON, infer identity from a
prefix, widen settings or dispatch again to repair such a failure; report the missing proof to the coordinator.

The supported create_thread/handoff_thread schemas have **no sandbox or approval setting**. Requested policy is
carried in the brief/state, not smuggled into API arguments. Desktop defaults/UI determine actual policy. Full
Access cannot be promised by these APIs, and approval `never` is not Full Access. A successor with unknown rollout
policy, read-only access, or a workspace sandbox that excludes the stage home fails honestly before migration;
the predecessor stays active. If policy permits the home, status records the actual policy even when it differs
from requested. The protocol changes no global settings or installations and grants no broader access to other hubs.

On native error, run `hub desktop-fail --stage <S> --request <token> --why <reason>`. Unknown results retain an
uncertain reservation: inspect supported app evidence or await self-registration; do not create another successor.
Only confirmed failure **before any thread was created** permits `--no-thread-created`; this resets dispatch on the
same request. `hub succeed … --again --surface desktop` prints that same request without increasing the chain.
Once any client/actual ID was recorded, a no-create assertion is rejected. Desktop reservations survive timeouts
and owner chain resets; they are not automatically dropped while an app thread might still exist.

Successor briefs work the finite handoff queue first. `jwait` runs only while outstanding work or external events
remain; an empty/completed queue journals DONE and finishes without an unconditional nine-minute wait.

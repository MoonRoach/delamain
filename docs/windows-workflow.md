# Finish a task from native Windows Codex

Keep the coordinator in the current native Windows Codex chat. Delamain's original Linux
core, hooks and detached workers run in WSL2 through the installed Desktop bridge.
This is a conditional transport-supported route, not a native Windows port of the core.
The [WSL terminal route](windows-wsl.md) starts a separate Linux coordinator only when
that mode is explicitly chosen. Native Windows Claude integration is not established.

## Prepare the selected installation

Use accessible WSL2, Python 3.11+ in Linux, PowerShell and a complete Linux Codex package
with its resources/helpers. Use the existing authenticated native Codex installation and
a separately configured Linux worker home. Preserve native model, effort, approval,
sandbox and authentication settings; provisioning a worker home is not permission to
replace them. The Windows app and Linux CLI may expose different model catalogs.

The Desktop envelope is built from the chosen source snapshot into a **new empty directory**.
Its private machine settings identify `Distro`, `LinuxCodex`, `LinuxHome`, `WindowsCodex`,
`WindowsCodexHome` and `HubHome`. Use actual configured paths, never another machine's values.
Keep settings/authentication outside repository docs. The builder copies the original tools,
adds Windows hook commands and a conditional skill prelude, and writes
`windows/build-receipt.json`. Its core and original-skill hashes prove source identity,
not successful product behavior. See [transport and packaging](windows-desktop.md#installed-runtime).

For an operator preparing an envelope, from the source checkout in Linux:

```sh
python3 windows/build_desktop_plugin.py --help
python3 windows/build_desktop_plugin.py --source /absolute/path/to/source \
  --output /absolute/path/to/new-empty-package --settings /absolute/path/to/private-settings.json
```

Install that package using its absolute native path:

```powershell
codex plugin marketplace add 'C:\Packages\Delamain'
codex plugin add delamain@delamain-windows
codex plugin list --marketplace delamain-windows
```

Enable and review/trust its hooks, then open a new chat in the intended repository. The
installed `delamain:` skills and SessionStart's current UUID/bridge path must be available.
Installation is not hook trust. Detached full access and hook-trust bypass have distinct
scopes; review [Codex permissions](codex.md#full-access-and-hook-trust) before launch.
No global network changes, runtime restarts or private app pipes are part of this route.

## Start with the user's result

Ask for `delamain:setup` for a new repository, preserving existing changes and configured
shared resources. Then use `delamain:hub` with the result the user wants. An explicit Codex-only
choice persists; upstream instructions still support either engine. The owner's Business DoD
is authoritative and inherited unchanged. Clarify only ambiguity that materially changes
that result; technical verification choices belong to the coordinator.

Follow the [hub skill](../skills/hub/SKILL.md), including its stage registration and decision
lookup. Use the actual current UUID and installed path supplied by SessionStart. For example:

```powershell
& '<installed-plugin>\windows\desktop.ps1' --session-id '<current-chat-UUID>' hub home --json
& '<installed-plugin>\windows\desktop.ps1' --session-id '<current-chat-UUID>' shell 'git status --short'
& '<installed-plugin>\windows\desktop.ps1' --session-id '<current-chat-UUID>' shell --cwd 'C:\Projects\Example' 'git status --short'
```

Bridge path and Bash source are literal PowerShell strings; double embedded single quotes.
Set the native shell tool's workdir for the intended repository. Use `path --windows` before
native editing of Linux paths, and run Git for WSL-created worktrees through bridge Bash.
The [transport contract](windows-desktop.md#transport-contract) explains stdout/stderr,
exit codes, Unicode, stdin and supported guard coverage. A bridge success is not proof a
user-facing action worked; check the actual output and child exit status.

## Make bounded progress and verify it

Choose the launch using the [native versus detached decision table](../skills/hub/SKILL.md#choosing-how-to-launch-work).
Native subagents suit session-bound short reads; detached workers preserve role reachability
across coordinator changes. Writers use isolated worktrees. Before a detached Codex launch,
check the selected CLI/version and its available model catalog as described in
[Codex launch guidance](codex.md#spawn-message-and-resume); unavailable catalog commands
are limitations to record, not commands to pretend succeeded. Preserve explicit model/effort.
Linux workers may use the existing authorized Windows proxy via the
[worker service route](windows-desktop.md#linux-worker-service-route), without changing
machine network policy or requesting a new daemon.

Use configured locks for shared resources and the question register for owner decisions;
existing applicable authority remains effective. Wait only for a concrete resource, data or
owner dependency, and continue independent authorized ready work. Each actor owns its
started PIDs/process groups and cleans up its helpers; do not use broad process-name kills.

## Continue after waits, stops and context transfer

Detached/journal events use one canonical `jwait` through the host's yielded shell execution
and continuation tools. Native children use native completion/wait tools. An unresolved
native status is not death; actual completed events and results are evidence. For both
sources, consume the report and apply [terminal follow-through](../skills/hub/SKILL.md#terminal-follow-through)
before waiting again. This workflow does not install polling, watchdogs or heartbeats.

STOP, call budget and context checkpoints close an actor brief, not the approved stage.
Transfer exact state: current snapshot/source hashes, completed coverage, remaining inputs,
next action and concrete blocker. Resume by role through the existing inbox/resume path,
or use a fresh session when needed. Do not repeat the entire investigation at every handoff.

Do not compact any session. Preserve the upstream mandatory one-third planning requirement.
Hand off at the configured context threshold, with exact state and remaining work.
A context checkpoint does not authorize continued work through compaction.
Preserve actual model, effort and access policy. Native same-stage transfer follows
[Desktop autopilot](codex.md#desktop-autopilot): inherited explicit human authority applies
until revoked, preparation/client IDs remain pending, and the predecessor stays active until
actual takeover is verified. No silent CLI fallback or duplicate successor is authorized.

## Supported boundary and final acceptance

The envelope has source-level controls for transport, hooks and worker cleanup; see
[validation scope](windows-desktop.md#validation-scope). Actual Windows behavior depends on
PowerShell/WSL, installed CLI/version, hook trust, catalog availability and the native app's
supported tools/access. Fake provider and offline controls do not establish authenticated
model availability or actual native successor takeover. Native Claude Windows is untested.

Final internal qualification requires a Windows internal-run record after actual tests, naming
source hashes, observed settings, tested scope, cleanup and unavailable checks. The integration
owner/verifier includes that record in the final PR and distinguishes first smoke, whole-result
review and publication/production acceptance. Publication follows the owner's requested sequence
and authority after internal qualification.

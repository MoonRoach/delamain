# Delamain in native Windows Codex

The native Windows installation keeps the coordinator in the current Codex app chat.
It packages the original skills with a conditional Windows transport section and
adds Windows hook commands. Original Python tools, hook implementations, file
protocols, detached workers and review/planning rules are unchanged and run in WSL2.

For the complete task path, start with the [Windows workflow](windows-workflow.md).

## First task

Open a new Codex chat in your repository after installation.
Select `delamain:setup` in the skill picker, or send:

```text
Use delamain:setup for this repository. Read project instructions, preserve existing
changes, check Windows/WSL prerequisites, and propose resource settings for approval.
```

After setup, select `delamain:hub` and describe the required result. If you want to
approve the plan first, say so explicitly. Merge, publication and deployment retain
the original owner-authorization rules. There is no need to open a WSL coordinator
terminal for this route.

The native plugin name is `delamain@delamain-windows`. Its five skills are `setup`,
`hub`, `handoff`, `delegation` and `status`, under the `delamain:` namespace. SessionStart
provides the actual current chat UUID and installed bridge path. If that context is
absent, enable and trust the installed plugin hooks and open a new chat; never guess
the session from another chat or from a shared working directory.

## Transport contract

The added skill section tells the agent how to call the unchanged commands:

```powershell
& '<installed-plugin>\windows\desktop.ps1' --session-id '<current-chat-UUID>' hub home --json
& '<installed-plugin>\windows\desktop.ps1' --session-id '<current-chat-UUID>' shell 'git status --short'
```

Supported bridge forms use a literal path whose final component is `desktop.ps1`,
either a direct literal invocation or `& '<path>\windows\desktop.ps1'`, with literal
arguments and optional literal `--session-id '<UUID>'`. For `shell`, supply one literal
Bash source; a single call may use `shell --cwd '<path>' '<source>'`. Several literal
calls separated by semicolons are supported. Calls inside assignments, blocks, functions
and pipelines are inspected independently. Native literal `git`, `glab` and `gh` calls
are normalized for the original guards. The original `lock-ok` escape, quoting and
command policies remain with the original hook.

A recognized literal bridge path with nonliteral arguments is refused when the program
cannot be inspected. Variable or dynamically resolved paths such as
`$b='C:\plugin\windows\desktop.ps1'; & $b shell 'git push origin main'`, aliases,
expressions, wrappers, hosted tools and later `write_stdin` input are outside supported
recognition. This is advisory coverage of supported literal forms, not a security
boundary or arbitrary PowerShell parsing: dynamic calls have no exact-source guarding
guarantee. Use the literal forms above for guarded work.

The `path --windows` and `path --linux` bridge helpers convert drive/UNC paths before
native editing or changing the tool workdir. Git for original WSL worktrees runs
through the bridge Bash: their Linux Git pointers are not native Windows Git pointers.
Native editors and Windows build tools can use mapped file paths. Path options are
converted; message, goal, title and brief text remain opaque data.

Hook `cwd`, transcript paths, known policy path fields and patch headers are mapped
transiently. Patch contents and persisted Windows rollouts are not rewritten.
The effective tool workdir is selected before resolving the original project/user
hub home. An explicit `AGENT_HUB_HOME` retains precedence; a configured installer `HubHome` is a
fallback to the original project/user home resolution. Original child launch code passes
the resolved home to workers.

The bridge streams UTF-8 stdout through the PowerShell success pipeline. Both
`$json = & '<installed-plugin>\windows\desktop.ps1' ...` and a pipeline to
`ConvertFrom-Json` retain normal PowerShell capture semantics. stdin bytes from a
redirected input handle are forwarded unchanged; piped PowerShell objects become
UTF-8 text lines. The child exit code, including original policy statuses 3 and 4,
is retained in `$LASTEXITCODE`.

Each call writes its Base64 JSON payload to a temporary file rather than the Windows
command line. The payload includes arguments, forwarded environment and, for hooks,
`tool_input`; it may contain credentials. Neither bridge logs payload contents.
`finally` deletes the file on completion or a caught failure; forced process termination
can bypass that cleanup. Base64 provides no encryption or additional file protection.

stderr is drained separately and mixed UTF-16 WSL startup lines and UTF-8 Linux
errors are normalized to UTF-8. Only the exact known WSL localhost-proxy/NAT
startup warning is suppressed: it does not describe the invoked Linux command
and would otherwise pollute tools that merge stderr with JSON stdout. Other WSL
diagnostics and real child errors remain visible.

## Installed runtime

The native envelope is version `1.0.8-wsl.1`, based on upstream Delamain 1.0.8.
Its build receipt records unchanged hashes of all original `bin/` files and Python
hooks, and the original skill bodies before the transport prefix.

Linux workers need a complete Codex package and a dedicated Linux configuration/home.
The envelope's private `desktop-config.json` records the selected distribution, Linux CLI/home,
native CLI/home and hub-home fallback. Preserve machine configuration and existing authentication;
a provisioned link to existing authentication/session state is an installation choice, not a
requirement to copy credentials. The separate Linux configuration does not replace native model,
effort, approval or sandbox settings. Package into a new empty build directory and check the
receipt against the chosen source snapshot; see [preparation](windows-workflow.md#prepare-the-selected-installation).

The worker executable boundary routes only `app-server proxy` to the native Windows
Codex executable, using the native home and actual app markers. Other commands use
Linux Codex; detached workers do not inherit their coordinator's Desktop attribution.
No replacement daemon, scheduler, journal or worker orchestration is installed.

### Linux worker service route

When no explicit `HTTP_PROXY`, `HTTPS_PROXY` or `ALL_PROXY` (upper- or lower-case)
exists in the worker environment, the adapter reads the current Windows user's
manual Internet Settings proxy. A disabled manual proxy keeps the normal direct
route. An enabled HTTP proxy is reached through a worker-owned Linux loopback
listener and standard WSL interoperability stdin/stdout to a hidden Windows
PowerShell/.NET TCP helper. One long-lived helper per Linux worker compiles once
and multiplexes concurrent connections with bounded frames and per-direction credits.
New workers select the explicit `-Multiplex` protocol; the helper retains its original
raw stdio interface without that switch for active older workers during a package update.
This works when that proxy listens only on Windows
`127.0.0.1`; it adds no Windows network listener or firewall rule.
Any local process can connect to the unauthenticated Linux loopback listener, including
Windows processes when WSL localhost forwarding is enabled.

The relay copies opaque HTTP/CONNECT bytes. Authentication and TLS remain with
Linux Codex and the existing proxy; the helper never reads auth files or decodes
traffic. Proxy credentials in URLs, PAC-only discovery, SOCKS endpoints and
different manual HTTP/HTTPS endpoints are not supported by automatic discovery.
Use an explicit worker proxy environment for those configurations. `NO_PROXY`
and `no_proxy` retain their exact caller values; Windows proxy bypass lists are
not translated into the client's bypass syntax. Explicit proxy values, including
empty values, retain precedence.

Linux Codex retains its original PID and process group through `exec`. Each relay
watches that PID's Linux start token, so normal exit, `agent stop`, SIGKILL and PID
reuse close the listener and owned helpers. Detached workers replace an inherited
managed relay with their own route. There is no persistent relay daemon, cron job
or credential cache. The route bounds concurrent connections (32), directional
buffers (64 KiB), Windows TCP connect time (10 seconds), and idle connections
(5 minutes). A native helper also exits after interop stdin EOF even when the
upstream CONNECT socket stays open.

The existing [Windows terminal launcher](windows-wsl.md) remains available for an
independent Linux coordinator. Both routes use the original shared hub-home protocol.

## Validation scope

The regression controls cover native PowerShell/WSL transport and canonical declared-plugin
hook dispatch, including nested `functions.exec` calls with a deterministic localhost provider.
These controls use no authenticated model. Authenticated worker qualification needs isolated
fixtures and an actual internal-run record with source hashes, observed settings and cleanup.
The final PR records that evidence and any unavailable checks before claiming internal readiness.
A control's presence is not a claim that it passed on the reader's installation.

Scoped locks evaluate each bridge invocation at its own working directory. Unsupported dynamic,
conditional or background PowerShell location changes cannot establish a directory for guarded
actions; use an explicit tool workdir or one literal `shell --cwd` call. Native delegation hooks
read mapped Windows role profiles, including relative, drive and UNC paths. Linux workers keep
their separate Linux configuration home.

Offline regression entry points are `bash tests/t_windows_runtime_transport.sh`
in Linux and `python -m unittest discover -s tests -p test_windows_runtime_transport.py -v`
on Windows. Native controls require PowerShell 5.1 and 7; actual interop controls
use a throwaway Windows loopback echo proxy and verify helper cleanup after normal
exit and SIGKILL. They do not call external services or models.

Automatic scheduling is not enabled. Native successor creation/binding with a
restricted Windows sandbox and its platform-specific writable roots requires the
original per-request validation; a raw rollout lookup does not prove successful
native handoff. Do not claim that an untested successor, pending tell or unknown
delivery has completed. The original fail-open behavior for hook implementation
errors and its recognized-command coverage remain in place.

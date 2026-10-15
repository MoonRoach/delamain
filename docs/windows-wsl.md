# Windows terminal, Linux runtime

The Windows launcher is a transport for the original Delamain plugin in WSL2 Ubuntu.
Codex, Python tools, workers, journals and hooks execute in Linux. The launcher does
not port the plugin core, change its workflow or install Windows-native hooks.
Use a normal PowerShell terminal for the interactive coordinator.

For the end-to-end task path in the native Windows Codex app, see
[the Windows workflow](windows-workflow.md) and [Desktop transport](windows-desktop.md). The terminal route below remains a
separate Linux coordinator session.

## Prerequisites and runtime layout

Use an installed WSL2 distribution (default `Ubuntu`), Python 3.11+ and the complete
Linux Codex package, including its sibling resources and helper executables. The
launcher expects this dedicated layout in the Linux user's home:

```text
~/.local/share/delamain/
  source/                       original plugin source snapshot or checkout
  codex/<version>/bin/codex      complete Linux CLI package
  codex/<version>/codex-path/    packaged helpers
  codex/<version>/codex-resources/
  codex-home/                    dedicated Linux Codex state and configuration
    plugins/cache/delamain-codex/delamain/<version>/
```

Install and enable Delamain inside that Linux `CODEX_HOME` using the original
[Codex installation procedure](codex.md#install-in-codex). Authentication belongs
to the Linux Codex runtime; the launcher does not read, copy or transmit `auth.json`.
An explicitly provisioned symlink to an existing authentication file is a deployment
choice outside this launcher. Keep the complete CLI package together when updating.

Default runtime discovery selects the newest numeric version under `codex/` and
the dedicated installed Delamain cache. `source/` is not used as a fallback: commands
and hooks must agree on the installed plugin version. The CLI's `bin/` and installed
plugin's `bin/` are prepended to Linux `PATH`, including for detached workers.

Select and record the source snapshot, complete CLI version and dedicated Linux home for your
installation. Preserve existing native configuration and authentication. Source hashes or a build
receipt establish package identity; they do not prove final internal qualification. Keep acceptance
fixtures and hub state separate from normal user stages.

An Ubuntu installation with only the C locales needs `en_US.UTF-8` generated for the
original monitor's terminal controls. In WSL as root, run
`localedef -i en_US -f UTF-8 en_US.UTF-8` when `locale -a` does not list `en_US.utf8`.
For the upstream test suite, use a Linux-only `PATH` (plus the Codex package's
`bin/` and `codex-path/`), because some test shell commands do not quote inherited
Windows PATH entries with spaces. These are environment prerequisites; no original
plugin code is patched.

## Start the coordinator

From this checkout in a Windows terminal:

```powershell
.\windows\start.ps1
```

This starts interactive Linux Codex with `--enable hooks`,
`--dangerously-bypass-hook-trust` and
`--dangerously-bypass-approvals-and-sandbox`. It is the explicit unattended, full
access starter for the dedicated installation. The trust bypass covers **all hooks
loaded in that launch**, not only Delamain. The provisioned dedicated home contains
the reviewed original Delamain plugin; review the starter's scope again if adding
other plugins or changing the home. These flags do not persist hook trust.

For ordinary Codex permission settings and manual hook review, use the generic launcher:

```powershell
.\windows\delamain.ps1
# In Codex, enable hooks and review/trust them with /hooks as needed.
```

Once Codex loads the installed plugin, ask for `delamain:setup` for a new project,
then `delamain:hub` for coordination, following the original
[agent entry point](agents/README.md#install-or-operate). Hook execution requires the
Codex hooks feature and trusted hooks; a direct `hub` invocation does not launch a
coordinator or turn on hooks. Windows Codex Desktop sessions do not gain these Linux
hooks by running this script.

## Run commands from PowerShell

```powershell
.\windows\delamain.ps1 codex --version
.\windows\delamain.ps1 hub home --json
.\windows\delamain.ps1 agent spawn --help
.\windows\delamain.ps1 codex --cd 'C:\Projects\Example'
.\windows\delamain.ps1 codex 'Read the project and propose a plan.'
```

The dispatcher accepts `hub`, `agent`, `jlog`, `jwait`, `lock`, `roles`, `ask`,
`tell`, `nightq`, `delegation`, `agent-top`, `watchdog` and `codex`. With no arguments,
or a leading Codex option, it chooses `codex`. Use explicit `codex` before a positional
prompt. Original tool syntax is unchanged; use each command's `--help`.

PowerShell parses the call first: quote text with PowerShell syntax, for example
single quotes around `$`, backticks and shell metacharacters. After that parsing,
the launcher transports argument boundaries, empty strings, Unicode, embedded
quotes and newlines in a UTF-8 JSON/Base64 payload file, so a large prompt or
forwarded environment does not consume the Windows command-line limit. The
per-call file is deleted in `finally` after completion or failure; abrupt process
termination can leave it behind. Its arguments/environment can contain sensitive data. It never inserts user arguments
into a Linux shell command. Base64 is transport encoding, not encryption; avoid
putting credentials in command-line arguments.

The current Windows filesystem directory is mapped with `wslpath`. Entire absolute
Windows drive or UNC path arguments are mapped, as are the values of
`--cwd=`, `--brief=`, `--repo=`, `--out=` and `--handoff=`. Separate option values use
the same entire-path rule. Linux paths and relative paths retain Linux semantics;
relative paths resolve from the mapped working directory. A prompt or inline brief
containing a Windows path within its text is left intact. Paths inside brief file
contents, JSON, comma-separated lists or arbitrary option values are not rewritten.
UNC paths must be accessible to the selected WSL distribution.

Exit status is forwarded to `$LASTEXITCODE`. Normal terminal input goes directly to
WSL, preserving the terminal for interactive Codex. Piped PowerShell objects are
forwarded as UTF-8 text; this is not a binary pipe or a Windows hook transport.

## Environment contract

Set overrides in the calling PowerShell process; no user profile changes are needed:

```powershell
$env:DELAMAIN_WSL_DISTRO = 'Ubuntu'
$env:AGENT_HUB_HOME = '/absolute/linux/path/to/hub-home'
$env:HUB_STAGE = 'example-stage'
.\windows\delamain.ps1 hub home --json
```

| Variable | Contract |
|---|---|
| `DELAMAIN_WSL_DISTRO` | WSL distribution name; default `Ubuntu`. |
| `DELAMAIN_CODEX_PATH` | Optional absolute executable path to the complete Linux package's `bin/codex`. |
| `DELAMAIN_PLUGIN_ROOT` | Optional absolute installed plugin root containing `bin/hub`. Must match the plugin loaded in Codex. |
| `DELAMAIN_CODEX_HOME` | Optional dedicated Linux Codex home; default `~/.local/share/delamain/codex-home`. The resulting Linux `CODEX_HOME` is set explicitly. |
| `AGENT_HUB_HOME` | Forwarded when set; otherwise Linux environment value or `~/agent-hub`. Whole absolute Windows paths are converted. |
| `AGENT_HUB_ENGINE` | Forwarded when set; otherwise Linux environment value or `codex`. |
| Other `AGENT_HUB_*`, `HUB_*`, `CODEX_THREAD_ID` | Forwarded verbatim when present in Windows; otherwise the existing Linux environment is retained. |
| `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY` (also lower-case) | Forwarded verbatim. Explicit proxy values, including empty values, take precedence over automatic Windows proxy discovery. |

Runtime override paths also accept whole absolute Windows paths via `wslpath`.
Other forwarded environment values are opaque strings, including paths embedded in
configuration text; supply Linux paths there. Linux `HOME` remains the WSL user's
home. Windows `HOME`, `PATH`, `CODEX_HOME` and unrelated environment variables are not
copied by the launcher. WSL's own environment interoperability still applies.

Linux coordinator and detached Codex launches use the same per-process Windows
system HTTP proxy route described in
[Linux worker service route](windows-desktop.md#linux-worker-service-route).
The launcher points `CODEX_BIN` at its bundled `worker_proxy.py` and records the
original Linux executable in `DELAMAIN_LINUX_CODEX`, so each detached worker owns
its own relay. Install `delamain.ps1`, `process_transport.ps1`, `launch.py`, `worker_proxy.py`
and `proxy_tcp.ps1` together;
the worker adapter must be executable in Linux. No Windows Python runtime or project-specific
virtual environment is required. The original Linux executable, home, PID and
worker orchestration remain in use.

This layer does not install cron jobs, register startup services or change native
Windows profiles. Watchdog installation and other operating steps remain the original
Linux plugin's responsibility and require the user's intended setup scope.

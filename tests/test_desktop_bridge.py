"""Transport regression tests; native integration needs Windows + Ubuntu WSL."""
from __future__ import annotations

import importlib.util
import base64
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import sys

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("desktop_runtime", ROOT / "windows/desktop_runtime.py")
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)
CODEX_SPEC = importlib.util.spec_from_file_location("desktop_codex", ROOT / "windows/desktop_codex.py")
codex = importlib.util.module_from_spec(CODEX_SPEC)
CODEX_SPEC.loader.exec_module(codex)
SID = "11111111-1111-4111-8111-111111111111"
OTHER = "22222222-2222-4222-8222-222222222222"
sys.path.insert(0, str(ROOT / "hooks"))
sys.path.insert(0, str(ROOT / "bin"))
import codex_compat
import board_locks
import subagent_rules


class PathTests(unittest.TestCase):
    def test_argument_paths_only_at_explicit_file_options(self):
        with patch.object(runtime, "linux_path", side_effect=lambda s: "/mapped/" + s if runtime.windows_path(s) else s):
            result = runtime.convert_args(["--goal", "C:\\literal\\goal", "--cwd", "C:\\repo", "--handoff=C:\\HANDOFF-x.md", "C:\\literal message"], "hub")
            self.assertEqual(result, ["--goal", "C:\\literal\\goal", "--cwd", "/mapped/C:\\repo", "--handoff=/mapped/C:\\HANDOFF-x.md", "C:\\literal message"])
            self.assertEqual(runtime.convert_args(["send", "session", "C:\\literal\\message"], "agent"), ["send", "session", "C:\\literal\\message"])
            self.assertEqual(runtime.convert_args(["send", "session", "--cwd", "C:\\literal\\message"], "agent"), ["send", "session", "--cwd", "C:\\literal\\message"])
            self.assertEqual(runtime.convert_args(["--", "--cwd", "C:\\literal"], "hub"), ["--", "--cwd", "C:\\literal"])
            self.assertEqual(runtime.convert_args(["rename", "--to", "C:\\literal"], "hub"), ["rename", "--to", "C:\\literal"])
            self.assertEqual(runtime.convert_args(["home", "migrate", "--to", "C:\\home"], "hub"), ["home", "migrate", "--to", "/mapped/C:\\home"])

    def test_patch_headers_not_content(self):
        command = "*** Begin Patch\n*** Add File: C:\\repo\\HANDOFF-test.md\n+C:\\literal\\must-stay.md\n*** Move to: \\\\server\\share\\HANDOFF-next.md\n*** End Patch"
        with patch.object(runtime, "linux_path", side_effect=lambda s: "/mapped/" + s if runtime.windows_path(s) else s):
            event = runtime.normalize_event({"tool_name": "apply_patch", "tool_input": {"command": command}}, {})
        result = event["tool_input"]["command"]
        self.assertIn("*** Add File: /mapped/C:\\repo\\HANDOFF-test.md", result)
        self.assertIn("+C:\\literal\\must-stay.md", result)
        self.assertIn("*** Move to: /mapped/\\\\server\\share\\HANDOFF-next.md", result)

    def test_structured_fields_only(self):
        source = {"cwd": "C:\\repo", "transcript_path": "C:\\rollout.jsonl", "agent_transcript_path": "C:\\agent.jsonl",
                  "sandbox_policy": {"writable_roots": ["C:\\repo", "/tmp"]},
                  "tool_input": {"command": "echo C:\\repo"}, "prompt": "C:\\repo"}
        with patch.object(runtime, "linux_path", side_effect=lambda s: "/mapped/" + s if runtime.windows_path(s) else s):
            result = runtime.map_paths(source)
        self.assertEqual(result["cwd"], "/mapped/C:\\repo")
        self.assertEqual(result["agent_transcript_path"], "/mapped/C:\\agent.jsonl")
        self.assertEqual(result["sandbox_policy"]["writable_roots"], ["/mapped/C:\\repo", "/tmp"])
        self.assertEqual(result["tool_input"], source["tool_input"])
        self.assertEqual(result["prompt"], source["prompt"])

    def test_utf16_offsets_and_all_segments(self):
        command = "echo '😀'; & 'X/desktop.ps1' shell 'gh pr merge 1'; & 'Y/desktop.ps1' shell 'sleep 120'"
        replacements = []
        for text, source in [("& 'X/desktop.ps1' shell 'gh pr merge 1'", "gh pr merge 1"),
                             ("& 'Y/desktop.ps1' shell 'sleep 120'", "sleep 120")]:
            at = command.index(text)
            replacements.append({"kind": "shell", "start": len(command[:at].encode("utf-16-le")) // 2,
                                 "end": len(command[:at + len(text)].encode("utf-16-le")) // 2, "script": source})
        self.assertEqual(runtime.translated_command(command, replacements), "echo '😀'; gh pr merge 1; sleep 120")

    def test_context_retains_outer_syntax_and_companion_side_effects(self):
        bridge = "& 'X/desktop.ps1' shell 'hub handoff --stage review'"
        original = "$result = " + bridge + "; [IO.File]::WriteAllText('/tmp/side-effect','x')"
        at = original.index(bridge)
        payload = {"hook": "context_budget", "command_replacements": [{"kind": "shell", "script": "hub handoff --stage review", "start": at, "end": at + len(bridge)}],
                   "command_projection": [{"kind": "shell", "script": "hub handoff --stage review"}]}
        result = runtime.normalize_event({"tool_name": "Bash", "tool_input": {"command": original}}, payload)
        self.assertEqual(result["tool_input"]["command"], "$result = hub handoff --stage review; [IO.File]::WriteAllText('/tmp/side-effect','x')")


def registered_hook_names():
    manifest = json.loads((ROOT / "hooks/codex-hooks.json").read_text(encoding="utf-8"))
    names = set()
    for groups in manifest["hooks"].values():
        for group in groups:
            for handler in group["hooks"]:
                match = re.search(r"/hooks/([a-z_]+)\.py", handler["command"])
                if not match:
                    raise AssertionError("Unknown registered hook: " + handler["command"])
                names.add(match[1])
    return names


class HookDispatchTests(unittest.TestCase):
    def test_runtime_supports_every_registered_transport_hook(self):
        # no_compaction terminates in PowerShell before the WSL runtime.
        self.assertEqual(runtime.HOOKS, registered_hook_names() - {"no_compaction"})


class NativeHookDispatchTests(unittest.TestCase):
    """Exercise real parameter validation independently of WSL or installation."""
    @classmethod
    def setUpClass(cls):
        cls.shells = list(dict.fromkeys(shell for shell in
            (shutil.which("powershell.exe"), shutil.which("pwsh.exe")) if shell))
        if not cls.shells or (os.name != "nt" and not shutil.which("wslpath")):
            raise unittest.SkipTest("Windows PowerShell executable access is required")
        cls.temp = tempfile.TemporaryDirectory(prefix="hook-dispatch-native-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.scratch = Path(cls.temp.name)
        shutil.copy2(ROOT / "windows/desktop_hook.ps1", cls.scratch / "desktop_hook.ps1")
        (cls.scratch / "desktop.ps1").write_text(
            "param([string]$Mode, [string]$Payload)\n"
            "if ($Mode -ne '--hook-payload') { throw 'unexpected transport mode' }\n"
            "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload)); exit 37\n",
            encoding="utf-8")
        native = str(cls.scratch) if os.name == "nt" else subprocess.check_output(
            ["wslpath", "-w", str(cls.scratch)], text=True, cwd=ROOT).strip()
        cls.script = native + "\\desktop_hook.ps1"

    def invoke(self, shell, name):
        return subprocess.run([shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", self.script,
            "-Hook", name],
            input='{"hook_event_name":"SessionStart"}', capture_output=True,
            encoding="utf-8", errors="replace", cwd=ROOT, timeout=15)

    def test_every_registered_hook_passes_native_parameter_validation(self):
        for shell in self.shells:
            for name in sorted(registered_hook_names()):
                with self.subTest(shell=shell, hook=name):
                    run = self.invoke(shell, name)
                    if name == "no_compaction":
                        self.assertEqual(run.returncode, 0, run.stderr)
                        self.assertIs(json.loads(run.stdout)["continue"], False)
                    else:
                        self.assertEqual(run.returncode, 37, run.stderr)
                        self.assertEqual(json.loads(run.stdout)["hook"], name)
                    self.assertEqual(run.stderr, "")

    def test_unknown_hook_is_rejected_before_transport(self):
        for shell in self.shells:
            with self.subTest(shell=shell):
                run = self.invoke(shell, "unknown_hook")
                self.assertNotEqual(run.returncode, 0)
                self.assertNotEqual(run.returncode, 37)
                self.assertEqual(run.stdout.strip(), "")
                self.assertIn("unknown_hook", run.stderr)


class NoCompactionPackageTests(unittest.TestCase):
    def test_builder_packages_terminal_launcher_without_changing_core(self):
        spec = importlib.util.spec_from_file_location("desktop_builder", ROOT / "windows/build_desktop_plugin.py")
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        with tempfile.TemporaryDirectory(prefix="agent-top-package-") as scratch:
            package = Path(scratch) / "package"
            receipt = builder.build(ROOT, package, {"Distro": "fixture"})
            self.assertEqual(receipt['version'], '1.0.9-wsl.1')
            self.assertTrue(receipt['core_unchanged'])
            self.assertEqual((package / 'windows/agent-top.ps1').read_bytes(),
                             (ROOT / 'windows/agent-top.ps1').read_bytes())
            self.assertEqual((package / 'bin/agent-top').read_bytes(), (ROOT / 'bin/agent-top').read_bytes())
            self.assertEqual(json.loads((package / '.codex-plugin/plugin.json').read_text())['version'], receipt['version'])

    def test_builder_preserves_precompact_registration_and_adds_native_handler(self):
        spec = importlib.util.spec_from_file_location("desktop_builder", ROOT / "windows/build_desktop_plugin.py")
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        with tempfile.TemporaryDirectory(prefix="no-compaction-build-") as scratch:
            package = Path(scratch) / "package"
            receipt = builder.build(ROOT, package, {})
            original = json.loads((ROOT / "hooks/codex-hooks.json").read_text())
            built = json.loads((package / "hooks/codex-hooks.json").read_text())
            self.assertEqual(set(original['hooks']), set(built['hooks']))
            for event, groups in original['hooks'].items():
                for group, packaged in zip(groups, built['hooks'][event], strict=True):
                    self.assertEqual(group.get('matcher'), packaged.get('matcher'))
                    for handler, native in zip(group['hooks'], packaged['hooks'], strict=True):
                        self.assertEqual(handler['command'], native['command'])
                        if event == 'PreCompact':
                            self.assertIn('-Hook no_compaction', native['commandWindows'])
                            self.assertNotIn('-HookArgs', native['commandWindows'])
            self.assertEqual(built['hooks']['PreCompact'][0]['matcher'], '^(manual|auto)$')
            self.assertEqual((ROOT / 'hooks/no_compaction.py').read_bytes(),
                             (package / 'hooks/no_compaction.py').read_bytes())
        self.assertIn(str(Path('hooks') / 'no_compaction.py'), receipt['core_hashes'])


@unittest.skipUnless(os.name == 'nt', 'native Windows PowerShell controls')
class NativeAgentTopLauncherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shells = list(dict.fromkeys(shell for shell in
            (shutil.which('powershell.exe'), shutil.which('pwsh.exe')) if shell))
        if not cls.shells:
            raise unittest.SkipTest('PowerShell executable access is required')

    def probe(self, shell, source):
        encoded = base64.b64encode(source.encode('utf-16-le')).decode('ascii')
        return subprocess.run([shell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded],
                              capture_output=True, encoding='utf-8', errors='replace', timeout=20)

    def test_inherited_terminal_call_ast_with_negative_control(self):
        launcher = str(ROOT / 'windows/agent-top.ps1').replace("'", "''")
        # A direct native pipeline with one element inherits handles; assignments,
        # pipes and subprocess wrappers would take terminal ownership away.
        source = r"""
function Test-DirectTerminal($tree) {
    $calls = @($tree.FindAll({ param($n)
        $n -is [Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'wsl.exe' -and
        @($n.CommandElements | Where-Object { $_.Extent.Text -eq 'python3' }).Count -eq 1
    }, $true))
    return ($calls.Count -eq 1 -and
        $calls[0].Parent -is [Management.Automation.Language.PipelineAst] -and
        $calls[0].Parent.PipelineElements.Count -eq 1 -and
        $calls[0].Parent.Parent -is [Management.Automation.Language.StatementBlockAst] -and
        $calls[0].Redirections.Count -eq 0)
}
$tokens=$null; $errors=$null
$tree=[Management.Automation.Language.Parser]::ParseFile('LAUNCHER',[ref]$tokens,[ref]$errors)
if ($errors.Count -or -not (Test-DirectTerminal $tree)) { exit 91 }
foreach ($bad in @('$x = & wsl.exe --exec python3 runner',
                  '& wsl.exe --exec python3 runner | Out-String',
                  '& wsl.exe --exec python3 runner > output',
                  'Start-Process wsl.exe -WindowStyle Hidden')) {
    $tree=[Management.Automation.Language.Parser]::ParseInput($bad,[ref]$tokens,[ref]$errors)
    if (Test-DirectTerminal $tree) { exit 92 }
}
""".replace('LAUNCHER', launcher)
        for shell in self.shells:
            with self.subTest(shell=shell):
                run = self.probe(shell, source)
                self.assertEqual(run.returncode, 0, run.stderr)

    def test_payload_unicode_config_reload_exit_and_cleanup_without_wsl(self):
        with tempfile.TemporaryDirectory(prefix='agent-top-native-') as scratch:
            folder = Path(scratch) / 'package юникод' / 'windows'
            folder.mkdir(parents=True)
            shutil.copy2(ROOT / 'windows/agent-top.ps1', folder / 'agent-top.ps1')
            (folder / 'desktop_runtime.py').write_text('# transport fixture\n')
            report = Path(scratch) / 'report.json'
            quote = lambda value: "'" + str(value).replace("'", "''") + "'"
            source = r"""
$env:CODEX_THREAD_ID='SID'
$env:AGENT_SESSION_ID='stale'
$env:UNRELATED_SECRET='must-not-forward'
$env:AGENT_HUB_TEST='forwarded'
$global:fixtureMaps=@()
function global:wsl.exe {
    if ($args[3] -eq 'wslpath') {
        $global:fixtureMaps += [string]$args[-1]
        $global:LASTEXITCODE=0
        return $args[-1]
    }
    $file=[string]$args[-1]
    $data=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([IO.File]::ReadAllText($file))) | ConvertFrom-Json
    @{payload=$data; command=@($args); maps=$global:fixtureMaps; file=$file} |
        ConvertTo-Json -Depth 100 | Set-Content -LiteralPath REPORT -Encoding UTF8
    Write-Output 'terminal-fixture'
    $global:LASTEXITCODE=17
}
& LAUNCHER --once --stage 'этап 😀' --agent 'literal $HOME `text`'
exit $LASTEXITCODE
""".replace('SID', SID).replace('REPORT', quote(report)).replace('LAUNCHER', quote(folder / 'agent-top.ps1'))
            for shell in self.shells:
                for distro in ('fixture-one', 'fixture-two'):
                    with self.subTest(shell=shell, distro=distro):
                        (folder / 'desktop-config.json').write_text(json.dumps({'Distro': distro, 'LinuxHome': '/fixture'}))
                        run = self.probe(shell, source)
                        self.assertEqual(run.returncode, 17, run.stderr)
                        self.assertEqual(run.stdout.strip(), 'terminal-fixture')
                        data = json.loads(report.read_text(encoding='utf-8-sig'))
                        payload = data['payload']
                        self.assertEqual(payload['mode'], 'tool')
                        self.assertEqual(payload['argv'], ['agent-top', '--once', '--stage', 'этап 😀', '--agent', 'literal $HOME `text`'])
                        self.assertEqual(payload['pluginroot'], str(folder.parent))
                        self.assertEqual(payload['config']['Distro'], distro)
                        self.assertEqual(payload['env']['AGENT_SESSION_ID'], SID)
                        self.assertEqual(payload['env']['AGENT_HUB_TEST'], 'forwarded')
                        self.assertNotIn('UNRELATED_SECRET', payload['env'])
                        self.assertEqual(data['command'][:5], ['--distribution', distro, '--exec', 'python3', str(folder / 'desktop_runtime.py')])
                        self.assertEqual(data['maps'][0], str(folder / 'desktop_runtime.py'))
                        self.assertFalse(Path(data['file']).exists())
                report.unlink()
                (folder / 'desktop-config.json').unlink()
                run = self.probe(shell, source)
                self.assertEqual(run.returncode, 1)
                self.assertFalse(report.exists(), 'missing config must fail before transport')


class NativeNoCompactionTests(unittest.TestCase):
    """Run real PowerShell with no WSL on PATH and a failing transport control."""
    @classmethod
    def setUpClass(cls):
        cls.shells = list(dict.fromkeys(shell for shell in
            (shutil.which('powershell.exe'), shutil.which('pwsh.exe')) if shell))
        if not cls.shells or (os.name != 'nt' and not shutil.which('wslpath')):
            raise unittest.SkipTest('Windows PowerShell executable access is required')
        # Under WSL this checkout is on a Windows drive; no installed copy is used.
        cls.temp = tempfile.TemporaryDirectory(prefix='.no-compaction-native-', dir=ROOT)
        cls.addClassCleanup(cls.temp.cleanup)
        cls.scratch = Path(cls.temp.name)
        shutil.copy2(ROOT / 'windows/desktop_hook.ps1', cls.scratch / 'desktop_hook.ps1')
        (cls.scratch / 'desktop.ps1').write_text(
            "[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'transport-called'), 'called'); exit 97\n")
        cls.native = str(cls.scratch) if os.name == 'nt' else subprocess.check_output(
            ['wslpath', '-w', str(cls.scratch)], text=True, cwd=ROOT).strip()
        cls.quoted = cls.native.replace("'", "''")

    def invoke(self, shell, hook, raw, *, wait_for_stdin_eof=True):
        # Set paths inside the native child as WSL environment forwarding varies.
        # The fresh directory contains no wsl.exe, config, Python or transcript.
        source = ("$env:PATH='" + self.quoted + "'; "
                  "$env:HOME='" + self.quoted + "'; $env:USERPROFILE=$env:HOME; "
                  "$env:TEMP=$env:HOME; $env:TMP=$env:HOME; "
                  "$env:AGENT_HUB_HOME=$env:HOME; $env:AGENT_HUB_CONTEXT_BUDGET='off'; "
                  "if (Get-Command wsl.exe -ErrorAction SilentlyContinue) { throw 'WSL must be unavailable' }; "
                  "& '" + self.quoted + "\\desktop_hook.ps1' -Hook '" + hook + "'; exit $LASTEXITCODE")
        args = [shell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', source]
        if not wait_for_stdin_eof:
            run = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, encoding='utf-8', errors='replace', cwd=ROOT)
            try:
                code = run.wait(timeout=15)
                return subprocess.CompletedProcess(args, code, run.stdout.read(), run.stderr.read())
            finally:
                if run.poll() is None:
                    run.kill()
                    run.wait()
                run.stdin.close()
                run.stdout.close()
                run.stderr.close()
        return subprocess.run(args,
            input=raw, capture_output=True, encoding='utf-8', errors='replace', cwd=ROOT, timeout=15)

    def test_veto_auto_manual_and_missing_input_without_wsl(self):
        expected = subprocess.run([sys.executable, str(ROOT / 'hooks/no_compaction.py')],
            capture_output=True, text=True, cwd=ROOT, timeout=5)
        self.assertEqual(expected.returncode, 0, expected.stderr)
        output = json.loads(expected.stdout)
        self.assertEqual(set(output), {'continue', 'stopReason', 'systemMessage'})
        self.assertIs(output['continue'], False)
        self.assertEqual(output['stopReason'], 'Delamain forbids automatic and manual compaction. Save a checkpoint and follow the existing handoff policy.')
        self.assertEqual(output['systemMessage'], 'Delamain blocked compaction. If the automatic context limit has been reached, this session may stop before an answer; continue from its checkpoint with a fresh coordinator for the same stage under existing authority. Repeating prompts in an overfull session will not help. Below that limit, normal prompts and tools can continue.')
        marker = self.scratch / 'transport-called'
        marker.unlink(missing_ok=True)
        payloads = ['', '{}', 'null', 'invalid JSON']
        for trigger in ('auto', 'manual'):
            payloads.extend(json.dumps({'hook_event_name': 'PreCompact', 'trigger': trigger, **extra})
                for extra in ({}, {'session_id': SID, 'transcript_path': 'Z:\\missing'},
                              {'agent_id': 'child', 'agent_transcript_path': 'Z:\\missing'}))
        for shell in self.shells:
            for raw in payloads:
                with self.subTest(shell=shell, payload=raw):
                    run = self.invoke(shell, 'no_compaction', raw)
                    self.assertEqual(run.returncode, 0, run.stderr)
                    self.assertEqual(run.stderr, '')
                    self.assertEqual(json.loads(run.stdout), json.loads(expected.stdout))
                    self.assertFalse(marker.exists(), 'veto must not invoke transport')

    def test_veto_exits_before_stdin_eof_without_wsl(self):
        expected = subprocess.run([sys.executable, str(ROOT / 'hooks/no_compaction.py')],
            capture_output=True, text=True, cwd=ROOT, timeout=5)
        self.assertEqual(expected.returncode, 0, expected.stderr)
        marker = self.scratch / 'transport-called'
        for shell in self.shells:
            with self.subTest(shell=shell):
                marker.unlink(missing_ok=True)
                run = self.invoke(shell, 'no_compaction', '', wait_for_stdin_eof=False)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertEqual(run.stderr, '')
                self.assertEqual(json.loads(run.stdout), json.loads(expected.stdout))
                self.assertFalse(marker.exists(), 'veto must not invoke transport')

    def test_unrelated_hook_keeps_existing_transport_and_exit(self):
        marker = self.scratch / 'transport-called'
        for shell in self.shells:
            with self.subTest(shell=shell):
                marker.unlink(missing_ok=True)
                run = self.invoke(shell, 'questions', json.dumps({'hook_event_name': 'SessionStart'}))
                self.assertEqual(run.returncode, 97, run.stderr)
                self.assertEqual(run.stdout.strip(), '')
                self.assertTrue(marker.exists(), 'unrelated hooks must still invoke transport')


class CodexSelectionTests(unittest.TestCase):
    def select(self, args):
        config = {"LinuxHome": "/desktop-home", "LinuxCodex": "/linux/codex", "WindowsCodex": "C:\\codex.exe", "WindowsCodexHome": "C:\\native-home"}
        with patch.object(codex.Path, "read_text", return_value=json.dumps(config)), patch.object(codex.sys, "argv", ["adapter", *args]), \
             patch.dict(codex.os.environ, {"CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Codex Desktop", "CODEX_APP_TOOLS_PIPE_PATH": "native-pipe",
                                          "WSLENV": "CUSTOM:CODEX_HOME/p:CODEX_APP_TOOLS_PIPE_PATH/p"}, clear=True), \
             patch("worker_proxy.prepare_proxy", return_value=None), \
             patch.object(codex.subprocess, "check_output", return_value="/mnt/c/codex.exe\n"), patch.object(codex.os, "execvpe") as execute:
            codex.main()
            return execute.call_args.args

    def test_workers_use_linux_home_and_strip_native_markers(self):
        executable, args, env = self.select(["exec", "--json", "literal $prompt"])
        self.assertEqual(executable, "/linux/codex")
        self.assertEqual(args, ["/linux/codex", "exec", "--json", "literal $prompt"])
        self.assertEqual(env["CODEX_HOME"], "/desktop-home")
        self.assertNotIn("CODEX_APP_TOOLS_PIPE_PATH", env)
        self.assertNotIn("CODEX_INTERNAL_ORIGINATOR_OVERRIDE", env)
        self.assertNotIn("CODEX_APP_TOOLS_PIPE_PATH", env["WSLENV"])

    def test_app_server_uses_native_executable_home_and_exported_markers(self):
        executable, args, env = self.select(["app-server", "proxy"])
        self.assertEqual(executable, "/mnt/c/codex.exe")
        self.assertEqual(args, ["/mnt/c/codex.exe", "app-server", "proxy"])
        self.assertEqual(env["CODEX_HOME"], "C:\\native-home")
        self.assertEqual(env["CODEX_APP_TOOLS_PIPE_PATH"], "native-pipe")
        self.assertIn("CODEX_HOME", env["WSLENV"].split(":"))
        self.assertIn("CODEX_APP_TOOLS_PIPE_PATH", env["WSLENV"].split(":"))
        self.assertNotIn("CODEX_HOME/p", env["WSLENV"])

    def test_app_server_daemon_does_not_select_native_transport(self):
        executable, args, env = self.select(["app-server"])
        self.assertEqual(executable, "/linux/codex")
        self.assertNotIn("CODEX_APP_TOOLS_PIPE_PATH", env)


@unittest.skipIf(os.name == "nt", "POSIX home resolution and lock board require WSL")
class HubHomeFallbackTests(unittest.TestCase):
    def test_configured_home_and_resolution_priority_in_isolated_repository(self):
        for selection in ("default", "user", "project", "env", "legacy", "standard"):
            with self.subTest(selection=selection), tempfile.TemporaryDirectory(prefix="desktop-home-") as directory:
                scratch = Path(directory).resolve()
                home, repo, package = scratch / "home", scratch / "repo", scratch / "package"
                home.mkdir()
                (repo / ".git").mkdir(parents=True)
                for name in ("bin", "hooks", "windows"):
                    shutil.copytree(ROOT / name, package / name, ignore=shutil.ignore_patterns("__pycache__"))
                configured = scratch / "configured-hub"
                expected = configured
                env = {"HOME": str(home), "PATH": os.defpath, "AGENT_HUB_TZ": "UTC"}
                layer = selection
                if selection in ("project", "user"):
                    (repo / ".agent-hub").mkdir()
                    (repo / ".agent-hub/config.json").write_text(json.dumps({"AGENT_HUB_HOME": selection}))
                    if selection == "project":
                        expected = repo / ".agent-hub/local"
                elif selection == "env":
                    expected = scratch / "explicit-hub"
                    env["AGENT_HUB_HOME"] = str(expected)
                elif selection == "legacy":
                    expected = home / ".claude/agent-hub"
                    expected.mkdir(parents=True)
                elif selection == "standard":
                    configured = expected = home / "agent-hub"
                    layer = "default"
                # Read the real resolver before transport: no mocked user layer.
                probe = subprocess.run([sys.executable, "-c",
                    "import sys; sys.path.insert(0, sys.argv[1]); import hubcore; print(hubcore.home().layer)",
                    str(package / "bin")], cwd=repo, env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(probe.returncode, 0, probe.stderr)
                self.assertEqual(probe.stdout.strip(), layer)
                config = {"LinuxHome": str(scratch / "codex"), "WindowsCodexHome": str(scratch / "native"),
                          "LinuxCodex": "/bin/true", "HubHome": str(configured)}
                payload = {"mode": "tool", "cwd": str(repo), "pluginroot": str(package), "config": config,
                           "env": {"CODEX_THREAD_ID": OTHER, "AGENT_SESSION_ID": OTHER}}
                def invoke(data, as_json=True):
                    encoded = base64.b64encode(json.dumps(data).encode()).decode()
                    run = subprocess.run([sys.executable, str(package / "windows/desktop_runtime.py"), encoded],
                                         cwd=repo, env=env, capture_output=True, text=True, timeout=10)
                    self.assertEqual(run.returncode, 0, run.stderr)
                    self.assertNotIn("fail-open", run.stderr)
                    return json.loads(run.stdout) if as_json and run.stdout.strip() else {}
                resolved = invoke({**payload, "argv": ["hub", "home", "--json"]})
                self.assertEqual(resolved["home"], str(expected))
                invoke({**payload, "argv": ["lock", "take", "main-merge", "--repo", "*",
                    "--until", "2099-01-01T00:00", "--why", "isolated home fixture"]}, as_json=False)
                self.assertTrue((expected / "board.md").is_file())
                event = {"hook_event_name": "PreToolUse", "session_id": SID, "cwd": str(repo),
                         "tool_name": "Bash", "tool_input": {"command": "gh pr merge 42"}}
                hook = {**payload, "mode": "hook", "hook": "board_locks", "event": event}
                self.assertEqual(invoke(hook)["hookSpecificOutput"]["permissionDecision"], "deny")
                event["tool_input"]["command"] = "gh pr view 42"
                self.assertFalse(invoke(hook))
                if expected != configured:
                    self.assertFalse(configured.exists())
                if selection != "standard":
                    self.assertFalse((home / "agent-hub").exists())


@unittest.skipIf(os.name == "nt", "POSIX policy evaluators require WSL (fcntl lock board)")
class PolicyBoundaryTests(unittest.TestCase):
    """Original policy evaluators with distinct, isolated native/worker homes."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="desktop-policy-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.a, self.b = self.root / "repo-A", self.root / "repo-B"
        for repo in (self.a, self.b):
            (repo / ".git").mkdir(parents=True)
        self.native, self.linux = self.root / "native ё", self.root / "linux"
        self.native.mkdir()
        self.linux.mkdir()
        self.env = {"HOME": str(self.root), "PATH": os.defpath, "TMPDIR": str(self.root),
                    "AGENT_HUB_HOME": str(self.root / "hub"), "AGENT_HUB_TZ": "UTC"}
        Path(self.env["AGENT_HUB_HOME"]).mkdir()
        self.config = {"LinuxHome": str(self.linux), "WindowsCodexHome": str(self.native),
                       "LinuxCodex": "/bin/true", "HubHome": self.env["AGENT_HUB_HOME"]}
        run = subprocess.run([sys.executable, str(ROOT / "bin/lock"), "take", "main-merge",
                              "--repo", self.a.name, "--until", "2099-01-01T00:00", "--why", "scoped fixture"],
                             capture_output=True, text=True, env={**self.env, "CODEX_THREAD_ID": OTHER}, cwd=self.a, timeout=5)
        self.assertEqual(run.returncode, 0, run.stderr)

    def payload(self, projection=None, cwd=None, workdir=None, hook="board_locks"):
        event = {"hook_event_name": "PreToolUse", "session_id": SID, "cwd": str(cwd or self.a),
                 "tool_name": "Bash", "tool_input": {"command": "native source"}}
        if workdir:
            event["tool_input"]["workdir"] = str(workdir)
        return {"mode": "hook", "hook": hook, "event": event, "command_projection": projection or [],
                "pluginroot": str(ROOT), "cwd": str(self.a), "config": self.config, "env": self.env}

    def run_payload(self, payload):
        encoded = base64.b64encode(json.dumps(payload).encode()).decode()
        run = subprocess.run([sys.executable, str(ROOT / "windows/desktop_runtime.py"), encoded],
                             capture_output=True, text=True, env=self.env, cwd=self.a, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotIn("fail-open", run.stderr)
        return json.loads(run.stdout) if run.stdout.strip() else {}

    def shell(self, source):
        return {"kind": "shell", "script": source}

    def denied(self, payload):
        return self.run_payload(payload).get("hookSpecificOutput", {}).get("permissionDecision") == "deny"

    def test_separate_process_cd_cannot_hide_scoped_lock(self):
        calls = [self.shell("cd " + str(self.b)), self.shell("git push origin HEAD:main")]
        payload = self.payload(calls)
        self.assertTrue(self.denied(payload))
        self.assertFalse(self.denied(self.payload([calls[0], self.shell("git status --short")])))
        # A cd in the SAME Bash program still changes its effective repository.
        self.assertFalse(self.denied(self.payload([self.shell("cd " + str(self.b) + "; git push origin HEAD:main")])))
        self.assertTrue(self.denied(self.payload([self.shell("cd " + str(self.a) + "; git push origin HEAD:main")], cwd=self.b)))

    def test_tool_workdir_and_native_location_use_actual_repo(self):
        action = self.shell("git push origin HEAD:main")
        self.assertFalse(self.denied(self.payload([action], workdir=self.b)))
        self.assertTrue(self.denied(self.payload([action], cwd=self.b, workdir=self.a)))
        self.assertFalse(self.denied(self.payload([{"kind": "location", "path": str(self.b)}, action])))
        self.assertTrue(self.denied(self.payload([{"kind": "location", "path": str(self.a)}, action], cwd=self.b)))
        self.assertFalse(self.denied(self.payload([{"kind": "location", "path": "../repo-B"}, action])))

    def test_conditional_dynamic_and_invalid_location_fail_closed(self):
        for location in ({"kind": "location", "path": str(self.b), "uncertain_cwd": True},
                         {"kind": "raw", "script": "Set-Location $path", "uncertain_cwd": True},
                         {"kind": "location", "path": str(self.root / "missing")}):
            with self.subTest(location=location):
                self.assertTrue(self.denied(self.payload([location, self.shell("git push origin HEAD:main")], cwd=self.b)))
                self.assertFalse(self.denied(self.payload([location, self.shell("git status --short")])))

    def test_unmappable_native_location_cannot_fail_open(self):
        payload = self.payload([{"kind": "location", "path": r"Z:\missing"}, self.shell("git push origin HEAD:main")])
        def map_path(value):
            if value == r"Z:\missing":
                raise OSError("unmappable")
            return value
        with patch.object(runtime, "linux_path", side_effect=map_path):
            event = runtime.normalize_event(payload["event"], payload)
        self.assertEqual(event["_desktop_commands"][0]["cwd"], str(self.a))
        self.assertTrue(event["_desktop_commands"][0]["_desktop_uncertain_cwd"])

    def test_polling_keeps_exact_bash_source_and_separate_escape_scope(self):
        self.assertTrue(self.denied(self.payload([self.shell("echo safe"), self.shell("until false; do sleep 20; done")], hook="polling_guard")))
        self.assertFalse(self.denied(self.payload([self.shell("echo safe"), self.shell("printf '%s' 'sleep 120'")], hook="polling_guard")))
        self.assertTrue(self.denied(self.payload([self.shell("echo safe # wait-ok: another process"), self.shell("sleep 120")], hook="polling_guard")))

    def test_kill_guard_dispatches_projected_source_to_original_policy(self):
        # These are policy input strings only; no process receives a signal.
        dangerous="pkill -f '[s]leep 300'"
        denied=self.run_payload(self.payload([self.shell("echo safe"),self.shell(dangerous)],hook="kill_guard"))
        specific=denied["hookSpecificOutput"]
        self.assertEqual(specific["permissionDecision"],"deny")
        self.assertIn("Delamain kill guard",specific["permissionDecisionReason"])
        for source in ("kill 12345","printf '%s' 'pkill -f sleep'",dangerous+" # kill-ok: deliberate fixture"):
            with self.subTest(source=source):
                self.assertFalse(self.denied(self.payload([self.shell(source)],hook="kill_guard")))
        # The original non-overridable BSD option-order trap remains intact.
        self.assertTrue(self.denied(self.payload([self.shell(dangerous+" -P 1 # kill-ok: fixture")],hook="kill_guard")))
        self.assertFalse(self.denied(self.payload([{"kind":"argv","argv":["Write-Output",dangerous]}],hook="kill_guard")))

    def test_kill_guard_keeps_only_real_pipeline_dependencies(self):
        command="lookup | consumer"
        pipeline={"kind":"pipeline","stages":[{"script":"lookup","start":0,"end":6},
                                              {"script":"consumer","start":9,"end":17}]}
        payload=self.payload([pipeline,self.shell("pgrep sleep"),self.shell("xargs kill")],hook="kill_guard")
        payload["event"]["tool_input"]["command"]=command
        payload["command_replacements"]=[{"kind":"shell","script":"pgrep sleep","start":0,"end":6},
                                         {"kind":"shell","script":"xargs kill","start":9,"end":17}]
        self.assertTrue(self.denied(payload))
        for first,second,denied in (
                ("pgrep sleep # trailing comment","xargs kill",True),
                ("pgrep sleep; echo 1","xargs kill",True),
                ("pgrep sleep","true; xargs kill",True),
                ("pgrep sleep",'while read p; do kill "$p"; done',True),
                ("pgrep sleep",'true; while read p; do kill "$p"; done',True),
                ("pgrep sleep # kill-ok: source only","xargs kill",True),
                ("pgrep sleep","xargs kill # kill-ok: sink owns it",False),
                ("printf 12345","xargs kill",False)):
            with self.subTest(first=first,second=second):
                variant=json.loads(json.dumps(payload))
                for index,body in enumerate((first,second)):
                    variant["command_replacements"][index]["script"]=body
                    variant["command_projection"][index+1]["script"]=body
                self.assertEqual(self.denied(variant),denied)
        self.assertFalse(self.denied(self.payload([self.shell("pgrep sleep"),self.shell("xargs kill")],hook="kill_guard")))
        for source in ("pgrep sleep | sort -n","kill 12345","printf '%s' 'pkill -f sleep'"):
            self.assertFalse(self.denied(self.payload([self.shell(source)],hook="kill_guard")))
        self.assertTrue(self.denied(self.payload([self.shell("pgrep sleep | xargs kill")],hook="kill_guard")))
        payload["command_projection"].insert(0,{"kind":"location","path":str(self.b)})
        normalized=runtime.normalize_event(payload["event"],payload)
        self.assertTrue(normalized["_desktop_commands"])
        self.assertEqual({item["cwd"] for item in normalized["_desktop_commands"]},{str(self.b)})
        # The original hook currently exposes this switch through environment;
        # its config keys are not registered by hubcore. Preserve that contract.
        payload["env"]["AGENT_HUB_KILL_GUARD"]="off"
        self.assertFalse(self.denied(payload))

    def test_kill_guard_keeps_nested_bridge_body_scopes_separate(self):
        command="lookup | & { leaf1; $input | leaf2 }"
        split=command.index("&")
        slots=[("lookup",0),("leaf1",command.index("leaf1")),("leaf2",command.index("leaf2"))]
        pipeline={"kind":"pipeline","stages":[{"script":"lookup","start":0,"end":6},
                   {"script":command[split:],"start":split,"end":len(command)}]}
        for first,other,sink,denied in (
                ("pgrep sleep","true # ordinary","xargs kill",True),
                ("pgrep sleep","true # kill-ok: other body","xargs kill",True),
                ("pgrep sleep","true # ordinary","xargs kill # kill-ok: owns sink",False),
                ("pgrep sleep","true # ordinary","pkill -f sleep -P 1 # kill-ok: trap",True),
                ("pgrep sleep","true # ordinary","cat",False),
                ("printf 12345","pgrep sleep","xargs kill",False)):
            with self.subTest(first=first,other=other,sink=sink):
                payload=self.payload([pipeline,*map(self.shell,(first,other,sink))],hook="kill_guard")
                payload["event"]["tool_input"]["command"]=command
                payload["command_replacements"]=[{"kind":"shell","script":body,"start":at,"end":at+len(slot)}
                    for (slot,at),body in zip(slots,(first,other,sink))]
                self.assertEqual(self.denied(payload),denied)

    def pipeline_payload(self, *bodies):
        slots = ["stage" + str(index) for index in range(len(bodies))]
        command = " | ".join(slots)
        stages = [{"script": slot, "start": command.index(slot),
                   "end": command.index(slot) + len(slot)} for slot in slots]
        payload = self.payload([{"kind": "pipeline", "stages": stages},
                                *map(self.shell, bodies)], hook="kill_guard")
        payload["event"]["tool_input"]["command"] = command
        payload["command_replacements"] = [dict(stage, kind="shell", script=body)
                                            for stage, body in zip(stages, bodies)]
        return payload

    def test_kill_pipeline_multiline_data_cannot_create_escape_comment(self):
        import kill_guard
        sink = "printf '%s\\n' 'fixture data\nkill-ok: this is data'; xargs kill"
        original = "pgrep sleep | { " + sink + "; }"
        self.assertIsNotNone(kill_guard.check(original))
        self.assertNotRegex(original, r"#\s*kill-ok\b")
        self.assertTrue(self.denied(self.pipeline_payload("pgrep sleep", sink)))
        self.assertFalse(self.denied(self.pipeline_payload("pgrep sleep", sink + " # kill-ok: sink owns it")))
        payload = self.pipeline_payload("pgrep sleep", sink)
        payload["command_projection"].append({"kind": "comment", "script": "# kill-ok: native outer"})
        self.assertFalse(self.denied(payload))
        self.assertTrue(self.denied(self.pipeline_payload("pgrep sleep # kill-ok: producer only", sink)))

    def test_kill_pipeline_executable_stdin_uses_shared_parser(self):
        import kill_guard
        producer = "printf '%s\\n' 'pkill -f sleep'"
        for sink in ("bash", "sh", "env -i bash", "true; bash"):
            with self.subTest(sink=sink):
                if ";" not in sink:
                    self.assertIsNotNone(kill_guard.check(producer + " | " + sink))
                self.assertTrue(self.denied(self.pipeline_payload(producer, sink)))
        self.assertTrue(self.denied(self.pipeline_payload(producer, "cat", "bash")))
        self.assertTrue(self.denied(self.pipeline_payload(producer + " # kill-ok: producer only", "bash")))
        self.assertTrue(self.denied(self.pipeline_payload("printf '%s\\n' 'pkill -f sleep # kill-ok: printed data'", "bash")))
        self.assertFalse(self.denied(self.pipeline_payload(producer, "bash # kill-ok: sink owns it")))
        for bodies in ((producer, "cat"), ("pgrep sleep", "sort -n"),
                       ("printf '%s\\n' 'echo harmless'", "bash"), ("printf 12345", "xargs kill")):
            with self.subTest(bodies=bodies):
                self.assertFalse(self.denied(self.pipeline_payload(*bodies)))

    def test_explicit_native_comments_preserve_escape_without_cross_bridge_escape(self):
        action = self.shell("git push origin HEAD:main")
        self.assertFalse(self.denied(self.payload([action, {"kind": "comment", "script": "# lock-ok: fixture"}])))
        self.assertTrue(self.denied(self.payload([self.shell("echo safe # lock-ok: another process"), action])))
        self.assertTrue(self.denied(self.payload([action, {"kind": "argv", "argv": ["Write-Output", "# lock-ok: display"]}])))

    def write_role(self, home, effort, mapped=None):
        role = 'model="gpt-6-astra"\nmodel_reasoning_effort="' + effort + '"\n'
        if mapped is None:
            (home / "agents").mkdir(exist_ok=True)
            (home / "agents/reviewer.toml").write_text('name="reviewer"\ndescription="fixture"\ndeveloper_instructions="fixture"\n' + role)
        else:
            (home / "config.toml").write_text('[agents.reviewer]\nconfig_file=' + json.dumps(mapped) + '\n')
        return role

    def role_call(self, mode="hook"):
        payload = self.payload()
        payload["mode"] = mode
        with patch.dict(os.environ, self.env, clear=True):
            env = runtime.environment(payload, ROOT)
        with patch.dict(os.environ, env, clear=True):
            return codex_compat.agent_call("spawn_agent", {"agent_type": "reviewer", "model": "gpt-6-astra", "reasoning_effort": "high"}, str(self.a), None)

    def test_native_definition_overrides_explicit_effort_through_environment(self):
        self.write_role(self.native, "low")
        self.write_role(self.linux, "high")
        rules = [{"when": {"model": "gpt-6-astra", "effort": "low"}, "decision": "deny"}]
        call = self.role_call()
        self.assertEqual((call["defined"], call["effort"]), ("true", "low"))
        self.assertEqual(subagent_rules.evaluate(rules, call)[0], "deny")
        payload = self.payload(hook="delegation")
        payload["hookargs"] = ["pre-tool"]
        payload["env"]["AGENT_HUB_EFFORT_RULES"] = json.dumps(rules)
        payload["event"].update(tool_name="spawn_agent", tool_input={"agent_type": "reviewer", "model": "gpt-6-astra", "reasoning_effort": "high"})
        self.assertTrue(self.denied(payload))
        self.write_role(self.native, "high")
        self.assertFalse(self.denied(payload))

    def test_linux_tool_mode_and_missing_native_profile_do_not_use_other_home(self):
        self.write_role(self.native, "low")
        self.write_role(self.linux, "high")
        self.assertEqual(self.role_call("tool")["effort"], "high")
        (self.native / "agents/reviewer.toml").unlink()
        call = self.role_call()
        self.assertEqual((call["defined"], call["effort"]), ("false", "high"))
        with patch.dict(os.environ, {**self.env, "AGENT_HUB_NATIVE_CODEX_PATHS": "1"}, clear=True):
            env = runtime.environment({**self.payload(), "mode": "tool"}, ROOT)
        self.assertNotIn("AGENT_HUB_NATIVE_CODEX_PATHS", env)
        self.assertEqual(env["CODEX_HOME"], str(self.linux))

    def test_native_relative_and_absolute_profile_sources_override_discovery(self):
        self.write_role(self.native, "high")
        role = self.write_role(self.native, "low", r"profiles\reviewer ё.toml")
        profiles = self.native / "profiles"
        profiles.mkdir()
        target = profiles / "reviewer ё.toml"
        target.write_text(role)
        self.assertEqual(self.role_call()["effort"], "low")
        for filename in (r"C:\fixture\reviewer ё.toml", r"\\server\share\reviewer ё.toml", str(target)):
            self.write_role(self.native, "low", filename)
            with patch.object(codex_compat.subprocess, "check_output", return_value=str(target) + "\n") as mapper:
                self.assertEqual(self.role_call()["effort"], "low")
                if filename.startswith(("C:", "\\")):
                    mapper.assert_called_once_with(["wslpath", "-a", "-u", filename], text=True)
                else:
                    mapper.assert_not_called()
        # This transport marker must never change ordinary Linux path semantics.
        with patch.dict(os.environ, self.env, clear=True), patch.object(codex_compat.subprocess, "check_output") as mapper:
            filename = r"C:\literal\linux-filename.toml"
            self.assertEqual(codex_compat.role_profile_path(filename, self.linux), self.linux / filename)
            mapper.assert_not_called()

    def test_native_home_mapping_and_project_role_precedence(self):
        self.write_role(self.native, "low")
        native = str(self.native)
        self.config["WindowsCodexHome"] = r"C:\fixture\native ё"
        with patch.object(runtime, "linux_path", side_effect=lambda value: native if value == self.config["WindowsCodexHome"] else value):
            self.assertEqual(self.role_call()["effort"], "low")
            project = self.a / ".codex"
            project.mkdir()
            (project / "config.toml").write_text('[agents.reviewer]\nconfig_file="project.toml"\n')
            (project / "project.toml").write_text('model="gpt-6-astra"\nmodel_reasoning_effort="high"\n')
            self.assertEqual(self.role_call()["effort"], "high")


@unittest.skipUnless(os.name == "nt" and shutil.which("wsl.exe"), "native Windows + WSL integration")
class NativeBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Policy homes must not inherit config from this checkout's ancestors.
        cls.temp = tempfile.TemporaryDirectory(prefix="desktop-adapter-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.scratch = Path(cls.temp.name)
        if any((parent / ".git").exists() for parent in (cls.scratch, *cls.scratch.parents)):
            raise RuntimeError("Native policy fixtures require a temporary directory outside Git ancestors")
        cls.package = cls.scratch / "package юникод"
        cls.package.mkdir()
        for directory in ("bin", "hooks"):
            shutil.copytree(ROOT / directory, cls.package / directory)
        (cls.package / "windows").mkdir()
        for name in ("desktop.ps1", "desktop_hook.ps1", "desktop_runtime.py", "desktop_codex.py", "process_transport.ps1", "worker_proxy.py", "proxy_tcp.ps1"):
            shutil.copy2(ROOT / "windows" / name, cls.package / "windows" / name)
        (cls.package / "bin/transport_probe").write_text("#!/usr/bin/env python3\nimport os,json,sys\nprint(json.dumps({'argv':sys.argv[1:],'cwd':os.getcwd(),'env':{k:os.getenv(k) for k in ['CODEX_THREAD_ID','AGENT_SESSION_ID','CODEX_HOME','CODEX_APP_TOOLS_PIPE_PATH','UNRELATED_SECRET']}}))\n", encoding="utf-8", newline="\n")
        cls.linux = cls.wslpath(cls.scratch)
        config = {"Distro": "Ubuntu", "LinuxHome": cls.linux + "/codex-home", "HubHome": cls.linux + "/fallback-hub",
                  "LinuxCodex": "/bin/true", "WindowsCodex": str(Path(os.environ["SYSTEMROOT"]) / "System32/cmd.exe"),
                  "WindowsCodexHome": str(cls.scratch / "native-home")}
        (cls.package / "windows/desktop-config.json").write_text(json.dumps(config), encoding="utf-8")
        cls.shells = [shell for shell in (shutil.which("powershell.exe"), shutil.which("pwsh.exe")) if shell]
        if not cls.shells:
            raise unittest.SkipTest("PowerShell 5.1 or 7 is required")
        cls.env = {**{k: v for k, v in os.environ.items() if k.upper() in
                     {"SYSTEMROOT", "WINDIR", "COMSPEC", "PATH", "PATHEXT", "TEMP", "TMP"}},
                   "USERPROFILE": str(cls.scratch), "HOME": str(cls.scratch),
                   "AGENT_HUB_HOME": str(cls.scratch / "hub-home"), "CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Codex Desktop",
                   "CODEX_APP_TOOLS_PIPE_PATH": "native-pipe-fixture", "UNRELATED_SECRET": "must-not-forward"}
        (cls.scratch / "hub-home").mkdir()
        (cls.scratch / "hub-home/config.json").write_text(json.dumps({"AGENT_HUB_SCOPE_DIRS": cls.linux}))
        for name in ("CODEX_THREAD_ID", "AGENT_SESSION_ID"):
            cls.env.pop(name, None)

    @staticmethod
    def wslpath(path):
        run = subprocess.run(["wsl.exe", "-d", "Ubuntu", "--exec", "wslpath", "-a", "-u", str(path)], capture_output=True, encoding="utf-8")
        if run.returncode:
            raise RuntimeError(run.stderr)
        return run.stdout.strip()

    def invoke(self, shell, args, stdin=None, hook=False, cwd=None, env=None):
        script = self.package / "windows" / ("desktop_hook.ps1" if hook else "desktop.ps1")
        run = subprocess.run([shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script), *args],
                             input=stdin, capture_output=True, encoding="utf-8", errors="replace", env=self.env if env is None else env, cwd=ROOT if cwd is None else cwd, timeout=35)
        return run

    def hook(self, shell, name, command, sid=SID, **extra):
        event = {"hook_event_name": "PreToolUse", "session_id": sid, "cwd": str(self.scratch),
                 "tool_name": "Bash", "tool_input": {"command": command}, **extra}
        run = self.invoke(shell, ["-Hook", name], json.dumps(event, ensure_ascii=False), hook=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        return json.loads(run.stdout) if run.stdout.strip() else {}

    def bridge(self, source):
        return "& '" + str(self.package / "windows/desktop.ps1").replace("'", "''") + "' --session-id '" + SID + "' shell '" + source.replace("'", "''") + "'"

    def test_native_powershell_parser_controls(self):
        for shell in self.shells:
            for name in ("desktop.ps1", "desktop_hook.ps1"):
                path = str(self.package / "windows" / name).replace("'", "''")
                source = "$tokens=$null; $errors=$null; [void][Management.Automation.Language.Parser]::ParseFile('" + path + "',[ref]$tokens,[ref]$errors); if ($errors.Count) { $errors | Out-String | Write-Error; exit 1 }"
                run = subprocess.run([shell, "-NoProfile", "-Command", source], capture_output=True, encoding="utf-8", errors="replace", env=self.env, timeout=15)
                self.assertEqual(run.returncode, 0, run.stderr)

    def test_original_scan_guard_root_deny_project_allow_and_escape(self):
        for shell in self.shells:
            with self.subTest(shell=shell):
                denied = self.hook(shell, "scan_guard", self.bridge("find / -name fixture"))
                self.assertEqual(denied["hookSpecificOutput"]["permissionDecision"], "deny")
                self.assertFalse(self.hook(shell, "scan_guard", self.bridge("find ./project -name fixture")))
                self.assertFalse(self.hook(shell, "scan_guard", self.bridge("find / -name fixture # scan-ok")))

    def test_unicode_identity_stdio_exit_and_opaque_shell(self):
        for shell in self.shells:
            with self.subTest(shell=shell):
                source = "printf '%s\\n' 'Привет $HOME `literal`'; cat; printf '%s\\n' \"$CODEX_THREAD_ID|$AGENT_SESSION_ID\"; exit 7"
                run = self.invoke(shell, ["--session-id", SID, "shell", source], "Вход\n")
                self.assertEqual(run.returncode, 7, run.stderr)
                self.assertIn("Привет $HOME `literal`", run.stdout)
                self.assertIn("Вход", run.stdout)
                self.assertIn(SID + "|" + SID, run.stdout)

    def test_original_shell_aliases_keep_their_interpreter_and_help_exit(self):
        for alias in ("agent-spawn", "agent-status", "agent-send", "agent-stop"):
            expected = subprocess.run(["wsl.exe", "-d", "Ubuntu", "--exec", self.wslpath(self.package / "bin" / alias), "--help"], capture_output=True, encoding="utf-8", errors="replace")
            for shell in self.shells:
                with self.subTest(alias=alias, shell=shell):
                    run = self.invoke(shell, ["--session-id", SID, alias, "--help"])
                    self.assertEqual(run.returncode, expected.returncode, run.stderr)
                    self.assertEqual(run.stdout, expected.stdout)
                    self.assertNotIn("SyntaxError", run.stderr)

    def test_generic_argv_env_and_actual_shell_writes(self):
        original = ["empty follows", "", "Unicode ё 😀", "$HOME;`literal`", "--flag=value", "a'b\"c", "C:\\native\\literal message", "--goal", "C:\\native\\goal"]
        for index, shell in enumerate(self.shells):
            with self.subTest(shell=shell):
                run = self.invoke(shell, ["--session-id", SID, "transport_probe", *original])
                self.assertEqual(run.returncode, 0, run.stderr)
                data = json.loads(run.stdout)
                self.assertEqual(data["argv"], original)
                self.assertEqual(data["env"]["CODEX_THREAD_ID"], SID)
                self.assertEqual(data["env"]["AGENT_SESSION_ID"], SID)
                self.assertEqual(data["env"]["CODEX_APP_TOOLS_PIPE_PATH"], "native-pipe-fixture")
                self.assertIsNone(data["env"]["UNRELATED_SECRET"])
                marker = self.scratch / ("marker-" + str(index))
                run = self.invoke(shell, ["--session-id", SID, "shell", "--cwd", str(self.scratch), "printf '%s' 'actual marker' > " + marker.name])
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertEqual(marker.read_text(), "actual marker")

    def test_real_journal_preserves_windows_prefixed_message(self):
        text = "C:\\native\\literal message"
        run = self.invoke(self.shells[0], ["--session-id", SID, "jlog", "--stage", "review", "--tag", "reviewer", text])
        self.assertEqual(run.returncode, 0, run.stderr)
        journals = list((self.scratch / "hub-home/review").rglob("journal-*.md"))
        self.assertTrue(journals)
        self.assertTrue(any(text in journal.read_text(encoding="utf-8") for journal in journals))

    def test_effective_workdir_selects_project_user_and_explicit_home(self):
        user = self.scratch / "userrepo"
        project = self.scratch / "projectrepo"
        for directory, choice in ((user, "user"), (project, "project")):
            directory.mkdir()
            (directory / ".git").mkdir()
            (directory / ".agent-hub").mkdir()
            (directory / ".agent-hub/config.json").write_text(json.dumps({"AGENT_HUB_HOME": choice}))
        configpath = self.package / "windows/desktop-config.json"
        old_config = configpath.read_text(encoding="utf-8")
        config = json.loads(old_config)
        config["HubHome"] = self.linux + "/shared-fallback"
        configpath.write_text(json.dumps(config), encoding="utf-8")
        env = dict(self.env)
        env.pop("AGENT_HUB_HOME")
        takeargs = ["--session-id", OTHER, "lock", "take", "main-merge", "--repo", "*", "--until", "2099-01-01T00:00", "--why", "effective home fixture", "--owner", "Other"]
        def probe(shell, workdir, override=None, source=None):
            event = {"hook_event_name": "PreToolUse", "session_id": SID, "cwd": str(user), "tool_name": "Bash",
                     "tool_input": {"command": source or self.bridge("gh pr merge 42"), "workdir": str(workdir)}}
            run = self.invoke(shell, ["-Hook", "board_locks"], json.dumps(event, ensure_ascii=False), hook=True, cwd=user, env=env if override is None else override)
            self.assertEqual(run.returncode, 0, run.stderr)
            return json.loads(run.stdout) if run.stdout.strip() else {}
        try:
            run = self.invoke(self.shells[0], takeargs, cwd=project, env=env)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertTrue((project / ".agent-hub/local/board.md").is_file())
            for shell in self.shells:
                self.assertEqual(probe(shell, project)["hookSpecificOutput"]["permissionDecision"], "deny")
                self.assertFalse(probe(shell, user))
                explicit = {**env, "AGENT_HUB_HOME": str(self.scratch / "explicit-home")}
                self.assertFalse(probe(shell, project, override=explicit))
                source = self.bridge("gh pr merge 42").replace("shell 'gh", "shell --cwd '" + str(project).replace("'", "''") + "' 'gh")
                self.assertEqual(probe(shell, user, source=source)["hookSpecificOutput"]["permissionDecision"], "deny")
            run = self.invoke(self.shells[0], takeargs, cwd=user, env=env)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertTrue((self.scratch / "shared-fallback/board.md").is_file())
            for shell in self.shells:
                self.assertEqual(probe(shell, user)["hookSpecificOutput"]["permissionDecision"], "deny")
            explicit = {**env, "AGENT_HUB_HOME": str(self.scratch / "explicit-home")}
            run = self.invoke(self.shells[0], takeargs, cwd=user, env=explicit)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertTrue((self.scratch / "explicit-home/board.md").is_file())
            for shell in self.shells:
                self.assertEqual(probe(shell, project, override=explicit)["hookSpecificOutput"]["permissionDecision"], "deny")
        finally:
            configpath.write_text(old_config, encoding="utf-8")

    def test_original_board_lock_own_other_and_multiple_literal_calls(self):
        take = self.invoke(self.shells[0], ["--session-id", OTHER, "lock", "take", "main-merge", "--repo", "*",
                                                "--until", "2099-01-01T00:00", "--why", "transport fixture", "--owner", "Other"])
        self.assertEqual(take.returncode, 0, take.stderr)
        for shell in self.shells:
            with self.subTest(shell=shell):
                denied = self.hook(shell, "board_locks", self.bridge("echo ok") + "; " + self.bridge("gh pr merge 42"))
                self.assertEqual(denied["hookSpecificOutput"]["permissionDecision"], "deny")
                self.assertFalse(self.hook(shell, "board_locks", self.bridge("gh pr merge 42"), sid=OTHER))
                self.assertFalse(self.hook(shell, "board_locks", self.bridge("gh pr view 42")))
                direct = self.hook(shell, "board_locks", "git.exe -C '" + str(ROOT) + "' push origin HEAD:main")
                self.assertEqual(direct["hookSpecificOutput"]["permissionDecision"], "deny")
                self.assertFalse(self.hook(shell, "board_locks", "git.exe push origin HEAD:main # lock-ok: fixture"))
                self.assertFalse(self.hook(shell, "board_locks", self.bridge("gh pr merge 42") + " # lock-ok: fixture"))

    def test_guarded_actions_inside_powershell_wrappers_and_companions(self):
        take = self.invoke(self.shells[0], ["--session-id", OTHER, "lock", "take", "main-merge", "--repo", "*",
                                          "--until", "2099-01-01T00:00", "--why", "wrapper fixture", "--owner", "Other"])
        self.assertEqual(take.returncode, 0, take.stderr)
        wrappers = [lambda c: "$result = " + c, lambda c: "if ($true) { " + c + " }",
                    lambda c: "function Invoke-Guarded { " + c + " }; Invoke-Guarded",
                    lambda c: "Write-Output '😀'; $result = " + c,
                    lambda c: "$result = " + self.bridge("echo safe") + "; " + c + "; git.exe push origin HEAD:main"]
        for shell in self.shells:
            for wrap in wrappers:
                with self.subTest(shell=shell, wrapper=wrap(self.bridge("gh pr merge 42"))):
                    blocked = self.hook(shell, "board_locks", wrap(self.bridge("gh pr merge 42")))
                    self.assertEqual(blocked["hookSpecificOutput"]["permissionDecision"], "deny")
                    blocked = self.hook(shell, "polling_guard", wrap(self.bridge("sleep 120")))
                    self.assertEqual(blocked["hookSpecificOutput"]["permissionDecision"], "deny")
            mixed = "$result = " + self.bridge("echo safe") + "; if ($true) { git.exe push origin HEAD:main }"
            self.assertEqual(self.hook(shell, "board_locks", mixed)["hookSpecificOutput"]["permissionDecision"], "deny")
            displayed = "Write-Output '" + self.bridge("gh pr merge 42").replace("'", "''") + "'"
            self.assertFalse(self.hook(shell, "board_locks", displayed))

    def test_scoped_lock_separate_calls_native_location_and_explicit_cwd(self):
        a, b = self.scratch / "scoped-A", self.scratch / "scoped-B"
        for repo in (a, b):
            (repo / ".git").mkdir(parents=True)
        env = {**self.env, "AGENT_HUB_HOME": str(self.scratch / "scoped-hub")}
        take = self.invoke(self.shells[0], ["--session-id", OTHER, "lock", "take", "main-merge",
                            "--repo", a.name, "--until", "2099-01-01T00:00", "--why", "scoped native fixture"], env=env, cwd=a)
        self.assertEqual(take.returncode, 0, take.stderr)
        def probe(shell, source, cwd=a, workdir=None):
            event = {"hook_event_name": "PreToolUse", "session_id": SID, "cwd": str(cwd), "tool_name": "Bash",
                     "tool_input": {"command": source}}
            if workdir:
                event["tool_input"]["workdir"] = str(workdir)
            run = self.invoke(shell, ["-Hook", "board_locks"], json.dumps(event), hook=True, env=env, cwd=cwd)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertNotIn("fail-open", run.stderr)
            return (json.loads(run.stdout) if run.stdout.strip() else {}).get("hookSpecificOutput", {}).get("permissionDecision") == "deny"
        action = self.bridge("git push origin HEAD:main")
        native_b = "Set-Location -LiteralPath '" + str(b).replace("'", "''") + "'"
        native_a = "Set-Location -LiteralPath '" + str(a).replace("'", "''") + "'"
        for shell in self.shells:
            # Read-only execution demonstrates the actual fresh-process cwd;
            # guarded strings below are sent to hooks only, never executed.
            run = self.invoke(shell, ["--session-id", SID, "shell", "cd " + self.wslpath(b)], env=env, cwd=a)
            self.assertEqual(run.returncode, 0, run.stderr)
            run = self.invoke(shell, ["--session-id", SID, "shell", "pwd"], env=env, cwd=a)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(run.stdout.strip(), self.wslpath(a))
            for native, expected in (("if ($false) { " + native_b + " }", a), (native_b, b)):
                run = subprocess.run([shell, "-NoProfile", "-Command", native + "; " + self.bridge("pwd")],
                                     capture_output=True, encoding="utf-8", errors="replace", env=env, cwd=a, timeout=35)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertEqual(run.stdout.strip(), self.wslpath(expected))
            self.assertTrue(probe(shell, self.bridge("cd " + self.wslpath(b)) + "; " + action))
            self.assertFalse(probe(shell, self.bridge("cd " + self.wslpath(b)) + "; " + self.bridge("git status --short")))
            self.assertTrue(probe(shell, "if ($false) { " + native_b + " }; " + action))
            self.assertTrue(probe(shell, "Set-Location $unknown; " + action, cwd=b))
            self.assertFalse(probe(shell, "if ($false) { " + native_b + " }; " + self.bridge("git status --short")))
            self.assertFalse(probe(shell, native_b + "; " + action))
            self.assertTrue(probe(shell, native_a + "; " + action, cwd=b))
            self.assertTrue(probe(shell, "Microsoft.PowerShell.Management\\" + native_a + "; " + action, cwd=b))
            self.assertFalse(probe(shell, action, workdir=b))
            self.assertTrue(probe(shell, action, cwd=b, workdir=a))
            one_cwd = action.replace("shell 'git", "shell --cwd '" + str(a).replace("'", "''") + "' 'git")
            self.assertTrue(probe(shell, one_cwd, cwd=b))
            for wrap in (lambda c: "$result = " + c, lambda c: "& { " + c + " }",
                         lambda c: "function Invoke-Safe { " + c + " }; Invoke-Safe", lambda c: c + " | Out-Null"):
                with self.subTest(shell=shell, wrapper=wrap(self.bridge("git status --short"))):
                    self.assertFalse(probe(shell, wrap(self.bridge("git status --short"))))
                    self.assertTrue(probe(shell, wrap(action)))

    def test_ps7_background_location_preserves_parent_cwd_and_scoped_lock(self):
        shells = [shell for shell in self.shells if Path(shell).name.lower() == "pwsh.exe"]
        if not shells:
            self.skipTest("PowerShell 7 is required for background pipeline syntax")
        a, b = self.scratch / "background-A", self.scratch / "background-B"
        for repo in (a, b):
            (repo / ".git").mkdir(parents=True)
        env = {**self.env, "AGENT_HUB_HOME": str(self.scratch / "background-hub")}
        take = self.invoke(shells[0], ["--session-id", OTHER, "lock", "take", "main-merge",
                            "--repo", a.name, "--until", "2099-01-01T00:00", "--why", "background native fixture"], env=env, cwd=a)
        self.assertEqual(take.returncode, 0, take.stderr)
        native_b = "Set-Location -LiteralPath '" + str(b).replace("'", "''") + "'"
        readonly = native_b + " & " + self.bridge("pwd")
        for shell in shells:
            # Execute only the read-only source. This fresh PS process owns job 1;
            # wait finitely and remove it before returning, even on an error.
            source = ("try { " + readonly + " } finally { "
                      "$job = Get-Job -Id 1 -ErrorAction SilentlyContinue; if ($job) { try { "
                      "Wait-Job -Job $job -Timeout 10 | Out-Null; "
                      "if ($job.State -ne 'Completed' -or $job.ChildJobs[0].Error.Count) { throw 'Background location job failed or timed out' } "
                      "} finally { Stop-Job -Job $job; Remove-Job -Job $job -Force } } }")
            run = subprocess.run([shell, "-NoProfile", "-Command", source], capture_output=True,
                                 encoding="utf-8", errors="replace", env=env, cwd=a, timeout=35)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn(self.wslpath(a), [line.strip() for line in run.stdout.splitlines()])
            def probe(command):
                event = {"hook_event_name": "PreToolUse", "session_id": SID, "cwd": str(a),
                         "tool_name": "Bash", "tool_input": {"command": command}}
                result = self.invoke(shell, ["-Hook", "board_locks"], json.dumps(event), hook=True, env=env, cwd=a)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("fail-open", result.stderr)
                return (json.loads(result.stdout) if result.stdout.strip() else {}).get("hookSpecificOutput", {}).get("permissionDecision") == "deny"
            self.assertFalse(probe(readonly), "background location followed by parent pwd is read-only")
            # Guarded strings go to hooks only. Background cd leaves the push in
            # locked A; the same foreground cd really selects unlocked B.
            for action in (self.bridge("git push origin HEAD:main"), "git.exe push origin HEAD:main"):
                self.assertTrue(probe(native_b + " & " + action))
                self.assertFalse(probe(native_b + "; " + action))

    def test_native_role_effort_sources_override_explicit_spawn(self):
        home = self.scratch / "native-home"
        linux_home = self.scratch / "codex-home"
        for directory in (home, linux_home):
            (directory / "agents").mkdir(parents=True, exist_ok=True)
        prefix = 'name="reviewer"\ndescription="fixture"\ndeveloper_instructions="fixture"\nmodel="gpt-6-astra"\n'
        low, high = prefix + 'model_reasoning_effort="low"\n', prefix + 'model_reasoning_effort="high"\n'
        (linux_home / "agents/reviewer.toml").write_text(high)
        env = {**self.env, "AGENT_HUB_EFFORT_RULES": json.dumps([{"when": {"model": "gpt-6-astra", "effort": "low"}, "decision": "deny"}])}
        def probe(shell):
            event = {"hook_event_name": "PreToolUse", "session_id": SID, "cwd": str(self.scratch),
                     "tool_name": "spawn_agent", "tool_input": {"agent_type": "reviewer", "model": "gpt-6-astra", "reasoning_effort": "high"}}
            run = self.invoke(shell, ["-Hook", "delegation", "-HookArgs", "pre-tool"], json.dumps(event), hook=True, env=env)
            self.assertEqual(run.returncode, 0, run.stderr)
            return (json.loads(run.stdout) if run.stdout.strip() else {}).get("hookSpecificOutput", {}).get("permissionDecision") == "deny"
        try:
            for shell in self.shells:
                (home / "agents/reviewer.toml").write_text(low)
                self.assertTrue(probe(shell))
                (home / "agents/reviewer.toml").write_text(high)
                self.assertFalse(probe(shell))
                (home / "agents/reviewer.toml").unlink()
                self.assertFalse(probe(shell))
                (home / "agents/reviewer.toml").write_text(high)
                target = home / "profiles/reviewer ё.toml"
                target.parent.mkdir(exist_ok=True)
                target.write_text(low)
                unc = "\\\\wsl.localhost\\Ubuntu" + self.wslpath(target).replace("/", "\\")
                for filename in (r"profiles\reviewer ё.toml", str(target), unc):
                    (home / "config.toml").write_text('[agents.reviewer]\nconfig_file=' + json.dumps(filename) + '\n')
                    self.assertTrue(probe(shell))
                (home / "config.toml").unlink()
        finally:
            for filename in (home / "agents/reviewer.toml", home / "config.toml"):
                filename.unlink(missing_ok=True)

    def test_polling_literals_dynamic_and_quoted_display(self):
        for shell in self.shells:
            with self.subTest(shell=shell):
                deny = self.hook(shell, "polling_guard", self.bridge("sleep 120"))
                self.assertEqual(deny["hookSpecificOutput"]["permissionDecision"], "deny")
                self.assertFalse(self.hook(shell, "polling_guard", "Write-Output '" + self.bridge("sleep 120").replace("'", "''") + "'"))
                dynamic = self.bridge("sleep 120").replace("'sleep 120'", "$source")
                deny = self.hook(shell, "polling_guard", dynamic)
                self.assertEqual(deny["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_kill_guard_literal_projection_numeric_pid_and_display(self):
        # Hook probes only: even the denied/allowed kill strings are never run.
        dangerous="pkill -f '[s]leep 300'"
        for shell in self.shells:
            with self.subTest(shell=shell):
                for command in (self.bridge(dangerous),dangerous):
                    denied=self.hook(shell,"kill_guard",command)["hookSpecificOutput"]
                    self.assertEqual(denied["permissionDecision"],"deny")
                    self.assertIn("Delamain kill guard",denied["permissionDecisionReason"])
                self.assertFalse(self.hook(shell,"kill_guard","kill 12345"))
                self.assertFalse(self.hook(shell,"kill_guard","Write-Output 'pkill -f sleep'"))
                displayed="Write-Output '"+self.bridge(dangerous).replace("'","''")+"'"
                self.assertFalse(self.hook(shell,"kill_guard",displayed))
                self.assertFalse(self.hook(shell,"kill_guard",self.bridge(dangerous+" # kill-ok: deliberate fixture")))
                trap=self.hook(shell,"kill_guard",self.bridge(dangerous+" -P 1 # kill-ok: fixture"))
                self.assertEqual(trap["hookSpecificOutput"]["permissionDecision"],"deny")
                dynamic=self.bridge(dangerous).rsplit(" shell ",1)[0]+" shell $source"
                self.assertEqual(self.hook(shell,"kill_guard",dynamic)["hookSpecificOutput"]["permissionDecision"],"deny")

    def test_kill_guard_preserves_native_pipeline_between_bridge_calls(self):
        # These JSON probes never execute pgrep, xargs, kill, or pkill.
        pair=self.bridge("pgrep sleep")+" | "+self.bridge("xargs kill")
        for shell in self.shells:
            with self.subTest(shell=shell):
                for source in (pair,self.bridge("pgrep sleep | xargs kill"),
                               self.bridge("pgrep sleep # trailing comment")+" | "+self.bridge("xargs kill"),
                               self.bridge("pgrep sleep; echo 1")+" | "+self.bridge("xargs kill"),
                               self.bridge("pgrep sleep")+" | "+self.bridge("true; xargs kill"),
                               self.bridge("pgrep sleep")+" | "+self.bridge('while read p; do kill "$p"; done'),
                               self.bridge("pgrep sleep")+" | "+self.bridge('true; while read p; do kill "$p"; done'),
                               self.bridge("ps -ef")+" | "+self.bridge("grep sleep")+" | "+self.bridge("xargs kill"),
                               self.bridge("pgrep sleep # kill-ok: source only")+" | "+self.bridge("xargs kill"),
                               self.bridge("pgrep sleep")+" | "+self.bridge("pkill -f sleep -P 1 # kill-ok: trap"),
                               "if ($true) { "+pair+" }",
                               "& { "+pair+" }",self.bridge("pgrep sleep")+" | xargs kill"):
                    denied=self.hook(shell,"kill_guard",source)["hookSpecificOutput"]
                    self.assertEqual(denied["permissionDecision"],"deny")
                    self.assertIn("Delamain kill guard",denied["permissionDecisionReason"])
                for source in (self.bridge("pgrep sleep")+"; "+self.bridge("xargs kill"),
                               self.bridge("pgrep sleep | sort -n"),"kill 12345",
                               "Write-Output 'pkill -f sleep'",
                               "Write-Output '"+pair.replace("'","''")+"'",
                               self.bridge("printf 12345")+" | "+self.bridge("xargs kill"),
                               self.bridge("pgrep sleep")+" | "+self.bridge("xargs kill # kill-ok: sink owns it"),
                               pair+" # kill-ok: whole native pipeline",
                               "Write-Output 'pgrep sleep' | "+self.bridge("xargs kill")):
                    self.assertFalse(self.hook(shell,"kill_guard",source))
                event={"hook_event_name":"PreToolUse","session_id":SID,"cwd":str(self.scratch),
                       "tool_name":"Bash","tool_input":{"command":pair}}
                disabled=self.invoke(shell,["-Hook","kill_guard"],json.dumps(event),hook=True,
                                     env={**self.env,"AGENT_HUB_KILL_GUARD":"off"})
                self.assertEqual(disabled.returncode,0,disabled.stderr)
                self.assertFalse(disabled.stdout.strip())

    def test_kill_guard_nested_bridge_bodies_keep_stdin_and_escape_scope(self):
        # Hook-only probes for real $input forwarding through a native stage.
        def nested(first,other,sink):
            return self.bridge(first)+" | & { "+self.bridge(other)+"; $input | "+self.bridge(sink)+" }"
        for shell in self.shells:
            with self.subTest(shell=shell):
                for command in (nested("pgrep sleep","true # ordinary","xargs kill"),
                                nested("pgrep sleep","true # kill-ok: other body","xargs kill"),
                                nested("pgrep sleep","true # ordinary","pkill -f sleep -P 1 # kill-ok: trap"),
                                nested("printf 12345","pgrep sleep # ordinary","true")+" | "+self.bridge("xargs kill")):
                    self.assertEqual(self.hook(shell,"kill_guard",command)["hookSpecificOutput"]["permissionDecision"],"deny")
                for command in (nested("pgrep sleep","true # ordinary","xargs kill # kill-ok: owns sink"),
                                nested("pgrep sleep","true # ordinary","xargs kill")+" # kill-ok: outer",
                                nested("pgrep sleep","true # ordinary","cat"),
                                nested("printf 12345","true # ordinary","cat"),
                                self.bridge("printf 12345")+" | & { "+self.bridge("pgrep sleep")+"; "+self.bridge("xargs kill")+" }"):
                    self.assertFalse(self.hook(shell,"kill_guard",command))
                event={"hook_event_name":"PreToolUse","session_id":SID,"cwd":str(self.scratch),
                       "tool_name":"Bash","tool_input":{"command":nested("pgrep sleep","true # ordinary","xargs kill")}}
                disabled=self.invoke(shell,["-Hook","kill_guard"],json.dumps(event),hook=True,
                                     env={**self.env,"AGENT_HUB_KILL_GUARD":"off"})
                self.assertEqual(disabled.returncode,0,disabled.stderr)
                self.assertFalse(disabled.stdout.strip())

    def test_native_kill_pipeline_multiline_data_and_executable_stdin(self):
        # Only hook probes: none of these kill strings is executed.
        sink = "printf '%s\\n' 'fixture data\nkill-ok: this is data'; xargs kill"
        producer = "printf '%s\\n' 'pkill -f sleep'"
        for shell in self.shells:
            with self.subTest(shell=shell):
                for command in (self.bridge("pgrep sleep") + " | " + self.bridge(sink),
                                self.bridge("pgrep sleep # kill-ok: producer only") + " | " + self.bridge(sink),
                                self.bridge(producer) + " | " + self.bridge("bash"),
                                self.bridge(producer) + " | " + self.bridge("true; sh"),
                                self.bridge(producer) + " | " + self.bridge("env -i bash"),
                                self.bridge(producer) + " | " + self.bridge("cat") + " | " + self.bridge("bash"),
                                self.bridge(producer + " # kill-ok: producer only") + " | " + self.bridge("bash"),
                                self.bridge("printf '%s\\n' 'pkill -f sleep # kill-ok: printed data'") + " | " + self.bridge("bash")):
                    with self.subTest(command=command):
                        self.assertEqual(self.hook(shell, "kill_guard", command)["hookSpecificOutput"]["permissionDecision"], "deny")
                for command in (self.bridge("pgrep sleep") + " | " + self.bridge(sink + " # kill-ok: sink owns it"),
                                self.bridge("pgrep sleep") + " | " + self.bridge(sink) + " # kill-ok: native outer",
                                self.bridge(producer) + " | " + self.bridge("bash # kill-ok: sink owns it"),
                                self.bridge(producer) + " | " + self.bridge("cat"),
                                self.bridge("printf '%s\\n' 'echo harmless'") + " | " + self.bridge("bash"),
                                self.bridge("printf 12345") + " | " + self.bridge("xargs kill"),
                                self.bridge("pgrep sleep") + " | " + self.bridge("sort -n"),
                                "Write-Output 'pkill -f sleep'"):
                    with self.subTest(command=command):
                        self.assertFalse(self.hook(shell, "kill_guard", command))

    def test_real_transcript_path_and_tool_workdir(self):
        transcript = self.scratch / "native-rollout.jsonl"
        transcript.write_text(json.dumps({"type": "event_msg", "payload": {"type": "token_count", "info": {"last_token_usage": {"total_tokens": 600001}}}}) + "\n")
        for shell in self.shells:
            result = self.hook(shell, "context_budget", "echo ok", transcript_path=str(transcript), tool_name="spawn_agent", tool_input={"workdir": str(self.scratch)})
            self.assertEqual(result["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_native_handoff_patch_header_reaches_original_guard(self):
        target = self.scratch / "hub-home" / "HANDOFF-native.md"
        target.parent.mkdir(exist_ok=True)
        command = "*** Begin Patch\n*** Add File: " + str(target) + "\n+" + "x" * 16000 + "\n*** End Patch"
        for shell in self.shells:
            event = {"hook_event_name": "PreToolUse", "session_id": SID, "cwd": str(self.scratch), "tool_name": "apply_patch", "tool_input": {"command": command}}
            run = self.invoke(shell, ["-Hook", "handoff_size"], json.dumps(event, ensure_ascii=False), hook=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(json.loads(run.stdout)["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_session_start_exact_identity_and_path_helper(self):
        for shell in self.shells:
            start = {"hook_event_name": "SessionStart", "session_id": SID, "cwd": str(self.scratch)}
            run = self.invoke(shell, ["-Hook", "questions"], json.dumps(start), hook=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            context = json.loads(run.stdout)["hookSpecificOutput"]["additionalContext"]
            self.assertIn("Current session_id: " + SID, context)
            path = self.invoke(shell, ["--session-id", SID, "path", "--windows", "/home/user"])
            self.assertEqual(path.returncode, 0, path.stderr)
            self.assertTrue(path.stdout.strip().startswith("\\\\"), path.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)

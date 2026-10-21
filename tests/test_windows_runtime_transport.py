"""Offline Windows/WSL controls: no service authentication or model calls."""
from __future__ import annotations

import importlib.util
import base64
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "windows"))
import worker_proxy as proxy


@unittest.skipIf(os.name == "nt", "Original context policy requires POSIX/WSL")
class ContextReadProvenanceTests(unittest.TestCase):
    """Exercise the real runtime normalizer and context hook, never execute a guarded command."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="context-read-origin-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.hub = self.home / "hub"
        stage = self.hub / "stage-a"
        stage.mkdir(parents=True)
        (self.hub / "config.json").write_text(json.dumps({"AGENT_HUB_AUTO_HANDOFF": "on"}))
        (stage / "config.json").write_text(json.dumps({"AGENT_HUB_CONTEXT_BLOCK": 500000}))
        (stage / "roles.json").write_text(json.dumps({"roles": {"hub": {"session": "context-origin-own"}}}))
        self.transcript = self.home / "usage.jsonl"
        self.transcript.write_text(json.dumps({"type": "token_usage_record", "payload": {"usage": {"total_tokens": 510000}}}) + "\n")
        self.shadow = self.home / "shadow"
        self.shadow.mkdir()
        for name in ("path", "Get-Content"):
            executable = self.shadow / name
            executable.write_text("#!/bin/sh\nexit 99\n")
            executable.chmod(0o755)
        self.env = {"HOME": str(self.home), "PATH": str(self.shadow) + os.pathsep + os.defpath,
                    "AGENT_HUB_HOME": str(self.hub), "AGENT_HUB_TZ": "UTC"}
        self.config = {"LinuxHome": str(self.home), "WindowsCodexHome": str(self.home),
                       "LinuxCodex": "/bin/true", "HubHome": str(self.hub)}

    def hook(self, command, replacements=(), spoof=False):
        event = {"hook_event_name": "PreToolUse", "session_id": "context-origin-own",
                 "cwd": str(self.home), "transcript_path": str(self.transcript), "tool_name": "Bash",
                 "tool_input": {"command": command}}
        if spoof:
            event["_desktop_context_native_reads"] = ["path", "get-content"]
        payload = {"mode": "hook", "hook": "context_budget", "event": event,
                   "command_replacements": list(replacements), "pluginroot": str(ROOT),
                   "cwd": str(self.home), "config": self.config, "env": self.env}
        encoded = base64.b64encode(json.dumps(payload).encode()).decode()
        run = subprocess.run([sys.executable, str(ROOT / "windows/desktop_runtime.py"), encoded],
                             capture_output=True, text=True, cwd=self.home, env=self.env, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotIn("fail-open", run.stderr)
        return json.loads(run.stdout) if run.stdout.strip() else {}

    def replacement(self, command, **fields):
        return dict(start=0, end=len(command.encode("utf-16-le")) // 2, **fields)

    def assertDenied(self, out):
        self.assertEqual(out.get("hookSpecificOutput", {}).get("permissionDecision"), "deny")

    def test_standalone_literal_bridge_conversions_pass(self):
        for mode in ("--linux", "--windows"):
            source = f"& 'X/desktop.ps1' path {mode} '/tmp/HANDOFF-a.md'"
            item = self.replacement(source, kind="argv", argv=["path", mode, "/tmp/HANDOFF-a.md"])
            self.assertEqual(self.hook(source, [item]), {})

    def test_bridge_shell_cannot_borrow_native_marker_or_spoofed_origin(self):
        for body in ("path --linux /tmp/HANDOFF-a.md", "Get-Content -LiteralPath /tmp/HANDOFF-a.md"):
            source = "& 'X/desktop.ps1' shell '" + body + "'"
            item = self.replacement(source, kind="shell", script=body)
            self.assertDenied(self.hook(source, [item], spoof=True))

    def test_bare_posix_path_and_spoofed_input_are_denied(self):
        self.assertDenied(self.hook("path --linux /tmp/HANDOFF-a.md", spoof=True))
        self.assertDenied(self.hook(str(self.shadow / "path") + " --linux /tmp/HANDOFF-a.md", spoof=True))

    def test_direct_native_handoff_read_passes_but_mutation_does_not(self):
        self.assertEqual(self.hook("Get-Content -LiteralPath 'C:\\h\\HANDOFF-a.md'"), {})
        self.assertDenied(self.hook("PATH=/tmp; Get-Content -LiteralPath /tmp/HANDOFF-a.md", spoof=True))

    def test_enclosing_syntax_and_companions_do_not_gain_conversion_origin(self):
        conversion = "& 'X/desktop.ps1' path --linux '/tmp/HANDOFF-a.md'"
        for prefix, suffix in (("$result = ", ""), ("", "; path --linux /tmp/HANDOFF-a.md"), ("", "; git status")):
            item = self.replacement(conversion, kind="argv", argv=["path", "--linux", "/tmp/HANDOFF-a.md"])
            offset = len(prefix.encode("utf-16-le")) // 2
            item.update(start=offset, end=item["end"] + offset)
            self.assertDenied(self.hook(prefix + conversion + suffix, [item], spoof=True))


class ProxyContractTests(unittest.TestCase):
    def test_manual_endpoint_variants_and_disabled(self):
        self.assertIsNone(proxy.proxy_endpoint({"enabled": False, "server": "ignored"}))
        for server in ("127.0.0.1:10809", "http://127.0.0.1:10809", "http=127.0.0.1:10809;https=127.0.0.1:10809"):
            self.assertEqual(proxy.proxy_endpoint({"enabled": True, "server": server}), ("127.0.0.1", 10809))
        self.assertEqual(proxy.proxy_endpoint({"enabled": True, "server": "[::1]:8080"}), ("::1", 8080))
        self.assertEqual(proxy.proxy_endpoint({"enabled": True, "server": "localhost"}), ("localhost", 80))
        for server in ("", "socks=localhost:1", "https://localhost:1", "user:secret@localhost:1", "localhost:bad", "localhost:1/path", "localhost:0", "http=a:1;https=b:2"):
            with self.subTest(server=server):
                with self.assertRaises(RuntimeError) as caught:
                    proxy.proxy_endpoint({"enabled": True, "server": server})
                self.assertNotIn("secret", str(caught.exception))

    def test_explicit_caller_values_and_no_proxy_preserved(self):
        for key in proxy.PROXY_KEYS:
            for value in ("", "http://caller:42"):
                env = {key: value, "NO_PROXY": "example.test,localhost"}
                with patch.object(proxy, "powershell_command") as discover:
                    self.assertIsNone(proxy.prepare_proxy(env))
                discover.assert_not_called()
                self.assertEqual(env, {key: value, "NO_PROXY": "example.test,localhost"})

    def test_inherited_owned_relay_is_replaced_but_caller_override_survives(self):
        env = {proxy.OWNER_KEY: "http://127.0.0.1:42", "HTTP_PROXY": "http://127.0.0.1:42",
               "HTTPS_PROXY": "http://explicit:88", "no_proxy": "localhost"}
        proxy.clean_inherited_proxy(env)
        self.assertEqual(env, {"HTTPS_PROXY": "http://explicit:88", "no_proxy": "localhost"})

    def test_disabled_proxy_keeps_direct_environment(self):
        env = {"NO_PROXY": "example.test"}
        with patch.object(proxy, "powershell_command", return_value=["fake"]), patch.object(proxy, "discover_proxy", return_value=None):
            self.assertIsNone(proxy.prepare_proxy(env))
        self.assertEqual(env, {"NO_PROXY": "example.test"})

    def test_discovery_errors_are_actionable_and_hide_endpoint_data(self):
        with patch.object(proxy.subprocess, "run", side_effect=subprocess.TimeoutExpired("secret-proxy", 15)):
            with self.assertRaises(RuntimeError) as caught:
                proxy.discover_proxy(["fake"])
        self.assertIn("explicit worker proxy", str(caught.exception))
        self.assertNotIn("secret-proxy", str(caught.exception))

    def test_owned_client_uses_selected_distribution_without_default(self):
        self.assertEqual(proxy.owned_wsl_command("selected 日本語"),
            ["wsl.exe", "--distribution", "selected 日本語", "--exec", sys.executable])
        for distro in (None, "", " ", "bad\x00name"):
            with self.assertRaises(RuntimeError): proxy.owned_wsl_command(distro)

    @unittest.skipUnless(sys.platform == "linux", "Linux pidfd ownership")
    def test_owned_cleanup_does_not_signal_reused_pid(self):
        # The pinned process handle eliminates the check-to-kill reuse race.
        with patch.object(proxy.os, "pidfd_open", return_value=99) as opened, \
             patch.object(proxy.os, "close") as closed, \
             patch.object(proxy.signal, "pidfd_send_signal") as send:
            with patch.object(proxy, "owner_token", return_value="new-start"):
                proxy.stop_owned(1234, "old-start", 15)
                send.assert_not_called()
            with patch.object(proxy, "owner_token", return_value="old-start"):
                proxy.stop_owned(1234, "old-start", 15)
                send.assert_called_once_with(99,15)
            self.assertEqual(opened.call_args_list, [((1234,),), ((1234,),)])
            self.assertEqual(closed.call_count,2)


# Echo implementation of the multiplexed protocol, including receiver credits.
FAKE_RELAY = r"""
import os,sys,struct
from pathlib import Path
H=struct.Struct('<BII')
log=Path(__file__).with_suffix('.pids')
with log.open('a') as f: f.write(str(os.getpid())+'\n')
def exact(size):
 data=bytearray()
 while len(data)<size:
  b=os.read(0,size-len(data))
  if not b: raise EOFError
  data.extend(b)
 return bytes(data)
def send(k,i,b=b''):
 data=H.pack(k,i,len(b))+b
 while data:
  n=os.write(1,data);data=data[n:]
states={}
send(1,0)
try:
 while True:
  k,i,n=H.unpack(exact(9)); b=exact(n)
  if i==0 or n>32768: raise ValueError('Invalid frame header.')
  if k==2:
   if n or len(states)>=32 or i in states: raise ValueError('Invalid open.')
   states[i]={'credit':65536,'queue':bytearray(),'fin':False,'fin_sent':False}
  elif k==5 and n==0: states.pop(i,None)
  elif i in states:
   c=states[i]
   if k==3 and not c['fin'] and n and len(c['queue'])+n<=65536:c['queue'].extend(b)
   elif k==6 and n==4:
    count=struct.unpack('<I',b)[0]
    if count==0 or count>65536 or c['credit']+count>65536: raise ValueError('Invalid credit.')
    c['credit']+=count
   elif k==4 and n==0 and not c['fin']:c['fin']=True
   else:raise ValueError('Invalid connection frame.')
  for i,c in list(states.items()):
   while c['queue'] and c['credit']:
    n=min(32768,c['credit'],len(c['queue']))
    b=bytes(c['queue'][:n]);del c['queue'][:n];c['credit']-=n
    send(3,i,b);send(6,i,struct.pack('<I',n))
   if c['fin'] and not c['queue'] and not c['fin_sent']:send(4,i);c['fin_sent']=True
except (EOFError,BrokenPipeError):pass
"""


@unittest.skipUnless(sys.platform == "linux", "Linux /proc and pass_fds lifecycle")
class LinuxRelayTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="delamain proxy unicode ")
        self.addCleanup(self.scratch.cleanup)
        self.helper = Path(self.scratch.name) / "fake helper.py"
        self.helper.write_text(FAKE_RELAY, encoding="utf-8")
        # Exercise the full private FD handoff on Linux. Native controls use
        # the real dedicated wsl.exe client instead of this process stand-in.
        owned = patch.object(proxy, "owned_wsl_command", return_value=[sys.executable])
        owned.start()
        self.addCleanup(owned.stop)

    def start(self, env=None):
        env = {} if env is None else env
        with patch.object(proxy, "powershell_command", return_value=[sys.executable, str(self.helper)]), \
             patch.object(proxy, "discover_proxy", return_value=("127.0.0.1", 1234)):
            relay = proxy.prepare_proxy(env)
        self.addCleanup(self.stop, relay)
        return relay, int(env["HTTP_PROXY"].rsplit(":", 1)[1])

    def test_desktop_worker_preparation_preserves_file_and_pipe_stdin(self):
        # Use the installed adapter and automatic preparation, including both
        # external commands. The stand-ins intentionally drain inherited stdin
        # to model native PowerShell startup without relying on its version.
        directory = Path(self.scratch.name)
        package = directory / "installed package Русский"
        package.mkdir()
        for name in ("desktop_codex.py", "worker_proxy.py"):
            shutil.copy2(ROOT / "windows" / name, package / name)
        log = directory / "preparation.jsonl"
        tools = directory / "tools"
        tools.mkdir()
        for name in ("wslpath", "powershell.exe", "wsl.exe"):
            helper = tools / name
            helper.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
if Path(sys.argv[0]).name == "wsl.exe":
    assert sys.argv[1:4] == ["--distribution", "fixture", "--exec"]
    os.execv(sys.argv[4],sys.argv[4:])
if Path(sys.argv[0]).name == "wslpath" or "-Discover" in sys.argv:
    incoming = sys.stdin.buffer.read()
    with open(os.environ["FIXTURE_PREPARATION_LOG"], "a") as log:
        log.write(json.dumps({"helper":Path(sys.argv[0]).name,"bytes":len(incoming)})+"\\n")
    if Path(sys.argv[0]).name == "wslpath": print(sys.argv[-1])
    else: print(json.dumps({"enabled":os.environ["FIXTURE_PROXY_ENABLED"]=="1","server":"127.0.0.1:1234"}))
else:
    exec(''' + repr(FAKE_RELAY) + ''')
''', encoding="utf-8")
            helper.chmod(0o755)
        worker = directory / "fake worker 日本語.py"
        worker.write_text('''#!/usr/bin/env python3
import json,os,socket,sys
prompt = sys.stdin.buffer.read().decode("utf-8")
address = os.environ.get("HTTP_PROXY")
if address:
    payload = bytes(range(256))*256
    with socket.create_connection(("127.0.0.1",int(address.rsplit(":",1)[1])),timeout=5) as client:
        client.sendall(payload)
        client.shutdown(socket.SHUT_WR)
        received = bytearray()
        while True:
            data=client.recv(32768)
            if not data: break
            received.extend(data)
        assert received == payload, "connection helper stdin was detached"
print(json.dumps({"pid":os.getpid(),"argv":sys.argv[1:],"prompt":prompt,"proxy":address}))
''', encoding="utf-8")
        worker.chmod(0o755)
        (package / "desktop-config.json").write_text(json.dumps({"LinuxCodex":str(worker), "LinuxHome":str(directory / "home"), "Distro":"fixture"}), encoding="utf-8")
        env = {k:v for k,v in os.environ.items() if k not in proxy.PROXY_KEYS and k != proxy.OWNER_KEY}
        env.update(PATH=str(tools)+os.pathsep+env["PATH"], FIXTURE_PREPARATION_LOG=str(log), FIXTURE_PROXY_ENABLED="1")
        prompt = "Сохрани весь prompt 日本語 😀\nsecond line\n".encode()
        # Positive controls establish that each fixture really consumes stdin.
        for command in ([str(tools / "wslpath"), "-a", "-w", "helper.ps1"],
                        [str(tools / "powershell.exe"), "-Discover"]):
            subprocess.run(command, input=prompt, capture_output=True, env=env, check=True)
        self.assertEqual([json.loads(line)["bytes"] for line in log.read_text().splitlines()], [len(prompt)]*2)
        args = ["exec", "--json", "", "quote\" and $literal", "日本語 😀", "line1\nline2", "-"]
        for enabled in ("0", "1"):
            for mode in ("file", "pipe"):
                with self.subTest(enabled=enabled, stdin=mode):
                    log.write_text("")
                    env["FIXTURE_PROXY_ENABLED"] = enabled
                    with tempfile.TemporaryFile() as incoming:
                        incoming.write(prompt)
                        incoming.seek(0)
                        process = subprocess.Popen([sys.executable, str(package / "desktop_codex.py"), *args],
                                                   stdin=incoming if mode == "file" else subprocess.PIPE,
                                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
                        try:
                            output, error = process.communicate(prompt if mode == "pipe" else None, timeout=15)
                        finally:
                            if process.poll() is None:
                                process.kill()
                                process.communicate(timeout=5)
                    self.assertEqual(process.returncode, 0, error.decode(errors="replace"))
                    data = json.loads(output)
                    self.assertEqual(data["pid"], process.pid)
                    self.assertEqual(data["argv"], args)
                    self.assertEqual(data["prompt"].encode(), prompt)
                    prepared = [json.loads(line) for line in log.read_text().splitlines()]
                    self.assertEqual(prepared, [{"helper":"wslpath","bytes":0}, {"helper":"powershell.exe","bytes":0}])
                    self.assertEqual(bool(data["proxy"]), enabled == "1")
                    if data["proxy"]:
                        port = int(data["proxy"].rsplit(":",1)[1])
                        deadline = time.monotonic()+5
                        while time.monotonic() < deadline:
                            try:
                                socket.create_connection(("127.0.0.1",port),timeout=0.25).close()
                            except OSError:
                                break
                            time.sleep(0.05)
                        else:
                            self.fail("worker exit left the prepared relay listener alive")

    @staticmethod
    def stop(relay):
        if relay.poll() is None:
            relay.terminate()
        relay.wait(timeout=8)

    def test_opaque_large_stream_concurrent_and_half_close(self):
        relay, port = self.start({"NO_PROXY": "example.test"})
        payload = bytes(range(256)) * 2048 + "Русский 日本語 😀".encode()
        errors = []
        def transfer():
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=4) as client:
                    # Writer and reader run concurrently to exercise backpressure.
                    def send():
                        client.sendall(payload)
                        client.shutdown(socket.SHUT_WR)
                    writer = threading.Thread(target=send)
                    writer.start()
                    received = bytearray()
                    while True:
                        data = client.recv(32768)
                        if not data:
                            break
                        received.extend(data)
                    writer.join()
                    self.assertEqual(received, payload)
            except BaseException as error:
                errors.append(error)
        threads = [threading.Thread(target=transfer) for _ in range(4)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=10)
            self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])
        self.assertIsNone(relay.poll())
        pids = [int(line) for line in self.helper.with_suffix('.pids').read_text().splitlines()]
        self.assertEqual(len(pids), 1, "concurrent connections spawned extra helpers")
        self.assertIsNotNone(proxy.owner_token(pids[0]))
        self.stop(relay)
        self.assertIsNone(proxy.owner_token(pids[0]), "relay exit left its helper alive")
        print(f"fixture concurrent streams: one helper PID {pids[0]}, relay PID {relay.pid}; both reaped")
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", port), timeout=1)

    def test_upstream_first_half_close_waits_for_confirmed_upload_drainage(self):
        # Exercise production relay_main against a protocol helper that models
        # a Windows upstream closing its send half before receiving our upload.
        # Credit is the confirmation that Windows network.Write consumed bytes.
        payload = bytes(range(256)) * 128
        import hashlib
        for delayed in (False, True):
            with self.subTest(delayed_upload_credit=delayed):
                audit = self.helper.with_suffix('.half-close.jsonl')
                release = self.helper.with_suffix('.release')
                audit.unlink(missing_ok=True)
                release.unlink(missing_ok=True)
                self.helper.write_text(r'''
import hashlib,json,os,select,struct
from pathlib import Path
H=struct.Struct('<BII')
audit=Path(__file__).with_suffix('.half-close.jsonl')
release=Path(__file__).with_suffix('.release')
delayed=DELAYED
outstanding=0
number=None
upload=hashlib.sha256()
def record(kind,size=0,data=b''):
 with audit.open('a') as f:
  f.write(json.dumps({'kind':kind,'outstanding':outstanding,'size':size,
    'digest':upload.hexdigest() if kind=='DATA' else hashlib.sha256(data).hexdigest()})+'\n')
def send(kind,number,data=b''):
 wire=H.pack(kind,number,len(data))+data
 while wire:
  count=os.write(1,wire);wire=wire[count:]
def exact(size):
 data=bytearray()
 while len(data)<size:
  part=os.read(0,size-len(data))
  if not part: raise EOFError
  data.extend(part)
 return bytes(data)
def grant():
 global outstanding
 credit=outstanding;outstanding=0
 record('CREDIT',credit)
 send(6,number,struct.pack('<I',credit))
send(1,0)
try:
 while True:
  if outstanding and delayed and release.exists(): grant()
  if not select.select([0],[],[],.02)[0]: continue
  kind,number,size=H.unpack(exact(9));data=exact(size)
  if kind==2:
   record('OPEN');send(4,number)
  elif kind==3:
   outstanding+=size;upload.update(data);record('DATA',size,data)
   if not delayed:grant()
  elif kind==4:record('FIN')
  elif kind==5:record('CLOSE')
except (EOFError,BrokenPipeError):pass
'''.replace('DELAYED',repr(delayed)),encoding='utf-8')
                relay,port = self.start()
                def records():
                    return [json.loads(line) for line in audit.read_text().splitlines()] if audit.exists() else []
                def wait_for(kind):
                    deadline = time.monotonic()+4
                    while time.monotonic()<deadline:
                        result = records()
                        if any(row['kind']==kind for row in result): return result
                        time.sleep(.02)
                    self.fail(f"helper did not receive {kind}: {records()}")
                try:
                    with socket.create_connection(('127.0.0.1',port),timeout=4) as client:
                        # This EOF comes before any upload; TCP still permits
                        # sending the complete request after that read half EOF.
                        self.assertEqual(client.recv(1),b'')
                        client.sendall(payload)
                        client.shutdown(socket.SHUT_WR)
                        wait_for('FIN')
                        if delayed:
                            # Ensure several relay iterations observe both FINs
                            # while the Windows write is deliberately uncredited.
                            time.sleep(.35)
                            self.assertFalse(any(row['kind']=='CLOSE' for row in records()),
                                f"CLOSE canceled an unconfirmed Windows upload: {records()}")
                            release.touch()
                        rows = wait_for('CLOSE')
                        self.assertEqual([row['outstanding'] for row in rows if row['kind']=='CLOSE'],[0])
                        uploaded = [row for row in rows if row['kind']=='DATA']
                        self.assertEqual(sum(row['size'] for row in uploaded),len(payload))
                        self.assertEqual(uploaded[-1]['digest'],hashlib.sha256(payload).hexdigest())
                        kinds = [row['kind'] for row in rows]
                        self.assertLess(kinds.index('CREDIT'),kinds.index('CLOSE'))
                        if delayed:self.assertLess(kinds.index('FIN'),kinds.index('CREDIT'))
                        self.assertIsNone(relay.poll())
                finally:self.stop(relay)
                print(f"upstream-first half-close: delayed={delayed}, relay PID {relay.pid}; CLOSE acknowledged zero outstanding upload bytes")

    def test_stalled_connection_does_not_block_other_connections(self):
        relay, port = self.start()
        stalled = socket.create_connection(("127.0.0.1", port), timeout=2)
        stalled.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        stopped = threading.Event()
        def flood():
            try: stalled.sendall(b"z" * (4 * 1024 * 1024))
            except OSError: pass
            finally: stopped.set()
        writer = threading.Thread(target=flood)
        writer.start()
        try:
            time.sleep(0.15)
            with socket.create_connection(("127.0.0.1", port), timeout=2) as client:
                client.sendall(b"independent")
                self.assertEqual(client.recv(11), b"independent")
            self.assertIsNone(relay.poll())
        finally:
            stalled.shutdown(socket.SHUT_RDWR)
            stalled.close()
            writer.join(timeout=3)
        self.assertTrue(stopped.is_set(), "fixture writer survived socket cleanup")
        self.assertEqual(len(self.helper.with_suffix('.pids').read_text().splitlines()), 1)

    def test_32_connection_limit_rejects_excess_and_recovers_slot(self):
        relay, port = self.start()
        clients = []
        try:
            for _ in range(proxy.MAX_CONNECTIONS):
                client = socket.create_connection(("127.0.0.1", port), timeout=2)
                clients.append(client)
                client.sendall(b"slot")
                self.assertEqual(client.recv(4),b"slot")
            with socket.create_connection(("127.0.0.1", port), timeout=2) as extra:
                self.assertEqual(extra.recv(1), b"")
            clients.pop().close()
            time.sleep(0.2)
            with socket.create_connection(("127.0.0.1", port), timeout=2) as replacement:
                replacement.sendall(b"reuse")
                self.assertEqual(replacement.recv(5),b"reuse")
            self.assertIsNone(relay.poll())
            self.assertEqual(len(self.helper.with_suffix('.pids').read_text().splitlines()),1)
        finally:
            for client in clients: client.close()

    def test_helper_eof_or_invalid_frame_closes_clients_and_owned_process(self):
        for ending in ("os.close(1)", "os.write(1,struct.pack('<BII',3,1,65537))"):
            with self.subTest(ending=ending):
                self.helper.write_text("import os,struct,time\nfrom pathlib import Path\n"
                    "Path(__file__).with_suffix('.pids').write_text(str(os.getpid()))\n"
                    "os.write(1,struct.pack('<BII',1,0,0))\ntime.sleep(.2)\n" + ending + "\ntime.sleep(60)\n")
                relay,port = self.start()
                with socket.create_connection(("127.0.0.1",port),timeout=5) as client:
                    self.assertEqual(client.recv(1),b"")
                relay.wait(timeout=8)
                self.assertNotEqual(relay.returncode,0)
                pid=int(self.helper.with_suffix('.pids').read_text())
                self.assertIsNone(proxy.owner_token(pid),"faulty helper survived relay cleanup")
                with self.assertRaises(OSError): socket.create_connection(("127.0.0.1",port),timeout=1)

    def test_exec_preserves_worker_pid_and_relay_dies_after_sigkill(self):
        record = Path(self.scratch.name) / "worker.json"
        wrapper = Path(self.scratch.name) / "wrapper.py"
        worker = Path(self.scratch.name) / "worker.py"
        worker.write_text("import json,os,sys,time\nfrom pathlib import Path\nPath(sys.argv[1]).write_text(json.dumps({'pid':os.getpid(),'proxy':os.environ['HTTP_PROXY']}))\ntime.sleep(60)\n")
        wrapper.write_text("import sys\nsys.path.insert(0,sys.argv[1])\nimport worker_proxy as p\np.owned_wsl_command=lambda d:[sys.executable]\np.powershell_command=lambda:[sys.executable,sys.argv[2]]\np.discover_proxy=lambda c:('127.0.0.1',1234)\np.exec_worker(sys.executable,[sys.argv[3],sys.argv[4]],{})\n")
        owner = subprocess.Popen([sys.executable, str(wrapper), str(ROOT / "windows"), str(self.helper), str(worker), str(record)])
        try:
            deadline = time.monotonic() + 5
            while not record.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            data = json.loads(record.read_text())
            self.assertEqual(data["pid"], owner.pid)
            port = int(data["proxy"].rsplit(":", 1)[1])
            with socket.create_connection(("127.0.0.1", port), timeout=2) as client:
                client.sendall(b"alive")
                self.assertEqual(client.recv(5), b"alive")
                helper_pid = int(self.helper.with_suffix('.pids').read_text().strip())
                owner.kill()
                owner.wait(timeout=5)
                self.assertEqual(client.recv(5), b"")
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    socket.create_connection(("127.0.0.1", port), timeout=0.25).close()
                except OSError:
                    break
                time.sleep(0.05)
            else:
                self.fail("owner exit left the relay listener alive")
            deadline = time.monotonic() + 5
            while proxy.owner_token(helper_pid) is not None and time.monotonic() < deadline: time.sleep(.05)
            self.assertIsNone(proxy.owner_token(helper_pid), "SIGKILL left the owned helper alive")
            print(f"fixture SIGKILL: original worker PID {owner.pid}, helper PID {helper_pid}; listener closed and helper gone")
        finally:
            if owner.poll() is None:
                owner.kill()
                owner.wait()

    def test_owner_start_token_mismatch_closes_helper_without_affecting_owner(self):
        with patch.object(proxy,"powershell_command",return_value=[sys.executable,str(self.helper)]), \
             patch.object(proxy,"discover_proxy",return_value=("127.0.0.1",1234)), \
             patch.object(proxy,"owner_token",return_value="different-start-token"):
            with self.assertRaises(RuntimeError): proxy.prepare_proxy({})
        self.assertIsNotNone(proxy.owner_token(os.getpid()))
        # The relay rejects ownership before signalling readiness, even if the
        # Windows helper is still compiling/starting when the token changes.
        logfile = self.helper.with_suffix('.pids')
        if logfile.exists():
            for pid in logfile.read_text().splitlines(): self.assertIsNone(proxy.owner_token(int(pid)))

    def test_exec_failure_cleans_relay_and_owner_token_handles_exit(self):
        self.assertIsNotNone(proxy.owner_token(os.getpid()))
        self.assertIsNone(proxy.owner_token(999999999))
        env = {}
        with patch.object(proxy, "powershell_command", return_value=[sys.executable, str(self.helper)]), \
             patch.object(proxy, "discover_proxy", return_value=("127.0.0.1", 1234)):
            with self.assertRaises(OSError):
                proxy.exec_worker("/no/such/executable", [], env)
        port = int(env["HTTP_PROXY"].rsplit(":", 1)[1])
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", port), timeout=1)

    def test_owned_client_failed_launch_closes_readiness_and_private_handoff(self):
        before = set(Path("/tmp").glob("delamain-relay-*"))
        with patch.object(proxy, "owned_wsl_command", return_value=["/no/such/owned-wsl-client"]), \
             patch.object(proxy, "powershell_command", return_value=[sys.executable, str(self.helper)]), \
             patch.object(proxy, "discover_proxy", return_value=("127.0.0.1",1234)):
            with self.assertRaises(RuntimeError): proxy.prepare_proxy({})
        self.assertEqual(set(Path("/tmp").glob("delamain-relay-*")), before)
        self.assertFalse(self.helper.with_suffix('.pids').exists())

    def test_slow_owned_client_without_handoff_is_reaped_before_startup_failure_returns(self):
        # The child never connects, so no peer identity or EOF cleanup channel
        # exists. Cover cooperative TERM and a child requiring exact-Popen KILL.
        slow = Path(self.scratch.name) / "slow owned client.py"
        record = Path(self.scratch.name) / "slow-client.json"
        slow.write_text('''import json,os,signal,sys,time
from pathlib import Path
if sys.argv[2] == "ignore": signal.signal(signal.SIGTERM,signal.SIG_IGN)
fields=Path(f"/proc/{os.getpid()}/stat").read_text().rsplit(")",1)[1].split()
Path(sys.argv[1]).write_text(json.dumps({"pid":os.getpid(),"token":fields[19],
    "socket":sys.argv[sys.argv.index("--owned-relay")+1]}))
while True: time.sleep(60)
''',encoding="utf-8")
        real_popen = proxy.subprocess.Popen
        def started_fixture(*args, **kwargs):
            child = real_popen(*args, **kwargs)
            if "--supervise" in args[0]:
                # Start the short cancellation deadline after the fixture has
                # launched. Otherwise a cold Python startup can be cancelled
                # before this test has a recorded PID to verify or clean up.
                deadline = time.monotonic() + 3
                while child.poll() is None and time.monotonic() < deadline:
                    try:
                        json.loads(record.read_text())
                        return child
                    except (FileNotFoundError, json.JSONDecodeError): time.sleep(.01)
                child.terminate()
                child.wait(timeout=3)
                raise RuntimeError("Owned slow-client fixture did not start")
            return child
        for mode in ("normal", "ignore"):
            with self.subTest(termination=mode):
                record.unlink(missing_ok=True)
                started = time.monotonic()
                try:
                    with patch.object(proxy.subprocess, "Popen", side_effect=started_fixture), \
                         patch.object(proxy, "CONNECT_TIMEOUT", .5), \
                         patch.object(proxy, "owned_wsl_command", return_value=[sys.executable,str(slow),str(record),mode]), \
                         patch.object(proxy, "powershell_command", return_value=[sys.executable,str(self.helper)]), \
                         patch.object(proxy, "discover_proxy", return_value=("127.0.0.1",1234)):
                        with self.assertRaises(RuntimeError): proxy.prepare_proxy({})
                    data = json.loads(record.read_text())
                    path = Path(data["socket"])
                    remaining = (proxy.owner_token(data["pid"]),path.parent.exists())
                    print(f"startup returned: {mode}, exact client {data['pid']}, alive={remaining[0] is not None}, private_dir={remaining[1]}")
                    self.assertEqual(remaining,(None,False), "startup failure left its owned client or private handoff")
                    self.assertFalse(self.helper.with_suffix('.pids').exists(), "unconnected client started a helper")
                    self.assertLess(time.monotonic()-started,5.5,"unconnected client cancellation exceeded its bounded budget")
                    print(f"startup cancellation: {mode}, exact client {data['pid']}; reaped, private directory removed")
                finally:
                    # Negative before-control also cleans only the recorded,
                    # start-token-verified fixture child and exact private path.
                    if record.exists():
                        data = json.loads(record.read_text())
                        proxy.stop_owned(data["pid"],data["token"],signal.SIGKILL)
                        deadline = time.monotonic()+3
                        while proxy.owner_token(data["pid"]) == data["token"] and time.monotonic()<deadline:
                            time.sleep(.02)
                        self.assertNotEqual(proxy.owner_token(data["pid"]),data["token"],"fixture cleanup left exact client alive")
                        path = Path(data["socket"])
                        path.unlink(missing_ok=True)
                        try: path.parent.rmdir()
                        except FileNotFoundError: pass

    def test_owned_handoff_rejects_symlink_directory_before_connect(self):
        # A Unix socket's address is bounded even when the caller's TMPDIR is
        # valid but long. Keep the real positive fixture within that OS bound.
        with tempfile.TemporaryDirectory(prefix="relay-symlink-", dir="/tmp") as scratch:
            directory = Path(scratch) / "private"
            directory.mkdir(mode=0o700)
            link = Path(self.scratch.name) / "redirect"
            link.symlink_to(directory, target_is_directory=True)
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(directory / "control"))
                (directory / "control").chmod(0o600)
                with self.assertRaises(RuntimeError):
                    proxy.owned_relay_main([str(link / "control"), str(os.getpid()), proxy.owner_token(os.getpid())])

    def test_supervisor_sigkill_closes_owned_client_helper_and_private_paths(self):
        relay, port = self.start()
        child = int(Path(f"/proc/{relay.pid}/task/{relay.pid}/children").read_text().strip())
        command = Path(f"/proc/{child}/cmdline").read_bytes().split(b"\0")
        path = Path(os.fsdecode(command[command.index(b"--owned-relay") + 1]))
        helper = int(self.helper.with_suffix('.pids').read_text().strip())
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        with socket.create_connection(("127.0.0.1", port),timeout=3) as client:
            client.sendall(b"owned-before-kill")
            self.assertEqual(client.recv(17), b"owned-before-kill")
            relay.kill()
            relay.wait(timeout=5)
            self.assertEqual(client.recv(1), b"")
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline and (proxy.owner_token(child) or proxy.owner_token(helper) or path.parent.exists()):
            time.sleep(.05)
        self.assertIsNone(proxy.owner_token(child), "owned client survived supervisor SIGKILL")
        self.assertIsNone(proxy.owner_token(helper), "helper survived supervisor SIGKILL")
        self.assertFalse(path.parent.exists(), "private handoff survived supervisor SIGKILL")
        with self.assertRaises(OSError): socket.create_connection(("127.0.0.1",port),timeout=1)
        print(f"supervisor SIGKILL: relay {relay.pid}, owned client {child}, helper {helper}; all gone, private paths removed")


@unittest.skipUnless(os.name == "posix", "POSIX exec/PID launcher fixture; native payload is checked through WSL")
class LauncherPayloadTests(unittest.TestCase):
    def test_file_payload_over_windows_limit_preserves_argv_env_stdin_and_pid(self):
        import base64
        with tempfile.TemporaryDirectory(prefix="launcher payload Русский ") as directory:
            directory = Path(directory)
            plugin = directory / "plugin"
            (plugin / "bin").mkdir(parents=True)
            (plugin / "bin/hub").touch()
            worker = directory / "worker.py"
            worker.write_text("#!/usr/bin/env python3\nimport json,os,sys\n"
                "print(json.dumps({'pid':os.getpid(),'argv':sys.argv[1:],'stdin':sys.stdin.read(),'opaque':os.environ['HUB_FIXTURE_OPAQUE']}))\n")
            worker.chmod(0o755)
            args = ["", "x" * 50000, "Русский 日本語 😀", "quote\" and $literal", "line1\nline2"]
            opaque = "日本語" * 5000
            payload = {"argv":["codex",*args], "cwd":str(directory), "env":{
                "DELAMAIN_CODEX_PATH":str(worker), "DELAMAIN_PLUGIN_ROOT":str(plugin),
                "HTTP_PROXY":"", "HUB_FIXTURE_OPAQUE":opaque}}
            incoming = "input 日本語 😀\nsecond line\n"
            filename = directory / "payload"
            filename.write_text(base64.b64encode(json.dumps(payload).encode()).decode(),encoding="ascii")
            self.assertGreater(filename.stat().st_size,32768)
            process = subprocess.Popen([sys.executable,str(ROOT / "windows/launch.py"),"--payload-file",str(filename)],
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            output,error = process.communicate(incoming.encode(),timeout=10)
            self.assertEqual(process.returncode,0,error)
            self.assertEqual(json.loads(output),{"pid":process.pid,"argv":args,"stdin":incoming,"opaque":opaque})


FAKE_WSL = r'''
using System;
using System.IO;
using System.Text;
using System.Threading;
public static class FakeWsl {
    public static int Main(string[] args) {
        string searchMarker = Environment.GetEnvironmentVariable("FIXTURE_SEARCH_MARKER");
        if (searchMarker != null) {
            File.WriteAllText(searchMarker, Environment.CurrentDirectory);
            Console.WriteLine("fake cwd WSL executed"); return 0;
        }
        if (args.Length == 3 && args[0] == "--owned-quiet") {
            File.WriteAllText(args[1], System.Diagnostics.Process.GetCurrentProcess().Id.ToString());
            Console.WriteLine("{\"ready\":true}"); Console.Out.Flush();
            Thread.Sleep(3000); File.WriteAllText(args[2], "survived"); return 0;
        }
        byte[] warning = Encoding.Unicode.GetBytes("wsl: A localhost proxy configuration was detected but not mirrored into WSL. WSL in NAT mode does not support localhost proxies.\r\n");
        Stream error = Console.OpenStandardError(); error.Write(warning, 0, warning.Length); error.Flush();
        if (Array.IndexOf(args, "wslpath") >= 0) {
            if (Environment.GetEnvironmentVariable("FIXTURE_MAP_FAIL") == "1" && !args[args.Length - 1].EndsWith(".py")) return 8;
            Console.OutputEncoding = new UTF8Encoding(false);
            Console.WriteLine(args[args.Length - 1]); return 0;
        }
        byte[] unknown = Encoding.Unicode.GetBytes("wsl: unexpected startup error: Русский 日本語 😀\r\n");
        error.Write(unknown, 0, unknown.Length); error.Flush();
        int at = Array.IndexOf(args, "--payload-file");
        string json = Encoding.UTF8.GetString(Convert.FromBase64String(File.ReadAllText(args[at + 1])));
        byte[] real = Encoding.UTF8.GetBytes("real child error: Русский 日本語 😀\n");
        error.Write(real, 0, real.Length); error.Flush();
        byte[] large = Encoding.UTF8.GetBytes(new String('x', 65534) + "😀日本語\n");
        error.Write(large, 0, large.Length); error.Flush();
        if (json.Contains("\"stream\"")) {
            Stream output = Console.OpenStandardOutput(); byte[] first = Encoding.UTF8.GetBytes("{\"first\":true}\n");
            output.Write(first, 0, first.Length); output.Flush(); Thread.Sleep(1800);
            byte[] last = Encoding.UTF8.GetBytes("{\"last\":true}\n"); output.Write(last, 0, last.Length); output.Flush(); return 0;
        }
        MemoryStream input = new MemoryStream(); Console.OpenStandardInput().CopyTo(input);
        Console.OutputEncoding = new UTF8Encoding(false);
        Console.WriteLine("{\"payload\":" + json + ",\"stdinBase64\":\"" + Convert.ToBase64String(input.ToArray()) + "\"}");
        return json.Contains("\"exit3\"") ? 3 : json.Contains("\"exit4\"") ? 4 : 0;
    }
}
'''


@unittest.skipUnless(sys.platform == "linux", "Real embedded Linux guardian")
class ForegroundGuardianTests(unittest.TestCase):
    def test_completion_drains_both_pipes_before_ack_and_late_start_is_cancelled(self):
        source = (ROOT / "windows/process_transport.ps1").read_text()
        guardian = source.split('const string Guardian = @"', 1)[1].split('";', 1)[0]
        with tempfile.TemporaryDirectory() as scratch:
            base = Path(scratch)
            control = base / "control"
            acknowledgement = Path(str(control) + ".ack")
            acknowledgement.touch()
            marker = base / "should-not-launch"
            # Missing or already cancelled startup must never launch a command.
            for initial in (None, "cancel"):
                if initial is not None: control.write_text(initial)
                run = subprocess.run([sys.executable, "-c", guardian, str(control),
                    sys.executable, "-c", "from pathlib import Path; import sys; Path(sys.argv[1]).touch()",
                    str(marker)], capture_output=True, timeout=3)
                self.assertEqual(run.returncode, 1)
                self.assertFalse(marker.exists())
                control.unlink(missing_ok=True)
            control.write_text("run")
            acknowledgement.write_text("")
            run = subprocess.Popen([sys.executable, "-c", guardian, str(control),
                sys.executable, "-c", "import os,sys,time; print(os.getpid(),flush=True); print('error 日本語',file=sys.stderr,flush=True); os.close(1); os.close(2); time.sleep(.2); sys.exit(4)"],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                # WSL entry status and both EOFs must arrive without host ack.
                output, error = run.communicate(timeout=3)
                self.assertEqual(run.returncode, 4)
                self.assertEqual(error.decode(), "error 日本語\n")
                leader = int(output)
                stat = Path(f"/proc/{leader}/stat")
                self.assertEqual(stat.read_text().rsplit(')',1)[1].split()[0], "Z")
                # A transient truncate during a host decision is not cancellation.
                control.write_text("")
                time.sleep(.1)
                self.assertTrue(stat.exists())
                control.write_text("complete")
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline and acknowledgement.read_text() != "done": time.sleep(.02)
                self.assertEqual(acknowledgement.read_text(), "done")
                self.assertFalse(stat.exists(), "Completion left the pinned leader unreaped")
                print(f"embedded normal completion: entry {run.pid}, leader {leader}; stdout/stderr EOF before ack, status 4, pinned leader reaped")
            finally:
                control.unlink(missing_ok=True)
                if run.poll() is None: run.kill(); run.communicate(timeout=3)

    def test_early_leader_exit_then_cancel_preserves_detached_control(self):
        # Execute the exact embedded program, including its real file protocol.
        source = (ROOT / "windows/process_transport.ps1").read_text()
        guardian = source.split('const string Guardian = @"', 1)[1].split('";', 1)[0]
        with tempfile.TemporaryDirectory() as scratch:
            base = Path(scratch)
            control = base / "control"
            acknowledgement = Path(str(control) + ".ack")
            acknowledgement.touch()
            control.write_text("run")
            helper = base / "fixture.py"
            helper.write_text("""import json,os,signal,subprocess,sys,time
from pathlib import Path
base=Path(sys.argv[1])
if sys.argv[2]=='leader':
 child=subprocess.Popen([sys.executable,__file__,str(base),'child'])
 while not (base/'child-owner').exists(): time.sleep(.01)
 print(os.getpid(),flush=True)
 sys.exit(3)
os.close(1); os.close(2)
signal.signal(signal.SIGTERM,signal.SIG_IGN)
fields=Path(f'/proc/{os.getpid()}/stat').read_text().rsplit(')',1)[1].split()
(base/'child-owner').write_text(json.dumps([os.getpid(),fields[19]]))
time.sleep(1.5); (base/'effect').touch(); time.sleep(20)
""")
            detached = subprocess.Popen([sys.executable, "-c",
                "import sys,time; from pathlib import Path; time.sleep(1.5); Path(sys.argv[1]).touch()",
                str(base / "detached-effect")], start_new_session=True,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            run = subprocess.Popen([sys.executable, "-c", guardian, str(control),
                sys.executable, str(helper), str(base), "leader"],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                leader = int(run.stdout.readline())
                time.sleep(.4)  # A downstream consumer still owns the output.
                stat = Path(f"/proc/{leader}/stat")
                self.assertTrue(not stat.exists() or stat.read_text().rsplit(')',1)[1].split()[0]=='Z')
                control.write_text("cancel")
                output, error = run.communicate(timeout=3)
                detached.wait(timeout=3)
                self.assertEqual(output, b"")
                self.assertEqual(error, b"")
                print(f"embedded guardian {run.pid}, leader {leader}, child {json.loads((base/'child-owner').read_text())}, detached {detached.pid}: effect={(base/'effect').exists()}, detached effect={(base/'detached-effect').exists()}")
                self.assertTrue((base / "detached-effect").exists())
                self.assertFalse((base / "effect").exists(), "Early leader exit abandoned its same-group descendant")
                self.assertEqual(acknowledgement.read_text(), "done")
            finally:
                control.unlink(missing_ok=True)
                if run.poll() is None:
                    try: run.communicate(timeout=3)
                    except subprocess.TimeoutExpired: run.kill(); run.communicate(timeout=3)
                if detached.poll() is None: detached.kill(); detached.wait()
                record = base / "child-owner"
                if record.exists():
                    pid, token = json.loads(record.read_text())
                    proxy.stop_owned(pid, token, signal.SIGKILL)


@unittest.skipUnless(os.name == "nt", "Native PowerShell 5.1/7 process controls")
class WindowsTransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="delamain runtime юникод ")
        cls.directory = Path(cls.scratch.name)
        cls.package = cls.directory / "package"
        cls.package.mkdir()
        for name in ("desktop.ps1", "delamain.ps1", "launch.py", "process_transport.ps1", "desktop_runtime.py"):
            shutil.copy2(ROOT / "windows" / name, cls.package / name)
        (cls.package / "desktop-config.json").write_text('{"Distro":"fixture"}')
        source = cls.directory / "fake.cs"
        source.write_text(FAKE_WSL, encoding="utf-8-sig")
        compile_script = cls.directory / "compile.ps1"
        compile_script.write_text("param($Source,$Output)\n$ErrorActionPreference='Stop'\nAdd-Type -TypeDefinition ([IO.File]::ReadAllText($Source)) -OutputAssembly $Output -OutputType ConsoleApplication\n")
        cls.shells = [shutil.which("powershell.exe"), shutil.which("pwsh.exe")]
        if not all(cls.shells):
            raise unittest.SkipTest("Both PowerShell 5.1 and 7 are required")
        subprocess.run([cls.shells[0], "-NoProfile", "-File", str(compile_script), str(source), str(cls.directory / "wsl.exe")], check=True, capture_output=True)
        # The byte/argv fixtures deliberately exercise ProcessTransport directly
        # with an absolute owned helper. Production WSL resolution is tested below
        # against the unmodified source, with a real cwd/PATH substitution control.
        transport = cls.package / "process_transport.ps1"
        fixture = r"""
function Invoke-DelamainWsl([string[]]$Arguments, [switch]$Capture, [switch]$RedirectInput, [AllowNull()][object]$InputText) {
    $executable = Join-Path (Split-Path -Parent $PSScriptRoot) 'wsl.exe'
    if ($Capture) {
        return [Delamain.ProcessTransport]::Run($executable, $Arguments, $true,
            $RedirectInput.IsPresent, ($null -eq $InputText), $InputText)
    }
    $child = [Delamain.ProcessTransport]::Start($executable, $Arguments,
        $RedirectInput.IsPresent, ($null -eq $InputText), $InputText)
    try {
        while ($null -ne ($line = $child.ReadLine())) { Write-Output $line }
        $global:LASTEXITCODE = $child.Complete()
    } finally { $child.Dispose() }
}
"""
        transport.write_text(transport.read_text() + fixture, encoding="utf-8-sig")
        cls.env = {**os.environ, "PATH": str(cls.directory) + os.pathsep + os.environ["PATH"]}

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def invoke(self, shell, args, stdin=b"", bridge="desktop.ps1"):
        argument_file = self.directory / "args.json"
        argument_file.write_text(json.dumps(args, ensure_ascii=False), encoding="utf-8-sig")
        invocation = self.directory / "invoke.ps1"
        invocation.write_text("param($Bridge,$ArgumentFile)\n$a=Get-Content -LiteralPath $ArgumentFile -Raw -Encoding UTF8 | ConvertFrom-Json\n& $Bridge @a\nexit $LASTEXITCODE\n")
        return subprocess.run([shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(invocation), str(self.package / bridge), str(argument_file)],
                              input=stdin, capture_output=True, env=self.env, timeout=20)

    def native_shells(self):
        shells = list(self.shells)
        wow = Path(os.environ["WINDIR"]) / "SysWOW64/WindowsPowerShell/v1.0/powershell.exe"
        if wow.exists(): shells.append(str(wow))
        else: print("SKIP: 32-bit PowerShell is unavailable")
        return shells

    def run_transport_script(self, shell, source, *args, env=None, timeout=20, input=None):
        script = self.directory / "real-transport.ps1"
        script.write_text(source, encoding="utf-8-sig")
        incoming={"stdin":subprocess.DEVNULL} if input is None else {"input":input}
        return subprocess.run([shell, "-NoProfile", "-File", str(script),
            str(ROOT / "windows/process_transport.ps1"), *map(str,args)],
            capture_output=True, timeout=timeout, env=env, **incoming)

    def test_owned_windows_process_cancellation_after_pipeline_abort_or_sink_failure(self):
        fake=self.directory/"wsl.exe"
        source=r"""
param($Transport,$Executable,$Owner,$Marker,$Mode)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. $Transport
function Emit-Owned {
    $child=[Delamain.ProcessTransport]::Start($Executable,@('--owned-quiet',$Owner,$Marker),$false,$false,$null)
    try {
        while ($null -ne ($line=$child.ReadLine())) { Write-Output $line }
        $global:LASTEXITCODE=$child.Complete()
    } finally { $child.Dispose() }
}
if ($Mode -eq 'select') { Emit-Owned | Select-Object -First 1 }
else {
    try { Emit-Owned | ForEach-Object { throw 'fixture output sink failed' } }
    catch { if (-not $_.Exception.Message.Contains('fixture output sink failed')) { throw } }
}
"""
        for shell in self.native_shells():
            for mode in ("select","throw"):
                with self.subTest(shell=shell,mode=mode), tempfile.TemporaryDirectory(dir=self.directory) as scratch:
                    directory=Path(scratch)
                    positive=subprocess.Popen([str(fake),"--owned-quiet",str(directory/"unrelated-owner"),str(directory/"unrelated-marker")],
                        stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                    try:
                        self.assertEqual(json.loads(positive.stdout.readline()),{"ready":True})
                        result=self.run_transport_script(shell,source,fake,directory/"owner",directory/"marker",mode)
                        self.assertEqual(result.returncode,0,result.stderr.decode(errors="replace"))
                        time.sleep(3.5)
                        self.assertEqual(positive.wait(timeout=5),0)
                        self.assertTrue((directory/"unrelated-marker").exists(),"Cancellation killed an unrelated owned control")
                        self.assertTrue((directory/"owner").exists(),"Aborted child never started")
                        self.assertFalse((directory/"marker").exists(),"Quiet owned Windows process survived abnormal output disposal")
                        print(f"Windows cancellation: {shell} {mode}, owned PID {(directory/'owner').read_text()}, unrelated PID {positive.pid} survived")
                    finally:
                        if positive.poll() is None: positive.kill(); positive.wait(timeout=5)
                        positive.stdout.close(); positive.stderr.close()

    @unittest.skipUnless(shutil.which("wsl.exe"), "Real trusted WSL")
    def test_trusted_wsl_ignores_actual_process_cwd_path_and_system_environment(self):
        # Get-Location and the actual Win32 process cwd intentionally differ.
        # The unsafe control proves this fake is discoverable by Windows itself.
        source = r"""
param($Transport,$Directory,$ProviderDirectory,$Marker)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. $Transport
$trustedPath=[Delamain.ProcessTransport]::WslExecutable()
$linuxDirectory=(& $trustedPath --distribution Ubuntu --exec wslpath -a -u $Directory | Out-String).Trim()
$windowsDirectory=Split-Path -Parent (Split-Path -Parent $trustedPath)
Set-Location -LiteralPath $ProviderDirectory
[Environment]::CurrentDirectory=$Directory
$env:PATH=$Directory+';'+$env:PATH
$priorSystemRoot=$env:SystemRoot; $priorWindir=$env:WINDIR
$env:SystemRoot=$Directory
$env:WINDIR=$Directory
$env:FIXTURE_SEARCH_MARKER=$Marker
# Inspect the actual environment block from the production Info factory. Use
# native cmd.exe as the child so WSL interop cannot rewrite inherited values.
$nativeArguments=[string[]]@('/d','/c','echo %SystemRoot%&&echo %WINDIR%')
$method=[Delamain.ProcessTransport].GetMethod('Info',[Reflection.BindingFlags]'Static,NonPublic')
$invokeArguments=[object[]]@('wsl.exe',$nativeArguments,$false)
$childInfo=$method.Invoke($null,$invokeArguments)
$childInfo.FileName=Join-Path $windowsDirectory 'System32/cmd.exe'
$child=[Diagnostics.Process]::Start($childInfo)
$childOutput=$child.StandardOutput.ReadToEnd()
$childError=$child.StandardError.ReadToEnd()
$child.WaitForExit()
if ($child.ExitCode -ne 0) { throw "Native environment probe failed: $childError" }
$childEnvironment=@($childOutput -split "`r?`n" | Where-Object { $_ -ne '' })
$child.Dispose()
if ($childEnvironment.Count -ne 2 -or $childEnvironment[0] -ine $windowsDirectory -or $childEnvironment[1] -ine $windowsDirectory) {
    throw "Trusted WSL ProcessStartInfo child environment mismatch: expected '$windowsDirectory' twice, received '$($childEnvironment -join ', ')'."
}
$info=[Diagnostics.ProcessStartInfo]::new()
$info.FileName='wsl.exe'; $info.UseShellExecute=$false
$info.RedirectStandardOutput=$true; $info.CreateNoWindow=$true
$control=[Diagnostics.Process]::Start($info)
$null=$control.StandardOutput.ReadToEnd(); $control.WaitForExit()
if (-not [IO.File]::Exists($Marker)) { throw 'Unsafe cwd search did not run the positive fake control' }
[IO.File]::Delete($Marker); $control.Dispose()
$code='import json,sys; print(json.dumps([sys.argv[1:],"trusted Linux"]))'
$arguments=@('--distribution','Ubuntu','--cd',$linuxDirectory,'--exec','python3','-I','-c',$code,'','日本語 😀','quote" and $literal')
$captured=Invoke-DelamainWsl -Arguments $arguments -Capture
if ($captured.ExitCode -ne 0) { throw 'Trusted WSL capture failed' }
$streamed=@(Invoke-DelamainWsl -Arguments $arguments)
if ($LASTEXITCODE -ne 0) { throw 'Trusted WSL streaming failed' }
# Info also resolves the legacy literal rather than accepting the search path.
$direct=[Delamain.ProcessTransport]::Run('wsl.exe',$arguments,$true,$false,$false,$null)
if ($direct.ExitCode -ne 0) { throw 'Trusted Info selection failed' }
if ([IO.File]::Exists($Marker)) { throw 'Production invoked cwd/PATH fake WSL' }
$env:SystemRoot=$priorSystemRoot; $env:WINDIR=$priorWindir
[pscustomobject]@{ path=$trustedPath; bits=[IntPtr]::Size;
 cwd=[Environment]::CurrentDirectory; location=(Get-Location).ProviderPath;
 fake=[IO.File]::Exists($Marker); capture=$captured.Output; stream=$streamed; direct=$direct.Output;
 environment=$childEnvironment; windowsDirectory=$windowsDirectory } | ConvertTo-Json -Compress
"""
        for shell in self.native_shells():
            with self.subTest(shell=shell):
                marker=self.directory/"fake-search-marker"
                result=self.run_transport_script(shell,source,self.directory,self.package,marker,env=self.env)
                self.assertEqual(result.returncode,0,result.stderr.decode(errors="replace"))
                data=json.loads(result.stdout)
                self.assertFalse(data["fake"],"Production invoked the cwd/PATH fake")
                self.assertNotEqual(data["cwd"],data["location"])
                expected=Path(os.environ["WINDIR"])/("Sysnative" if data["bits"]==4 else "System32")/"wsl.exe"
                self.assertEqual(Path(data["path"]),expected)
                for value in (data["capture"],data["stream"][0],data["direct"]):
                    self.assertEqual(json.loads(value),[["","日本語 😀",'quote" and $literal'],"trusted Linux"])
                self.assertEqual(data["environment"],[data["windowsDirectory"],data["windowsDirectory"]],
                    f"Trusted WSL child inherited poisoned Windows variables: {data['environment']}")
                print(f"trusted WSL: {shell}, {data['path']}; child environment {data['environment']}; unsafe cwd fake positive, production fake negative")

    @unittest.skipUnless(shutil.which("wsl.exe"), "Real trusted WSL")
    def test_guardian_ignores_malicious_python_module_in_selected_linux_cwd(self):
        source=r"""
param($Transport,$Directory)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. $Transport
$linuxDirectory=(& ([Delamain.ProcessTransport]::WslExecutable()) --distribution Ubuntu --exec wslpath -a -u $Directory | Out-String).Trim()
# Positive control: ordinary Python really imports the hostile cwd module.
$info=[Diagnostics.ProcessStartInfo]::new()
$info.FileName=[Delamain.ProcessTransport]::WslExecutable()
$info.Arguments='--distribution Ubuntu --cd "'+$linuxDirectory+'" --exec python3 -c "import subprocess"'
$info.UseShellExecute=$false; $info.CreateNoWindow=$true
$info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
$unsafe=[Diagnostics.Process]::Start($info)
$null=$unsafe.StandardOutput.ReadToEnd(); $errorText=$unsafe.StandardError.ReadToEnd(); $unsafe.WaitForExit()
if ($unsafe.ExitCode -eq 0 -or -not $errorText.Contains('Untrusted cwd module imported by guardian')) { throw 'Malicious cwd positive control did not run' }
$unsafe.Dispose()
$arguments=@('--distribution','Ubuntu','--cd',$linuxDirectory,'--exec','/bin/true')
$captured=Invoke-DelamainWsl -Arguments $arguments -Capture
$streamed=@(Invoke-DelamainWsl -Arguments $arguments)
if ($captured.ExitCode -ne 0 -or $LASTEXITCODE -ne 0) { throw 'Guardian imported a caller cwd Python module' }
[Console]::Write('isolated guardian passed capture and stream; malicious cwd positive control passed')
"""
        for shell in self.native_shells():
            with self.subTest(shell=shell), tempfile.TemporaryDirectory(dir=self.directory) as scratch:
                directory=Path(scratch)
                (directory/'subprocess.py').write_text("raise RuntimeError('Untrusted cwd module imported by guardian')\n")
                result=self.run_transport_script(shell,source,directory)
                self.assertEqual(result.returncode,0,result.stderr.decode(errors="replace"))
                self.assertIn(b'isolated guardian passed',result.stdout)

    @unittest.skipUnless(shutil.which("wsl.exe"), "Real trusted WSL")
    def test_failed_foreground_launch_keeps_terminal_ack_for_capture_and_stream(self):
        source=r"""
param($Transport)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. $Transport
$arguments=@('--distribution','Ubuntu','--exec','/nonexistent-delamain-foreground-fixture')
$captured=Invoke-DelamainWsl -Arguments $arguments -Capture
$streamed=@(Invoke-DelamainWsl -Arguments $arguments)
[pscustomobject]@{capture=$captured.ExitCode;stream=$LASTEXITCODE;output=$captured.Output;lines=$streamed.Count} | ConvertTo-Json -Compress
"""
        for shell in self.native_shells():
            with self.subTest(shell=shell), tempfile.TemporaryDirectory(dir=self.directory) as scratch:
                result=self.run_transport_script(shell,source,env={**self.env,"TEMP":scratch,"TMP":scratch})
                self.assertEqual(result.returncode,0,result.stderr.decode(errors="replace"))
                data=json.loads(result.stdout)
                self.assertNotEqual(data['capture'],0)
                self.assertNotEqual(data['stream'],0)
                self.assertEqual(data['output'],"")
                self.assertEqual(data['lines'],0)
                self.assertIn(b'FileNotFoundError',result.stderr)
                self.assertNotIn(b'cleanup deadline',result.stderr)
                self.assertEqual(list(Path(scratch).iterdir()),[],"Failed Popen left private request/ack files")

    @unittest.skipUnless(shutil.which("wsl.exe"), "Real trusted WSL")
    def test_completion_ack_can_remain_open_while_windows_owner_releases_lease(self):
        # Force the real cross-filesystem interleaving: Windows observes done
        # while Linux still holds the acknowledgement's descriptor open.
        transport=(ROOT/'windows/process_transport.ps1').read_text()
        publish="try: os.write(fd,b'done')"
        self.assertEqual(transport.count(publish),1)
        transport=transport.replace(publish,"try:\n            os.write(fd,b'done')\n            time.sleep(.6)")
        source=r"""
param($Transport,$Fixture)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. $Fixture
$arguments=@('--distribution','Ubuntu','--exec','/bin/true')
$captured=Invoke-DelamainWsl -Arguments $arguments -Capture
$streamed=@(Invoke-DelamainWsl -Arguments $arguments)
if ($captured.ExitCode -ne 0 -or $LASTEXITCODE -ne 0) { throw 'Delayed acknowledgement close changed command status' }
"""
        for shell in self.native_shells():
            with self.subTest(shell=shell), tempfile.TemporaryDirectory(dir=self.directory) as scratch:
                directory=Path(scratch)
                fixture=directory/'delayed-ack.ps1'
                fixture.write_text(transport,encoding='utf-8-sig')
                controls=directory/'controls'; controls.mkdir()
                result=self.run_transport_script(shell,source,fixture,env={**self.env,'TEMP':str(controls),'TMP':str(controls)})
                self.assertEqual(result.returncode,0,result.stderr.decode(errors='replace'))
                deadline=time.monotonic()+2
                while list(controls.iterdir()) and time.monotonic()<deadline: time.sleep(.02)
                self.assertEqual(list(controls.iterdir()),[],"Delayed acknowledgement close retained a leased path")

    @unittest.skipUnless(shutil.which("wsl.exe"), "Real trusted WSL")
    def test_owned_wsl_normal_unicode_input_exit_codes_and_control_file_cleanup(self):
        source=r"""
param($Transport)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. $Transport
$text='Русский 日本語 😀'+[char]0+"`nsecond line`n"
$code='import base64,json,sys; print("stderr 日本語",file=sys.stderr); print(json.dumps({"argv":sys.argv[2:],"stdin":base64.b64encode(sys.stdin.buffer.read()).decode()})); sys.exit(int(sys.argv[1]))'
$results=@()
foreach ($status in @(0,3,4)) {
    $arguments=@('--distribution','Ubuntu','--exec','python3','-c',$code,[string]$status,'','日本語 😀','quote" $literal')
    $captured=Invoke-DelamainWsl -Arguments $arguments -Capture -RedirectInput -InputText $text
    $streamed=@(Invoke-DelamainWsl -Arguments $arguments -RedirectInput -InputText $text)
    $results+=@{ expected=$status; captureExit=$captured.ExitCode; streamExit=$LASTEXITCODE;
        capture=$captured.Output; stream=$streamed }
}
ConvertTo-Json -InputObject $results -Depth 10 -Compress
"""
        import base64
        for shell in self.native_shells():
            with self.subTest(shell=shell), tempfile.TemporaryDirectory(dir=self.directory) as scratch:
                result=self.run_transport_script(shell,source,env={**self.env,"TEMP":scratch,"TMP":scratch},timeout=45)
                self.assertEqual(result.returncode,0,result.stderr.decode(errors="replace"))
                self.assertEqual(result.stderr.decode("utf-8").count("stderr 日本語"), 6)
                for value in json.loads(result.stdout):
                    self.assertEqual(value['captureExit'],value['expected'])
                    self.assertEqual(value['streamExit'],value['expected'])
                    for output in (value['capture'],value['stream'][0]):
                        data=json.loads(output)
                        self.assertEqual(data['argv'],["","日本語 😀",'quote" $literal'])
                        self.assertEqual(base64.b64decode(data['stdin']),"Русский 日本語 😀\x00\nsecond line\n".encode())
                self.assertEqual(list(Path(scratch).iterdir()),[],"Private cancellation file survived normal completion")
                raw_source=r"""
param($Transport)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. $Transport
$code='import base64,sys; print(base64.b64encode(sys.stdin.buffer.read()).decode())'
$value=Invoke-DelamainWsl -Arguments @('--distribution','Ubuntu','--exec','python3','-c',$code) -Capture -RedirectInput -InputText $null
[Console]::Write($value.Output)
exit $value.ExitCode
"""
                incoming=bytes(range(256))*256+"raw pipe 日本語 😀".encode()
                raw=self.run_transport_script(shell,raw_source,input=incoming,env={**self.env,"TEMP":scratch,"TMP":scratch})
                self.assertEqual(raw.returncode,0,raw.stderr.decode(errors="replace"))
                self.assertEqual(base64.b64decode(raw.stdout),incoming,"Private path mapping consumed caller stdin")
                self.assertEqual(list(Path(scratch).iterdir()),[])
                print(f"real foreground completion: {shell}, capture/stream status 0/3/4, UTF-8 stdin with NUL, private files removed")

    @unittest.skipUnless(shutil.which("wsl.exe"), "Real trusted WSL")
    def test_aborted_pipeline_stops_quiet_linux_foreground_and_preserves_detached(self):
        self.check_aborted_linux_pipeline(("normal", "ignore"))

    @unittest.skipUnless(shutil.which("wsl.exe"), "Real trusted WSL")
    def test_early_leader_exit_retains_foreground_until_delayed_pipeline_abort(self):
        self.check_aborted_linux_pipeline(("early",))

    @unittest.skipUnless(shutil.which("wsl.exe"), "Real trusted WSL")
    def test_hard_killed_native_owner_cancels_quiet_and_early_foreground(self):
        self.check_aborted_linux_pipeline(("ignore", "early"), hard_kill=True)

    def check_aborted_linux_pipeline(self, modes, hard_kill=False):
        # Test the Linux side effect after the caller has returned, not merely
        # disappearance of the Windows client. Exact start tokens pin teardown.
        helper=self.directory/"foreground.py"
        helper.write_text(r"""import json,os,signal,subprocess,sys,time
from pathlib import Path
base=Path(sys.argv[1]); mode=sys.argv[2]
def token(pid): return Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()[19]
if mode=='inspect':
 pid=int((base/'foreground-owner').read_text().split(',')[0].lstrip('['))
 try: state=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()[0]
 except FileNotFoundError: state='gone'
 (base/'leader-state').write_text(state)
 sys.exit(0)
elif mode=='quiet-child':
 os.close(1); os.close(2)
 signal.signal(signal.SIGTERM,signal.SIG_IGN)
 (base/'descendant-owner').write_text(json.dumps([os.getpid(),token(os.getpid())]))
 time.sleep(3); (base/'foreground-marker').write_text('survived'); time.sleep(30)
elif mode=='detached':
 (base/'detached-owner').write_text(json.dumps([os.getpid(),token(os.getpid())]))
 time.sleep(3); (base/'detached-marker').write_text('survived'); time.sleep(30)
else:
 if mode=='ignore':
  signal.signal(signal.SIGHUP,signal.SIG_IGN); signal.signal(signal.SIGTERM,signal.SIG_IGN)
 child=subprocess.Popen([sys.executable,__file__,str(base),'detached'],start_new_session=True,
  stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 (base/'foreground-owner').write_text(json.dumps([os.getpid(),token(os.getpid())]))
 (base/'guardian-owner').write_text(json.dumps([os.getppid(),token(os.getppid())]))
 while not (base/'detached-owner').exists(): time.sleep(.01)
 if mode=='early':
  subprocess.Popen([sys.executable,__file__,str(base),'quiet-child'])
  while not (base/'descendant-owner').exists(): time.sleep(.01)
 print(json.dumps({'pid':os.getpid(),'token':token(os.getpid())}),flush=True)
 if mode=='early': sys.exit(3)
 time.sleep(3); (base/'foreground-marker').write_text('survived'); time.sleep(30)
""",encoding="utf-8")
        trusted=str(Path(os.environ["WINDIR"])/"System32/wsl.exe")
        def wsl(*args):
            result = subprocess.run([trusted,"--distribution","Ubuntu","--exec",*args],
                stdin=subprocess.DEVNULL,capture_output=True,timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            return result
        linux_helper=wsl("wslpath","-a","-u",str(helper)).stdout.decode().strip()
        source=r"""
param($Transport,$Helper,$Directory,$Mode,$NativeDirectory,$HardKill)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. $Transport
Invoke-DelamainWsl -Arguments @('--distribution','Ubuntu','--exec','python3',$Helper,$Directory,$Mode) | ForEach-Object {
    [IO.File]::WriteAllText((Join-Path $NativeDirectory 'first-ticks'),[DateTime]::UtcNow.Ticks.ToString())
    if ($Mode -eq 'early') {
        Start-Sleep -Milliseconds 800
        & ([Delamain.ProcessTransport]::WslExecutable()) --distribution Ubuntu --exec python3 $Helper $Directory inspect
        if ($LASTEXITCODE -ne 0) { throw 'Leader inspection failed' }
    }
    if ($HardKill -eq 'yes') {
        [IO.File]::WriteAllText((Join-Path $NativeDirectory 'kill-ready'),'ready')
        Start-Sleep -Seconds 30
    }
    $_
} | Select-Object -First 1
[IO.File]::WriteAllText((Join-Path $NativeDirectory 'return-ticks'),[DateTime]::UtcNow.Ticks.ToString())
"""
        cleanup=r"""import json,os,signal,sys,time
from pathlib import Path
base=Path(sys.argv[1])
for name in ('foreground-owner','descendant-owner','detached-owner','guardian-owner'):
 p=base/name
 if not p.exists(): continue
 pid,expected=json.loads(p.read_text())
 try:
  fields=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
  if fields[19]!=expected or fields[0]=='Z': continue
  fd=os.pidfd_open(pid)
 except (FileNotFoundError,ProcessLookupError): continue
 try:
  fields=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
  if fields[19]==expected: signal.pidfd_send_signal(fd,signal.SIGKILL)
 except (FileNotFoundError,ProcessLookupError): pass
 finally: os.close(fd)
for name in ('foreground-owner','descendant-owner','detached-owner','guardian-owner'):
 p=base/name
 if not p.exists(): continue
 pid,expected=json.loads(p.read_text()); deadline=time.monotonic()+3
 while time.monotonic()<deadline:
  try: fields=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
  except FileNotFoundError: break
  if fields[19]!=expected or fields[0]=='Z': break
  time.sleep(.02)
 else: raise RuntimeError('Owned fixture remained alive')
 print(f'cleanup verified {name}: PID {pid}, start {expected}, gone or zombie')
"""
        for shell in self.native_shells():
            for mode in modes:
                with self.subTest(shell=shell,mode=mode), tempfile.TemporaryDirectory(dir=self.directory) as scratch:
                    directory=Path(scratch)
                    linux_directory=wsl("wslpath","-a","-u",scratch).stdout.decode().strip()
                    controls=directory/'transport-controls'
                    controls.mkdir()
                    try:
                        began=time.monotonic()
                        environment={**self.env,"TEMP":str(controls),"TMP":str(controls)}
                        if hard_kill:
                            script=directory/'hard-kill.ps1'
                            script.write_text(source,encoding="utf-8-sig")
                            run=subprocess.Popen([shell,"-NoProfile","-File",str(script),
                                str(ROOT/'windows/process_transport.ps1'),linux_helper,linux_directory,mode,scratch,'yes'],
                                stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=environment)
                            try:
                                deadline=time.monotonic()+20
                                while not (directory/'kill-ready').exists() and run.poll() is None and time.monotonic()<deadline:
                                    time.sleep(.02)
                                if not (directory/'kill-ready').exists():
                                    if run.poll() is None: run.kill()
                                    output,error=run.communicate(timeout=8)
                                    self.fail("Native owner never reached kill point: "+error.decode(errors="replace"))
                                self.assertTrue(list(controls.iterdir()),"Owner did not retain its cancellation lease")
                                # TerminateProcess bypasses PowerShell finally and C# Dispose.
                                killed=time.monotonic(); run.kill()
                                output,error=run.communicate(timeout=8)
                                deadline=time.monotonic()+2
                                while list(controls.iterdir()) and time.monotonic()<deadline: time.sleep(.02)
                                abort_seconds=time.monotonic()-killed
                            finally:
                                if run.poll() is None: run.kill(); run.communicate(timeout=8)
                            owner={'pid':json.loads((directory/'foreground-owner').read_text())[0]}
                        else:
                            result=self.run_transport_script(shell,source,linux_helper,linux_directory,mode,scratch,'no',
                                env=environment)
                            self.assertEqual(result.returncode,0,result.stderr.decode(errors="replace"))
                            owner=json.loads(result.stdout)
                            abort_seconds=(int((directory/'return-ticks').read_text())-int((directory/'first-ticks').read_text()))/10_000_000
                        elapsed=time.monotonic()-began
                        self.assertEqual(owner['pid'],json.loads((directory/'foreground-owner').read_text())[0])
                        time.sleep(4)
                        if mode=='early':
                            self.assertIn((directory/'leader-state').read_text(),('gone','Z'), 'Abort did not follow leader exit')
                            self.assertTrue((directory/'descendant-owner').exists())
                        foreground=(directory/'foreground-marker').exists()
                        detached=(directory/'detached-marker').exists()
                        print(f"abort {shell} {mode}: exact Linux owner {owner}, startup+return {elapsed:.2f}s, abort {abort_seconds:.2f}s, foreground marker={foreground}, detached marker={detached}")
                        self.assertLess(abort_seconds,3,"Pipeline abort waited for delayed foreground output")
                        self.assertTrue(detached,"Abort killed a detached worker")
                        self.assertFalse(foreground,"Quiet Linux foreground survived the Windows client cancellation")
                        self.assertEqual(list(controls.iterdir()),[],"Aborted caller left a private cancellation file")
                        verify="import sys; from pathlib import Path; p=Path('/proc/'+sys.argv[1]+'/stat'); f=p.read_text().rsplit(')',1)[1].split() if p.exists() else None; assert f is None or f[19]!=sys.argv[2] or f[0]=='Z', 'guardian survived owner cleanup'"
                        guardian_pid,guardian_token=json.loads((directory/'guardian-owner').read_text())
                        wsl('python3','-I','-c',verify,str(guardian_pid),guardian_token)
                    finally:
                        print(wsl("python3","-c",cleanup,linux_directory).stdout.decode(),end="")

    def test_warning_stays_stderr_real_error_unicode_stdin_and_exit_codes(self):
        import base64
        stdin = "Строка 日本語 😀\nsecond\x00binary preserved\n".encode()
        for shell in self.shells:
            for status in (0, 3, 4):
                with self.subTest(shell=shell, status=status):
                    args = [f"exit{status}", "quote\" and $literal", "日本語 😀", "line1\nline2", "x" * 40000]
                    result = self.invoke(shell, args, stdin)
                    self.assertEqual(result.returncode, status, result.stderr.decode(errors="replace"))
                    output = json.loads(result.stdout)
                    self.assertEqual(output["payload"]["argv"], args)
                    self.assertEqual(base64.b64decode(output["stdinBase64"]), stdin)
                    error = result.stderr.decode("utf-8")
                    self.assertNotIn("\x00", error)
                    self.assertNotIn("wsl: A localhost proxy", error)
                    self.assertIn("real child error: Русский 日本語 😀", error)
                    self.assertIn("wsl: unexpected startup error: Русский 日本語 😀", error)
                    self.assertIn("x" * 65534 + "😀日本語", error)

    def test_stdout_streams_before_child_exit(self):
        for shell in self.shells:
            for bridge in ("desktop.ps1", "delamain.ps1"):
                self.check_streaming(shell,bridge)

    def check_streaming(self,shell,bridge):
        with self.subTest(shell=shell,bridge=bridge):
            process = subprocess.Popen([shell, "-NoProfile", "-File", str(self.package / bridge), "stream"],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
            try:
                self.assertEqual(process.stdout.readline().rstrip(b'\r\n'), b'{"first":true}')
                self.assertIsNone(process.poll())
                output, error = process.communicate(timeout=10)
                self.assertEqual(output.rstrip(b'\r\n'), b'{"last":true}')
                self.assertEqual(process.returncode, 0, error)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

    def test_powershell_pipeline_input_and_empty_argument(self):
        for shell in self.shells:
            for bridge in ("desktop.ps1", "delamain.ps1"):
                self.check_pipeline_input(shell,bridge)

    def check_pipeline_input(self,shell,bridge):
        import base64
        with self.subTest(shell=shell,bridge=bridge):
            script = self.directory / "pipeline.ps1"
            path = str(self.package / bridge).replace("'", "''")
            script.write_text("'Русский 日本語 😀' | & '" + path + "' exit0 '' 'end'\nexit $LASTEXITCODE\n", encoding="utf-8-sig")
            result = subprocess.run([shell, "-NoProfile", "-File", str(script)], capture_output=True, env=self.env, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = json.loads(result.stdout)
            self.assertEqual(output["payload"]["argv"], ["exit0", "", "end"])
            self.assertEqual(base64.b64decode(output["stdinBase64"]).decode(), "Русский 日本語 😀\r\n")

    def test_powershell_structured_capture_pipeline_and_assignment(self):
        for shell in self.shells:
            for capture in ("$value = & $Bridge exit0 '' '日本語 😀' | ConvertFrom-Json",
                            "$raw = & $Bridge exit0 '' '日本語 😀'; $value = $raw | ConvertFrom-Json"):
                with self.subTest(shell=shell, capture=capture):
                    script = self.directory / "capture.ps1"
                    script.write_text("param($Bridge)\n$ErrorActionPreference='Stop'\n[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)\n" + capture + "\n$value | ConvertTo-Json -Compress -Depth 100\nexit $LASTEXITCODE\n", encoding="utf-8-sig")
                    result = subprocess.run([shell, "-NoProfile", "-File", str(script), str(self.package / "desktop.ps1")],
                                            input=b"", capture_output=True, env=self.env, timeout=20)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout)["payload"]["argv"], ["exit0", "", "日本語 😀"])
                    self.assertNotIn(b"wsl: A localhost proxy", result.stderr)
                    self.assertIn(b"wsl: unexpected startup error:", result.stderr)

    def test_terminal_launcher_long_payload_stdin_empty_unicode_exit_and_cleanup(self):
        import base64
        temp = self.directory / "payload-temp"
        temp.mkdir(exist_ok=True)
        previous_env = self.env
        self.env = {**self.env, "TEMP": str(temp), "TMP": str(temp), "HUB_OPAQUE_FIXTURE": "ё日本語" * 3000}
        try:
            for shell in self.shells:
                for status in (0, 3, 4):
                    args = [f"exit{status}", "", "x" * 50000 + "😀日本語", "quote\" $literal", "line1\nline2"]
                    stdin = "Русский 日本語 😀\n\x00bytes\n".encode()
                    result = self.invoke(shell, args, stdin, bridge="delamain.ps1")
                    self.assertEqual(result.returncode, status, result.stderr.decode(errors="replace"))
                    output = json.loads(result.stdout)
                    self.assertEqual(output["payload"]["argv"], args)
                    self.assertEqual(output["payload"]["env"]["HUB_OPAQUE_FIXTURE"], self.env["HUB_OPAQUE_FIXTURE"])
                    self.assertEqual(base64.b64decode(output["stdinBase64"]), stdin)
                    self.assertEqual(list(temp.iterdir()), [], "payload file survived launcher finally")
        finally:
            self.env = previous_env

    def test_terminal_payload_is_deleted_after_mapping_failure(self):
        temp = self.directory / "failed-payload-temp"
        temp.mkdir(exist_ok=True)
        old = self.env
        self.env = {**self.env,"TEMP":str(temp),"TMP":str(temp),"FIXTURE_MAP_FAIL":"1"}
        try:
            for shell in self.shells:
                result = self.invoke(shell,["exit0","x"*50000],bridge="delamain.ps1")
                self.assertEqual(result.returncode,1)
                self.assertIn(b"payload path",result.stderr)
                self.assertEqual(list(temp.iterdir()),[],"mapping failure left a sensitive payload file")
        finally: self.env = old

    def test_native_tcp_single_helper_concurrent_opaque_bytes_and_pipe_eof(self):
        # Run both native versions against four concurrent upstream connections,
        # including peers that hold CONNECT open after the client half-closes.
        import struct
        header = struct.Struct("<BII")
        payload = bytes(range(256)) * 256
        for shell in self.shells:
            for hold_open in (False, True):
                with self.subTest(shell=shell, hold_open=hold_open), socket.socket() as server:
                    server.bind(("127.0.0.1", 0))
                    server.listen(4)
                    release = threading.Event()
                    received = {}
                    errors = []
                    peers = []
                    def echo(number, client):
                        try:
                            with client:
                                client.settimeout(15)
                                data = bytearray()
                                while True:
                                    chunk = client.recv(32768)
                                    if not chunk: break
                                    data.extend(chunk); client.sendall(chunk)
                                received[number] = bytes(data)
                                if hold_open: release.wait(15)
                        except BaseException as error: errors.append(error)
                    def accept():
                        try:
                            server.settimeout(15)
                            for number in range(4):
                                thread = threading.Thread(target=echo, args=(number, server.accept()[0]))
                                peers.append(thread); thread.start()
                        except BaseException as error: errors.append(error)
                    acceptor = threading.Thread(target=accept); acceptor.start()
                    helper = subprocess.Popen([shell, "-NoProfile", "-File", str(ROOT / "windows/proxy_tcp.ps1"),
                        "-Multiplex", "-ProxyHost", "127.0.0.1", "-ProxyPort", str(server.getsockname()[1])],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
                    output = {number:bytearray() for number in range(1,5)}
                    complete = threading.Event()
                    write_lock = threading.Lock()
                    def send(kind, number, data=b""):
                        with write_lock:
                            wire = header.pack(kind, number, len(data)) + data
                            at = 0
                            while at < len(wire): at += helper.stdin.write(wire[at:])
                    def exact(size):
                        data = bytearray()
                        while len(data) < size:
                            part = helper.stdout.read(size-len(data))
                            if not part: raise EOFError
                            data.extend(part)
                        return bytes(data)
                    ready = threading.Event()
                    def read():
                        try:
                            self.assertEqual(header.unpack(exact(9)), (1,0,0)); ready.set()
                            while True:
                                kind, number, size = header.unpack(exact(9))
                                self.assertLessEqual(size,32768)
                                data = exact(size)
                                if kind == 3:
                                    output[number].extend(data)
                                    send(6,number,struct.pack("<I",size))
                                    if all(len(value)==len(payload) for value in output.values()): complete.set()
                                elif kind == 5: raise AssertionError("native connection failed")
                        except EOFError: pass
                        except BaseException as error: errors.append(error)
                    reader = threading.Thread(target=read); reader.start()
                    try:
                        self.assertTrue(ready.wait(15), "helper handshake failed")
                        for number in range(1,5): send(2,number)
                        for number in range(1,5):
                            send(3,number,payload[:32768]); send(3,number,payload[32768:]); send(4,number)
                        self.assertTrue(complete.wait(15), "multiplexed helper stalled")
                        with write_lock: helper.stdin.close()
                        self.assertEqual(helper.wait(timeout=8),0,helper.stderr.read())
                        self.assertEqual(output,{number:payload for number in range(1,5)})
                    finally:
                        release.set()
                        if helper.poll() is None: helper.kill(); helper.wait()
                        reader.join(timeout=3); acceptor.join(timeout=3)
                        for peer in peers: peer.join(timeout=3)
                        for pipe in (helper.stdin,helper.stdout,helper.stderr):
                            if not pipe.closed: pipe.close()
                    self.assertFalse(reader.is_alive())
                    self.assertTrue(all(not peer.is_alive() for peer in peers))
                    self.assertEqual(received,{number:payload for number in range(4)})
                    self.assertEqual(errors,[])

    def test_native_legacy_raw_helper_interface_survives_package_update(self):
        payload = bytes(range(256)) * 256 + "legacy Русский 日本語 😀".encode()
        for shell in self.shells:
            with self.subTest(shell=shell), socket.socket() as server:
                server.bind(("127.0.0.1",0)); server.listen(1)
                received = bytearray()
                errors = []
                def echo():
                    try:
                        server.settimeout(15)
                        with server.accept()[0] as client:
                            client.settimeout(15)
                            while True:
                                chunk = client.recv(32768)
                                if not chunk: break
                                received.extend(chunk); client.sendall(chunk)
                    except BaseException as error: errors.append(error)
                peer = threading.Thread(target=echo); peer.start()
                result = subprocess.run([shell,"-NoProfile","-File",str(ROOT/"windows/proxy_tcp.ps1"),
                    "-ProxyHost","127.0.0.1","-ProxyPort",str(server.getsockname()[1])],
                    input=payload,capture_output=True,timeout=20)
                peer.join(timeout=3)
                self.assertFalse(peer.is_alive())
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(result.stdout,payload,"legacy raw mode emitted protocol frames")
                self.assertEqual(received,payload)
                self.assertEqual(errors,[])

    @unittest.skipUnless(shutil.which("wsl.exe"), "WSL interoperability")
    def test_wsl_real_proxy_discovery_preserves_file_and_pipe_stdin(self):
        # Read only discovery exercises real Windows PowerShell startup. Input
        # is created inside WSL so the desktop bridge cannot mask its loss.
        package = self.directory / "discovery package Русский"
        package.mkdir()
        for name in ("worker_proxy.py", "proxy_tcp.ps1"):
            shutil.copy2(ROOT / "windows" / name, package / name)
        entry = package / "fixture.py"
        entry.write_text('''import json,subprocess,sys,tempfile
import worker_proxy as p
if sys.argv[1:] == ["worker"]:
    endpoint = p.discover_proxy(p.powershell_command())
    print(json.dumps({"prompt":sys.stdin.buffer.read().decode(),"enabled":endpoint is not None}))
else:
    prompt = "Сохрани prompt 日本語 😀\\nsecond line\\n".encode()
    for mode in ("file","pipe"):
        with tempfile.TemporaryFile() as incoming:
            incoming.write(prompt)
            incoming.seek(0)
            result = subprocess.run([sys.executable,__file__,"worker"],stdin=incoming,
                                    capture_output=True,timeout=20) if mode == "file" else subprocess.run(
                                    [sys.executable,__file__,"worker"],input=prompt,capture_output=True,timeout=20)
        assert result.returncode == 0,result.stderr.decode(errors="replace")
        assert json.loads(result.stdout)["prompt"].encode() == prompt,mode+" lost worker prompt"
    print("file and pipe prompts preserved through real Windows discovery")
''', encoding="utf-8")
        linux = subprocess.run(["wsl.exe", "--distribution", "Ubuntu", "--exec", "wslpath", "-a", "-u", str(entry)],
                               stdin=subprocess.DEVNULL, capture_output=True, timeout=15, check=True).stdout.decode().strip()
        run = subprocess.run(["wsl.exe", "--distribution", "Ubuntu", "--exec", "python3", linux],
                             stdin=subprocess.DEVNULL, capture_output=True, timeout=50)
        self.assertEqual(run.returncode, 0, run.stderr.decode(errors="replace"))
        self.assertIn(b"file and pipe prompts preserved", run.stdout)

    @unittest.skipUnless(shutil.which("wsl.exe"), "WSL interoperability")
    def test_wsl_native_stdio_relay_and_real_windows_helper_cleanup(self):
        # A throwaway Windows echo proxy stands in for the system proxy. This
        # exercises actual interop without credentials, external HTTP or models.
        package = self.directory / "interop package Русский"
        package.mkdir(exist_ok=True)
        for name in ("worker_proxy.py", "proxy_tcp.ps1"):
            shutil.copy2(ROOT / "windows" / name, package / name)
        entry = package / "fixture.py"
        entry.write_text('''import json,os,select,signal,socket,sys,threading,time
from pathlib import Path
import worker_proxy as p
if sys.argv[1] == "worker":
    assert os.getpid() == int(sys.argv[2]), "exec changed worker PID"
    port=int(os.environ["HTTP_PROXY"].rsplit(":",1)[1])
    clients=[]
    errors=[]
    def transfer():
        try:
            client=socket.create_connection(("127.0.0.1",port),timeout=15)
            clients.append(client)
            data=bytes(range(256))*512 + "Русский 日本語 😀".encode()
            client.sendall(data)
            received=bytearray()
            while len(received)<len(data):
                part=client.recv(32768)
                assert part,"helper EOF during native transfer"
                received.extend(part)
            assert received==data
        except BaseException as error: errors.append(error)
    threads=[threading.Thread(target=transfer) for _ in range(3)]
    for thread in threads: thread.start()
    for thread in threads:
        thread.join(20)
        assert not thread.is_alive(),"native connection stalled"
    assert not errors,errors
    print(json.dumps({"pid":os.getpid(),"port":port,"connections":len(clients)}),flush=True)
    # Keep all connections and the helper alive for the Windows PID control.
    assert select.select([sys.stdin],[],[],20)[0],"native owner release timed out"
    sys.stdin.readline()
    if sys.argv[3]=="kill": os.kill(os.getpid(),signal.SIGKILL)
    for client in clients: client.close()
    sys.exit(0)
p.discover_proxy=lambda c:("127.0.0.1",int(sys.argv[1]))
env={k:v for k,v in os.environ.items() if k not in p.PROXY_KEYS and k != p.OWNER_KEY}
p.exec_worker(sys.executable,[__file__,"worker",str(os.getpid()),sys.argv[2]],env)
''', encoding="utf-8")
        native_helpers = self.directory / "owned-helpers.ps1"
        native_helpers.write_text("param($Helper)\n@(Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains($Helper) } | ForEach-Object { $_.ProcessId }) | ConvertTo-Json -Compress\n")
        linux = subprocess.run(["wsl.exe", "--distribution", "Ubuntu", "--exec", "wslpath", "-a", "-u", str(entry)], capture_output=True, timeout=15, check=True).stdout.decode().strip()
        for mode in ("normal", "kill"):
            with self.subTest(mode=mode), socket.socket() as server:
                server.bind(("127.0.0.1", 0))
                server.listen(3)
                accepted = []
                closed = []
                errors = []
                peers = []
                def echo(client):
                    try:
                        with client:
                            accepted.append(True)
                            client.settimeout(25)
                            while True:
                                chunk = client.recv(32768)
                                if not chunk: break
                                client.sendall(chunk)
                        closed.append(True)
                    except BaseException as error: errors.append(error)
                def accept():
                    try:
                        server.settimeout(25)
                        for _ in range(3):
                            peer = threading.Thread(target=echo,args=(server.accept()[0],))
                            peers.append(peer); peer.start()
                    except BaseException as error: errors.append(error)
                thread = threading.Thread(target=accept); thread.start()
                run = subprocess.Popen(["wsl.exe", "--distribution", "Ubuntu", "--exec", "python3", linux,
                    str(server.getsockname()[1]), mode], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                first = []
                ready = threading.Event()
                def first_line():
                    first.append(run.stdout.readline()); ready.set()
                reader = threading.Thread(target=first_line); reader.start()
                try:
                    self.assertTrue(ready.wait(25), "native worker did not become ready")
                    data = json.loads(first[0])
                    self.assertEqual(data["connections"],3)
                    owned = subprocess.run([self.shells[0], "-NoProfile", "-File", str(native_helpers),
                        str(package / "proxy_tcp.ps1")], capture_output=True, timeout=10, check=True)
                    ids = json.loads(owned.stdout)
                    ids = ids if isinstance(ids,list) else [ids]
                    self.assertEqual(len(ids),1,"concurrent native connections spawned additional PowerShell helpers")
                    self.assertGreater(ids[0],0)
                    print(f"native {mode}: Linux worker PID {data['pid']}, three connections, one Windows helper PID {ids[0]}")
                    output,error = run.communicate(b"release\n",timeout=25)
                    self.assertEqual(run.returncode,0 if mode=="normal" else 9,error.decode(errors="replace"))
                    self.assertEqual(output,b"")
                finally:
                    if run.poll() is None: run.kill(); run.communicate(timeout=10)
                    reader.join(timeout=3)
                    thread.join(timeout=3)
                    for peer in peers: peer.join(timeout=8)
                self.assertEqual(len(accepted),3)
                self.assertEqual(len(closed),3,"Windows helper left upstream TCP sockets alive")
                self.assertTrue(all(not peer.is_alive() for peer in peers))
                self.assertFalse(reader.is_alive())
                self.assertEqual(errors,[])
                deadline = time.monotonic() + 8
                while True:
                    owned = subprocess.run([self.shells[0], "-NoProfile", "-File", str(native_helpers), str(package / "proxy_tcp.ps1")], capture_output=True, timeout=5, check=True)
                    if not owned.stdout.strip():
                        break
                    if time.monotonic() >= deadline:
                        self.fail("worker exit left an owned native Windows helper alive: " + owned.stdout.decode())
                    time.sleep(0.2)


if __name__ == "__main__":
    unittest.main()

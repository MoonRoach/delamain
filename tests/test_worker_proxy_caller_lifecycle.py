"""Offline caller-return regression; run natively on Windows with Ubuntu WSL.

Only the private fixture overrides discovery. Production prepare_proxy, real WSL
interop, and the real Windows byte relay are exercised without external traffic.
The native Python observer remains running after its desktop.ps1 child returns;
outer tool-job disposal needs a separate launch/observe integration probe.
"""
from __future__ import annotations

import json
import hashlib
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent

# This script runs in WSL. All paths and identities belong to this test's temp
# directory; cleanup never enumerates or signals unrelated workers.
FIXTURE = r'''
import json, os, signal, socket, subprocess, sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent / "windows"))
import worker_proxy as p
root = Path(sys.argv[2])
def put(name, value):
    path=root/name
    temporary=path.with_suffix('.new')
    temporary.write_text(json.dumps(value))
    temporary.replace(path)
def wait(name, seconds=120):
    end=time.monotonic()+seconds
    while not (root/name).exists():
        if time.monotonic()>end: raise TimeoutError(name)
        time.sleep(.05)
def descendants(pid):
    result=[]
    try: children=Path(f'/proc/{pid}/task/{pid}/children').read_text().split()
    except FileNotFoundError: return result
    for child in children:
        child=int(child)
        try: fields=Path(f'/proc/{child}/stat').read_text().rsplit(')',1)[1].split()
        except FileNotFoundError: continue
        token=fields[19]
        if fields[0]!='Z' and int(fields[1])==pid and p.owner_token(child)==token:
            result.append([child,token]); result.extend(descendants(child))
    return result
def relay_processes(supervisor,owner):
    # A Windows -> WSL client starts below a fresh /init, outside the worker's
    # Linux parent tree. Identify its peer by the private copied module AND the
    # supervisor PID/start pair passed by production's public prepare_proxy.
    found=[]
    token=p.owner_token(supervisor)
    for process in Path('/proc').iterdir():
        if not process.name.isdigit(): continue
        pid=int(process.name); start=p.owner_token(pid)
        if not start: continue
        try: argv=(process/'cmdline').read_bytes().split(b'\0')
        except OSError: continue
        if os.fsencode(str(Path(p.__file__).resolve())) not in argv or b'--owned-relay' not in argv: continue
        at=argv.index(b'--owned-relay')
        # The interop /init launcher carries the forwarded argv too. Only the
        # Python script invocation is the authenticated Unix-socket peer.
        if at!=2: continue
        if argv[at+2:at+4]!=[str(supervisor).encode(),str(token).encode()]: continue
        if argv[at+4:at+6]!=[str(owner).encode(),str(p.owner_token(owner)).encode()]: continue
        if p.owner_token(pid)==start: found.append([pid,start]); found.extend(descendants(pid))
    return found
def response(client):
    data=b''
    while b'\r\n\r\n' not in data:
        part=client.recv(4096)
        assert part, 'proxy EOF before HTTP response'
        data+=part
    return data
def exercise(port,count):
    completed=[]
    for index in range(count):
        command=subprocess.run(['/bin/sh','-c','printf "fixture-command-%s" "$1"','sh',str(index)],
            capture_output=True,timeout=3,check=True)
        assert command.stdout==f'fixture-command-{index}'.encode()
        with socket.create_connection(('127.0.0.1',port),timeout=6) as client:
            client.sendall(f'GET http://fixture.invalid/{root.name}/{index} HTTP/1.1\r\nHost: fixture.invalid\r\n\r\n'.encode())
            assert b'200 OK' in response(client)
        with socket.create_connection(('127.0.0.1',port),timeout=6) as client:
            client.sendall(f'CONNECT {root.name}.fixture.invalid:443 HTTP/1.1\r\nHost: fixture.invalid\r\n\r\n'.encode())
            assert b'200 Connection Established' in response(client)
            value=b'opaque\x00\xff'+str(index).encode()
            client.sendall(value)
            result=b''
            while len(result)<len(value):
                part=client.recv(1024)
                assert part, 'CONNECT byte exchange EOF'
                result+=part
            assert result==value
        completed.append(dict(command=command.stdout.decode(),exit=command.returncode))
        time.sleep(.25)
    return completed
mode=sys.argv[1]
if mode=='handoff':
    group=root
    manifest=json.loads((group/'handoff-manifest').read_text())
    for name,expected in manifest.items():
        root=group/name
        ready=json.loads((root/'ready').read_text())
        assert {key:ready[key] for key in expected}==expected, 'handoff identity or endpoint changed'
        for key in ('worker','relay'):
            pid,token=expected[key]
            assert p.owner_token(pid)==token, 'handoff inherited a dead/reused process'
        put('handoff-command',expected)
elif mode=='launch-group':
    group=root
    for index in range(6):
        root=group/f'lane-{index}'
        with (root/'stdout').open('wb') as out, (root/'stderr').open('wb') as err:
            worker=subprocess.Popen([sys.executable,__file__,'worker',str(root),sys.argv[3]],
                stdin=subprocess.DEVNULL,stdout=out,stderr=err,start_new_session=True)
        put('launched',[worker.pid,p.owner_token(worker.pid)])
    for index in range(6):
        root=group/f'lane-{index}'
        wait('ready',45)
elif mode in ('launch','launch-monitor'):
    with (root/'stdout').open('wb') as out, (root/'stderr').open('wb') as err:
        worker=subprocess.Popen([sys.executable,__file__,'monitor' if mode=='launch-monitor' else 'worker',str(root),sys.argv[3]],
            stdin=subprocess.DEVNULL,stdout=out,stderr=err,start_new_session=True)
    put('launched',[worker.pid,p.owner_token(worker.pid)])
    wait('ready',30)
    if sys.argv[4]=='retained': wait('release-caller')
elif mode=='monitor':
    import threading
    wrapper=os.getpid()
    def record_shim():
        until=time.monotonic()+30
        while time.monotonic()<until:
            for pid,token in descendants(wrapper):
                try: argv=Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
                except OSError: continue
                if b'--owned-relay' not in argv: continue
                at=argv.index(b'--owned-relay')
                if at==2 or os.fsencode(str(Path(p.__file__).resolve())) not in argv: continue
                if argv[at+4:at+6]!=[str(wrapper).encode(),str(p.owner_token(wrapper)).encode()]: continue
                if p.owner_token(pid)==token:
                    put('shim',[pid,token]); return
            time.sleep(.02)
    threading.Thread(target=record_shim,daemon=True).start()
    p.discover_proxy=lambda command: ('127.0.0.1',int(sys.argv[3]))
    env={k:v for k,v in os.environ.items() if k not in p.PROXY_KEYS and k!=p.OWNER_KEY}
    try:
        p.exec_worker(sys.executable,[__file__,'monitor-cli',str(root)],env,'Ubuntu')
    except BaseException as error:
        put('monitor-exit',dict(code=error.code if isinstance(error,SystemExit) else 1,error=repr(error)))
        raise
elif mode=='monitor-cli':
    wrapper=os.getppid()
    owned=[[wrapper,p.owner_token(wrapper)]]+descendants(wrapper)
    supervisor=next(pid for pid,token in owned if b'--supervise' in Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0'))
    peers=relay_processes(supervisor,wrapper)
    assert peers, 'authenticated peer identity was not observed'
    owned+=peers
    owned=[list(identity) for identity in dict.fromkeys(map(tuple,owned))]
    port=int(os.environ['HTTP_PROXY'].rsplit(':',1)[1])
    listener_inode=next(line.split()[9] for line in Path('/proc/net/tcp').read_text().splitlines()[1:]
        if int(line.split()[1].split(':')[1],16)==port and line.split()[3]=='0A')
    controls=[]
    for pid,token in owned:
        argv=Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
        if b'--owned-relay' in argv: controls.append(os.fsdecode(argv[argv.index(b'--owned-relay')+1]))
    command=subprocess.run(['/bin/sh','-c','printf monitor-command'],capture_output=True,timeout=3,check=True)
    assert command.stdout==b'monitor-command'
    with socket.create_connection(('127.0.0.1',port),timeout=6) as client:
        client.sendall(b'GET http://fixture.invalid/monitor HTTP/1.1\r\nHost: fixture.invalid\r\n\r\n')
        assert b'200 OK' in response(client)
    put('ready',dict(worker=owned[0],cli=[os.getpid(),p.owner_token(os.getpid())],
        relay=[supervisor,p.owner_token(supervisor)],peer=peers[0],owned=owned,controls=controls,
        port=port,listener_inode=listener_inode))
    wait('fault-command')
    put('completed',exercise(port,1))
    wait('finish')
elif mode=='signal':
    identity=json.loads(sys.argv[3])
    p.stop_owned(*identity,signal.SIGKILL)
elif mode=='shim-state':
    pid,token=json.loads((root/'shim').read_text())
    location=Path(f'/proc/{pid}/stat')
    fields=location.read_text().rsplit(')',1)[1].split() if location.exists() else None
    print(json.dumps(dict(reaped=fields is None or fields[19]!=token)))
elif mode=='worker':
    # Loopback fixture endpoint only; no system discovery, auth or model access.
    p.discover_proxy=lambda command: ('127.0.0.1',int(sys.argv[3]))
    env={k:v for k,v in os.environ.items() if k not in p.PROXY_KEYS and k!=p.OWNER_KEY}
    relay=p.prepare_proxy(env,'Ubuntu')
    port=int(env['HTTP_PROXY'].rsplit(':',1)[1])
    listener_inode=next(line.split()[9] for line in Path('/proc/net/tcp').read_text().splitlines()[1:]
        if int(line.split()[1].split(':')[1],16)==port and line.split()[3]=='0A')
    owned=[[os.getpid(),p.owner_token(os.getpid())], [relay.pid,p.owner_token(relay.pid)]]
    owned+=descendants(relay.pid)
    peers=relay_processes(relay.pid,os.getpid())
    assert peers, 'authenticated peer identity was not observed'
    owned+=peers
    owned=[list(identity) for identity in dict.fromkeys(map(tuple,owned))]
    controls=[]
    for pid,token in owned:
        try: argv=Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
        except FileNotFoundError: continue
        if b'--owned-relay' in argv:
            controls.append(os.fsdecode(argv[argv.index(b'--owned-relay')+1]))
    put('ready',dict(worker=owned[0],relay=owned[1],peer=peers[0],owned=owned,controls=controls,
        port=port,listener_inode=listener_inode))
    try:
        wait('command')
        put('completed',exercise(port,5))
        deadline=time.monotonic()+120
        while not (root/'handoff-command').exists() and not (root/'finish').exists():
            if time.monotonic()>deadline: raise TimeoutError('finish or handoff-command')
            time.sleep(.05)
        if (root/'handoff-command').exists(): put('handoff-completed',exercise(port,2))
        wait('finish')
    except BaseException as error:
        put('error',dict(error=repr(error),relay_exit=relay.poll(),worker=os.getpid(),port=port)); raise
elif mode in ('inspect','cleanup'):
    ready=json.loads((root/'ready').read_text()) if (root/'ready').exists() else {}
    identities=ready.get('owned',[])
    if (root/'launched').exists(): identities.append(json.loads((root/'launched').read_text()))
    if mode=='cleanup':
        # PID descriptors and recorded start times prevent PID-reuse signalling.
        for pid,token in identities:
            if token:
                p.stop_owned(pid,token,signal.SIGTERM)
        end=time.monotonic()+18
        while any(p.owner_token(pid)==token for pid,token in identities) and time.monotonic()<end:
            time.sleep(.1)
        for pid,token in identities:
            if token: p.stop_owned(pid,token,signal.SIGKILL)
    live=[[pid,token] for pid,token in identities if token and p.owner_token(pid)==token]
    paths=[path for path in ready.get('controls',[]) if Path(path).exists() or Path(path).parent.exists()]
    # A port may be reused by a different owned lane after early failure. Bind
    # cleanup observations to the original socket inode, never a port alone.
    listening=bool(ready) and any(line.split()[9]==ready['listener_inode'] and line.split()[3]=='0A'
        for line in Path('/proc/net/tcp').read_text().splitlines()[1:])
    print(json.dumps(dict(live=live,paths=paths,listening=listening)))
'''


@unittest.skipUnless(os.name == 'nt' and shutil.which('wsl.exe'),
                     'caller lifetime requires native Windows PowerShell + Ubuntu WSL; Linux unit tests cannot reproduce Windows handle lifetime')
class CallerLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='proxy-caller-lifetime-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.package = self.directory / 'package'
        (self.package / 'windows').mkdir(parents=True)
        for name in ('desktop.ps1', 'process_transport.ps1', 'desktop_runtime.py',
                     'worker_proxy.py', 'proxy_tcp.ps1'):
            shutil.copy2(ROOT / 'windows' / name, self.package / 'windows' / name)
        self.source_hash=hashlib.sha256((self.package/'windows/worker_proxy.py').read_bytes()).hexdigest()
        self.assertEqual(self.source_hash,hashlib.sha256((ROOT/'windows/worker_proxy.py').read_bytes()).hexdigest())
        self.entry = self.package / 'fixture.py'
        self.entry.write_text(FIXTURE, encoding='utf-8')
        self.linux = self.wsl('wslpath', '-a', '-u', str(self.directory)).stdout.decode().strip()
        config = dict(Distro='Ubuntu', LinuxHome=self.linux+'/home',
                      WindowsCodexHome=str(self.directory/'native-home'),
                      LinuxCodex='/bin/true', HubHome=self.linux+'/hub')
        (self.package/'windows/desktop-config.json').write_text(json.dumps(config))
        self.shell = shutil.which('powershell.exe')
        if not self.shell:
            self.skipTest('native Windows PowerShell is unavailable')
        self.env = {k:v for k,v in os.environ.items() if k.upper() in
                    {'SYSTEMROOT','WINDIR','COMSPEC','PATH','PATHEXT','TEMP','TMP'}}
        self.env.update(HOME=str(self.directory), USERPROFILE=str(self.directory),
                        AGENT_HUB_HOME=str(self.directory/'hub'))
        self.server = socket.socket()
        self.server.bind(('127.0.0.1', 0))
        self.server.listen(16)
        self.server.settimeout(.2)
        self.stop_server = threading.Event()
        self.requests = []
        self.request_lock = threading.Lock()
        self.errors = []
        self.peers = []
        self.acceptor = threading.Thread(target=self.accept, daemon=True)
        self.acceptor.start()
        self.addCleanup(self.close_server)

    def wsl(self, *arguments):
        return subprocess.run(['wsl.exe','--distribution','Ubuntu','--exec',*arguments],
                              stdin=subprocess.DEVNULL,capture_output=True,timeout=35,check=True)

    def accept(self):
        while not self.stop_server.is_set():
            try: client,_ = self.server.accept()
            except socket.timeout: continue
            except OSError: break
            peer = threading.Thread(target=self.exchange,args=(client,),daemon=True)
            self.peers.append(peer)
            peer.start()

    def exchange(self, client):
        try:
            with client:
                client.settimeout(10)
                data=b''
                while b'\r\n\r\n' not in data:
                    part=client.recv(4096)
                    if not part: return
                    data+=part
                first=data.split(b'\r\n',1)[0]
                with self.request_lock:
                    self.requests.append(first)
                if first.startswith(b'CONNECT '):
                    client.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
                    while True:
                        data=client.recv(4096)
                        if not data: break
                        client.sendall(data)
                else:
                    client.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
        except OSError as error:
            self.errors.append(repr(error))

    def close_server(self):
        self.stop_server.set()
        self.server.close()
        self.acceptor.join(2)
        for peer in self.peers: peer.join(11)

    def wait_file(self, directory, name, seconds=30):
        deadline=time.monotonic()+seconds
        while not (directory/name).exists():
            if (directory/'error').exists():
                self.fail((directory/'error').read_text())
            if time.monotonic()>deadline:
                stderr=(directory/'stderr').read_text(errors='replace') if (directory/'stderr').exists() else ''
                self.fail(f'{name} timeout: {stderr}')
            time.sleep(.1)
        return json.loads((directory/name).read_text())

    def native_helpers(self):
        # Match only this private copied helper, then retain native creation
        # timestamps as well as PIDs. Never stop processes by name or pattern.
        helper=str(self.package/'windows/proxy_tcp.ps1').replace("'", "''")
        script=("@(Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | "
                f"Where-Object {{ $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains('{helper}') }} | "
                "ForEach-Object { @{pid=$_.ProcessId;start=$_.CreationDate.ToUniversalTime().Ticks} }) | ConvertTo-Json -Compress")
        run=subprocess.run([self.shell,'-NoProfile','-NonInteractive','-WindowStyle','Hidden',
                            '-Command',script],capture_output=True,timeout=12,check=True)
        data=json.loads(run.stdout) if run.stdout.strip() else []
        return data if isinstance(data,list) else [data]

    def lifecycle(self, name, retained):
        directory=self.directory/name
        directory.mkdir()
        linux_directory=self.linux+'/'+name
        command=shlex.join(['python3',self.linux+'/package/fixture.py','launch',linux_directory,
                            str(self.server.getsockname()[1]),'retained' if retained else 'returned'])
        caller=subprocess.Popen([self.shell,'-NoProfile','-NonInteractive','-WindowStyle','Hidden',
            '-ExecutionPolicy','Bypass','-File',str(self.package/'windows/desktop.ps1'),'shell',command],
            stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
            cwd=self.directory,env=self.env)
        def inspect(mode='inspect'):
            return json.loads(self.wsl('python3',self.linux+'/package/fixture.py',mode,linux_directory).stdout)
        try:
            ready=self.wait_file(directory,'ready')
            self.assertTrue(ready['controls'],'private relay handoff was not observed')
            helpers=self.native_helpers()
            if retained:
                self.assertIsNone(caller.poll(),'positive control caller returned prematurely')
            else:
                output,error=caller.communicate(timeout=15)
                self.assertEqual(caller.returncode,0,error.decode(errors='replace'))
                # Give WSL time to observe native caller completion before I/O.
                time.sleep(30)
            before=len(self.requests)
            (directory/'command').touch()
            completed=self.wait_file(directory,'completed',40)
            self.assertEqual(completed,[dict(command=f'fixture-command-{i}',exit=0) for i in range(5)])
            self.assertEqual(len(self.requests)-before,10,'HTTP/CONNECT requests did not reach local fixture')
            helpers=self.native_helpers()
            self.assertEqual(len(helpers),1,'expected exactly one native helper after actual HTTP/CONNECT success')
            observed=inspect()
            self.assertIn(ready['worker'],observed['live'])
            self.assertIn(ready['relay'],observed['live'])
            self.assertTrue(observed['listening'])
            if retained:
                self.assertIsNone(caller.poll())
            (directory/'finish').touch()
            deadline=time.monotonic()+20
            while True:
                observed=inspect()
                if not observed['live'] and not observed['paths'] and not observed['listening']: break
                if time.monotonic()>deadline: self.fail(f'owned resources survived worker finish: {observed}')
                time.sleep(.25)
            self.assertEqual(self.native_helpers(),[],f'native helper survived worker finish: {helpers}')
            (directory/'release-caller').touch()
            output,error=caller.communicate(timeout=15)
            self.assertEqual(caller.returncode,0,error.decode(errors='replace'))
            self.assertEqual(self.errors,[])
            print(f'{name}: sha256={self.source_hash}, worker={ready["worker"]}, relay={ready["relay"]}, native={helpers}, 5 commands + HTTP/CONNECT completed; owned processes/listener/paths gone',flush=True)
            return ready
        finally:
            (directory/'finish').touch()
            (directory/'release-caller').touch()
            try:
                cleaned=inspect('cleanup')
                self.assertEqual(cleaned,dict(live=[],paths=[],listening=False),'exact-owner cleanup failed')
            finally:
                if caller.poll() is None: caller.kill()
                caller.communicate(timeout=10)

    def test_six_workers_after_caller_return_then_fresh_resume(self):
        lanes=[self.directory/f'lane-{index}' for index in range(6)]
        for directory in lanes: directory.mkdir()
        command=shlex.join(['python3',self.linux+'/package/fixture.py','launch-group',self.linux,
                            str(self.server.getsockname()[1])])
        caller=subprocess.Popen([self.shell,'-NoProfile','-NonInteractive','-WindowStyle','Hidden',
            '-ExecutionPolicy','Bypass','-File',str(self.package/'windows/desktop.ps1'),'shell',command],
            stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
            cwd=self.directory,env=self.env)
        def inspect(directory,mode='inspect'):
            return json.loads(self.wsl('python3',self.linux+'/package/fixture.py',mode,
                                       self.linux+'/'+directory.name).stdout)
        try:
            ready=[self.wait_file(directory,'ready',55) for directory in lanes]
            helpers=self.native_helpers()
            output,error=caller.communicate(timeout=20)
            self.assertEqual(caller.returncode,0,error.decode(errors='replace'))
            time.sleep(30)
            for directory in lanes: (directory/'command').touch()
            for directory in lanes:
                completed=self.wait_file(directory,'completed',40)
                self.assertEqual(completed,[dict(command=f'fixture-command-{i}',exit=0) for i in range(5)])
                gets=[item for item in self.requests if item.startswith(f'GET http://fixture.invalid/{directory.name}/'.encode())]
                connects=[item for item in self.requests if item.startswith(f'CONNECT {directory.name}.fixture.invalid:'.encode())]
                self.assertEqual(len(gets),5)
                self.assertEqual(len(connects),5)
            helpers=self.native_helpers()
            self.assertEqual(len(helpers),6,'expected six native helpers after actual HTTP/CONNECT success')
            for directory,item in zip(lanes,ready):
                observed=inspect(directory)
                self.assertIn(item['worker'],observed['live'])
                self.assertIn(item['relay'],observed['live'])
                self.assertTrue(observed['listening'])
            manifest={directory.name:{key:item[key] for key in ('worker','relay','port','listener_inode')}
                      for directory,item in zip(lanes,ready)}
            (self.directory/'handoff-manifest').write_text(json.dumps(manifest))
            successor_command=shlex.join(['python3',self.linux+'/package/fixture.py','handoff',self.linux])
            successor=subprocess.run([self.shell,'-NoProfile','-NonInteractive','-WindowStyle','Hidden',
                '-ExecutionPolicy','Bypass','-File',str(self.package/'windows/desktop.ps1'),'shell',successor_command],
                stdin=subprocess.DEVNULL,capture_output=True,timeout=30,cwd=self.directory,env=self.env)
            self.assertEqual(successor.returncode,0,successor.stderr.decode(errors='replace'))
            for directory,item in zip(lanes,ready):
                completed=self.wait_file(directory,'handoff-completed')
                self.assertEqual(completed,[dict(command=f'fixture-command-{i}',exit=0) for i in range(2)])
                current=json.loads((directory/'ready').read_text())
                self.assertEqual({key:current[key] for key in manifest[directory.name]},manifest[directory.name])
                observed=inspect(directory)
                self.assertIn(item['worker'],observed['live'])
                self.assertIn(item['relay'],observed['live'])
                self.assertTrue(observed['listening'])
                gets=[request for request in self.requests if request.startswith(f'GET http://fixture.invalid/{directory.name}/'.encode())]
                connects=[request for request in self.requests if request.startswith(f'CONNECT {directory.name}.fixture.invalid:'.encode())]
                self.assertEqual(len(gets),7)
                self.assertEqual(len(connects),7)
            for directory in lanes: (directory/'finish').touch()
            deadline=time.monotonic()+25
            for directory in lanes:
                while True:
                    observed=inspect(directory)
                    if observed==dict(live=[],paths=[],listening=False): break
                    if time.monotonic()>deadline: self.fail(f'{directory.name} leaked: {observed}')
                    time.sleep(.2)
            self.assertEqual(self.native_helpers(),[])
            self.assertEqual(self.errors,[])
            print(f'six-worker caller-return + coordinator handoff: sha256={self.source_hash}, identities={ready}, native={helpers}; 42 commands + 42 HTTP + 42 CONNECT completed on unchanged workers/endpoints; owned resources gone',flush=True)
        except BaseException:
            print(f'FAILED six-worker source sha256={self.source_hash}',file=sys.stderr,flush=True)
            for directory in lanes:
                evidence={name:(directory/name).read_text(errors='replace') for name in
                          ('ready','error','stderr','completed') if (directory/name).exists()}
                print(json.dumps(dict(lane=directory.name,evidence=evidence)),file=sys.stderr,flush=True)
            raise
        finally:
            for directory in lanes: (directory/'finish').touch()
            try:
                cleanup_results=[]
                for directory in lanes:
                    try: cleanup_results.append((directory.name,inspect(directory,'cleanup')))
                    except Exception as error: cleanup_results.append((directory.name,repr(error)))
                self.assertEqual(cleanup_results,[(directory.name,dict(live=[],paths=[],listening=False)) for directory in lanes])
            finally:
                if caller.poll() is None: caller.kill()
                caller.communicate(timeout=10)
        resumed=self.lifecycle('fresh-resume',False)
        self.assertNotIn(resumed['worker'],[item['worker'] for item in ready])

    def test_retained_caller_positive(self):
        self.lifecycle('retained-positive',True)

    def test_exec_worker_monitor_stops_cli_on_supervisor_or_wrapper_loss(self):
        for target in ('relay','worker','peer'):
            with self.subTest(killed=target):
                directory=self.directory/('monitor-'+target)
                directory.mkdir()
                linux_directory=self.linux+'/'+directory.name
                caller=subprocess.Popen(['wsl.exe','--distribution','Ubuntu','--exec','python3',
                    self.linux+'/package/fixture.py','monitor',linux_directory,
                    str(self.server.getsockname()[1])],stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                def inspect(mode='inspect'):
                    return json.loads(self.wsl('python3',self.linux+'/package/fixture.py',mode,linux_directory).stdout)
                try:
                    ready=self.wait_file(directory,'ready')
                    self.assertTrue(inspect()['listening'])
                    self.wsl('python3',self.linux+'/package/fixture.py','signal',linux_directory,json.dumps(ready[target]))
                    output,error=caller.communicate(timeout=20)
                    self.assertNotEqual(caller.returncode,0,'monitor fault returned success')
                    deadline=time.monotonic()+20
                    while True:
                        observed=inspect()
                        if observed==dict(live=[],paths=[],listening=False): break
                        if time.monotonic()>deadline: self.fail(f'monitor {target} leaked: {observed}; stderr={error!r}')
                        time.sleep(.2)
                    self.assertEqual(self.native_helpers(),[])
                    print(f'monitor {target} loss: sha256={self.source_hash}, owned={ready["owned"]}, native exit={caller.returncode}; CLI and owned resources gone',flush=True)
                finally:
                    (directory/'finish').touch()
                    try:
                        self.assertEqual(inspect('cleanup'),dict(live=[],paths=[],listening=False))
                    finally:
                        if caller.poll() is None: caller.kill()
                        caller.communicate(timeout=10)

    def test_peer_failure_after_launch_shim_is_already_reaped(self):
        directory=self.directory/'reaped-shim'
        directory.mkdir()
        linux_directory=self.linux+'/'+directory.name
        command=shlex.join(['python3',self.linux+'/package/fixture.py','launch-monitor',
                            linux_directory,str(self.server.getsockname()[1]),'returned'])
        caller=subprocess.Popen([self.shell,'-NoProfile','-NonInteractive','-WindowStyle','Hidden',
            '-ExecutionPolicy','Bypass','-File',str(self.package/'windows/desktop.ps1'),'shell',command],
            stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,cwd=self.directory,env=self.env)
        def probe(mode):
            return json.loads(self.wsl('python3',self.linux+'/package/fixture.py',mode,linux_directory).stdout)
        try:
            ready=self.wait_file(directory,'ready')
            output,error=caller.communicate(timeout=15)
            self.assertEqual(caller.returncode,0,error.decode(errors='replace'))
            deadline=time.monotonic()+8
            while not (directory/'shim').exists():
                if time.monotonic()>deadline: self.skipTest('interop shim ended before its exact PID/start could be observed')
                time.sleep(.1)
            while not probe('shim-state')['reaped']:
                if time.monotonic()>deadline:
                    self.skipTest('native launch shim stayed alive during bounded observation; already-reaped negative was not exercised')
                time.sleep(.2)
            (directory/'fault-command').touch()
            self.assertEqual(self.wait_file(directory,'completed'),[dict(command='fixture-command-0',exit=0)])
            self.assertIn(ready['peer'],probe('inspect')['live'],'peer died before the controlled fault')
            self.wsl('python3',self.linux+'/package/fixture.py','signal',linux_directory,json.dumps(ready['peer']))
            deadline=time.monotonic()+22
            while True:
                observed=probe('inspect')
                if observed==dict(live=[],paths=[],listening=False): break
                if time.monotonic()>deadline: self.fail(f'peer failure after shim reap left resources: {observed}')
                time.sleep(.2)
            self.assertIn('Owned worker relay exited unexpectedly', (directory/'stderr').read_text(errors='replace'))
            terminal=self.wait_file(directory,'monitor-exit')
            self.assertNotEqual(terminal['code'],0)
            self.assertEqual(self.native_helpers(),[])
            print(f'already-reaped shim then peer loss: sha256={self.source_hash}, shim={json.loads((directory/"shim").read_text())}, peer={ready["peer"]}, wrapper_exit={terminal["code"]}; command/HTTP/CONNECT positive before fault, monitor terminal diagnostic and owned cleanup',flush=True)
        finally:
            (directory/'finish').touch()
            try: self.assertEqual(probe('cleanup'),dict(live=[],paths=[],listening=False))
            finally:
                if caller.poll() is None: caller.kill()
                caller.communicate(timeout=10)


if __name__ == '__main__':
    unittest.main()

"""Offline Linux ownership contracts for the CLI relay monitor."""
from pathlib import Path
import ctypes
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]

# This runs only in a disposable subprocess: exec_worker may exec or signal itself.
WRAPPER = r'''
import os, sys, subprocess
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import worker_proxy as proxy
base = Path(sys.argv[2])
def prepare(env, distro):
    relay_code = 'import pathlib,sys,time; p=pathlib.Path(sys.argv[1]); exec('+repr('while not p.exists(): time.sleep(.025)')+'); sys.exit(int(p.read_text()))'
    relay = subprocess.Popen([sys.executable, '-c', relay_code, str(base / 'relay.exit')])
    (base / 'relay.pid').write_text(str(relay.pid))
    return relay
proxy.prepare_proxy = prepare
proxy.exec_worker(sys.executable, [str(base / 'cli.py'), str(base), sys.argv[3]], dict(os.environ))
'''
CLI = r'''
import os, signal, sys, time
from pathlib import Path
base = Path(sys.argv[1])
mode = sys.argv[2]
if mode == 'handler':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(17))
if mode == 'ignore':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
(base / 'cli.pid').write_text(str(os.getpid()))
(base / 'armed').touch()
if mode == 'exit':
    while not (base / 'release').exists():
        time.sleep(.025)
    sys.exit(23)
while True:
    time.sleep(.05)
'''

@unittest.skipUnless(sys.platform.startswith('linux'), 'Linux ownership and parent-death contracts')
class MonitorContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Reap orphans from the SIGKILL test even on hosts with a non-reaping PID 1.
        cls.libc = ctypes.CDLL(None, use_errno=True)
        cls.previous_subreaper = ctypes.c_int()
        if cls.libc.prctl(37, ctypes.byref(cls.previous_subreaper), 0, 0, 0):
            raise OSError(ctypes.get_errno(), 'PR_GET_CHILD_SUBREAPER')
        if cls.libc.prctl(36, 1, 0, 0, 0):
            raise OSError(ctypes.get_errno(), 'PR_SET_CHILD_SUBREAPER')

    @classmethod
    def tearDownClass(cls):
        cls.libc.prctl(36, cls.previous_subreaper.value, 0, 0, 0)

    def setUp(self):
        if not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
            self.skipTest('Linux pidfd signalling required for fixture ownership safety')
        self.temp = tempfile.TemporaryDirectory(prefix='relay-monitor-')
        self.base = Path(self.temp.name)
        (self.base / 'cli.py').write_text(CLI)
        self.wrapper = None
        self.identities = {}
        self.addCleanup(self.cleanup)

    def wait_for(self, predicate, message, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.025)
        self.fail(message)

    def token(self, pid):
        try:
            stat = Path('/proc', str(pid), 'stat').read_text()
            return stat[stat.rfind(')') + 2:].split()[19]
        except FileNotFoundError:
            return None

    def remember(self, name):
        pid = int((self.base / (name + '.pid')).read_text())
        self.identities[name] = (pid, self.token(pid))
        return pid

    def signal_owned(self, pid, token, signum):
        try:
            fd = os.pidfd_open(pid)
        except ProcessLookupError:
            return
        try:
            if token and self.token(pid) == token:
                signal.pidfd_send_signal(fd, signum)
        except ProcessLookupError:
            pass
        finally:
            os.close(fd)
    def cleanup(self):
        if self.wrapper and self.wrapper.poll() is None:
            self.wrapper.kill()
            self.wrapper.wait(timeout=12)
        # Guard even fixture teardown against PID reuse; never signal by PID alone.
        for pid, token in self.identities.values():
            self.signal_owned(pid, token, signal.SIGKILL)
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
        if self.wrapper:
            self.wrapper.communicate(timeout=12)
        self.temp.cleanup()

    def start(self, mode='default'):
        self.wrapper = subprocess.Popen(
            [sys.executable, '-c', WRAPPER, str(ROOT / 'windows'), str(self.base), mode],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.wait_for(lambda: (self.base / 'armed').exists(), 'CLI never became ready')
        self.remember('cli')
        self.remember('relay')
        if mode == 'exit':
            (self.base / 'release').touch()

    def assert_gone(self, name):
        pid, token = self.identities[name]
        # Reap an adopted child, then require the exact owned process to disappear.
        def gone():
            try:
                os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                pass
            return self.token(pid) != token
        self.wait_for(gone, name + ' remained alive or unreaped')

    def test_natural_exit_preserves_status_and_cleans_owned_resources(self):
        self.start('exit')
        self.assertEqual(self.wrapper.wait(timeout=20), 23)
        self.assert_gone('cli')
        self.assert_gone('relay')

    def relay_loss(self, status):
        self.start('ignore')
        if status < 0:
            self.signal_owned(*self.identities['relay'], -status)
        else:
            (self.base / 'relay.exit').write_text(str(status))
        self.assertNotEqual(self.wrapper.wait(timeout=20), 0)
        self.assert_gone('cli')
        self.assert_gone('relay')

    def test_relay_zero_exit_is_terminal(self):
        self.relay_loss(0)

    def test_relay_nonzero_exit_is_terminal(self):
        self.relay_loss(7)

    def test_relay_sigkill_is_terminal(self):
        self.relay_loss(-signal.SIGKILL)

    def signal_exit(self, mode, expected):
        self.start(mode)
        self.wrapper.send_signal(signal.SIGTERM)
        self.assertEqual(self.wrapper.wait(timeout=20), expected)
        self.assert_gone('cli')
        self.assert_gone('relay')

    def test_signal_handler_exit_status_is_preserved(self):
        self.signal_exit('handler', 17)

    def test_default_signal_status_is_preserved(self):
        self.signal_exit('default', -signal.SIGTERM)
    def test_wrapper_sigkill_cannot_leave_cli_running(self):
        self.start('ignore')
        self.wrapper.kill()
        self.assertEqual(self.wrapper.wait(timeout=12), -signal.SIGKILL)
        self.assert_gone('cli')

    def test_cli_exit_racing_monitor_signal_preserves_actual_status(self):
        # Model CLI exit between the monitor loop and its cleanup observation.
        # Signal delivery stays in a disposable process, never the test runner.
        code = r'''
import signal, sys
from unittest.mock import patch
sys.path.insert(0, sys.argv[1])
import worker_proxy as p
class Child:
    pid = 999999999
    calls = 0
    def poll(self):
        self.calls += 1
        if self.calls == 1:
            signal.raise_signal(signal.SIGTERM)
            return None
        return 17
    def wait(self, timeout=None): return 17
class Relay:
    def poll(self): return None
    def terminate(self): pass
    def wait(self, timeout=None): return 0
with patch.object(p, 'prepare_proxy', return_value=Relay()), \
     patch.object(p.subprocess, 'Popen', return_value=Child()), \
     patch.object(p, 'owner_token', return_value='fixture-token'):
    p.exec_worker('fixture-cli', [], {})
'''
        run = subprocess.run([sys.executable, '-c', code, str(ROOT / 'windows')],
                             capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 17, run.stderr)

if __name__ == '__main__':
    unittest.main()

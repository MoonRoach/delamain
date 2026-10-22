"""Offline diagnostics controls; every filesystem fixture uses a scratch home."""
import contextlib
from concurrent.futures import ProcessPoolExecutor
from datetime import datetime
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('handoff_events', Path(__file__).resolve().parents[1] / 'bin' / 'handoff_events.py')
events = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(events)
SENTINEL = 'PRIVATE_SENTINEL_prompt_auth_tool_result_grant_settings'


def writer(arguments):
    root, worker = arguments
    successes = 0
    for index in range(800):
        successes += events.emit_handoff_event('progress', root=root, session_id='shared',
                                               stage='scratch-stage', tokens=index,
                                               request_id=f'worker-{worker}-{index}')
    return successes


class HandoffEventsTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.directory = self.root / '.state' / 'handoff-events'

    def emit(self, event='observation', **fields):
        arguments = dict(root=self.root, session_id='session-123', stage='scratch-stage')
        arguments.update(fields)
        return events.emit_handoff_event(event, **arguments)

    def records(self, session='session-123'):
        return [json.loads(line) for line in (self.directory / (session + '.jsonl')).read_text(encoding='utf-8').splitlines()]

    def test_append_schema_and_all_enums(self):
        for event in sorted(events.EVENTS):
            self.assertTrue(self.emit(event, turn_id='turn_1', tokens=120, metric_age_seconds=0.5,
                                      metric_at='2026-10-15T01:02:03Z', observed_at='2026-10-15T01:02:03.123456Z'))
        for field, values in events.ENUM_FIELDS.items():
            for value in values:
                self.assertTrue(self.emit(**{field: value}))
        rows = self.records()
        self.assertEqual(len(rows), len(events.EVENTS) + sum(map(len, events.ENUM_FIELDS.values())))
        first = rows[0]
        self.assertEqual(first['schema_version'], 1)
        self.assertEqual(first['session_id'], 'session-123')
        self.assertEqual(first['stage'], 'scratch-stage')
        self.assertEqual(first['turn_id'], 'turn_1')
        self.assertEqual(first['tokens'], 120)
        self.assertTrue(first['created_at'].endswith('Z'))
        datetime.fromisoformat(first['created_at'].replace('Z', '+00:00'))
        for file in self.directory.iterdir():
            if os.name != 'nt':
                self.assertEqual(stat.S_IMODE(file.stat().st_mode), 0o600)
        self.assertTrue(self.emit(tokens=events.MAX_NUMBER, window=0, warn=1, block=2,
                                  due_since_tokens=3, no_progress_count=4, stop_continuations=5,
                                  metric_source='unavailable', request_id='req-1'))

    def test_identifiers_and_windows_device_names(self):
        bad = ['', '.', '..', '../escape', '/absolute', 'a/b', 'a\\b', 'a:b', 'a.jsonl',
               'CON', 'nul', 'COM1', 'LPT9', 'CONOUT$', 'name ', 'name.', 'é', 'a' * 97,
               SENTINEL + '\n', None, 1, True]
        for field in ('session_id', 'stage', 'turn_id', 'request_id'):
            for value in bad:
                if value is None and field == 'turn_id':
                    continue
                with self.subTest(field=field, value=value):
                    self.assertFalse(self.emit(**{field: value}))
        self.assertFalse(self.directory.exists())
        self.assertTrue(self.emit(session_id='a', stage='B_2', turn_id='c-3', request_id='d4'))

    def test_private_unknown_invalid_fields_leave_no_content(self):
        self.assertTrue(self.emit())  # positive control for the same log sink
        before = (self.directory / 'session-123.jsonl').read_bytes()
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            for field in ('prompt', 'last_assistant_text', 'tool_command', 'tool_result', 'grant',
                          'private_config', 'auth_token', 'path', 'exception', 'created_at', 'schema_version'):
                self.assertFalse(self.emit(**{field: SENTINEL}))
            for field in events.ENUM_FIELDS:
                self.assertFalse(self.emit(**{field: SENTINEL}))
                self.assertFalse(self.emit(**{field: ['observation']}))
            self.assertFalse(self.emit(SENTINEL))
            for field in events.NUMERIC_FIELDS:
                for value in (-1, float('nan'), float('inf'), True, None, SENTINEL,
                              events.MAX_NUMBER + 1, 10**1000, [], {}):
                    self.assertFalse(self.emit(**{field: value}))
            for value in ('2026-02-30T00:00:00Z', '2026-10-15', '2026-10-15T00:00:00+00:00',
                          '2026-10-15T00:00:00.1234567Z', SENTINEL, 'x' * 100000):
                self.assertFalse(self.emit(metric_at=value))
            self.assertFalse(self.emit(error_type='PermissionError: ' + SENTINEL))
            self.assertFalse(self.emit(request_id='x' * 100000))
        self.assertEqual((self.directory / 'session-123.jsonl').read_bytes(), before)
        for file in self.directory.iterdir():
            self.assertNotIn(SENTINEL.encode(), file.read_bytes())
        self.assertEqual(out.getvalue() + err.getvalue(), '')

    def test_event_byte_limit(self):
        self.assertTrue(self.emit())
        before = (self.directory / 'session-123.jsonl').read_bytes()
        with mock.patch.object(events, 'MAX_EVENT_BYTES', 16):
            self.assertFalse(self.emit())
        self.assertEqual((self.directory / 'session-123.jsonl').read_bytes(), before)

    def test_rotation_real_bounds_and_one_retained(self):
        # Real default bounds, enough writes to replace the retained file twice.
        total = 0
        for index in range(3500):
            self.assertTrue(self.emit(tokens=index, request_id='r' * 96))
            total += 1
        files = sorted(self.directory.glob('*.jsonl*'))
        self.assertEqual([file.name for file in files], ['session-123.jsonl', 'session-123.jsonl.1'])
        rows = []
        for file in reversed(files):
            raw = file.read_bytes()
            self.assertLessEqual(len(raw), 256 * 1024)
            self.assertTrue(raw.endswith(b'\n'))
            for line in raw.splitlines(keepends=True):
                self.assertLessEqual(len(line), 4096)
                rows.append(json.loads(line))
        sequence = [row['tokens'] for row in rows]
        self.assertEqual(sequence, list(range(sequence[0], total)))
        self.assertGreater(sequence[0], 0)

    def test_io_failures_are_quiet_and_do_not_escape(self):
        self.assertTrue(self.emit())
        before = (self.directory / 'session-123.jsonl').read_bytes()
        for error in (PermissionError(SENTINEL), OSError(30, SENTINEL)):
            # _open is the actual shared boundary: Windows uses CreateFileW, not os.open.
            with mock.patch.object(events, '_open', side_effect=error):
                self.assertFalse(self.emit())
            for method in ('mkdir', 'write'):
                with mock.patch.object(events.os, method, side_effect=error):
                    self.assertFalse(self.emit())
        self.assertEqual((self.directory / 'session-123.jsonl').read_bytes(), before)
        with mock.patch.object(events, 'MAX_FILE_BYTES', len(before)):
            with mock.patch.object(events.os, 'replace', side_effect=PermissionError(SENTINEL)):
                self.assertFalse(self.emit())
        self.assertNotIn(SENTINEL.encode(), (self.directory / 'session-123.jsonl').read_bytes())

    def test_short_write_rolls_back_without_retry(self):
        self.assertTrue(self.emit())
        path = self.directory / 'session-123.jsonl'
        before = path.read_bytes()
        real_write = os.write

        def partial(fd, data):
            return real_write(fd, data[:17])

        with mock.patch.object(events.os, 'write', side_effect=partial) as write:
            self.assertFalse(self.emit())
            self.assertEqual(write.call_count, 1)
        self.assertEqual(path.read_bytes(), before)
        self.assertTrue(self.emit())
        self.assertEqual(len(self.records()), 2)

    @unittest.skipIf(os.name == 'nt', 'POSIX mode control; injected read-only errors run on all hosts')
    def test_actual_readonly_directory(self):
        self.assertTrue(self.emit())
        self.directory.chmod(0o500)
        self.addCleanup(self.directory.chmod, 0o700)
        if os.geteuid() == 0:
            self.skipTest('root bypasses mode bits; EROFS/PermissionError controls still run')
        self.assertFalse(self.emit(session_id='new-session'))

    def test_nonblocking_lock_contention(self):
        self.assertTrue(self.emit())
        lock = os.open(self.directory / 'session-123.lock', os.O_RDWR)
        try:
            with events._locked(lock):
                started = time.monotonic()
                self.assertFalse(self.emit())
                self.assertLess(time.monotonic() - started, 1)
            self.assertTrue(self.emit())
        finally:
            os.close(lock)
        self.assertEqual(len(self.records()), 2)

    def test_invalid_roots(self):
        for root in ('relative', self.root / '..' / self.root.name, None):
            self.assertFalse(self.emit(root=root))
        if os.name == 'nt':
            for root in (r'\\server\share', r'\\?\C:\test', r'C:\bad:stream', 'C:\\bad.\\child'):
                self.assertFalse(self.emit(root=root))

    def symlink(self, source, target, directory=False):
        try:
            source.symlink_to(target, target_is_directory=directory)
        except (OSError, NotImplementedError):
            self.skipTest('host cannot create test symlinks')

    def test_symlink_hub_root_and_ancestor(self):
        external = self.root / 'external'
        external.mkdir()
        alias = self.root / 'alias'
        self.symlink(alias, external, True)
        child = external / 'child'
        child.mkdir()
        for root in (external, alias, alias / 'child'):
            with self.subTest(root=root):
                self.assertTrue(self.emit(root=root))
                path = root / '.state' / 'handoff-events' / 'session-123.jsonl'
                self.assertEqual(json.loads(path.read_text().splitlines()[-1])['event'], 'observation')

    @unittest.skipIf(os.name == 'nt', 'The context hook runs on POSIX/WSL')
    def test_hook_diagnostic_is_quiet_through_root_aliases(self):
        external = self.root / 'external'
        external.mkdir()
        (external / 'child').mkdir()
        alias = self.root / 'alias'
        self.symlink(alias, external, True)
        plugin = Path(__file__).resolve().parents[1]
        code = '''import sys
from pathlib import Path
from types import SimpleNamespace
sys.path[:0] = [str(Path(sys.argv[1]) / 'hooks'), str(Path(sys.argv[1]) / 'bin')]
from context_budget import diagnostic
diagnostic(SimpleNamespace(root=lambda: Path(sys.argv[2])),
           {'session_id': 'hook-session', 'hook_event_name': 'PostToolUse'},
           'scratch-stage', 'observation', tokens=123)
'''
        for root in (external, alias, alias / 'child'):
            with self.subTest(root=root):
                run = subprocess.run([sys.executable, '-c', code, str(plugin), str(root)],
                                     capture_output=True, text=True, timeout=10)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertEqual(run.stdout, '')
                self.assertEqual(run.stderr, '')
                path = root / '.state' / 'handoff-events' / 'hook-session.jsonl'
                self.assertEqual(json.loads(path.read_text().splitlines()[-1])['tokens'], 123)

    def test_root_alias_retarget_after_resolution_uses_pinned_destination(self):
        original = self.root / 'original'
        replacement = self.root / 'replacement'
        original.mkdir()
        replacement.mkdir()
        alias = self.root / 'alias'
        self.symlink(alias, original, True)
        realpath = os.path.realpath

        def retarget(root):
            canonical = realpath(root)
            alias.unlink()
            alias.symlink_to(replacement, target_is_directory=True)
            return canonical

        with mock.patch.object(events.os.path, 'realpath', side_effect=retarget) as resolve:
            self.assertTrue(self.emit(root=alias))
            resolve.assert_called_once_with(alias)
        self.assertTrue((original / '.state' / 'handoff-events' / 'session-123.jsonl').is_file())
        self.assertEqual(list(replacement.iterdir()), [])

    def test_symlink_state_directory(self):
        external = self.root / 'external'
        external.mkdir()
        self.symlink(self.root / '.state', external, True)
        self.assertFalse(self.emit())
        self.assertEqual(list(external.iterdir()), [])

    def test_symlink_event_directory(self):
        (self.root / '.state').mkdir()
        external = self.root / 'external'
        external.mkdir()
        self.symlink(self.directory, external, True)
        self.assertFalse(self.emit())
        self.assertEqual(list(external.iterdir()), [])

    def test_symlink_files_and_hardlinks(self):
        self.assertTrue(self.emit())
        external = self.root / 'external'
        external.write_text(SENTINEL, encoding='utf-8')
        for suffix in ('.jsonl', '.jsonl.1', '.lock'):
            path = self.directory / ('session-123' + suffix)
            if path.exists():
                path.unlink()
            self.symlink(path, external)
            self.assertFalse(self.emit())
            self.assertEqual(external.read_text(encoding='utf-8'), SENTINEL)
            path.unlink()
        path = self.directory / 'session-123.jsonl'
        try:
            os.link(external, path)
        except OSError:
            self.skipTest('host cannot create test hardlinks')
        self.assertFalse(self.emit())
        self.assertEqual(external.read_text(encoding='utf-8'), SENTINEL)

    def test_reparse_attribute_rejected(self):
        # Portable Windows reparse control; real symlinks above exercise the IO path.
        info = mock.Mock(st_mode=stat.S_IFDIR | 0o700, st_file_attributes=0x400)
        with self.assertRaises(ValueError):
            events._check(info, directory=True)
        info.st_file_attributes = 0
        events._check(info, directory=True)

    def test_oversized_or_nonregular_existing_files(self):
        self.assertTrue(self.emit())
        current = self.directory / 'session-123.jsonl'
        current.write_bytes(b'x' * (events.MAX_FILE_BYTES + 1))
        self.assertFalse(self.emit())
        self.assertEqual(current.stat().st_size, events.MAX_FILE_BYTES + 1)
        current.unlink()
        retained = self.directory / 'session-123.jsonl.1'
        retained.mkdir()
        self.assertFalse(self.emit())
        self.assertTrue(retained.is_dir())
        retained.rmdir()
        if hasattr(os, 'mkfifo'):
            os.mkfifo(current)
            started = time.monotonic()
            self.assertFalse(self.emit())
            self.assertLess(time.monotonic() - started, 1)

    def test_concurrent_bounded_append_and_rotation(self):
        # Seed near the actual cap so rotation is deterministic even if most
        # concurrent attempts lose the nonblocking lock.
        seeded = 0
        while not (self.directory / 'shared.jsonl').exists() or (self.directory / 'shared.jsonl').stat().st_size < events.MAX_FILE_BYTES - 1024:
            self.assertTrue(events.emit_handoff_event('progress', root=self.root,
                                                      session_id='shared', stage='scratch-stage',
                                                      request_id=f'seed-{seeded}'))
            seeded += 1
        # ProcessPoolExecutor joins all of its own workers on exit.
        with ProcessPoolExecutor(max_workers=4) as pool:
            counts = list(pool.map(writer, [(str(self.root), n) for n in range(4)]))
        self.assertGreater(sum(counts), 0)
        files = sorted(self.directory.glob('shared.jsonl*'))
        self.assertEqual(len(files), 2)  # positive rotation control under concurrency
        records = []
        for file in files:
            data = file.read_bytes()
            self.assertLessEqual(len(data), events.MAX_FILE_BYTES)
            self.assertTrue(data.endswith(b'\n'))
            for line in data.splitlines(keepends=True):
                self.assertLessEqual(len(line), events.MAX_EVENT_BYTES)
                records.append(json.loads(line))
        ids = [row['request_id'] for row in records]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertLessEqual(len(ids), sum(counts) + seeded)
        self.assertTrue(all(row['event'] == 'progress' for row in records))
        self.assertTrue(events.emit_handoff_event('progress', root=self.root,
                                                  session_id='shared', stage='scratch-stage'))


if __name__ == '__main__':
    unittest.main(verbosity=2)

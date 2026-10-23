"""Small, observational, best-effort handoff diagnostic writer.

No runtime, IPC, provider or policy dependencies. The lock never waits; ordinary
filesystem calls can still stall. Success means an append completed, not durable
storage (there is deliberately no fsync). Invalid records are dropped in full.
"""

from contextlib import contextmanager
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import stat

SCHEMA_VERSION = 1
MAX_FILE_BYTES = 256 * 1024
MAX_EVENT_BYTES = 4096
MAX_NUMBER = 2**53 - 1
EVENTS = frozenset({
    'observation', 'due_latched', 'instruction_emitted', 'gate_denied',
    'progress', 'continuation_requested', 'continuation_stopped', 'blocked',
    'takeover_verified', 'failure',
})
REASONS = frozenset({
    'threshold_reached', 'already_due', 'unknown_usage', 'ordinary_work_denied',
    'no_progress', 'settings_unavailable', 'authority_blocked', 'transport_failure',
    'takeover_verified', 'not_registered', 'disabled', 'diagnostics_unavailable',
    'continuation_limit', 'owner_stop', 'headroom_unavailable', 'progress_changed',
    # Exact context-budget/autopilot producer decisions; keep strict rejection of unknown reasons.
    'first_warn', 'canonical_progress', 'state_io', 'progress_unavailable', 'handoff_due',
    'not_due', 'not_ready', 'canonical_blocker', 'headroom_unknown', 'headroom_low',
    'stop_active', 'settings_blocked', 'handoff_only', 'exact_takeover', 'explicit_blocker',
})
ENUM_FIELDS = {
    'estimate_state': frozenset({'estimated', 'unknown'}),
    'estimate_reason': frozenset({
        'server_reasoning_unknown', 'server_reasoning_and_boundary_unknown',
        'unsupported_format', 'output_truncation_unknown', 'scan_limit', 'record_limit',
        'incomplete_history', 'compacted_history', 'ownership_unknown',
        'pending_output_unknown', 'unreadable_history', 'snapshot_changed', 'stale_usage',
    }),
    'metric_source': frozenset({'provider_last_usage', 'claude_input_usage', 'unavailable'}),
    'phase': frozenset({'prepared', 'dispatching', 'submitted', 'bound', 'taking-over',
                        'taken-over', 'uncertain', 'checkpoint', 'none'}),
    'reason': REASONS,
    'hook_event': frozenset({'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop'}),
    'error_type': frozenset({'OSError', 'PermissionError', 'FileNotFoundError',
                            'FileExistsError', 'NotADirectoryError', 'IsADirectoryError',
                            'BlockingIOError', 'TimeoutError', 'ConnectionError',
                            'ValueError', 'TypeError', 'RuntimeError', 'Failure', 'UsageError'}),
}
NUMERIC_FIELDS = frozenset({
    'tokens', 'window', 'warn', 'block', 'due_since_tokens', 'no_progress_count',
    'stop_continuations', 'metric_age_seconds',
    'estimate_lower_tokens', 'estimate_upper_tokens', 'estimate_provider_tokens',
    'estimate_local_tail_tokens', 'estimate_prior_reasoning_tokens',
})
_ID = re.compile(r'[A-Za-z0-9][A-Za-z0-9_-]{0,95}', re.ASCII)
_TIMESTAMP = re.compile(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z', re.ASCII)
_RESERVED = frozenset({'CON', 'PRN', 'AUX', 'NUL', 'CLOCK$', 'CONIN$', 'CONOUT$'} |
                      {f'{prefix}{n}' for prefix in ('COM', 'LPT') for n in range(10)})


def _safe_id(value):
    return type(value) is str and _ID.fullmatch(value) is not None and value.upper() not in _RESERVED


def _record(event, session_id, stage, turn_id, fields):
    if type(event) is not str or event not in EVENTS:
        raise ValueError('event')
    if not _safe_id(session_id) or not _safe_id(stage) or (turn_id is not None and not _safe_id(turn_id)):
        raise ValueError('identifier')
    record = {'schema_version': SCHEMA_VERSION,
              'created_at': datetime.now(timezone.utc).isoformat(timespec='microseconds').replace('+00:00', 'Z'),
              'event': event, 'session_id': session_id, 'stage': stage}
    if turn_id is not None:
        record['turn_id'] = turn_id
    for key, value in fields.items():
        if key in ENUM_FIELDS:
            valid = type(value) is str and value in ENUM_FIELDS[key]
        elif key in NUMERIC_FIELDS:
            valid = type(value) in (int, float) and 0 <= value <= MAX_NUMBER and math.isfinite(value)
        elif key == 'request_id':
            valid = _safe_id(value)
        elif key in ('metric_at', 'observed_at'):
            valid = type(value) is str and len(value) <= 27 and _TIMESTAMP.fullmatch(value) is not None
            if valid:
                datetime.fromisoformat(value.replace('Z', '+00:00'))
        else:
            valid = False
        if not valid:
            raise ValueError('field')
        record[key] = value
    line = (json.dumps(record, ensure_ascii=True, separators=(',', ':'), allow_nan=False) + '\n').encode('utf-8')
    if len(line) > MAX_EVENT_BYTES:
        raise ValueError('record size')
    return line


def _check(info, directory=False):
    if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
        raise ValueError('link or reparse point')
    if directory:
        if not stat.S_ISDIR(info.st_mode):
            raise ValueError('directory')
    elif not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError('regular unshared file')


@contextmanager
def _windows_directory(root):
    # Pin every directory against rename/deletion, including existing ancestors.
    # OPEN_REPARSE_POINT lets us reject junctions rather than traversing them.
    import ctypes
    from ctypes import wintypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    create = kernel.CreateFileW
    create.argtypes = (wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                       wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE)
    create.restype = wintypes.HANDLE
    close = kernel.CloseHandle
    close.argtypes = (wintypes.HANDLE,)
    close.restype = wintypes.BOOL
    handles = []
    try:
        path = Path(root.anchor)
        parts = list(root.parts[1:]) + ['.state', 'handoff-events']
        for index in range(len(parts) + 1):
            if index:
                path = path / parts[index - 1]
                if index > len(parts) - 2:
                    try:
                        path.mkdir(mode=0o700)
                    except FileExistsError:
                        pass
            handle = create(str(path), 0, 3, None, 3, 0x02200000, None)
            if handle == wintypes.HANDLE(-1).value:
                raise OSError('directory open')
            handles.append(handle)
            _check(path.lstat(), directory=True)
        yield path, None
    finally:
        for handle in reversed(handles):
            close(handle)


def _root_path(root):
    root = Path(root)
    if not root.is_absolute() or '..' in root.parts:
        raise ValueError('absolute resolved root required')
    if os.name == 'nt':
        # Do not accept UNC/device namespaces or alternate data stream syntax.
        if not re.fullmatch(r'[A-Za-z]:\\', root.anchor) or any(':' in p or p.endswith((' ', '.')) for p in root.parts[1:]):
            raise ValueError('root namespace')
    return root


@contextmanager
def _directory(root):
    # The configured hub root is trusted, including aliases in its ancestors.
    # Resolve it once, then pin the canonical path with no-follow opens. Aliases
    # below that boundary (.state, handoff-events and files) remain forbidden.
    # Validate both spellings so resolution cannot sanitize a forbidden namespace.
    root = _root_path(os.path.realpath(_root_path(root)))
    if os.name == 'nt':
        with _windows_directory(root) as location:
            yield location
        return
    descriptors = []
    try:
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK
        descriptor = os.open(root.anchor, flags)
        descriptors.append(descriptor)
        parts = list(root.parts[1:]) + ['.state', 'handoff-events']
        for index, part in enumerate(parts):
            if index >= len(parts) - 2:
                try:
                    os.mkdir(part, 0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
            descriptor = os.open(part, flags, dir_fd=descriptor)
            descriptors.append(descriptor)
            _check(os.fstat(descriptor), directory=True)
        yield root / '.state' / 'handoff-events', descriptor
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def _open(directory, descriptor, name, flags):
    if descriptor is not None:
        fd = os.open(name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=descriptor)
    else:
        # Native no-follow file open; CRT os.open alone follows Windows reparse points.
        import ctypes
        from ctypes import wintypes
        import msvcrt
        create = ctypes.WinDLL('kernel32', use_last_error=True).CreateFileW
        create.argtypes = (wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                           wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE)
        create.restype = wintypes.HANDLE
        handle = create(str(directory / name), 0xC0000000, 3, None,
                        1 if flags & os.O_EXCL else 4, 0x00200000, None)
        if handle == wintypes.HANDLE(-1).value:
            raise OSError('file open')
        try:
            fd = msvcrt.open_osfhandle(handle, os.O_RDWR | os.O_BINARY)
        except Exception:
            ctypes.WinDLL('kernel32').CloseHandle(wintypes.HANDLE(handle))
            raise
    try:
        _check(os.fstat(fd))
        # lstat additionally detects a Windows reparse handle and replaced names.
        info = os.stat(name, dir_fd=descriptor, follow_symlinks=False) if descriptor is not None else (directory / name).lstat()
        _check(info)
        if (info.st_dev, info.st_ino) != (os.fstat(fd).st_dev, os.fstat(fd).st_ino):
            raise ValueError('replaced file')
        if flags & os.O_APPEND:
            os.lseek(fd, 0, os.SEEK_END)
        return fd
    except Exception:
        os.close(fd)
        raise


def _existing(directory, descriptor, name):
    try:
        info = os.stat(name, dir_fd=descriptor, follow_symlinks=False) if descriptor is not None else (directory / name).lstat()
    except FileNotFoundError:
        return
    _check(info)
    if info.st_size > MAX_FILE_BYTES:
        raise ValueError('oversized file')


@contextmanager
def _locked(fd):
    if os.name == 'nt':
        import msvcrt
        if os.fstat(fd).st_size == 0:
            os.write(fd, b'0')
        os.lseek(fd, 0, os.SEEK_SET)
        msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
        try:
            yield
        finally:
            os.lseek(fd, 0, os.SEEK_SET)
            msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
    else:
        import fcntl
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)



def _append(fd, line):
    size = os.fstat(fd).st_size
    if os.write(fd, line) == len(line):
        return True
    # A short write (e.g. a full disk) must not poison the next JSONL append.
    # Rollback is best effort too; an I/O failure or process crash can leave a tail.
    os.ftruncate(fd, size)
    return False


def emit_handoff_event(event, *, root, session_id, stage, turn_id=None, **fields) -> bool:
    """Append one allowlisted event, or return False without emitting error text.

    Data files: <root>/.state/handoff-events/<session_id>.jsonl[.1].
    Each is at most 256 KiB; lines are at most 4 KiB. A stable per-session
    .lock file coordinates cooperating writers (never unlinked). No retries,
    fsync, threads, or changes to handoff/veto policy. Unknown fields reject
    the whole record; callers decide how to surface a False result safely.
    """
    try:
        line = _record(event, session_id, stage, turn_id, fields)
        with _directory(root) as (directory, descriptor):
            name = session_id + '.jsonl'
            retained = name + '.1'
            lock = _open(directory, descriptor, session_id + '.lock', os.O_RDWR | os.O_CREAT)
            try:
                if os.fstat(lock).st_size > 1:
                    return False
                with _locked(lock):
                    _existing(directory, descriptor, name)
                    _existing(directory, descriptor, retained)
                    fd = _open(directory, descriptor, name, os.O_WRONLY | os.O_CREAT | os.O_APPEND)
                    try:
                        rotate = os.fstat(fd).st_size + len(line) > MAX_FILE_BYTES
                        if not rotate:
                            return _append(fd, line)
                    finally:
                        os.close(fd)
                    if descriptor is not None:
                        os.replace(name, retained, src_dir_fd=descriptor, dst_dir_fd=descriptor)
                    else:
                        os.replace(directory / name, directory / retained)
                    fd = _open(directory, descriptor, name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_APPEND)
                    try:
                        return _append(fd, line)
                    finally:
                        os.close(fd)
            finally:
                os.close(lock)
    except Exception:
        # Never serialize exceptions: even their messages can contain secrets.
        return False

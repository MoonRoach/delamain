#!/usr/bin/env python3
"""Per-worker WSL loopback relay to the existing Windows system HTTP proxy.

No Windows listener, global proxy setting, auth access or TLS termination. The
worker is still exec'ed at its original PID. Its relay watches /proc start time
so normal exit, SIGKILL and PID reuse all remove owned helpers and the listener.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import selectors
import signal
import socket
import subprocess
import sys
import struct
from collections import deque
import time
from urllib.parse import urlsplit

PROXY_KEYS = ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy")
OWNER_KEY = "DELAMAIN_OWNED_PROXY"
MAX_CONNECTIONS = 32
CONNECT_TIMEOUT = 15
WINDOW = 65536
CHUNK = 32768
IDLE_TIMEOUT = 300
# Portable little-endian frame: kind (byte), connection (uint32), size (uint32).
HEADER = struct.Struct("<BII")
READY, OPEN, DATA, FIN, CLOSE, CREDIT = range(1, 7)


def owner_token(pid: int) -> str | None:
    try:
        # comm can contain spaces and parentheses. Fields start after the final ).
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        if fields[0] == "Z":
            return None
        return fields[19]  # field 22: starttime
    except (OSError, IndexError):
        return None


def powershell_command() -> list[str]:
    helper = Path(__file__).with_name("proxy_tcp.ps1")
    # Preparation commands must never consume the prompt intended for exec.
    windows = subprocess.check_output(["wslpath", "-a", "-w", str(helper)],
                                      stdin=subprocess.DEVNULL, text=True).strip()
    # WSL interop uses Windows PowerShell independently of Linux Python installs.
    return ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", windows]


def proxy_endpoint(settings: dict) -> tuple[str, int] | None:
    if not settings.get("enabled"):
        return None
    server = str(settings.get("server", "")).strip()
    if "=" in server:
        protocols = {}
        for part in server.split(";"):
            key, separator, value = part.partition("=")
            if separator:
                protocols[key.strip().lower()] = value.strip()
        if protocols.get("http") and protocols.get("https") and protocols["http"] != protocols["https"]:
            raise RuntimeError("Windows uses different HTTP and HTTPS proxy endpoints; set explicit worker proxy environment for that configuration.")
        # The relay's HTTP endpoint must be suitable for both HTTP and CONNECT.
        server = protocols.get("https") or protocols.get("http") or ""
    if not server:
        raise RuntimeError("Windows manual proxy is enabled without an HTTP endpoint; set an explicit worker proxy environment or correct Internet Settings.")
    parsed = urlsplit(server if "://" in server else "http://" + server)
    if parsed.scheme != "http" or parsed.username or parsed.password or not parsed.hostname or parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        raise RuntimeError("Windows proxy endpoint is unsupported; use an unauthenticated HTTP endpoint or explicit worker proxy environment.")
    try:
        port = parsed.port
        if port is None:
            port = 80
    except ValueError as error:
        raise RuntimeError("Windows proxy port is invalid.") from error
    if port < 1 or port > 65535:
        raise RuntimeError("Windows proxy port is invalid.")
    return parsed.hostname, port


def discover_proxy(command: list[str]) -> tuple[str, int] | None:
    try:
        result = subprocess.run([*command, "-Discover"], stdin=subprocess.DEVNULL,
                                capture_output=True, timeout=CONNECT_TIMEOUT, check=True)
        settings = json.loads(result.stdout.decode("utf-8-sig"))
        return proxy_endpoint(settings)
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        raise RuntimeError("Cannot discover the Windows system HTTP proxy; check WSL interoperability or set an explicit worker proxy environment.") from error


def clean_inherited_proxy(env: dict[str, str]) -> None:
    owned = env.pop(OWNER_KEY, None)
    if owned:
        for key in PROXY_KEYS:
            if env.get(key) == owned:
                del env[key]


def prepare_proxy(env: dict[str, str]) -> subprocess.Popen | None:
    clean_inherited_proxy(env)
    # Presence, even an empty value, is an explicit caller choice. NO_PROXY is
    # preserved verbatim and remains the HTTP client's bypass authority.
    if any(key in env for key in PROXY_KEYS):
        return None
    command = powershell_command()
    endpoint = discover_proxy(command)
    if endpoint is None:
        return None
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(MAX_CONNECTIONS)
    pid, token = os.getpid(), owner_token(os.getpid())
    if not token:
        listener.close()
        raise RuntimeError("Cannot establish worker lifetime for the Windows proxy relay.")
    read_fd, write_fd = os.pipe()
    relay = None
    try:
        relay = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--relay",
                                  str(listener.fileno()), str(write_fd), str(pid), token,
                                  endpoint[0], str(endpoint[1]), *command],
                                 pass_fds=(listener.fileno(), write_fd), stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, start_new_session=True)
        os.close(write_fd)
        write_fd = -1
        with selectors.DefaultSelector() as ready:
            ready.register(read_fd, selectors.EVENT_READ)
            if not ready.select(CONNECT_TIMEOUT) or os.read(read_fd, 1) != b"1":
                raise RuntimeError("Worker proxy relay failed to start; check Windows system proxy and WSL interoperability.")
        address = f"http://127.0.0.1:{listener.getsockname()[1]}"
        for key in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"):
            env[key] = address
        env[OWNER_KEY] = address
        return relay
    except BaseException:
        if relay:
            relay.terminate()
            try:
                relay.wait(timeout=3)
            except subprocess.TimeoutExpired:
                relay.kill()
                relay.wait()
        raise
    finally:
        listener.close()
        os.close(read_fd)
        if write_fd >= 0:
            os.close(write_fd)


def relay_main(args: list[str]) -> None:
    fd, ready_fd, pid = map(int, args[:3])
    token, host, port = args[3:6]
    command = [*args[6:], "-Multiplex", "-ProxyHost", host, "-ProxyPort", port]
    stopped = False

    def terminate(_signum, _frame):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    listener = socket.socket(fileno=fd)
    listener.setblocking(False)
    helper = None
    clients = {}
    closed = deque()
    order = deque()
    next_id = 1
    pending = bytearray()
    received = bytearray()
    ready = False
    stderr_open = True
    error_reported = False
    started = time.monotonic()

    def frame(kind, number, data=b""):
        return HEADER.pack(kind, number, len(data)) + data

    def close(number):
        state = clients.pop(number, None)
        if state:
            state["socket"].close()
            order.remove(number)
            closed.append(number)

    try:
        # Exactly one Windows process compiles the relay once for this worker.
        helper = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, bufsize=0)
        for pipe in (helper.stdin, helper.stdout, helper.stderr):
            os.set_blocking(pipe.fileno(), False)
        with selectors.DefaultSelector() as poll:
            while not stopped and owner_token(pid) == token:
                now = time.monotonic()
                if not ready and now - started > CONNECT_TIMEOUT:
                    raise RuntimeError("Windows relay startup timed out.")
                for number, state in list(clients.items()):
                    if now - state["activity"] > IDLE_TIMEOUT:
                        close(number)
                        continue
                    if state["remote_fin"] and not state["output"] and not state["write_closed"]:
                        try:
                            state["socket"].shutdown(socket.SHUT_WR)
                            state["write_closed"] = True
                        except OSError:
                            close(number)
                            continue
                    # Both FINs end the streams, but Windows may still have
                    # uploads queued/in flight. Only returned upload credit
                    # confirms network.Write consumed every accepted byte.
                    if state["sent_fin"] and state["write_closed"] and state["send_credit"] == WINDOW:
                        close(number)
                # One bounded frame in flight. Rotate connections so a slow
                # upstream cannot monopolize the shared stdio stream. Credit
                # is returned only after the receiving socket consumes bytes.
                if not pending:
                    if closed:
                        pending.extend(frame(CLOSE, closed.popleft()))
                    else:
                        for _ in range(len(order)):
                            number = order[0]
                            order.rotate(-1)
                            state = clients[number]
                            if not state["opened"]:
                                pending.extend(frame(OPEN, number))
                                state["opened"] = True
                            elif state["credit_due"]:
                                credit = state["credit_due"]
                                pending.extend(frame(CREDIT, number, struct.pack("<I", credit)))
                                state["receive_credit"] += credit
                                state["credit_due"] = 0
                            elif state["input"]:
                                data = state["input"][:CHUNK]
                                del state["input"][:len(data)]
                                pending.extend(frame(DATA, number, data))
                            elif state["local_fin"] and not state["sent_fin"]:
                                pending.extend(frame(FIN, number))
                                state["sent_fin"] = True
                            if pending:
                                break
                poll.register(helper.stdout, selectors.EVENT_READ, "stdout")
                if stderr_open:
                    poll.register(helper.stderr, selectors.EVENT_READ, "stderr")
                if pending:
                    poll.register(helper.stdin, selectors.EVENT_WRITE, "stdin")
                if ready:
                    poll.register(listener, selectors.EVENT_READ, "listener")
                for number, state in clients.items():
                    events = (selectors.EVENT_READ if not state["local_fin"] and state["send_credit"] else 0)
                    if state["output"]:
                        events |= selectors.EVENT_WRITE
                    if events:
                        poll.register(state["socket"], events, number)
                events = poll.select(0.25)
                for key in list(poll.get_map().values()):
                    poll.unregister(key.fileobj)
                for key, mask in events:
                    if key.data == "listener":
                        client, _ = listener.accept()
                        if len(clients) + len(closed) >= MAX_CONNECTIONS:
                            client.close()
                            continue
                        client.setblocking(False)
                        clients[next_id] = {"socket": client, "input": bytearray(), "output": bytearray(),
                            "send_credit": WINDOW, "receive_credit": WINDOW, "credit_due": 0,
                            "opened": False, "local_fin": False, "sent_fin": False,
                            "remote_fin": False, "write_closed": False, "activity": now}
                        order.append(next_id)
                        next_id += 1
                    elif key.data == "stdin":
                        sent = os.write(helper.stdin.fileno(), pending)
                        del pending[:sent]
                    elif key.data == "stderr":
                        data = os.read(helper.stderr.fileno(), CHUNK)
                        if not data:
                            stderr_open = False
                        elif not error_reported:
                            print("delamain worker proxy: Windows relay error; check the configured system HTTP proxy.", file=sys.stderr)
                            error_reported = True
                    elif key.data == "stdout":
                        # Read exactly one bounded frame, never an unbounded
                        # stream or queue supplied by a faulty helper.
                        need = HEADER.size - len(received) if len(received) < HEADER.size else HEADER.unpack_from(received)[2] + HEADER.size - len(received)
                        if need:
                            data = os.read(helper.stdout.fileno(), need)
                            if not data:
                                raise RuntimeError("Windows relay closed its output.")
                            received.extend(data)
                        if len(received) < HEADER.size:
                            continue
                        kind, number, size = HEADER.unpack_from(received)
                        if size > CHUNK:
                            raise RuntimeError("Invalid Windows relay frame size.")
                        if len(received) < HEADER.size + size:
                            continue
                        data = bytes(received[HEADER.size:])
                        received.clear()
                        if kind == READY and number == 0 and size == 0 and not ready:
                            ready = True
                            os.write(ready_fd, b"1")
                            os.close(ready_fd)
                            ready_fd = -1
                            continue
                        if not ready:
                            raise RuntimeError("Invalid Windows relay handshake.")
                        state = clients.get(number)
                        if state is None:
                            # Responses already in transit for a closed id.
                            continue
                        if kind == DATA and size and not state["remote_fin"] and size <= state["receive_credit"]:
                            state["output"].extend(data)
                            state["receive_credit"] -= size
                        elif kind == CREDIT and size == 4:
                            credit = struct.unpack("<I", data)[0]
                            if credit == 0 or state["send_credit"] + credit > WINDOW:
                                raise RuntimeError("Invalid Windows relay credit.")
                            state["send_credit"] += credit
                        elif kind == FIN and size == 0:
                            state["remote_fin"] = True
                        elif kind == CLOSE and size == 0:
                            close(number)
                        else:
                            raise RuntimeError("Invalid Windows relay frame.")
                        state["activity"] = now
                    else:
                        number = key.data
                        state = clients.get(number)
                        if state is None:
                            continue
                        try:
                            if mask & selectors.EVENT_READ:
                                data = state["socket"].recv(min(CHUNK, state["send_credit"]))
                                if data:
                                    state["input"].extend(data)
                                    state["send_credit"] -= len(data)
                                else:
                                    state["local_fin"] = True
                            if mask & selectors.EVENT_WRITE:
                                sent = state["socket"].send(state["output"][:CHUNK])
                                del state["output"][:sent]
                                state["credit_due"] += sent
                            state["activity"] = now
                        except (ConnectionError, OSError):
                            close(number)
    finally:
        listener.close()
        for state in clients.values():
            state["socket"].close()
        if ready_fd >= 0:
            os.close(ready_fd)
        if helper:
            # EOF is the Windows helper's ownership signal, including WSL
            # interop where terminating the Linux wrapper alone is insufficient.
            helper.stdin.close()
            helper.stdout.close()
            helper.stderr.close()
            try:
                helper.wait(timeout=3)
            except subprocess.TimeoutExpired:
                helper.terminate()
                try:
                    helper.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    helper.kill()
                    helper.wait()


def exec_worker(executable: str, args: list[str], env: dict[str, str]) -> None:
    relay = prepare_proxy(env)
    try:
        os.execvpe(executable, [executable, *args], env)
    finally:
        # Exec success never returns. Failure must clean the listener immediately.
        if relay:
            relay.terminate()
            try:
                relay.wait(timeout=5)
            except subprocess.TimeoutExpired:
                relay.kill()
                relay.wait()


if __name__ == "__main__":
    try:
        if sys.argv[1:2] == ["--relay"]:
            relay_main(sys.argv[2:])
        else:
            exec_worker(os.environ["DELAMAIN_LINUX_CODEX"], sys.argv[1:], dict(os.environ))
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        print(f"delamain worker proxy: {error}", file=sys.stderr)
        sys.exit(1)

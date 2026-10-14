#!/usr/bin/env python3
"""Drives agent-top in a pseudo-terminal: keys in, screen text out (a small VT100 emulator, no external deps).

  agent_top_pty.py peek ROOT [ROWS COLS] [KEYS...]   print the screen after the keys (names: UP DOWN ENTER ESC TAB PGUP PGDN HOME END, else literal text)
  agent_top_pty.py ui ROOT AGENT_STUB LOGFILE        the interactive scenarios of t_agent_top.sh (PASS/FAIL lines, exit 1 on any FAIL)
"""
import fcntl
import os
import re
import select
import struct
import subprocess
import sys
import termios
import time
import unicodedata

HERE = os.path.dirname(os.path.realpath(__file__))
TOP = os.path.join(HERE, "..", "bin", "agent-top")
KEYS = {"UP": b"\x1bOA", "DOWN": b"\x1bOB", "RIGHT": b"\x1bOC", "LEFT": b"\x1bOD", "ENTER": b"\r", "ESC": b"\x1b", "TAB": b"\t",
        "PGUP": b"\x1b[5~", "PGDN": b"\x1b[6~", "HOME": b"\x1bOH", "END": b"\x1bOF", "BS": b"\x7f"}


def cw(ch):
    if unicodedata.category(ch) in ("Mn", "Me", "Cf"):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


class Screen:
    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.grid = [[" "] * cols for _ in range(rows)]
        self.r = self.c = 0
        self.buf = ""
        self.top, self.bot = 0, rows - 1     # scroll region (ncurses uses it for hardware scrolling)

    def text(self):
        return "\n".join("".join(row).rstrip() for row in self.grid)

    def _scroll(self, n=1, down=False):
        for _ in range(n):
            if down:
                del self.grid[self.bot]
                self.grid.insert(self.top, [" "] * self.cols)
            else:
                del self.grid[self.top]
                self.grid.insert(self.bot, [" "] * self.cols)

    def _put(self, ch):
        w = cw(ch)
        if w == 0:
            return
        if self.c + w > self.cols:
            self.c, self.r = 0, self.r + 1
        if self.r > self.bot:
            self._scroll()
            self.r = self.bot
        self.grid[self.r][self.c] = ch
        if w == 2 and self.c + 1 < self.cols:
            self.grid[self.r][self.c + 1] = ""
        self.c += w

    def feed(self, data: bytes, state={"tail": b""}):
        data = state["tail"] + data
        try:
            s = data.decode("utf-8")
            state["tail"] = b""
        except UnicodeDecodeError as e:
            s = data[:e.start].decode("utf-8", "replace")
            state["tail"] = data[e.start:]
        s = self.buf + s
        self.buf = ""
        i = 0
        while i < len(s):
            ch = s[i]
            if ch == "\x1b":
                m = re.compile(r"\x1b\[([?>]?)([0-9;]*)([@-~])").match(s, i)
                if m:
                    self._csi(m.group(1), m.group(2), m.group(3))
                    i = m.end()
                    continue
                m2 = re.compile(r"\x1b[()][A-Z0-9]|\x1b[=>78M]").match(s, i)
                if m2:
                    if m2.group(0) == "\x1bM":
                        self.r = max(0, self.r - 1)
                    i = m2.end()
                    continue
                self.buf = s[i:]  # incomplete escape: wait for more
                return
            if ch == "\r":
                self.c = 0
            elif ch == "\n":
                if self.r == self.bot:
                    self._scroll()
                else:
                    self.r = min(self.rows - 1, self.r + 1)
            elif ch == "\b":
                self.c = max(0, self.c - 1)
            elif ch == "\t":
                self.c = min(self.cols - 1, (self.c // 8 + 1) * 8)
            elif ch in "\x0e\x0f\x07":
                pass
            elif ch >= " ":
                self._put(ch)
            i += 1

    def _csi(self, priv, params, fin):
        p = [int(x) if x else 0 for x in params.split(";")] if params else []
        n = p[0] if p and p[0] else 1
        if priv:
            return
        if fin in "Hf":
            self.r = min(self.rows - 1, max(0, (p[0] if p and p[0] else 1) - 1))
            self.c = min(self.cols - 1, max(0, (p[1] if len(p) > 1 and p[1] else 1) - 1))
        elif fin == "A":
            self.r = max(0, self.r - n)
        elif fin == "B":
            self.r = min(self.rows - 1, self.r + n)
        elif fin == "C":
            self.c = min(self.cols - 1, self.c + n)
        elif fin == "D":
            self.c = max(0, self.c - n)
        elif fin == "G":
            self.c = min(self.cols - 1, n - 1)
        elif fin == "d":
            self.r = min(self.rows - 1, n - 1)
        elif fin == "J":
            mode = p[0] if p else 0
            if mode in (2, 3):
                self.grid = [[" "] * self.cols for _ in range(self.rows)]
            elif mode == 0:
                self.grid[self.r][self.c:] = [" "] * (self.cols - self.c)
                for r in range(self.r + 1, self.rows):
                    self.grid[r] = [" "] * self.cols
        elif fin == "K":
            mode = p[0] if p else 0
            row = self.grid[self.r]
            if mode == 0:
                row[self.c:] = [" "] * (self.cols - self.c)
            elif mode == 1:
                row[:self.c + 1] = [" "] * (self.c + 1)
            else:
                self.grid[self.r] = [" "] * self.cols
        elif fin == "X":
            for k in range(self.c, min(self.cols, self.c + n)):
                self.grid[self.r][k] = " "
        elif fin == "P":
            row = self.grid[self.r]
            del row[self.c:self.c + n]
            row.extend([" "] * (self.cols - len(row)))
        elif fin == "@":
            row = self.grid[self.r]
            row[self.c:self.c] = [" "] * n
            del row[self.cols:]
        elif fin == "L":
            for _ in range(n):
                del self.grid[self.bot]
                self.grid.insert(self.r, [" "] * self.cols)
        elif fin == "M":
            for _ in range(n):
                del self.grid[self.r]
                self.grid.insert(self.bot, [" "] * self.cols)
        elif fin == "S":
            self._scroll(n)
        elif fin == "T":
            self._scroll(n, down=True)
        elif fin == "r":
            self.top = min(self.rows - 1, max(0, (p[0] if p and p[0] else 1) - 1))
            self.bot = min(self.rows - 1, max(self.top, (p[1] if len(p) > 1 and p[1] else self.rows) - 1))
            self.r = self.c = 0
        elif fin == "b":
            last = self.grid[self.r][self.c - 1] if self.c else " "
            for _ in range(n):
                self._put(last)


class Session:
    def __init__(self, argv, env, rows=24, cols=100, color=False):
        self.rows, self.cols = rows, cols
        self.raw = bytearray()
        self.master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        env = dict(env, TERM=os.environ.get("PEEK_TERM", "xterm-256color"), LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
        if not color:
            env["NO_COLOR"] = "1"
        else:
            env.pop("NO_COLOR", None)
        self.proc = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True, close_fds=True)
        os.close(slave)
        self.screen = Screen(rows, cols)

    def pump(self, secs=0.3):
        end = time.monotonic() + secs
        while time.monotonic() < end:
            r, _, _ = select.select([self.master], [], [], 0.05)
            if r:
                try:
                    data = os.read(self.master, 65536)
                except OSError:
                    return
                if not data:
                    return
                self.raw.extend(data)
                self.screen.feed(data)

    def wait_for(self, needle, timeout=8.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            self.pump(0.05)
            if re.search(needle, self.screen.text()):
                self.pump(0.3)      # let the rest of the frame arrive before the caller reads the screen
                return re.search(needle, self.screen.text()) is not None
        return False

    def settle(self, quiet=0.3, cap=6.0):
        """Pump until the screen has not changed for `quiet` s: a key's effect is on the screen before it is read. A fixed
        pause is not enough on a loaded machine, where the program may not get a turn for a while."""
        end = time.monotonic() + cap
        last, since = self.screen.text(), time.monotonic()
        while time.monotonic() < end:
            self.pump(0.05)
            cur = self.screen.text()
            if cur != last:
                last, since = cur, time.monotonic()
            elif time.monotonic() - since >= quiet:
                return

    def send(self, *keys):
        for k in keys:
            os.write(self.master, KEYS.get(k, k.encode("utf-8")))
            self.pump(0.12)
        self.settle()

    def text(self):
        return self.screen.text()

    def resize(self, rows, cols):
        import signal
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.rows, self.cols = rows, cols
        self.screen = Screen(rows, cols)
        os.killpg(self.proc.pid, signal.SIGWINCH)

    def wait_exit(self, timeout=5.0):
        try:
            return self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            return None

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
        os.close(self.master)


def peek(argv):
    root = argv[0]
    rows, cols = (int(argv[1]), int(argv[2])) if len(argv) >= 3 else (30, 110)
    keys = argv[3:]
    s = Session([sys.executable, TOP, "--interval", "0.5"], dict(os.environ, AGENT_HUB_HOME=root) if root != "-" else dict(os.environ), rows, cols)
    s.settle(0.8, cap=10.0)
    s.send(*keys)
    s.settle(0.6)
    print(s.text())
    s.send("q")
    print("exit:", s.wait_exit())
    s.close()



# ---------------------------------------------------------------- scenarios of t_agent_top.sh

FAILS = []


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else f"\n{extra}"))
    if not cond:
        FAILS.append(name)


def stub_calls(log):
    try:
        return [ln for ln in open(log, encoding="utf-8").read().splitlines() if ln.strip()]
    except OSError:
        return []


def run(argv):
    root, stub, log = argv
    env = dict(os.environ, AGENT_HUB_HOME=root, AGENT_TOP_AGENT_BIN=stub, AGENT_TOP_HUB_BIN=stub, STUB_LOG=log)
    for k in ("HUB_TAG", "CLAUDE_CODE_SESSION_ID", "HUB_STAGE", "AGENT_BOARD_FILE"):
        env.pop(k, None)

    def start(rows=30, cols=100, extra=(), color=False):
        s = Session([sys.executable, TOP, "--interval", "0.5", *extra], env, rows, cols, color)
        return s

    # list ------------------------------------------------------------------------------------------------
    s = start()
    ok = s.wait_for(r"alive1")
    t = s.text()
    check("ui list: agents shown, with the stage column", ok and re.search(r"● stage-a\s+alive1", t) and re.search(r"✗ stage-a\s+crash1", t)
          and re.search(r"✓ stage-a\s+done1", t) and re.search(r"✓ stage-b\s+b1", t), t)
    check("ui list: header counts live 2, failed 4", "● 2" in t and "✗ 4" in t, t.splitlines()[0])
    check("ui list: quiet agent flagged", re.search(r"quiet1\s+quiet", t) is not None, t)
    check("ui list: the key bar offers m, x and c (positive control for --read-only)", "m message" in t and "x stop" in t and "c close stage" in t, t)
    check("ui list: selected agent detail pane", "▸ Bash: run the tests" in t and "✉ 1 unread" in t, t)
    check("ui list: archive and old agents hidden", "oldie" not in t and "done1*" not in t, t)

    # agent view -------------------------------------------------------------------------------------------
    s.send("ENTER")
    check("ui agent: feed opens", s.wait_for(r"1 feed") and s.wait_for(r"run the tests"), s.text())
    t = s.text()
    check("ui agent: thoughts, commands, pending marker", "✎ Running the tests" in t and "▸ Bash: run the tests" in t and "⏳" in t, t)
    card = t.split("1 feed")[0]
    check("ui agent: card has the unread message, not the read one", "new message from the hub" in card and "old message" not in card, card)
    s.send("TAB")
    check("ui agent: brief tab", s.wait_for(r"Fixture brief alive1"), s.text())
    s.send("TAB")
    check("ui agent: inbox tab", s.wait_for(r"new message from the hub") and "old message" in s.text(), s.text())
    s.send("1", "]")
    check("ui agent: ] opens the next agent", s.wait_for(r"quiet1 · stage-a"), s.text())
    s.send("ESC", "UP")
    check("ui agent: Esc back to the list, UP selects the previous agent", s.wait_for(r"ROLE") and "▸ Bash: run the tests" in s.text(), s.text())

    # journal ----------------------------------------------------------------------------------------------
    s.send("j")
    check("ui journal: lines of both stages", s.wait_for(r"ran the tests") and "[hub-t]" in s.text() and "a line of stage-b" in s.text(), s.text())
    s.send("t")
    t = s.text()
    check("ui journal: tag filter keeps the tag and @mentions", "ran the tests" in t and "check the inbox" in t and "DONE task 1" not in t, t)
    s.send("c")
    check("ui journal: filter cleared", "DONE task 1" in s.text(), s.text())
    s.send("/", "subtag", "ENTER")
    t = s.text()
    check("ui journal: text filter", "subtag line" in t and "ran the tests" not in t, t)
    s.send("c", ",")
    check("ui journal: yesterday is empty", "(empty)" in s.text(), s.text())
    s.send(".", "ESC")

    # summary + help ---------------------------------------------------------------------------------------
    s.send("s")
    t = s.text() if s.wait_for(r"Locks") else s.text()
    check("ui summary: locks, questions, hub", "main-merge" in t and "(expired)" in t and "overdue 1" in t and "* hub [hub-t]" in t, t)
    s.send("ESC", "?")
    check("ui help opens", s.wait_for(r"what the agents are doing"), s.text())
    s.send("x")  # any key closes help (x here must NOT start an action)
    check("ui help: key returns to the list", "STOP" not in s.text() and s.wait_for(r"ROLE"), s.text())

    # message: positive and negative ------------------------------------------------------------------------
    s.send("m")
    check("ui send: prompt", s.wait_for(r"message to alive1:"), s.text())
    s.send("hello agent", "ENTER")
    t = s.text()
    check("ui send: confirmation names the target and the effect", "send to alive1" in t and "goes to its inbox" in t and "[y/N]" in t, t)
    check("ui send: nothing sent before the answer", stub_calls(log) == [], str(stub_calls(log)))
    s.send("n")
    check("ui send: n cancels", s.wait_for(r"cancelled") and stub_calls(log) == [], s.text() + str(stub_calls(log)))
    s.send("m", "do not send", "ESC")
    check("ui send: Esc cancels input", stub_calls(log) == [], str(stub_calls(log)))
    s.send("m", "ENTER")
    check("ui send: empty message refused", "empty message" in s.text() or s.wait_for(r"empty message"), s.text())
    s.send("m", "second message", "ENTER", "y")
    check("ui send: y runs agent send", s.wait_for(r"✓ send alive1"), s.text())
    calls = stub_calls(log)
    check("ui send: exact argv, owner tag", calls == ["HUB_TAG=owner send alive1 --stage stage-a -- second message"], str(calls))

    # stop -------------------------------------------------------------------------------------------------
    s.send("x")
    t = s.text()
    check("ui stop: confirmation", "STOP" in t and "alive1" in t and "[y/N]" in t, t)
    s.send("n")
    check("ui stop: n cancels", stub_calls(log) == calls, str(stub_calls(log)))
    s.send("x", "y")
    check("ui stop: y runs agent stop", s.wait_for(r"✓ stop alive1"), s.text())
    calls = stub_calls(log)
    check("ui stop: exact argv", calls[-1:] == ["HUB_TAG=owner stop alive1 --stage stage-a"] and len(calls) == 2, str(calls))

    # close a stage (`hub close`, the stub stands in) --------------------------------------------------------
    s.send("c")
    check("ui close: asks which stage, the selected agent's prefilled", s.wait_for(r"close stage \(Enter, Esc cancels\): stage-a"), s.text())
    s.send("ENTER")
    t = s.text()
    check("ui close: confirmation names the stage and its live agents", "CLOSE stage stage-a" in t and "live agent" in t and "[y/N]" in t, t)
    s.send("n")
    check("ui close: n cancels", stub_calls(log) == calls, str(stub_calls(log)))
    s.send("c", "BS", "BS", "x", "ENTER")
    check("ui close: an unknown stage is refused", s.wait_for(r"no stage 'stagex' in this view") and stub_calls(log) == calls, s.text())
    s.send("c", "ENTER", "y")
    check("ui close: y runs hub close", s.wait_for(r"✓ close stage-a"), s.text())
    calls = stub_calls(log)
    check("ui close: exact argv", calls[-1:] == ["HUB_TAG= close --stage stage-a --why closed from agent-top"] and len(calls) == 3, str(calls))

    # message to a dead agent warns about the resume; nothing sent ------------------------------------------
    s.send("DOWN", "DOWN")
    s.send("m", "x", "ENTER")
    t = s.text()
    check("ui send to a dead agent: warns that the session is resumed", "crash1" in t and "RESUMED" in t, t)
    s.send("n")

    # all agents -------------------------------------------------------------------------------------------
    s.send("a")
    check("ui a: old and archived agents appear", s.wait_for(r"oldie") and "done1*" in s.text(), s.text())
    s.send("a")
    s.settle(0.8)
    check("ui a: toggles back", "oldie" not in s.text(), s.text())
    check("ui: no action leaked into the stub", len(stub_calls(log)) == 3, str(stub_calls(log)))
    s.send("q")
    check("ui q: exit code 0", s.wait_exit() == 0)
    s.close()

    # narrow terminal --------------------------------------------------------------------------------------
    s = start(12, 50)
    check("ui narrow 50x12: list renders", s.wait_for(r"alive1"), s.text())
    s.send("ENTER")
    check("ui narrow: agent view renders", s.wait_for(r"1 feed"), s.text())
    s.send("j", "s", "?", "q")
    check("ui narrow: journal/summary/help/quit without a crash", s.wait_exit() == 0, s.text())
    s.close()

    # resize -----------------------------------------------------------------------------------------------
    s = start(30, 120)
    s.wait_for(r"alive1")
    wide = s.text()
    s.resize(12, 50)
    s.settle(0.8, cap=10.0)
    t = s.text()
    check("ui resize: the layout follows the terminal (12x50: no stage/tag/model columns, key bar fits)",
          "alive1" in t and "STATUS" not in t and "MODEL" not in t and len(t.splitlines()) <= 12 and all(len(l) <= 50 for l in t.splitlines()), t)
    check("ui resize: the wide layout had them", "STATUS" in wide and "MODEL" in wide, wide)
    s.resize(30, 130)
    s.settle(0.8, cap=10.0)
    check("ui resize back: wide layout again", "MODEL" in s.text() and "NOW / LAST" in s.text(), s.text())
    s.send("q")
    check("ui resize: quits cleanly", s.wait_exit() == 0)
    s.close()

    # colours (the other tests run with NO_COLOR) -------------------------------------------------------------
    s = start(30, 100, color=True)
    s.wait_for(r"alive1")
    s.send("ENTER", "TAB", "TAB", "1", "ESC", "j", "s", "?")
    s.send("x")
    s.settle(0.5)
    raw = bytes(s.raw)
    check("ui colour: green for live and red for failed agents are emitted",
          re.search(rb"\x1b\[(?:[0-9;]*;)?32m", raw) is not None and re.search(rb"\x1b\[(?:[0-9;]*;)?31m", raw) is not None)
    s.send("q")
    check("ui colour: every view renders without an exception, exit 0", s.wait_exit() == 0, s.text())
    s.close()

    # read-only --------------------------------------------------------------------------------------------
    before = stub_calls(log)
    s = start(extra=("--read-only",))
    s.wait_for(r"alive1")
    check("ui read-only: key bar has no m/x/c", "m message" not in s.text() and "x stop" not in s.text() and "c close" not in s.text(), s.text())
    s.send("m")
    check("ui read-only: m refused", s.wait_for(r"read-only"), s.text())
    s.send("x")
    s.send("y")
    s.send("c")
    check("ui read-only: c refused", s.wait_for(r"read-only"), s.text())
    s.send("ENTER", "y")
    check("ui read-only: nothing sent, stopped or closed", stub_calls(log) == before, str(stub_calls(log)))
    s.send("q")
    s.wait_exit()
    s.close()
    return 1 if FAILS else 0


if __name__ == "__main__":
    if sys.argv[1] == "peek":
        peek(sys.argv[2:])
    elif sys.argv[1] == "ui":
        sys.exit(run(sys.argv[2:]))

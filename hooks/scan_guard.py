#!/usr/bin/env python3
"""Scan guard: a PreToolUse hook that refuses a filesystem walk rooted at the home directory or at `/`.

On macOS such a walk enters ~/Library — Mail, Messages, Safari, Containers — which App Data TCC protects: the system
asks "claude.app would like to access data from other apps", and the consent is not kept across agent processes, so
the prompt comes back every few minutes (15.10: five prompts in an hour, one of them from `find ~ -name hive1.py` in a
background session). Full Disk Access would end the prompt by letting every agent that runs without questions read
mail, messages and cookies, so the walk is refused instead and the agent is told where to search.

Refused, when the walk root is `~`, `$HOME`, `${HOME}`, the absolute home path, `/`, `/Users`, `~/Library`,
`~/Library/Containers`, `~/Library/Group Containers`, or a glob that reaches one of them (`~/*`, `/*`, `~/Library/*`):

* Bash: `find`, `bfs`, `fd`, `rg`, `grep -r` (`-R`, `--recursive`, `-d recurse`), `ag`, `ack`, `du`, `tree` and `ls -R`,
  also behind `sudo` / `env` / `timeout` / `nohup` / `xargs` / `eval` / `if !` / `VAR=x`, in a pipeline, after `&&` or
  `;`, inside `$(…)` and `bash -c "…"`; a walker with no root, or `.`, while the working directory is the home — the
  session's own, or after `cd ~` / `cd $HOME` / `cd` earlier in the command;
* the Grep and Glob tools: `path` is one of those roots, or absent while the session's directory is the home; Glob's
  `pattern` may also name the root (`~/**/x`).

Not refused: a named subdirectory (`find ~/repos`, `rg foo ~/agent-hub`, `find ~/Library/LaunchAgents`), the project, a
walk that stays on the first level (`find ~ -maxdepth 1`, `fd -d 1`, `tree -L 1`), `ls ~`, a file (`grep foo
~/.zshrc`), quoted text no shell runs, a segment that starts with `ssh` (it walks another machine's disk), a word the
hook cannot resolve without running something (`$(…)`, `$VAR`, `~user`), and a command that carries the marker
`# scan-ok` (AGENT_HUB_SCAN_ESCAPE) — for a walk the owner asked for. The Grep and Glob tools have no marker.

What it does not catch: arguments it cannot read — a script (`python3 -c "os.walk(…)"`, `node -e`), `cp -r`, `rsync`,
`tar`, `zip`, `chmod -R` and other tools that walk a tree as a side effect, `git -C ~ …`, a path built by a variable or
a substitution. It is a guard against the habit, not a sandbox.

Settings (environment, or the hub home's config.json):
  AGENT_HUB_SCAN_GUARD   on | off (default on)
  AGENT_HUB_SCAN_ESCAPE  scan-ok
Fail-open: an error of its own never blocks a call.
"""
from __future__ import annotations

if __name__ == "__main__":  # fail-safe first, before anything that can fail: see hooks/failsafe.py
    try:
        import failsafe

        failsafe.install()
    except Exception:  # noqa: BLE001 — without it the hook is as it was
        pass

import fnmatch
import json
import os
import re
import sys

import kill_guard as kg
import polling_guard as pg

DEFAULT_ESCAPE = "scan-ok"
_MAX_NESTING = 8
_MAX_GROUPS = 64  # `((((…`: more open parentheses than this are not tracked
_TOK = re.compile(r"\x01(\d+)\x01")
_VAR = re.compile(r"\$(?:\{(\w+)\}|(\w+))")
_ASSIGN = re.compile(r"^\w+(?:\[[^\]]*\])?\+?=")
_REDIRECT = re.compile(r"^(?:\d*|&)(<{1,3}|>{1,2}\|?|[<>]&)(.*)$")
_GLOB_CHARS = "*?["

INSTEAD = """Instead: search the project, the hub home (`$AGENT_HUB_HOME`, default `~/agent-hub`) or a named subdirectory \
(`find ~/repos -name x`); to find a file by name anywhere, `mdfind -name <file>` reads the Spotlight index and walks nothing."""


class _W(str):
    """A shell word as the program sees it (quotes and backslashes removed); `.raw` is the word as typed, with the
    quoted strings still in their tokens: expansion needs to know what was quoted."""

    raw = ""


class _Ctx:
    """What a check needs to resolve paths: the homes, the refused roots, the working directory, the data strings."""

    def __init__(self, cwd):
        env_home = os.environ.get("HOME") or ""
        found = [env_home, os.path.expanduser("~")]
        try:
            import pwd

            found.append(pwd.getpwuid(os.getuid()).pw_dir)
        except Exception:  # noqa: BLE001 — no pwd database (Windows): the environment's home alone
            pass
        self.homes = []
        for h in found:
            if h.startswith("/") and _norm(h) != "/" and _norm(h) not in self.homes:
                self.homes.append(_norm(h))
        self.home = _norm(env_home) if env_home.startswith("/") and _norm(env_home) != "/" else (self.homes[0] if self.homes else None)
        self.cwd = _norm(cwd) if isinstance(cwd, str) and cwd.startswith("/") else None
        self.data = []
        # the refused roots, case-folded (the usual macOS volume is case-insensitive), and why each one is refused
        self.targets = {"/": "the whole filesystem", "/users": "/Users, where every home lives"}
        for h in self.homes:
            self.targets[h.casefold()] = "your home directory"
            for sub in ("Library", "Library/Containers", "Library/Group Containers"):
                self.targets[(h + "/" + sub).casefold()] = f"~/{sub}, where other apps keep their data"
        self.segments = [(k.split("/"), why) for k, why in self.targets.items()]

    def text(self, token: str) -> str:
        """A token's string with its quotes, or "" for a token that is not one of ours."""
        m = _TOK.fullmatch(token)
        return self.data[int(m.group(1))] if m and int(m.group(1)) < len(self.data) else ""

    def restore(self, text: str) -> str:
        return _TOK.sub(lambda m: self.data[int(m.group(1))] if int(m.group(1)) < len(self.data) else "", text)


def _norm(path: str) -> str:
    return os.path.normpath(re.sub(r"^/{2,}", "/", path))


# -- words ---------------------------------------------------------------------------------------------------------

def _plain(ctx: _Ctx, raw: str) -> str:
    out, i, n = [], 0, len(raw)
    while i < n:
        c = raw[i]
        m = _TOK.match(raw, i) if c == "\x01" else None
        if m:
            out.append(pg._unquote(ctx.data[int(m.group(1))]) if int(m.group(1)) < len(ctx.data) else "")
            i = m.end()
        elif c == "\\" and i + 1 < n:
            out.append(raw[i + 1])
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _word(ctx: _Ctx, raw: str) -> _W:
    w = _W(_plain(ctx, raw))
    w.raw = raw
    return w


def _words(ctx: _Ctx, stage: str) -> list:
    """The words of a stage; an escaped blank stays inside its word, a quoted string is one token."""
    out, buf, i, n = [], [], 0, len(stage)
    while i < n:
        c = stage[i]
        if c == "\\" and i + 1 < n:
            buf.append(stage[i:i + 2])
            i += 2
        elif c in " \t\r\n":
            if buf:
                out.append(_word(ctx, "".join(buf)))
                buf = []
            i += 1
        else:
            buf.append(c)
            i += 1
    if buf:
        out.append(_word(ctx, "".join(buf)))
    return out


def _var(ctx: _Ctx, text: str, i: int, cwd):
    """(value, end) of the `$HOME` / `${HOME}` / `$PWD` at `text[i]`, or None for any other expansion."""
    m = _VAR.match(text, i)
    if not m:
        return None  # `$(`, `$$`, `$?` …
    name = m.group(1) or m.group(2)
    value = ctx.home if name == "HOME" else cwd if name == "PWD" else None
    return (value, m.end()) if value else None


def _expand(ctx: _Ctx, raw: str, cwd, shell: bool = True):
    """(absolute path pattern, has a glob) of a word, or None when it cannot be told without running something: a
    substitution, another variable, `~user`, a brace list. `shell=False` reads a tool's `path` — literal text, where
    only the leading `~` and `$HOME` mean anything."""
    out = []  # (char, inert): an inert char — quoted, escaped, or from an expansion — is never a glob
    i, n = 0, len(raw)
    while i < n:
        c = raw[i]
        if c == "\x01" and shell:
            m = _TOK.match(raw, i)
            quoted = ctx.text(m.group(0)) if m else ""
            if not quoted:
                return None
            body, j = quoted[1:-1], 0
            while j < len(body):
                ch = body[j]
                if quoted[0] == "'":
                    out.append((ch, True))
                    j += 1
                elif ch == "\\" and body[j + 1:j + 2] in ('"', "\\", "$", "`"):
                    out.append((body[j + 1], True))
                    j += 2
                elif ch == "$":
                    got = _var(ctx, body, j, cwd)
                    if got is None:
                        return None
                    out.extend((x, True) for x in got[0])
                    j = got[1]
                elif ch == "`":
                    return None
                else:
                    out.append((ch, True))
                    j += 1
            i = m.end()
        elif c == "\\" and shell:
            if i + 1 < n:
                out.append((raw[i + 1], True))
            i += 2
        elif c == "~" and i == 0:
            m = re.match(r"~(\+?)(?=/|$)", raw)
            base = (cwd if m and m.group(1) else ctx.home) if m else None
            if not base:
                return None
            out.extend((x, True) for x in base)
            i = m.end()
        elif c == "$":
            got = _var(ctx, raw, i, cwd)
            if got is None:
                return None
            out.extend((x, True) for x in got[0])
            i = got[1]
        elif c == "`" and shell:
            return None
        elif c == "{" and shell and raw[i:i + 2] != "{}":
            return None  # a brace list expands into several words
        else:
            out.append((c, not shell))
            i += 1
    if not out:
        return None
    if out[0][0] != "/":
        if not cwd:
            return None
        out = [(x, True) for x in cwd + "/"] + out
    glob = any(ch in _GLOB_CHARS and not inert for ch, inert in out)
    pattern = "".join(f"[{ch}]" if inert and ch in _GLOB_CHARS else ch for ch, inert in out)
    return _norm(pattern), glob


def _hit(ctx: _Ctx, word_raw: str, cwd, shell: bool = True):
    """Why the root a word names is refused, or None."""
    res = _expand(ctx, word_raw, cwd, shell)
    if not res:
        return None
    pattern, glob = res
    key = pattern.casefold()
    if not glob:
        return ctx.targets.get(key)
    parts = key.split("/")
    for segs, why in ctx.segments:
        if len(segs) == len(parts) and all(fnmatch.fnmatchcase(s, p) for s, p in zip(segs, parts)):
            return why + ", through a glob"
    return None


# -- commands ------------------------------------------------------------------------------------------------------

_KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "(", "time", "exec", "nohup", "setsid", "eval",
             "builtin", "noglob", "nocorrect", "caffeinate", "unbuffer", "coproc"}


def _skip_flags(words, i: int, valued=()) -> int:
    """The index after the option words that start at `i`; an option in `valued` takes the next word too."""
    n = len(words)
    while i < n and words[i].startswith("-") and len(words[i]) > 1:
        if words[i] == "--":
            return i + 1
        i += 2 if words[i] in valued else 1
    return i


def _strip_redirects(words):
    """(words without redirections, the stdin is redirected from a file)."""
    out, stdin, i = [], False, 0
    while i < len(words):
        m = _REDIRECT.match(words[i])
        if m:
            stdin = stdin or m.group(1).startswith("<")
            i += 1 if m.group(2) else 2
        else:
            out.append(words[i])
            i += 1
    return out, stdin


def _command(words):
    """(name, arguments, via xargs) of the command a stage runs: assignments, keywords and wrappers are skipped. None
    for a stage that runs nothing a walk could come from."""
    # a group opener glued to the command word: `(find ~ …`
    if words and words[0].startswith("(") and len(words[0]) > 1:
        head = _W(words[0].lstrip("("))
        head.raw = words[0].raw.lstrip("(")
        words = [head] + words[1:]
    n, i, xargs = len(words), 0, False
    while i < n:
        w = words[i]
        if w in _KEYWORDS or _ASSIGN.match(w):
            i += 1
        elif w in ("sudo", "doas"):
            i = _skip_flags(words, i + 1, ("-u", "-g", "-C", "-D", "-h", "-p", "-R", "-r", "-t", "-U", "-T"))
        elif w == "env":
            i = _skip_flags(words, i + 1, ("-u", "-C", "-S", "-P"))
        elif w == "timeout":
            i = _skip_flags(words, i + 1, ("-k", "-s")) + 1
        elif w in ("nice", "ionice", "stdbuf"):
            i = _skip_flags(words, i + 1, ("-n", "-c", "-p"))
        elif w == "xargs":
            xargs = True
            i = _skip_flags(words, i + 1, ("-I", "-J", "-L", "-n", "-P", "-s", "-d", "-E", "-a", "-R", "-S"))
        elif w == "command":
            if i + 1 < n and words[i + 1] in ("-v", "-V"):
                return None  # only looks the name up
            i += 1
        else:
            break
    if i >= n:
        return None
    name = str(words[i]).rsplit("/", 1)[-1]
    return name, list(words[i + 1:]), xargs


class _Walk:
    def __init__(self, roots, depth=None, stdin_default=False, base=None):
        self.roots, self.depth, self.stdin_default, self.base = roots, depth, stdin_default, base


def _parse(args, short_val="", long_val=()):
    """([(option, value)], [positional words]). A short cluster (`-rn`, `-A3`) is read letter by letter; a letter in
    `short_val` takes the rest of the word or the next word; `--name=value` and, for a name in `long_val`, `--name
    value`. `--` ends the options. GNU and BSD tools both let options follow the operands."""
    opts, pos, i, n = [], [], 0, len(args)
    while i < n:
        w = args[i]
        i += 1
        if w == "--":
            pos.extend(args[i:])
            break
        if w.startswith("--"):
            name, eq, val = w[2:].partition("=")
            if not eq and name in long_val and i < n:
                val = args[i]
                i += 1
            opts.append((name, val if (eq or name in long_val) else None))
        elif w.startswith("-") and len(w) > 1:
            j = 1
            while j < len(w):
                c = w[j]
                j += 1
                if c in short_val:
                    val = w[j:]
                    if not val and i < n:
                        val = args[i]
                        i += 1
                    opts.append((c, val))
                    break
                opts.append((c, None))
        else:
            pos.append(w)
    return opts, pos


def _int(opts, *names):
    for name, val in opts:
        if name in names and val is not None and str(val).strip().lstrip("+").isdigit():
            return int(str(val).strip().lstrip("+"))
    return None


def _has(opts, *names) -> bool:
    return any(name in names for name, _ in opts)


def _value(opts, *names):
    return next((v for name, v in opts if name in names and v is not None), None)


_FIND_FLAGS = {"-H", "-L", "-P", "-E", "-X", "-x", "-s", "-d", "-color", "-nocolor", "-mount", "-unique"}


def _find(args):
    roots, i, n = [], 0, len(args)
    while i < n:
        w = args[i]
        if w in _FIND_FLAGS or re.fullmatch(r"-O\d?|-j\d*", w):
            i += 1
        elif w in ("-D", "-S"):
            i += 2
        elif w == "-f" and i + 1 < n:
            roots.append(args[i + 1])
            i += 2
        elif (w.startswith("-") and len(w) > 1) or w in ("(", ")", "!", ","):
            break  # the expression starts
        else:
            roots.append(w)
            i += 1
    depth = None
    for k in range(i, n - 1):
        if args[k] == "-maxdepth" and args[k + 1].isdigit():
            depth = int(args[k + 1])
            break
    return _Walk(roots, depth)


_RG_LONG = {"after-context", "before-context", "context", "colors", "color", "context-separator", "dfa-size-limit", "encoding",
            "engine", "field-context-separator", "field-match-separator", "file", "glob", "hostname-bin", "hyperlink-format",
            "iglob", "ignore-file", "max-columns", "max-count", "max-depth", "maxdepth", "max-filesize", "path-separator", "pre",
            "pre-glob", "regex-size-limit", "regexp", "replace", "sort", "sortr", "threads", "type", "type-add", "type-clear",
            "type-not", "generate"}


def _rg(args):
    opts, pos = _parse(args, "ABCEMdefgjmrtT", _RG_LONG)
    if _has(opts, "type-list", "help", "version", "h", "V", "pcre2-version", "generate"):
        return None
    no_pattern = _has(opts, "e", "f", "regexp", "file", "files")
    return _Walk(pos if no_pattern else pos[1:], _int(opts, "d", "max-depth", "maxdepth"), True)


_GREP_LONG = {"after-context", "before-context", "context", "binary-files", "devices", "directories", "exclude", "exclude-dir",
              "exclude-from", "file", "include", "include-dir", "label", "max-count", "regexp"}


def _grep(args):
    opts, pos = _parse(args, "efmABCdD", _GREP_LONG)
    recursive = _has(opts, "r", "R", "recursive", "dereference-recursive") or _value(opts, "d", "directories") == "recurse"
    if not recursive:
        return None
    no_pattern = _has(opts, "e", "f", "regexp", "file")
    return _Walk(pos if no_pattern else pos[1:], None, True)


_AG_LONG = {"after", "before", "context", "depth", "file-search-regex", "ignore", "ignore-dir", "max-count", "path-to-ignore",
            "pager", "width", "workers"}


def _ag(args):
    opts, pos = _parse(args, "ABCGgmpW", _AG_LONG)
    return _Walk(pos if _has(opts, "g") else pos[1:], _int(opts, "depth"), True)


_ACK_LONG = {"after-context", "before-context", "context", "max-count", "ignore-dir", "ignore-directory", "noignore-dir",
             "ignore-file", "type", "pager", "output", "files-from", "env"}


def _ack(args):
    opts, pos = _parse(args, "ABCmg", _ACK_LONG)
    return _Walk(pos if _has(opts, "g", "f", "files-from") else pos[1:], None, True)


_FD_LONG = {"max-depth", "maxdepth", "min-depth", "exact-depth", "extension", "type", "exclude", "size", "owner", "color",
            "threads", "search-path", "base-directory", "changed-within", "changed-before", "newer", "older", "ignore-file",
            "max-results", "path-separator", "format", "batch-size", "and"}


def _fd(args):
    for k, w in enumerate(args):  # what follows -x / -X / --exec is another command
        if w in ("-x", "-X", "--exec", "--exec-batch") or w.startswith(("--exec=", "--exec-batch=")):
            args = args[:k]
            break
    opts, pos = _parse(args, "dteESocj", _FD_LONG)
    roots = pos[1:] + [v for name, v in opts if name == "search-path" and v]
    base = _value(opts, "base-directory")
    return _Walk(roots, _int(opts, "d", "max-depth", "maxdepth", "exact-depth"), False, base)


_DU_LONG = {"max-depth", "block-size", "threshold", "exclude", "exclude-from", "files0-from", "time-style", "ignore"}


def _du(args):
    opts, pos = _parse(args, "dIBtX", _DU_LONG)
    return _Walk(pos)  # `-d N` only trims what is printed: du still reads every file below


_TREE_LONG = {"charset", "filelimit", "sort", "timefmt", "hintro", "houtro"}


def _tree(args):
    opts, pos = _parse(args, "LPIoHT", _TREE_LONG)
    return _Walk(pos, _int(opts, "L"))


_LS_LONG = {"ignore", "block-size", "format", "hide", "indicator-style", "quoting-style", "sort", "tabsize", "time",
            "time-style", "width"}


def _ls(args):
    opts, pos = _parse(args, "", _LS_LONG)
    return _Walk(pos) if _has(opts, "R", "recursive") else None


_WALKERS = {"find": _find, "gfind": _find, "bfs": _find, "fd": _fd, "fdfind": _fd, "rg": _rg, "grep": _grep, "egrep": _grep,
            "fgrep": _grep, "ag": _ag, "ack": _ack, "du": _du, "tree": _tree, "ls": _ls, "gls": _ls}


class _Stage:
    def __init__(self, name, args, xargs, stdin):
        self.name, self.args, self.xargs, self.stdin = name, args, xargs, stdin


def _parse_stage(ctx: _Ctx, stage: str, closing: int):
    words, stdin = _strip_redirects(_words(ctx, stage))
    while closing > 0 and words and words[-1].endswith(")"):  # `find ~ -name x)`: the group's closer
        last = _W(words[-1][:-1])
        last.raw = words[-1].raw[:-1] if words[-1].raw.endswith(")") else words[-1].raw
        words = words[:-1] + ([last] if last else [])
        closing -= 1
    cmd = _command(words)
    return _Stage(cmd[0], cmd[1], cmd[2], stdin) if cmd else None


def _walk_reason(ctx: _Ctx, st: _Stage, cwd, piped_in: bool):
    """Why a stage is a walk of the home or `/`, or None."""
    parse = _WALKERS.get(st.name)
    walk = parse(st.args) if parse else None
    if walk is None or (walk.depth is not None and walk.depth <= 1):
        return None  # not a walk, or one that never leaves the first level
    if walk.base:
        base = _expand(ctx, walk.base.raw, cwd)
        cwd = base[0] if base and not base[1] else None
    if walk.roots:
        for w in walk.roots:
            why = _hit(ctx, w.raw, cwd)
            if why:
                return why
        return None
    if st.xargs or (walk.stdin_default and (piped_in or st.stdin)):
        return None  # the roots come from stdin, which cannot be read here
    why = ctx.targets.get(cwd.casefold()) if cwd else None
    return f"the current directory, which is {why.split(',')[0]}" if why else None


def _cd(ctx: _Ctx, st: _Stage, cwd):
    """The working directory after a stage, `cwd` when it does not change it, None when it cannot be told."""
    if st is None or st.name not in ("cd", "pushd", "popd"):
        return cwd
    if st.name == "popd":
        return None
    words = st.args[_skip_flags(st.args, 0):]
    if not words:
        return ctx.home
    if words[0] == "-":
        return None
    res = _expand(ctx, words[0].raw, cwd)
    return res[0] if res and not res[1] else None


def _scan(ctx: _Ctx, text: str, cwd, depth: int = 0):
    """(stage, why) of the first walk of the home or `/` in a command text that starts in `cwd`, or None."""
    stack, prev = [], None
    for stage, sep in kg._split(text):
        piped_in = prev in ("|", "|&")
        prev = sep
        balance = stage.count("(") - stage.count(")")
        if balance > 0:
            stack.extend([cwd] * min(balance, _MAX_GROUPS))
        st = _parse_stage(ctx, stage, max(-balance, 0))
        why = _walk_reason(ctx, st, cwd, piped_in) if st else None
        if why:
            return stage, why
        if depth < _MAX_NESTING:
            for body in kg._substitutions(stage):
                found = _scan(ctx, body, cwd, depth + 1)
                if found:
                    return found
        cwd = _cd(ctx, st, cwd)
        for _ in range(min(-balance, _MAX_GROUPS) if balance < 0 else 0):  # a `)` closes a subshell: its cd is undone
            if stack:
                cwd = stack.pop()
    return None


def check(command: str, cwd=None):
    """The reason of a denial for a Bash command, or None."""
    ctx = _Ctx(cwd)
    command = command.replace("\x01", "")
    executed = pg.views(kg._drop_ssh(command), True, ctx.data)[0]
    found = _scan(ctx, executed, ctx.cwd)
    if not found:
        return None
    shown = re.sub(r"\s+", " ", ctx.restore(found[0])).strip()
    return f"This is `{shown[:120] + '…' if len(shown) > 120 else shown}` — it walks {found[1]}."


def check_tool(name: str, ti: dict, cwd=None):
    """The reason of a denial for a Grep or Glob call, or None."""
    ctx = _Ctx(cwd)
    path = ti.get("path")
    if path is not None and not isinstance(path, str):
        return None
    if path:
        why = _hit(ctx, path.replace("\x01", ""), ctx.cwd, shell=False)
        if why:
            return f"This is {name} with path `{path}` — it walks {why}."
    elif ctx.cwd and ctx.targets.get(ctx.cwd.casefold()):
        return f"This is {name} with no path: it searches the current directory, which is {ctx.targets[ctx.cwd.casefold()].split(',')[0]}."
    pattern = ti.get("pattern")
    if name == "Glob" and isinstance(pattern, str) and "**" in pattern and (pattern.startswith(("~", "/", "$"))):
        literal = []
        for seg in pattern.split("/"):
            if any(ch in seg for ch in "*?[{"):
                break
            literal.append(seg)
        prefix = "/".join(literal) or "/"
        why = _hit(ctx, prefix.replace("\x01", ""), ctx.cwd, shell=False)
        if why:
            return f"This is Glob with the pattern `{pattern}` — it walks {why}."
    return None


def message(reason: str, escape_word: str, tool: bool = False) -> str:
    head = ("A walk of the home directory or `/` is not run (Delamain scan guard): it enters other apps' data "
            "(~/Library: Mail, Messages, Safari, Containers), and macOS then asks again to allow access to \"data from "
            "other apps\".")
    if tool:
        tail = f"Grep and Glob take no marker: a walk the owner asked for goes through Bash with `# {escape_word}`."
    else:
        tail = f"Only if the owner asked for this exact walk, add the comment `# {escape_word}` to the command."
    return f"{head}\n\n{reason}\n\n{INSTEAD}\n{tail}"


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(event, dict):
        return 0
    name, ti = event.get("tool_name"), event.get("tool_input") or {}
    if not isinstance(ti, dict) or name not in ("Bash", "Grep", "Glob"):
        return 0
    command = ti.get("command")
    if name == "Bash" and not isinstance(command, str):
        return 0
    cwd = event.get("cwd")
    try:
        hc = pg.hubcore()
        hc.use_cwd(cwd)
        enabled = hc.setting("AGENT_HUB_SCAN_GUARD", cwd=cwd) or "on"
        escape_word = (hc.setting("AGENT_HUB_SCAN_ESCAPE", cwd=cwd) or DEFAULT_ESCAPE).strip()
    except Exception:  # noqa: BLE001 — without the plugin's bin/ the built-in defaults still apply
        enabled, escape_word = "on", DEFAULT_ESCAPE
    if enabled.strip().lower() in ("off", "0", "false", "no"):
        return 0
    if name == "Bash":
        tail = r"\b" if re.match(r"\w", escape_word[-1:]) else ""
        if re.search(r"#\s*" + re.escape(escape_word) + tail, command):
            return 0
        reason = check(command, cwd)
    else:
        reason = check_tool(name, ti, cwd)
    if not reason:
        return 0
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": message(reason, escape_word, name != "Bash"),
    }}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        code = main()
    except Exception:  # noqa: BLE001 — fail-open
        code = 0
    sys.exit(code)

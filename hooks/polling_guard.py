#!/usr/bin/env python3
"""Polling guard: a PreToolUse hook on Bash that refuses home-made waiting in the foreground.

A foreground wait holds the session for nothing: a `until …; do sleep 20; done` loop runs until the Bash timeout,
and every one-off "is CI done yet?" read is a full turn that re-reads the whole context. The harness already
wakes a session when a background command ends; Delamain's `jwait` wakes it on journal lines, file output and
alarms. This hook denies:

* a loop (`until` / `while` / `for`) with `sleep` inside that has no upper bound, or one above
  AGENT_HUB_POLL_MAX_BOUNDED_WAIT seconds (iterations x longest sleep); if it waits on `pgrep -f <pattern>` without
  the bracket trick (`[p]ytest`), the reason says the pattern matches the waiting shell itself;
* a bare `sleep` longer than AGENT_HUB_POLL_MAX_SLEEP seconds (`5m`, `1h`, `2d` suffixes count);
* a one-off CI status read: a command segment matching AGENT_HUB_CI_STATUS_DENY and none of
  AGENT_HUB_CI_STATUS_ALLOW (defaults for `gh` and `glab` below: status, list, view and watch are denied; logs,
  traces, actions, write methods and a pipeline lookup by commit sha are allowed).

Not touched: `run_in_background: true` commands; short bounded retries; text inside `echo` / `printf` / `cat` and
heredoc bodies (that is writing a waiter, not running it) — unless that text is fed to a shell (`| bash`,
`bash <<EOF`, `| xargs sh -c`), which runs it; commands carrying the escape marker `# poll-ok: <reason>`
(AGENT_HUB_POLL_ESCAPE), which leaves the reason in the transcript.

Quoted text is data until a shell executes it. The guard looks inside a quoted string only when it is the argument of
`bash|sh|zsh|dash|ksh -c` (after `timeout` / `env` / `sudo` / `time` too), of `eval`, of `ssh`, a here-string to a
shell, or the text of `echo` / `printf` / `cat` piped to a shell; and inside `$(…)` in double quotes. Every other
quoted argument is data — `git commit -m "… sleep 5m …"`, `grep "sleep 5m"`, `rg "until .*; do"`, the body of a
`gh api` call — and a `;` or `|` inside it does not split the command. The guard is regex based, not a shell parser:
process substitution (`bash <(echo '…')`), `eval "$(…)"`, a script written and run in one command and the `-c` / `-e`
strings of interpreters (`python3 -c "os.system('sleep 300')"`, `perl -e`, `node -e`) are not looked into.

Settings (environment, the repository's .agent-hub/config.json, or the hub home's config.json):
  AGENT_HUB_POLL_GUARD              on | off (default on)
  AGENT_HUB_POLL_MAX_SLEEP          30      AGENT_HUB_POLL_MAX_BOUNDED_WAIT  90
  AGENT_HUB_POLL_ESCAPE             poll-ok
  AGENT_HUB_CI_STATUS_DENY          JSON list of regexes (replaces the defaults; `polling_guard.py --defaults`)
  AGENT_HUB_CI_STATUS_ALLOW         JSON list of regexes (replaces the defaults)
  AGENT_HUB_WAIT_HINT               one more line for the deny message, e.g. the project's own CI wait command
Fail-open: an error of its own never blocks a command.
"""
from __future__ import annotations

if __name__ == "__main__":  # fail-safe first, before anything that can fail: see hooks/failsafe.py
    try:
        import failsafe

        failsafe.install()
    except Exception:  # noqa: BLE001 — without it the hook is as it was
        pass

import bisect
import json
import os
import re
import shlex
import sys

DEFAULTS = {"max_sleep": 30, "max_bounded_wait": 90, "escape": "poll-ok"}

# One-off CI status reads, searched in each command segment (case-insensitive).
DEFAULT_CI_DENY = [
    r"\bglab\s+ci\s+(?:status|view|get|list)\b",
    r"\bglab\s+api\b.*?(?:^|[\s'\"/])(?:pipelines|jobs)(?:[/?\s'\"]|$)",
    r"\bgh\s+run\s+(?:view|list|watch)\b",
    r"\bgh\s+pr\s+checks\b",
    r"\bgh\s+api\b.*?/actions/(?:runs|jobs)\b",
    r"\bgh\s+api\b.*?/commits/[^/\s]+/(?:status|statuses|check-runs|check-suites)\b",
]
# A denied segment that also matches one of these passes: logs, actions, writes, a lookup by commit.
DEFAULT_CI_ALLOW = [
    r"/(?:trace|retry|play|cancel|erase|artifacts|logs|rerun|rerun-failed-jobs)\b",
    r"[?&](?:head_)?sha=[^&\s'\"]+",
    r"(?:-X|--method)[\s=]*['\"]?(?:POST|PUT|DELETE|PATCH)\b",
    r"(?:^|\s)(?:-f|-F|--field|--raw-field|--input)(?:[\s=]|$)",  # fields make `gh/glab api` a POST
    r"\bgh\s+run\s+view\b.*\s--log(?:-failed)?\b",
]

# A command starts after whitespace, a separator or a parenthesis — not after a quote: a quoted string is data
# (`git commit -m "… sleep 5m …"`) until a shell executes it, and `views` unwraps those strings into plain commands.
_START = r"(?:^|[\s;&|(])"
_SLEEP = re.compile(_START + r"(?:command\s+)?sleep\s+(\d+(?:\.\d+)?)([smhd]?)(?![\w.])")
_LOOP = re.compile(_START + r"(?:until|while|for)\s")
_UNTIL_WHILE = re.compile(_START + r"(?:until|while)\s")
_UNIT = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}
# A consumer that runs its stdin (or its argument) as commands: text fed to it is not "only printed". `xargs` counts
# only with `sh -c` (`xargs rm` gets the text as arguments); a wrapper's flag takes a value only for `-u` / `-g` /
# `-n` / `-c` (otherwise `env -i grep bash` would read `grep` as the flag's value; `sudo -n bash` still parses: the
# value reading is dropped when no shell follows).
_SHELL = r"(?:\S*/)?(?:bash|sh|zsh|dash|ksh)"
# A flag's value never starts with `-`: `-[ug]\s+\S+` and `-\S+` overlap, and `-u -u -u …` backtracked exponentially.
_WRAPPER = (r"(?:(?:\S*/)?(?:sudo|env|nohup|exec|time|setsid|nice|ionice|stdbuf|doas)"
            r"(?:\s+(?:-[ugnc]\s+(?!-)\S+|-\S+))*|command(?:\s+--)?)")  # `command -v bash` only looks bash up
_TIMEOUT = r"timeout(?:\s+(?:-[ks]\s+(?!-)\S+|-\S+))*\s+\S+"  # `timeout -k 5 600 bash`: flags, then the duration
# What may stand before the command word: a group opener (`( bash …`, `{ bash …`), `VAR=x`, wrappers.
_CMD_PREFIX = r"^\s*[({]?\s*(?:(?:\w+=\S+|" + _WRAPPER + r"|" + _TIMEOUT + r")\s+)*"
# A command that runs its argument somewhere else — another machine, a container, a pod: the string after it is not a
# command of this one (read only by callers that pass `data` to `views`).
_REMOTE = re.compile(r"(?:^|[\s;&|(])(?:\S*/)?(?:ssh|mosh|telnet|tsh|docker|podman|nerdctl|ctr|kubectl|oc|lxc|incus|nsenter|chroot"
                     r"|vagrant|multipass|limactl|colima|gcloud|aws|az|yc|doctl|fly|flyctl|heroku)(?![\w.-])")
_SHELL_CONSUMER = re.compile(
    _CMD_PREFIX
    + rf"(?:{_SHELL}\b|eval\b|source\b|\.\s+/dev/stdin\b|xargs\b.*?\s{_SHELL}\s+-\w*c\b"
    # `ssh host` and `ssh host bash` read their stdin as commands (`ssh host 'cat > f'` does not); so do `su`,
    # `su - user` and `sudo -i` / `sudo -s` (a login shell).
    rf"|ssh\b(?:\s+-\w+(?:\s+(?!-)\S+)?)*\s+[^\s-]\S*(?:\s+{_SHELL}\b|\s*$)"
    r"|su(?:\s+-(?!\w*c)\w*)?(?:\s+\w+)?\s*$"  # not `su -c cmd`: that runs a command, it does not read stdin
    r"|sudo(?=(?:\s+-\w+)*\s+-[is]\b)(?:\s+-\w+)*\s*$)"
)
# The command word of a segment is `gh` or `glab`: its quoted arguments carry the API path the CI rules read.
_CI_COMMAND = re.compile(_CMD_PREFIX + r"(?:\S*/)?(?:gh|glab)\b")
# A quoted string whole, backslash escapes included; `\x` outside quotes is swallowed so `\"` does not open a string.
_QUOTED = re.compile(r"""'[^']*'|"(?:\\.|[^"\\])*"|\\.""", re.DOTALL)
_TOKEN = re.compile(r"\x00(\d+)\x00")
# A string right after this is a program for a shell: the argument of `-c` (`bash -lc`, `bash -eo pipefail -c`,
# `timeout 600 bash -c`, `xargs sh -c`), of `eval`, a here-string to a shell, or `ssh host '…'`. An option with a
# value (`-o pipefail`) must not break the chain up to `-c`.
_EXEC_ARG = re.compile(r"(?:^|[\s;&|(/])(?:(?:bash|sh|zsh|dash|ksh)(?:\s+(?:-\w*[oO]\s+\w+|-\S+))*?\s+-\w*c(?:\s+--)?"
                       r"|eval)\s*$")
# Who may run such a string, for a caller that reads `data`: the command a segment really runs — behind its keywords,
# assignments and wrappers, each wrapper's options read with their values — is a shell, `eval`, or a command that runs the rest
# of its line (`find -exec`, `watch` …). `echo bash -c '…'`, `jlog bash -c '…'` and `env printf '%s' bash -c '…'` only print
# their arguments.
# Wrappers: command words that run the rest of their line, and the options of each that take a value.
WRAPPERS = {"sudo": ("-u", "-g", "-C", "-D", "-h", "-p", "-R", "-r", "-t", "-U", "-T", "--user", "--group", "--chdir", "--prompt"),
            "doas": ("-u", "-C"), "env": ("-u", "-C", "-S", "-P", "-a", "--chdir", "--unset", "--split-string", "--argv0"),
            "nice": ("-n",), "ionice": ("-n", "-c", "-p"), "caffeinate": ("-t", "-w"), "time": ("-f", "-o"), "exec": ("-a",),
            "stdbuf": ("-i", "-o", "-e"), "setsid": (), "nohup": (), "command": (), "builtin": (), "unbuffer": (), "noglob": (),
            "nocorrect": ()}
WRAPPER_CHDIR = {"env": ("-C", "--chdir"), "sudo": ("-D", "--chdir")}  # the options that give the child another directory
TIMEOUT_VALUED = ("-k", "-s", "--kill-after", "--signal")
XARGS_VALUED = ("-I", "-J", "-L", "-n", "-P", "-s", "-d", "-E", "-a", "-R", "-S")
_RUNNERS = frozenset(("watch", "flock", "parallel", "entr", "find", "bfs", "gfind", "fd", "fdfind", "su", "runuser", "setpriv", "unshare",
                      "arch", "xcrun", "taskset", "numactl", "script", "strace", "systemd-run", "tmux", "screen", "sandbox-exec"))
_SHELL_NAMES = frozenset(("bash", "sh", "zsh", "dash", "ksh"))
_WALK_KEYWORDS = frozenset(("if", "then", "else", "elif", "do", "while", "until", "!", "{", "(", "coproc"))
_ASSIGNMENT = re.compile(r"\w+(?:\[[^\]]*\])?\+?=")
_WORD = re.compile(r"\S+")
_WALK_WORDS = 64  # a command's own prefix is a few words; a longer one is read as "may run"


def skip_options(words, i: int, valued=(), grab=()):
    """(the index after the option words that start at `i`, [(k, offset)] of the values of the options in `grab`). An option
    in `valued` takes a value: the next word, or the rest of its own word (`--chdir=DIR`, `-C/tmp`, and in a cluster `-nu root`,
    `-iC/tmp`); that value is never read as an option (`sudo -p -D/ cmd`: `-D/` is the prompt). The value is `words[k]` from
    `offset` on (the whole word for `None`). `--` ends the options."""
    n, hits = len(words), []
    while i < n and words[i].startswith("-") and len(words[i]) > 1:
        w = str(words[i])
        if w == "--":
            return i + 1, hits
        takes, flag, off = False, None, None
        if w in valued:
            takes, flag = True, w
        elif w.startswith("--"):
            name, eq, _ = w.partition("=")
            if eq and name in valued:
                flag, off = name, len(name) + 1
        else:
            for p in range(1, len(w)):
                if "-" + w[p] in valued:
                    flag = "-" + w[p]
                    takes, off = p + 1 == len(w), (p + 1 if p + 1 < len(w) else None)
                    break
        if flag in grab:
            if not takes:
                hits.append((i, off))
            elif i + 1 < n:
                hits.append((i + 1, None))
        i += 2 if takes else 1
    return i, hits


def command_runs_string(seg: str, first: int):
    """(may the command that starts at `first` in `seg` run a `-c` / `eval` string, [the directory words its `env -C` /
    `sudo -D` wrappers give it, in order, as typed])."""
    words = [m.group() for _, m in zip(range(_WALK_WORDS), _WORD.finditer(seg, first))]
    n, i, dirs = len(words), 0, []
    while i < n:
        w = words[i].lstrip("({")
        base = w.rsplit("/", 1)[-1]
        if w in ("", *_WALK_KEYWORDS) or _ASSIGNMENT.match(w):
            i += 1
        elif base in _SHELL_NAMES or base == "eval":
            return True, dirs
        elif base == "command" and i + 1 < n and words[i + 1] in ("-v", "-V"):
            return False, dirs  # only looks the name up
        elif base in WRAPPERS:
            i, hits = skip_options(words, i + 1, WRAPPERS[base], WRAPPER_CHDIR.get(base, ()))
            dirs += [words[k] if off is None else words[k][off:] for k, off in hits]
        elif base in ("timeout", "gtimeout"):
            i = skip_options(words, i + 1, TIMEOUT_VALUED)[0] + 1  # then the duration
        elif base == "xargs":
            i = skip_options(words, i + 1, XARGS_VALUED)[0]
        else:
            return base in _RUNNERS, dirs
    return n >= _WALK_WORDS, dirs


_BACKGROUND = re.compile(r"(?<![&>|<])&(?![&>])")  # a single `&` ends a command inside a segment too
_SSH = re.compile(r"(?:^|[\s;&|(/])ssh\s")
_LOOKBEHIND = 300  # characters before a string read to decide "executed or data" (a whole-prefix search is quadratic)
_SEQ = re.compile(r"seq\s+(?:-?\w+\s+)?(\d+)\s+(\d+)")
_BRACE_RANGE = re.compile(r"\{(\d+)\.\.(\d+)\}")
_FOR_LIST = re.compile(r"\bfor\s+\w+\s+in\s+([^;$({\n]+?)(?:;|\s+do\b)")
_PGREP_F = re.compile(r"pgrep\s+(?:-\w+\s+)*-\w*f\w*\s+(?:'([^']*)'|\"([^\"]*)\"|(\S+))")
# A heredoc body is a file being written, not commands being run. The opener is `<<` or `<<-` and the delimiter word: bare
# (`EOF`, `END-NOTES`, `\EOF`), quoted (`'END.NOTES'`, `"EOF"`) or both (`E'O'F`); `<<<` is a here-string, not an opener.
# The terminator is looked up in a table of the command's lines (`strip_heredocs`), not by a regex that scans for it: an
# opener with no terminator made such a regex read every blank line after it again and again, for 12 s and more.
_HEREDOC_OPEN = re.compile(r"(?<!<)<<(?!<)-?[ \t]*((?:'[^'\n]*'|\"[^\"\n]*\"|\\.|[^\s;&|<>()'\"\\])+)")
_DELIM_QUOTES = re.compile(r"'([^']*)'|\"([^\"]*)\"|\\(.)")
_HEREDOC_MARK = "<<_HEREDOC_"  # stands for a heredoc whose body is dropped, where the caller reads the redirections
# Segments that print rather than run: `echo 'until …; do sleep 20; done'` (also in a subshell: `(echo '…') | bash`).
_PRINTING = re.compile(r"^\s*[({]?\s*(?:\w+=\S+\s+)*(?:echo|printf|cat)\b")
_SEGMENT_SEP = re.compile(r"(?:\|\||&&|[;|\n])")
_AWAIT = re.compile(_CMD_PREFIX + r"(?:\S*/)?await\s")
# shlex(punctuation_chars=True) hands operators over as tokens: a control operator is `&`, `&&`, `||`, `|`, `|&`, `;`,
# `;;`, a parenthesis; `>&`, `&>`, `2>` and the like are redirections and stay allowed.
_CONTROL = re.compile(r"&+|[|;()&]*[|;()][|;()&]*")
# The same, separators kept in the result; a `|` at the end of a line (`echo '…' |⏎ bash`) is a pipe too, and
# bash takes any number of blank lines after it.
_SEGMENT_SPLIT = re.compile(r"(\|\||&&|\|\s*\n|[;|\n])")
_PIPE = re.compile(r"(?<!\|)\|(?!\|)")  # a single `|`, not `||`

INSTEAD = """Instead:
  • a long command (tests, a build, a deploy) — the same command with Bash `run_in_background: true`; the harness
    wakes you when it ends and hands you its exit code, there is nothing to poll;
  • journal lines, a script's output, a deadline — one `jwait` with `run_in_background: true` (see the hub skill);
{hint}  • external state the harness does not track — the Monitor tool.

If the wait is deliberate, add the comment `# {escape}: <reason>` to the command; the reason stays in the
transcript."""

DEFAULT_HINT = ("  • CI — your CI's own blocking wait in the background (e.g. `gh run watch <id> --exit-status`);\n"
                "    a pipeline lookup by commit sha and job logs are allowed in the foreground;\n")
CODEX_INSTEAD = """Instead:
  • tests, builds, or a CI blocking wait — use exec_command with a short yield_time_ms. If it returns a session_id,
    use write_stdin to wait for that command's completion and exit code;
  • journal lines, a script's output, or a deadline — run one jwait through exec_command, then wait on its session_id.
    Do not replace it with a sleep or process-name polling loop.
{hint}
If the wait is deliberate, add the comment `# {escape}: <reason>` to the command; the reason stays in the
transcript."""


def hubcore():
    root = os.environ.get("PLUGIN_ROOT") or os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    sys.path.insert(0, os.path.join(root, "bin"))
    import hubcore as hc  # noqa: E402

    return hc


class Config:
    def __init__(self, cwd=None, hc=None):
        def num(name, default):
            try:
                return float(hc.setting(name, cwd=cwd) or default) if hc else default
            except ValueError:
                return default

        def patterns(name, default):
            raw = hc.setting_json(name, None, cwd=cwd) if hc else None
            src = default if raw is None else ([raw] if isinstance(raw, str) else list(raw))
            out = []
            for p in src:
                try:
                    out.append(re.compile(str(p), re.IGNORECASE))
                except re.error as e:
                    print(f"delamain: {name}: bad regex {p!r} ({e}); skipped", file=sys.stderr)
            if src and not out:  # every configured pattern broken: not the same as a deliberate []
                print(f"delamain: {name}: no valid pattern; using the defaults", file=sys.stderr)
                return [re.compile(p, re.IGNORECASE) for p in default]
            return out

        self.enabled = (hc.setting("AGENT_HUB_POLL_GUARD", cwd=cwd) if hc else None) or "on"
        self.enabled = self.enabled.strip().lower() not in ("off", "0", "false", "no")
        self.max_sleep = num("AGENT_HUB_POLL_MAX_SLEEP", DEFAULTS["max_sleep"])
        self.max_bounded = num("AGENT_HUB_POLL_MAX_BOUNDED_WAIT", DEFAULTS["max_bounded_wait"])
        self.escape_word = ((hc.setting("AGENT_HUB_POLL_ESCAPE", cwd=cwd) if hc else None) or DEFAULTS["escape"]).strip()
        tail = r"\b" if re.match(r"\w", self.escape_word[-1:]) else ""
        self.escape = re.compile(r"#\s*" + re.escape(self.escape_word) + tail)
        self.ci_deny = patterns("AGENT_HUB_CI_STATUS_DENY", DEFAULT_CI_DENY)
        self.ci_allow = patterns("AGENT_HUB_CI_STATUS_ALLOW", DEFAULT_CI_ALLOW)
        hint = hc.setting("AGENT_HUB_WAIT_HINT", cwd=cwd) if hc else None
        self.hint = f"  • {hint.strip()}\n" if hint else DEFAULT_HINT


def _delimiter(word: str) -> str:
    """The delimiter a word names, quotes and backslashes removed: `'END-NOTES'` -> `END-NOTES`."""
    return _DELIM_QUOTES.sub(lambda m: next(g for g in m.groups() if g is not None), word)


def _heredoc_lines(cmd: str) -> dict:
    """{a line without the blanks around it: [(start, end)] of every such line, in order}: where a terminator can stand."""
    lines, pos = {}, 0
    for line in cmd.split("\n"):
        key = line.strip()
        if key:
            lines.setdefault(key, []).append((pos, pos + len(line)))
        pos += len(line) + 1
    return lines


def _heredoc(cmd: str, start: int, after: int, nl: int, end: int, keep_line: bool, preserve_shell: bool) -> str:
    """What stands for the heredoc that opens at `start` (`after`: the end of its delimiter, `nl`: the end of its line,
    `end`: the end of its terminator). A body is dropped unless its command is a shell (`bash <<EOF`, `cat <<EOF | sh`).
    `keep_line` keeps the rest of the opening line (`cat <<EOF && find ~`: a command too) and, for a body that is
    dropped, a `<<_HEREDOC_` mark: that command's stdin is a heredoc. A shell on another machine (`ssh host bash <<EOF`)
    does not run the body here: with `keep_line` it is dropped like any other."""
    line_start = cmd.rfind("\n", 0, start) + 1
    before = _SEGMENT_SEP.split(cmd[line_start:start])[-1]
    consumers = [c for c in [before, *_PIPE.split(cmd[start:nl])[1:]] if _SHELL_CONSUMER.match(c)]  # any stage of the pipe
    rest = cmd[after:nl] if keep_line else ""
    if preserve_shell and any(not (keep_line and _REMOTE.search(c)) for c in consumers):
        return rest + "\n" + cmd[nl + 1:end]
    return _HEREDOC_MARK + rest if keep_line else " "


def strip_heredocs(cmd: str, keep_line: bool = False, *, preserve_shell: bool = True) -> str:
    """`cmd` with the bodies of its heredocs dropped (see `_heredoc`). Linear in the length of `cmd`: an opener with no
    terminator, or any number of them, is left as it stands. `preserve_shell=False` drops even shell-fed bodies,
    for callers such as board_locks that historically treated every heredoc as data."""
    out, last, pos, nl, lines = [], 0, 0, -2, None
    while True:
        m = _HEREDOC_OPEN.search(cmd, pos)
        if not m:
            break
        pos, delim = m.end(), _delimiter(m.group(1))
        if nl != -1 and nl < pos:
            nl = cmd.find("\n", pos)  # the body starts on the next line
        if nl == -1 or not delim:
            continue
        if lines is None:
            lines = _heredoc_lines(cmd)
        spans = lines.get(delim, ())
        k = bisect.bisect_left(spans, (nl + 1,))
        if k == len(spans):
            continue
        end = spans[k][1]
        out.append(cmd[last:m.start()])
        out.append(_heredoc(cmd, m.start(), pos, nl, end, keep_line, preserve_shell))
        last = pos = end
    out.append(cmd[last:])
    return "".join(out)


def _protect(cmd: str):
    """Every quoted string becomes a token `\\x00N\\x00`: a `;` or `|` inside a string does not split the command."""
    strings: list = []

    def stash(m):
        if m.group(0).startswith("\\"):
            return m.group(0)
        strings.append(m.group(0))
        return f"\x00{len(strings) - 1}\x00"

    return _QUOTED.sub(stash, cmd), strings


def _word_start(seg: str, end: int) -> int:
    """Where the shell word that ends at `end` starts: `'a'"$B"'c'` is one word made of three strings. A `<` ends the
    word before it too: in `bash <<<'…'` the string is the here-string's operand, and `<<<` is what stands before it."""
    low = max(0, end - _LOOKBEHIND)
    window = seg[low:end]
    gap = max(window.rfind(" "), window.rfind("\t"), window.rfind("<"))
    return low + gap + 1 if gap != -1 else low


def _runs_argument(seg: str, start: int, shell_segment: bool, exec_ok: bool = True) -> bool:
    """Does a shell run the word that starts at `start` in `seg`, or is it data? Only the tail before the word is
    read: `bash -lc` and `ssh -o … host` fit in it, and a search of the whole prefix per string is quadratic. A cheap
    check of the tail's end goes first: most strings are arguments of git or grep, not of a shell. `shell_segment` —
    the whole segment is a shell consumer (`bash … <<< '…'`) — and `exec_ok` — its command word may run a `-c` string —
    are computed once per segment."""
    head = seg[max(0, start - _LOOKBEHIND):start]
    tail = head.rstrip()
    if tail.endswith("<<<"):
        return shell_segment
    if tail.endswith(("c", "--", "eval")) and exec_ok and _EXEC_ARG.search(head):
        return True
    return "ssh" in head and bool(_SSH.search(head))


def _unquote(quoted: str) -> str:
    """The text of a string without its outer quotes; in double quotes `\\"` `\\\\` `\\$` are unescaped."""
    body = quoted[1:-1]
    if quoted[0] == '"':
        body = re.sub(r'\\(["\\$`])', r"\1", body)
    return body


def _substitutions(quoted: str) -> list:
    """Bodies of `$(…)` inside a double-quoted string: the shell runs them, it does not print them."""
    if quoted[0] != '"':
        return []
    bodies = []
    start = quoted.find("$(")
    while start != -1:
        escaped = (start - len(quoted[:start].rstrip("\\"))) % 2 == 1  # `\$(` is a literal, not a substitution
        depth, end = 1, start + 2
        while not escaped and end < len(quoted) and depth:
            depth += (quoted[end] == "(") - (quoted[end] == ")")
            end += 1
        if not escaped:
            bodies.append(quoted[start + 2:end - 1 if depth == 0 else end])
        start = quoted.find("$(", end if not escaped else start + 2)
    return bodies


def _datum(data, quoted: str) -> str:
    """What stands for a data string in the wait projection: `""`, or, when the caller collects them, a token
    `\\x01N\\x01` whose string is `data[N]`."""
    if data is None:
        return '""'
    data.append(quoted)
    return f"\x01{len(data) - 1}\x01"


def _segment_views(seg: str, strings: list, runs_all: bool, keep_seps: bool = False, data: list = None):
    """(wait text, CI text) of a segment. Strings a shell runs are unwrapped into commands (recursively); any other
    string is data: `""` for the wait search, and for the CI rules too unless the segment's command word is `gh` /
    `glab` — their quoted arguments carry the API path. `$(…)` in a data string still runs."""
    wait, ci = [], []
    pos = 0
    shell_segment = "<<<" in seg and bool(_SHELL_CONSUMER.match(seg))
    # a caller that collects `data` tells a command that runs a `-c` string from one that only carries it
    starts = [0] + [b.end() for b in _BACKGROUND.finditer(seg)] if data is not None else []
    runners: dict = {}
    keep_strings = bool(_CI_COMMAND.match(seg))
    for m in _TOKEN.finditer(seg):
        wait.append(seg[pos:m.start()])
        ci.append(seg[pos:m.start()])
        quoted = strings[int(m.group(1))]
        runs = runs_all
        if not runs:
            word = _word_start(seg, m.start())
            first = starts[bisect.bisect_right(starts, word) - 1] if starts else None
            if first is not None and first not in runners:
                runners[first] = command_runs_string(seg, first)
            runs = _runs_argument(seg, word, shell_segment, first is None or runners[first][0])
        if runs and not (data is not None and _REMOTE.search(seg[max(0, m.start() - _LOOKBEHIND):m.start()])):
            inner = views(_unquote(quoted), keep_seps, data)
            if data is None:
                wait.append(f";{inner[0]};")
            else:  # a caller that reads `cd` needs the subshell, and the directory `env -C` / `sudo -D` gave it
                moved = "".join(f"cd {_TOKEN.sub(lambda t: _datum(data, strings[int(t.group(1))]), d)}; "
                                for d in (runners[first][1] if not runs_all and first is not None else []))
                wait.append(f";({moved}{inner[0]});")
            ci.append(f";{inner[2]};")
        else:
            wait.append(_datum(data, quoted))
            ci.append(quoted if keep_strings else '""')
            for body in _substitutions(quoted):
                inner = views(body, keep_seps, data)
                # keep_seps: the substitution stays where it stood, `kill "$(pgrep x)"` is still one command
                wait.append(f"$({inner[0]})" if keep_seps else f";{inner[0]};")
                ci.append(f";{inner[2]};")
        pos = m.end()
    wait.append(seg[pos:])
    ci.append(seg[pos:])
    return "".join(wait), "".join(ci)


def views(cmd: str, keep_seps: bool = False, data: list = None):
    """Three projections of a command: (where to look for a wait, what the `pgrep -f` check reads, what the CI-status
    rules read).

    Quoted text is data until a shell executes it: `git commit -m "… sleep 5m …"` and `grep "sleep 5m"` are not waits,
    `bash -c "until …"` and `echo '…' | bash` are. So quoted strings are first hidden in tokens (a `;` or `|` inside
    one does not split the command), the command is split into segments and pipes, and each segment decides what
    happens to its strings:

    * a printing segment (`echo` / `printf` / `cat`) whose output reaches a shell through a pipe — its strings run;
      one whose output does not is dropped whole (it writes a file, it does not run anything), as is a heredoc body
      that no shell reads; only `$(…)` inside its double quotes still counts. A group (`( … )`, `{ …; }`) piped to a
      shell feeds every segment inside it;
    * any other segment — a string that is the argument of `-c`, `eval`, `ssh` or a here-string to a shell is unwrapped
      into commands (recursively); every other string becomes `""`.

    The `pgrep` projection keeps every string as it is (the pattern lives in one). The CI projection keeps a data
    string only in a `gh` / `glab` segment: the path of `glab api "…/pipelines/1"` lives in a string, a commit message
    that mentions `gh run view` does not.

    `keep_seps` joins the segments of each projection with the separators the command had (`|`, `&&`, a newline …)
    instead of `;`, so a pipeline stays a pipeline (hooks/kill_guard.py reads it). `data`, a list the caller passes in,
    makes the wait projection keep the data strings instead of `""`: each stands as a token `\\x01N\\x01` and is
    appended, quotes included, to the list as item N; a printing stage that nothing feeds to a shell is kept like any
    other stage, with its own `$(…)`; the string a shell runs stays in parentheses (its `cd` does not leave it), and
    the string of a command that runs it elsewhere (`ssh`, `docker exec`, `kubectl exec` …) stays data (hooks/scan_guard.py
    reads the arguments and the pipes of a command)."""
    # `\⏎` is a line continuation: `echo '…' \⏎ | bash` is one pipe, not two segments.
    cmd = strip_heredocs(cmd.replace("\x00", "").replace("\\\n", " "), data is not None)
    protected, strings = _protect(cmd)
    parts = _SEGMENT_SPLIT.split(protected)
    segs, seps = parts[0::2], parts[1::2]
    fed = [False] * len(segs)  # the segment's output reaches a shell through a pipe
    reaches_shell = False
    for i in range(len(segs) - 2, -1, -1):
        next_is_shell = bool(_SHELL_CONSUMER.match(segs[i + 1]))
        reaches_shell = seps[i].startswith("|") and seps[i] != "||" and (reaches_shell or next_is_shell)
        fed[i] = reaches_shell
    # A group `( a; b ) | bash` is split at its `;`: the segment that closes it carries the pipe, the others inside it
    # are fed through it too.
    openers = []
    for i, seg in enumerate(segs):
        net = seg.count("(") - seg.count(")") + seg.count("{") - seg.count("}")
        openers.extend([i] * net)
        for _ in range(-net):
            if openers:
                opened = openers.pop()
                if fed[i]:
                    fed[opened:i] = [True] * (i - opened)
    wait, quoted, ci = [], [], []
    after = {}  # index of the last item of a segment -> the separator that followed it
    for i, seg in enumerate(segs):
        printing = bool(_PRINTING.match(seg))
        before = len(wait)
        if printing and not fed[i] and data is None:
            # Printing is not running, but the shell does run `$(…)` in double quotes — for the wait search and for
            # the CI rules alike: `echo "$(gh run view 1)"`.
            for num in _TOKEN.findall(seg):
                for body in _substitutions(strings[int(num)]):
                    inner = views(body, keep_seps, data)
                    wait.append(f";{inner[0]};")
                    quoted.append(body)
                    ci.append(f";{inner[2]};")
        else:
            wait_text, ci_text = _segment_views(seg, strings, printing and fed[i], keep_seps, data)
            wait.append(wait_text)
            ci.append(ci_text)
            quoted.append(_TOKEN.sub(lambda m: strings[int(m.group(1))], seg))
        if i < len(seps) and len(wait) > before:
            after[len(wait) - 1] = seps[i]
    if keep_seps:
        def join(items):
            return "".join(item + after.get(k, ";") for k, item in enumerate(items))
        return join(wait), join(quoted), join(ci)
    return ";".join(wait), ";".join(quoted), ";".join(ci)


def bounded_iterations(cmd: str):
    """Upper bound of the loop's iterations, or None when there is none."""
    if _UNTIL_WHILE.search(cmd):
        return None  # a counter inside the body cannot be proven from the text
    m = _SEQ.search(cmd)
    if m:
        return int(m.group(2)) - int(m.group(1)) + 1
    m = _BRACE_RANGE.search(cmd)
    if m:
        return int(m.group(2)) - int(m.group(1)) + 1
    m = _FOR_LIST.search(cmd)
    if m:
        items = m.group(1).split()
        if items and all(not any(ch in it for ch in "*?[]`") for it in items):  # `for f in *.txt` is no bound
            return len(items)
    return None


def self_matching_pgrep(cmd: str):
    for m in _PGREP_F.finditer(cmd):
        pattern = next(g for g in m.groups() if g is not None)
        if "[" in pattern:  # bracket trick: "[p]ytest" does not match itself
            continue
        return pattern
    return None


def wait_reason(command: str, cfg: Config, raw: str = None):
    """Why a command (its `views` wait projection) is a foreground wait, or None. `raw` keeps the quotes: a `pgrep -f`
    pattern lives in a string, which the wait projection hides."""
    sleeps = [float(n) * _UNIT[u] for n, u in _SLEEP.findall(command)]
    if not sleeps:
        return None
    longest = max(sleeps)
    if _LOOP.search(command):
        iterations = bounded_iterations(command)
        if iterations is None:
            budget = "a loop without an upper bound"
        else:
            total = iterations * longest
            if total <= cfg.max_bounded:
                return None
            budget = f"a loop of up to {iterations} iterations of {longest:g} s, up to {total:.0f} s"
        pattern = self_matching_pgrep(command if raw is None else raw)
        if pattern is not None:
            return (f"This is polling in a loop ({budget}) on `pgrep -f {pattern}` — the pattern matches the waiting "
                    "shell's own command line, so the loop never ends.")
        return f"This is polling in a loop ({budget}); Bash cuts it off at its timeout, not at the event."
    if longest > cfg.max_sleep:
        return f"This is `sleep {longest:g}` in the foreground — {longest:.0f} s of a held session without an event."
    return None


def detached_await(command: str) -> bool:
    """The whole command is ONE `await [options] -- COMMAND` without `--wait`: it returns at once and its supervisor does
    the waiting, which is what the guard's message asks for, so COMMAND being `gh pr checks N --watch` is not a status
    read by hand. Read from the shell's own tokens (quotes removed: `"--wait"` is `--wait`), and refused when in doubt:
    any control operator after it (`&`, `;`, `&&`, `||`, `|`, a group, a newline), any substitution (`$(…)`, a backtick),
    a `--wait` among its options, or a quote the tokenizer cannot close. `await` takes no abbreviations, so `--wai` is
    a usage error there, not a wait."""
    m = _AWAIT.match(command)
    if not m or re.search(r"[\n\r`]|\$\(|[<>]\(", command):
        return False
    try:
        lex = shlex.shlex(command[m.end():], posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        tokens = list(lex)
    except ValueError:
        return False
    if any(_CONTROL.fullmatch(t) for t in tokens) or "--" not in tokens:
        return False
    return "--wait" not in tokens[:tokens.index("--")]


def ci_reason(command: str, cfg: Config):
    """Why a (printing-stripped) command is a one-off CI status read, or None."""
    for seg in _SEGMENT_SEP.split(command):
        if any(p.search(seg) for p in cfg.ci_deny) and not any(p.search(seg) for p in cfg.ci_allow):
            return f"This is `{seg.strip()}` — reading CI status by hand."
    return None


def check(command: str, background: bool, cfg: Config):
    """(kind, reason) of a denial, or None. kind: wait | ci."""
    if background or not cfg.enabled or cfg.escape.search(command):
        return None
    wait_cmd, quoted, ci_cmd = views(command)
    r = wait_reason(wait_cmd, cfg, quoted)
    if r:
        return "wait", r
    try:
        r = None if detached_await(command) else ci_reason(ci_cmd, cfg)
    except Exception:  # noqa: BLE001 — fail-open
        r = None
    return ("ci", r) if r else None


def message(kind: str, reason: str, cfg: Config) -> str:
    head = ("Waiting in the foreground is not run (Delamain polling guard)." if kind == "wait" else
            "Reading CI status by hand in the foreground is not run (Delamain polling guard): every such read is "
            "a turn that re-reads the whole context.")
    instead = CODEX_INSTEAD if os.environ.get("AGENT_HUB_ENGINE") == "codex" or os.environ.get("CODEX_THREAD_ID") else INSTEAD
    return f"{head}\n\n{reason}\n\n" + instead.format(hint=cfg.hint, escape=cfg.escape_word)


def main() -> int:
    if sys.argv[1:] == ["--defaults"]:
        print(json.dumps({"AGENT_HUB_CI_STATUS_DENY": DEFAULT_CI_DENY, "AGENT_HUB_CI_STATUS_ALLOW": DEFAULT_CI_ALLOW},
                         indent=1))
        return 0
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(event, dict) or event.get("tool_name") != "Bash":
        return 0
    ti = event.get("tool_input") or {}
    command = ti.get("command")
    if not isinstance(command, str):
        return 0
    background = bool(ti.get("run_in_background"))
    if background:
        return 0
    try:
        hc = hubcore()
        hc.use_cwd(event.get("cwd"))
    except Exception:  # noqa: BLE001 — without the plugin's bin/ the built-in defaults still apply
        hc = None
    cfg = Config(cwd=event.get("cwd"), hc=hc)
    res = check(command, background, cfg)
    if res:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": message(res[0], res[1], cfg),
        }}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        code = main()
    except Exception:  # noqa: BLE001 — fail-open
        code = 0
    sys.exit(code)

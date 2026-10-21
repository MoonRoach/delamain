---
name: agy-review
description: Review a branch with Gemini 4 Argon through the Antigravity CLI (agy), detached and read-only. A reviewer skill for the hub (the contract in docs/reviewers.md), usually as an optional second opinion from another vendor. Use it when `hub reviewer` prints "load skill `delamain:agy-review`"; it takes a brief file, a checkout, a base sha and a head ref.
---

# Argon review through agy

Inputs from the hub: BRIEF (a file, from `templates/brief-review.md`), REPO (a checkout that has the head commit), BASE
(a sha), HEAD (a ref; the brief names `git diff BASE..HEAD`). The tool is `agy-review` in the plugin's `bin/` (on PATH
under Claude Code; otherwise `<plugin-root>/bin/agy-review`, the root being `PLUGIN_ROOT` in Codex and
`CLAUDE_PLUGIN_ROOT` in Claude). The review itself is Argon's, run by `agy`; this skill only starts it and says how to wait.

1. **Check.** `agy-review check`: exit 0 means `agy` is installed and Argon's weekly quota is not known to be below 20 %.
   Anything else: say so and stop; the hub takes the next reviewer. (`run` repeats the check and refuses with exit 3.)
2. **Start.** `agy-review run --cwd REPO --brief BRIEF --name review-<branch> [--add-dir DIR]... [--stage S]`. It prints
   `run: <dir>` and `model: <id>` and returns at once; the review runs detached. Material outside REPO (the author's
   report, the spec) goes in with `--add-dir`, because the reviewer reads the checkout and those directories only.
3. **Wait** for the file `<dir>/rc` with one `jwait --file <dir>/rc`, in the background; no polling loop. With `--stage`
   the run also journals a start line and `REVIEWED <dir>/final.md — rc 0` (or `EXIT agy-review …`).
4. **Result.** `rc` is `0`: the review is `<dir>/final.md`; say that path in your final message. `2`: agy ended without an
   answer even after two resumes: read `out-N.json` and `stderr.log`, say what happened, and the hub decides. Any other
   value is agy's own exit code (`128+N` after signal N).
5. **The hub verifies every finding against the code** before it goes to the author: a review is a colleague's opinion.

**Cost and quota.** One review of a real change costs 6–13 % of the Google AI Pro weekly Argon quota and takes 6–12 minutes
(`agy-review limits` shows what is left; `--min-left PCT` or `AGENT_HUB_AGY_REVIEW_MIN_LEFT` moves the floor of 20 %).
That is why the config entry marks it `"second": true` and the hub asks for it only when a miss would be costly. In a
trial on two real merge requests Argon and Codex found about as many real defects, and different ones.

**Read-only, in three lines.** The review runs under its own HOME (`<hub home>/agy-review-home`) with a `settings.json` the
tool rewrites on every run: only commands that cannot start another program are allowed (`git diff/log/show`, `grep`, `cat`,
`head`, `tail`, `ls`, …); writes, the web, MCP, shells, interpreters, `awk`, `find`, `sed`, `rg`, `sort`, `xargs`, build
tools and network and database clients are denied. `agy` runs with `--sandbox`, which leaves the network open, so it is the
list that keeps programs from starting; `--dangerously-skip-permissions` is never used.
Your own `~/.gemini/antigravity-cli/settings.json` is neither read nor written.

Verified on macOS with agy 1.4.0 only. Linux and Windows are untested.

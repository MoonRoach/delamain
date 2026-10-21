# Reviewers

A review is a second reader of a change before it merges: a colleague's opinion that the hub checks against the code.
The hub does not hard-code who that colleague is. **By default a reviewer is an ordinary `agent spawn`** — a headless
agent with a review brief. A user who has something better to hand — a reviewer skill of their own, another vendor's
CLI, a cloud service with its own quota — plugs it in as a *reviewer skill* and lists it ahead of the default.

`hub reviewer` answers one question: *which reviewer, for this change, right now, and exactly how do I start it.*

The hub fills the review template's helper threshold from `hub reviewer` (`helper_threshold` in `--json`).
`AGENT_HUB_REVIEW_HELPER_LINES` is a non-negative integer (default 300 additions + deletions), read from env,
repository config or hub-home config; surrounding whitespace is ignored and an invalid value warns and falls back to 300.
Zero disables the size restriction, while named risks, disjoint scopes and call budgets still apply to judgement helpers. Below it, the reviewer starts no judgement-helper team; bounded mechanical
extraction is allowed. Larger deltas require named risks, disjoint scopes and call budgets before helpers start.

## Configuration

The setting `AGENT_HUB_REVIEWERS` is an ordered JSON list; the first entry that is available wins. Like every setting
it comes from the environment, a repository's `.agent-hub/config.json` or the hub home's `config.json`, in that order
([Configuration](reference.md#configuration)):

```json
{"AGENT_HUB_REVIEWERS": [
  {"name": "my-review-skill", "kind": "skill", "skill": "my-review-skill",
   "check": "my-review-quota --ok", "until": "2026-12-31", "for": ["code", "risky"]},
  {"name": "agent", "kind": "agent", "model": "opus", "effort": "high"}]}
```

| Field | | Meaning |
|---|---|---|
| `name` | required | Unique. An `agent` reviewer's role is `review-<name>`. Letters, digits, `.`, `_`, `-`; 64 characters at most. |
| `kind` | required | `agent` — a headless agent started with `agent spawn`; `skill` — a reviewer skill (contract below). |
| `skill` | kind `skill`, required | The skill's name, as the Skill tool knows it: letters, digits, `.`, `_`, `-` (64 characters at most), and one `:` for `plugin:skill`. |
| `model`, `effort` | kind `agent` | Default from `AGENT_HUB_REVIEW_MODEL` (`opus`) and `AGENT_HUB_REVIEW_EFFORT` (`high`). `model` is what `agent spawn --model` takes: `opus`, `sonnet`, `haiku`, `fable`, an alias of `AGENT_HUB_MODEL_MAP`, or a full id `claude-…` (letters, digits and `. _ : @ [ ] -` only, 100 at most — a Vertex id `claude-sonnet-4-5@20250929` is fine); `effort` one of `low`, `medium`, `high`, `xhigh`, `max`. A haiku reviewer gets its `effort` like any other (Haiku 5.5 has the setting; Haiku 4.5 ignores the flag). |
| `check` | optional | A shell command; exit 0 means "available now" — a quota probe, a login check. The verdict is the shell's own exit: a background child that keeps the output open does not hold it up. It runs in the hub home — not in the repository you are working in, whose `make`, `./script` or `npm` it would otherwise run — with a 10 s timeout (`AGENT_HUB_REVIEW_CHECK_TIMEOUT`, in seconds, finite and above 0, overrides it); on expiry its whole process group is killed. Its output is shown only by `--all`. |
| `until` | optional | `YYYY-MM-DD`: available through that day (hub time zone), not after — for a quota or a credit that expires. |
| `for` | optional | The change classes the entry serves (next section), each made of letters, digits, `.`, `_`, `-` (64 characters at most). Absent: every class. |
| `second` | optional | `true` or `false` (a JSON boolean, nothing else). `true`: the entry serves [second opinions](#a-second-opinion) only; a plain `hub reviewer` walk passes over it without running its `check`. |

Rules the tool enforces:
- **A `check` from a repository's config is never run.** A cloned repository must not run commands through the hub:
  such an entry is skipped, with a warning that names it. Put entries with a `check` in the environment or in the hub
  home's `config.json`. (An entry without a `check` works from either place.) The refusal covers the hub's own config
  files only: the environment is trusted, and a repository's `.claude/settings.json` has an `env` block that Claude
  Code applies to the session once you trust the folder — it can set `AGENT_HUB_REVIEWERS`, `check` included, and the
  hub cannot tell that from you setting it. Trust a folder only if you would run its commands.
- **Nothing a repository writes reaches the line the hub runs, or the text it reads, unchecked.** `name`, `skill`,
  `model`, `effort` and the change classes must match the patterns above whichever layer they come from; an entry that
  does not is reported and skipped, and a rejected key or value is echoed back cut to 30 characters. The `agent spawn` line the hub is told to run has every value shell-quoted. `--json` repeats the text of a `check` only for an entry whose check was run. An alias of `AGENT_HUB_MODEL_MAP` must stand for a model id too (letters, digits and `. _ : @ [ ] / -`, so a Bedrock id or an inference-profile ARN is fine); a pair outside that is reported and left out.
- **A broken entry is reported and skipped, never a crash.** Not an object, a missing or duplicate `name`, an unknown
  `kind`, a `skill` entry without a valid `skill`, a field that belongs to the other kind, a bad `model`, `effort`,
  `until` or class, a `second` that is not a boolean, an unknown field (a misspelt `for` must not quietly widen an entry to every class). A list with no valid entry — or
  not valid JSON — falls back to the built-in default.
- **The built-in default** when nothing is set is one entry, `{"name": "agent", "kind": "agent"}`, with the model and
  effort from `AGENT_HUB_REVIEW_MODEL` and `AGENT_HUB_REVIEW_EFFORT`.
- There is no implicit fallback: if every listed entry is unavailable, `hub reviewer` exits 1. Keep an `agent` entry
  last if a review must always be possible.

## Choosing

```
hub reviewer [--for CLASS] [--author ROLE|ENGINE[/MODEL]] [--stage STAGE] [--json] [--all] [--second]
```

It walks the list in order and stops at the first entry that is available now: not past its `until`, serving the
class `--for` names (without `--for` no entry is filtered by class), and — if it has a `check` — passing it. It prints
the choice and how to start it:

```
$ hub reviewer --for code
reviewer: my-review-skill (skill my-review-skill)
start: load skill `my-review-skill`; give it the brief file, the repository, the base sha and the head ref (…)

$ hub reviewer --for docs        # the skill serves code and risky only
reviewer: agent (agent opus/high)
start: agent spawn --role review-agent --cwd <REPO> --model opus --effort high --brief <BRIEF>

$ AGENT_HUB_ENGINE=codex hub reviewer --for code --stage web
reviewer: agent (agent gpt-6-astra/high)
start: agent spawn --role review-agent --cwd <HUB_HOME>/web/coordinator/work --engine codex --sandbox workspace-write --model gpt-6-astra --effort high --stage web --brief <BRIEF>
```

For a Claude `agent` reviewer the hub fills `<REPO>` (a checkout holding the head commit) and `<BRIEF>` (the brief
file). For a Codex `agent` reviewer it prints `--sandbox workspace-write` and `--cwd` pointing to the stage's
`coordinator/work` under the hub home. Without a stage, replace `<HUB_WORK>` with a directory under the hub home.
Create that directory before spawning, and put the absolute repository path, base and head in the brief for reading.
The reviewer receives only its cwd as a writable root; wider explicit roots are refused, and temporary-directory
writes are excluded. Home configuration and other agents' inboxes stay read-only. Keep the repository outside the
hub home and the chosen cwd; do not add it to writable roots. The sandbox then lets
Codex write its report and journal, while repository writes are denied. `read-only` cannot write either; spawning a
Codex review role/tag with that policy emits one warning. Claude's review brief prohibits repository edits; it does
not acquire a Codex sandbox through this command. In both cases run the line with **no `--worktree`**: a reviewer
reads the existing checkout. With `--stage S` (else `$HUB_STAGE`) the line
carries `--stage S`, so the reviewer joins that stage whatever the shell's `HUB_STAGE` is. `agent spawn` refuses a role whose agent still
runs, so a second review at the same time takes another `--role`. For a `skill` reviewer the hub loads the skill and
gives it the four inputs of the contract.

`--author` names who wrote the change, so the reviewer is chosen by that and not by the engine of the hub that runs
the command (see [the author](#the-author-of-the-change)). `--all` judges every entry and prints why each one passed or not (check exit code, `until` passed, class mismatch,
invalid), with the output of each `check`. `--json` prints the same as JSON (`chosen`, `start`, `entries`,
`invalid`). Exit 0 with a choice, 1 when none is available, 2 on a usage error. Nothing is written. `--second` asks for
a [second opinion](#a-second-opinion) instead.

## The author of the change

A reviewer must come from who *wrote* the change, and the hub's host says nothing about that: a Claude hub reviews
Codex-written changes and the other way round. So `hub reviewer` takes the author as an argument:

| `--author` | The author is |
|---|---|
| `claude`, `codex` | that engine, model unknown |
| `claude/opus`, `codex/gpt-6.1-sol` | that engine and model (the model: letters, digits and `. _ : @ [ ] / -`) |
| a role, e.g. `fix-parser` | the agent of that role in `--stage` (else `$HUB_STAGE`): its `engine` (absent means Claude) and its `resolved_model`, else `model`, from `agents/<role>/meta.json` |

An author that is none of these (an unknown engine, a role with no `meta.json`, a role and no stage) is a usage error,
exit 2: a mistyped author must not quietly turn into the host. The output names the author and where it came from
(`author: codex/gpt-6.1-sol (role fix-parser)`); `--json` has `author` (`engine`, `model`, `source`).

**Without `--author`** the author is unknown. `hub reviewer` assumes the host engine wrote the change, says so on
stderr (`author unknown: assuming the host engine (claude) …`) and prints `author: unknown, host engine … assumed`;
`--json` has `author: null` and `assumed_author_engine`. A hub that knows the author always passes it.

**For check authors.** Every `check` runs with two more environment variables:

| Variable | Value |
|---|---|
| `AGENT_HUB_REVIEW_AUTHOR_ENGINE` | `claude` or `codex` |
| `AGENT_HUB_REVIEW_AUTHOR_MODEL` | the author's model, empty when `--author` gave only an engine |

Without `--author` both are *removed* from the check's environment, even if the caller's shell has them: absent means
"unknown", and a check then falls back to its own guess (the host engine, `engines.selected()`). A check that rules an
entry in or out by the author's engine — "a Claude reviewer only for a Codex author" — reads the variable instead of
guessing the host. The variables are also the place for the rule above ("a different model from the author").

**The built-in default** (no valid list) follows the author as well: for a Codex author it is a Claude reviewer
(`opus`), for a Claude author a Codex reviewer (`gpt-6-astra`, read-only) when the `codex` CLI is installed (`CODEX_BIN`),
otherwise Claude as before. Without `--author` it stays the host engine's.

**A check should be forgiving about missing limit data.** Limits choose the engine for a launch; they rule an engine out
only when it is practically exhausted. A check that sees no observation, or one too old to trust, should report the
engine as available (exit 0) and refuse only on a known window above the threshold — otherwise a hub that has no recent
data of the other engine silently falls back to a reviewer of the author's own engine.

## Change classes

The class says how much review a change deserves; the hub decides it before asking for a reviewer. Three are
recommended; the names are free (`--for` and `for` just compare strings), so a team can add its own.

| Class | The change | Review |
|---|---|---|
| `docs` | Documentation only, or tooling and configuration whose own positive and negative controls were run and are shown in the PR | None by a model: CI and the author's controls are the check. |
| `code` | Any other change to code | One review. |
| `risky` | Money, migrations, production, permissions | One review by default, with its brief narrowed to that risk ("Look hardest at" in the template). The hub **may** add one [second opinion](#a-second-opinion) from a different vendor when a miss would be costly and that reviewer's quota allows: its decision, never a default and never required. |

*Why:* a review costs a full read of the diff and its context, and a second reviewer of the same vendor on the same
risk mostly finds the same thing twice, so one review is the default; a narrower brief gets more out of one reader than
a second reader gets out of a wide one. A reader from another vendor is a different case. In a trial on two real merge
requests (one small, one large and risky) Google's Gemini 4 Argon and a Codex reviewer found about as many real defects,
and mostly different ones: each missed what the other found, and neither reported a defect that was not there. That is
worth a second read when a miss is expensive, and not worth one on every change, because such a reviewer has its own
quota (one Argon review took 6–13 % of a Pro week). When the author cannot tell whether a change needs a review at all,
it reviews and says why in the PR.

## A second opinion

```
hub reviewer --second [--for CLASS] [--author ROLE|ENGINE[/MODEL]] [--stage STAGE] [--json] [--all]
```

It chooses the primary reviewer exactly as the plain walk does, then walks the list again, skips that entry and returns
the first other available one, in list order: an entry marked `"second": true` and an ordinary entry alike. The output
names it (`reviewer: argon (skill delamain:agy-review) — second opinion, the primary is skill-a`) and prints its start
line as a plain choice does. `--json` adds `"second": true` and `"primary"` (the primary's name, or null when no ordinary
entry is available; a second entry is then still returned if one is). Exit 1 means only that there is no second opinion
(no other entry is available): the primary review stands, and the hub goes on without one.

An entry with `"second": true` is skipped by a plain `hub reviewer`, so listing a costly reviewer that way keeps it out of
the default choice. The second opinion is optional and the hub's own call: no class requires it, and at most one is added.
Start it beside the primary review (an `agent` entry with its own role, a skill with its own run), and verify its findings
against the code like the primary's.

## The reviewer is a different model from the author

Recommended rule: whoever wrote a change does not review it — `--author` is how `hub reviewer` knows who that was — and a reviewer from the same model family as the author
tends to read the code the way it was written. Pick `AGENT_HUB_REVIEW_MODEL` (and the `model` of `agent` entries)
different from the model your executors write with, or list a reviewer skill that runs another vendor's model.
*Why:* a weaker or identical reader returns a confident summary of the diff, which reads like agreement.

For Sol-authored work, prefer Claude Opus/Fable at high when its quota permits, then Codex Astra at high. Do not
substitute an older Sol merely to change the model id. Reviewer engines are independent of the implementation
engine. Put limited reviewers first with a trusted `check`, followed by the fallback; the built-in Codex agent
reviewer uses `gpt-6-astra` rather than inheriting a Sol implementation default. `AGENT_HUB_REVIEW_MODEL` and explicit
entries still override that default. Check actual CLI model availability before launching the printed command.

## The brief

The hub writes the brief and launches the reviewer; the author of the change does neither.

`${CLAUDE_PLUGIN_ROOT}/templates/brief-review.md` is a self-contained review brief: what changed and why, the diff
(`git diff <base sha>..<head sha>`), where to look hardest, read-only, findings ranked high / medium / low with
`file:line`, a concrete failing scenario and a one-sentence fix, a verdict (`merge`, `merge after fixes`, `changes
requested`), and "say if you ran the tests". A read-only reviewer (a Codex `read-only` sandbox cannot write files or
create temp dirs) returns the review as its final answer and the caller saves it; the brief carries the author's test
commands with their exit codes and tells the reviewer not to rerun them unless a finding needs it. Its *Round N* section is for the next rounds: paste the previous round's
findings verbatim and limit the scope to the fix commits. At most three rounds per artifact (the hub skill's rule 5).

## The skill reviewer contract

A reviewer skill is any skill that follows this contract; the hub knows nothing else about it.

- **Input**, given by the hub when it loads the skill: the path of the brief file, the repository directory (a checkout
  that has the head commit), the base sha and the head ref.
- **It may run detached** — a CLI started in the background, a cloud session, a queue. It then says how the hub should
  wait for it (typically a file to watch with `jwait --file`, or a `Monitor`), and the hub waits the way its skill
  says: one waiter, no polling loop.
- **Output**: the review in a file, and the file's path in its final message (a reviewer that cannot write returns the
  review as its final answer, and the caller saves it). The format is the brief's: findings ranked, each with
  `file:line`, a scenario and a fix, then a verdict line.
- **The hub verifies each finding against the code before acting on it.** A review is a colleague's opinion: the hub
  confirms the cited line says what the finding claims, reproduces the scenario or reads it through, and only then
  hands the author a fix list — dropping what does not hold.
- It does not edit, commit or push. It may run the tests.

### Writing one

A reviewer skill is a `SKILL.md` that turns the four inputs into a call to whatever does the review. Skeleton:

```markdown
---
name: my-review-skill
description: Review a branch with <tool>. Use when the hub asks for a reviewer — it gives you a brief file, a
  repository, a base sha and a head ref.
---

Inputs: BRIEF (a file), REPO (a directory), BASE (a sha), HEAD (a ref).

1. Check the tool is usable: `my-review-quota --ok` (exit 0). If not, say so and stop — the hub picks the next reviewer.
2. Run it detached, read-only, in REPO, with BRIEF as its prompt and `git diff BASE..HEAD` as the change, writing the
   review to a file under the stage's `coordinator/work/` directory (`review-<head>.md`).
3. Say, in one message: the path of the review file, and how to know it is finished (the last line of the file is
   `VERDICT: …`).
```

Then list it: `{"name": "my-review-skill", "kind": "skill", "skill": "my-review-skill", "check": "my-review-quota --ok"}`
— the `check` lets `hub reviewer` skip it before anyone loads the skill when the quota is gone.

## The bundled Argon reviewer (`agy-review`)

The plugin ships a reviewer skill, `delamain:agy-review`, and the tool behind it, `bin/agy-review`: a read-only review by
Google's Gemini 4 Argon through the Antigravity CLI (`agy`). It is a third vendor beside Claude and Codex, plugged in as a
reviewer skill; it is not an `agent spawn` engine. Verified on macOS with agy 1.4.0 and a Google AI Pro account (Argon has
a weekly quota of its own there). **Linux is untested**: the review HOME links the macOS keychain (`~/Library`) and the
tool guesses nothing about another layout.

List it in the hub home's `config.json` (an entry with a `check` is never taken from a repository's config):

```json
{"AGENT_HUB_REVIEWERS": [
  {"name": "argon", "kind": "skill", "skill": "delamain:agy-review", "second": true,
   "for": ["code", "risky"], "check": "agy-review check"},
  {"name": "agent", "kind": "agent"}]}
```

- `skill` is `plugin:skill`; the plugin is `delamain`. With `"second": true` a plain `hub reviewer` never picks it; ask for
  it with [`hub reviewer --second`](#a-second-opinion), at the hub's discretion. Drop `second` and list it ahead of the
  others only if you want Argon to be the primary reviewer.
- `check` runs in the hub's environment, so `agy-review` must be on that `PATH`: the plugin's `bin/` is, in Claude Code.
  Where it is not (a Codex hub, a plain terminal), `hub reviewer --all` shows `check exited 127`; write the absolute path
  of the plugin copy's `bin/agy-review` instead. Exit 0 means `agy` is on `PATH` (or `AGENT_HUB_AGY_BIN` names it) and
  Argon's weekly quota is not *known* to be below 20 %; an unreadable quota counts as available. The reading is cached
  for 10 minutes in `<hub home>/agy-limits.json`, takes about 2 s, and is capped well inside the 10 s check timeout.

`agy-review run --cwd <checkout> --brief <file> [--model M] [--name N] [--add-dir D]... [--min-left PCT] [--stage S]`
starts the review detached and prints `run: <dir>` (`<hub home>/agy-runs/<name>-<time>`) and `model: <id>`. The directory
holds `brief.md` (the brief plus a read-only footer), `out-N.json` (agy's answer per attempt), `final.md` (the review),
`usage.json` (summed tokens, duration, attempts, conversation id, denied actions), `stderr.log`, `meta`, `pid` and `rc`,
written last. `rc`: `0` the review is in `final.md`; `2` agy finished without an answer even after two resumes; any other
value is agy's own exit code. The hub waits with one `jwait --file <dir>/rc`. With a stage the run journals a start line
and `REVIEWED <dir>/final.md — rc 0` (`EXIT agy-review …` when there is no review). `run` refuses with exit 3 when `agy`,
the checkout or the brief is missing, or when the weekly Argon quota is known to be below `--min-left` (default 20 %).
`agy-review limits [--json]` prints the quota; `agy-review run --dry-run` prepares everything and starts nothing.

| Setting (environment or the hub home's `config.json`; never a repository's) | Default | Meaning |
|---|---|---|
| `AGENT_HUB_AGY_BIN` | `agy` on `PATH` | The agy executable. |
| `AGENT_HUB_AGY_REVIEW_MODEL` | `gemini-4-argon-high` | The model id passed to `agy --model`; `--model` wins. |
| `AGENT_HUB_AGY_REVIEW_MIN_LEFT` | `20` | Percent of Argon's weekly quota below which `run` refuses and `check` fails. |

**Read-only.** The review runs under its own HOME, `<hub home>/agy-review-home`, which links only the sign-in files of
`~/.gemini` and `~/Library`. Its `settings.json` is rewritten on every run: only reading commands are allowed (`git
diff/log/show/grep/blame`, `rg`, `grep`, `ls`, `cat`, `head`, `sed -n`, `find`, …); writes, the web, MCP, shells,
interpreters, build and test runners, and network and database clients are denied, and a deny rule beats an allow rule.
`agy` runs with `--sandbox`, which stops shell writes (also inside the checkout) but not the network. The tool never
passes `--dangerously-skip-permissions`: with it the file tool writes outside the checkout even under `--sandbox`. The
owner's own `~/.gemini/antigravity-cli/settings.json` is never read or written. A headless `agy` ends its run without an
answer when the model calls a command that is neither allowed nor denied; the tool then resumes the same conversation, at
most twice (a real review needed one or two resumes).

**Cost.** One review of a real change took 6–12 minutes and 6–13 % of a Pro week's Argon quota, so roughly eight to fifteen
reviews a week: a second opinion for changes where a miss is expensive, not a review of every change.

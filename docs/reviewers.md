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
  `until` or class, an unknown field (a misspelt `for` must not quietly widen an entry to every class). A list with no valid entry — or
  not valid JSON — falls back to the built-in default.
- **The built-in default** when nothing is set is one entry, `{"name": "agent", "kind": "agent"}`, with the model and
  effort from `AGENT_HUB_REVIEW_MODEL` and `AGENT_HUB_REVIEW_EFFORT`.
- There is no implicit fallback: if every listed entry is unavailable, `hub reviewer` exits 1. Keep an `agent` entry
  last if a review must always be possible.

## Choosing

```
hub reviewer [--for CLASS] [--author ROLE|ENGINE[/MODEL]] [--stage STAGE] [--json] [--all]
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
```

For an `agent` reviewer the hub fills `<REPO>` (a checkout holding the head commit) and `<BRIEF>` (the brief file) and
runs the line as it is — **no `--worktree`**: a reviewer only reads. With `--stage S` (else `$HUB_STAGE`) the line
carries `--stage S`, so the reviewer joins that stage whatever the shell's `HUB_STAGE` is. `agent spawn` refuses a role whose agent still
runs, so a second review at the same time takes another `--role`. For a `skill` reviewer the hub loads the skill and
gives it the four inputs of the contract.

`--author` names who wrote the change, so the reviewer is chosen by that and not by the engine of the hub that runs
the command (see [the author](#the-author-of-the-change)). `--all` judges every entry and prints why each one passed or not (check exit code, `until` passed, class mismatch,
invalid), with the output of each `check`. `--json` prints the same as JSON (`chosen`, `start`, `entries`,
`invalid`). Exit 0 with a choice, 1 when none is available, 2 on a usage error. Nothing is written.

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
| `risky` | Money, migrations, production, permissions | The **same single review**, with its brief narrowed to that risk ("Look hardest at" in the template) — not a second reviewer. |

*Why:* a review costs a full read of the diff and its context, and a second reviewer on the same risk mostly finds the
same thing twice. A narrower brief gets more out of one reader than a second reader gets out of a wide one. When the
author cannot tell whether a change needs a review at all, it reviews and says why in the PR.

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

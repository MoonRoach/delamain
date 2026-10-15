# Brief: review <branch or PR> in <repository>

<!-- Self-contained brief for a reviewer — an `agent` reviewer (`hub reviewer` prints its `agent spawn` line) or a
reviewer skill; docs/reviewers.md has the contract. The reviewer has not seen the conversation: everything it needs
is here. Fill every <…>; delete the "Round N" section for a first review.
The hub writes this brief and launches the reviewer, never the author of the change: an author's brief steers the
reviewer to what the author already checked. For money, masking and permissions narrow "Look hardest at" to that
risk and leave style out. -->

## What changed and why
<The problem in two or three lines, with a source (an issue, a journal line, a report). Then what the change does,
one line per file or area that matters. Name the decisions the owner already took that the change relies on —
"do not reopen" for the reviewer too.>

## The change
- Repository: `<absolute path of a checkout that has the head commit>`
- Base: `<base sha>`   Head: `<head ref or sha>`
- Diff: `git diff <base sha>..<head sha>`; the commits: `git log --oneline <base sha>..<head sha>`
- Tests the author ran: `<command>` → exit `<code>` (one line per command, exit codes read from files, not pipes);
  what a green run proves, and what it does not. Do not rerun them unless a finding needs it.

## Helper budget
- Changed lines (additions + deletions): `<sum from git diff --numstat <base>..<head>; report binary files separately>`.
- Judgement-helper threshold: `<hub reviewer helper_threshold; AGENT_HUB_REVIEW_HELPER_LINES from config/env, default 300>`.
  Below that threshold, the reviewer does the review itself and starts no helper review team. At or above it, helpers
  need a named missed-defect risk, disjoint scopes and explicit call budgets; keep one final reviewer verdict.
  Mechanical extraction helpers are allowed at any size with exact paths, checkable evidence and a bounded call budget.
  A small delta does not justify repeatedly loading the full conversation into a review team.

## Look hardest at
<The two to five places where a mistake costs the most or the author is least sure: a migration, a permission check,
money arithmetic, a retry loop, a rename that missed a caller. For a change of class `risky` (money, migrations,
production, permissions) say here which risk the review is narrowed to, and leave style out.>

## How to review
- **Repository is read-only.** Do not edit, commit, push, merge or run anything that changes repository state.
  Read anything in the repository; rerun a test only when a finding needs it (the author's results are above).
  Write your report and journal line under the hub home. A Codex reviewer uses `workspace-write` with cwd there,
  and the reviewed repository outside writable roots; `read-only` cannot write the report or journal.
- Check the change against the intent above, not only the diff in isolation: read the callers and the tests of what it
  touches. Cap the reading by the diff size: a small diff reads its callers and tests, not the repository.
- Findings, ranked **high** (wrong result, data loss, security, breaks the build), **medium** (a real defect with a
  narrower trigger, a missing test for new behaviour) and **low** (style, naming — only if cheap). For each:
  `file:line` — the defect in one sentence — a concrete failing scenario (inputs or state, and the wrong output or
  crash) — the fix in one sentence. A finding without a scenario is an opinion: say so, or leave it out.
- No praise and no summary of the diff. If nothing is wrong, say "no findings" and what you checked.
- Say whether you ran any test, which, and the result. "Not run" is an acceptable answer; a guess is not.

## Answer
Return the review as your final answer, findings first, then one verdict line — do not write a file: the caller saves
it to `<review file>`.

`VERDICT: merge` | `VERDICT: merge after fixes` (every high and medium finding is fixable without a redesign) |
`VERDICT: changes requested`

At most <N> tool calls: if you are not done by then, stop and return what you have and what is left.

## Round N (delete for a first review)
<!-- From the second round on. -->
This is round <N>. The previous round's findings, verbatim:

```
<paste the previous review's findings here, unedited>
```

- Review only the fix commits: `git diff <previous head sha>..<new head sha>`. Do not re-review what the earlier round
  already covered.
- For each earlier finding say **fixed** (and where), **not fixed**, or **disagree** with the author's reason, quoted.
- A new finding inside the fix commits is in scope. One outside them counts only if it is **high** and has a concrete
  failing scenario; from round three on, that holds for every new finding.

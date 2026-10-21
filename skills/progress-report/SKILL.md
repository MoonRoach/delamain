---
name: progress-report
description: Build a one-page infographic status of a stage, phase or project for the owner and the team — how many tasks are done out of how many, per-track cards, the road to the end and the open decisions — as an HTML page from the bundled template. Use for “status with an infographic”, “progress report”, “how much is left”, “статус с инфографикой”, “сколько осталось по фазе”, “отчёт о прогрессе для команды”. Not for live agent status (skill `status`) or a shift handoff (skill `handoff`).
argument-hint: "[stage or phase] [audience]"
---

# Progress report

The page answers one question for a reader who was not in the work: *how much is done, what is left, what needs me*.
Every number on it is computed from a list of tasks, so the headline, the bar and the track counters cannot disagree.

1. **Fix the scope and the denominator.** Name the unit (a phase, a stage, a milestone) and its task list: the plan,
   specs or roadmap where the tasks are written down. The total is that list, not what happens to have activity.
   If the plan has no exit criterion or names deliverables without tasks, say so in a note; do not invent tasks.
2. **Establish each task's status from sources, not from memory.** In order of weight: what runs in production
   (deploy tag, release, prod check), merged changes on the main branch, open MRs/PRs and their CI and review state,
   the hub journal, handoffs, the question register (`ask summary`) and live agents (`<plugin-root>/bin/agent-top --json`,
   see skill `status`). Resolve the plugin root from `PLUGIN_ROOT`, `CLAUDE_PLUGIN_ROOT` or this skill's location.
   Delegate wide reading by the session's delegation rules. A task whose status you cannot establish is `planned`
   with a label saying it is unverified — never `done`. Record the sources for the footer.
3. **Map to the six statuses.** `done` — in production (or the scope's own definition of done, stated in the lede);
   `review` — implemented, in review or CI, or approved and waiting for merge; `active` — being done or rolled out now;
   `planned` — specified, not started, or waiting on another task; `decision` — waiting for the owner's decision or a
   missing spec; `dropped` — removed from scope (shown struck through, excluded from the total). The `label` of an item
   refines the pill (“CI green, to merge”, “target 01.11”) without changing its status.
4. **Fill the template.** Copy `<plugin-root>/skills/progress-report/resources/template.html`, set `<title>` (two to
   four words, e.g. “Phase D status”), and replace only the JSON in `<script id="report">`:
   - `eyebrow`: project · stage · date and time with time zone; `headline` with `{count}`, `count_format`
     (`{done} of {total}`; any status key, `total` and `dropped` are available, also in `lede` and `track_count_format`);
   - `lede`: two or three sentences — what is almost done, what it would add up to, what is blocked;
   - `statuses`: pill and legend labels in the reader's language;
   - `tracks[]`: `title`, `summary` (what the track gives its users when done), `items[]` of `code`, `title`,
     `status`, optional `label`; optional `wide` (default: more than eight items);
   - `road[]`: up to four steps with `kind` `now` / `soon` / `next` / `decision`, `when`, `title`, `items[]` —
     the decisions the owner owes go in the `decision` step, with task codes;
   - `notes[]`: gaps the reader must know about (no exit criterion, stale roadmap row, tasks without specs);
   - `foot`: sources, the prod tag or commit, what is out of scope.
   Text is plain; `backticks` render as code. Write in the reader's language and in outcomes, not process.
5. **Check before showing.** Open the page (built-in browser, or `python3 -m json.tool` on the JSON at least) and
   confirm no red problem banner, that the headline total equals the planned task list, and that every number in
   the lede matches the computed ones. Check it at phone width.
6. **Deliver.** Where the host can publish a private page (Claude Code's Artifact tool), publish it there with a
   one-sentence description and give the link; otherwise save it as
   `<stage>/coordinator/progress-<YYYY-MM-DD>.html` in a hub stage, or next to the work, and give the path.
   Sharing the page beyond the owner leaves the company only on the owner's word.

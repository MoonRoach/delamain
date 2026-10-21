---
name: progress-report
description: Build a one-page infographic status of a stage, phase or project for its owner, team or client — how much is done by the scope's own definition of done, what changed since the last report, per-track items, figures with their sources, what is left and who it waits on — as an HTML page from the bundled template. Use for “status with an infographic”, “progress report”, “how much is left”, “статус с инфографикой”, “сколько осталось по фазе”, “отчёт о прогрессе для команды”. Not for live agent status (skill `status`) or a shift handoff (skill `handoff`).
argument-hint: "[stage or phase] [reader] [deadline]"
---

# Progress report

The page answers, for a reader who was not in the work: *how much is done, what changed, what is left, what needs me*.
Counts and the bar are computed from a list of items, so they cannot disagree; anything typed by hand carries a source.
Development methods differ — many MRs or one per phase, a tracker or a checklist, production or a release tag or no
code at all — so the scope's own definition of done drives every step, not a default.

1. **Pick the shape before collecting anything.** Answer in a few lines of text now, and offer the page afterwards,
   when the reader needs it within ~30 minutes, the reader is another hub or agent, or the stage is small, idle or
   closed and its whole status fits in two lines. The page pays off for work with several items, a reader outside the
   work, or a recurring request (the next report reuses this one).
2. **Fix the scope, the item, and what done means.** The item is whatever the work is tracked by: tracker issues, a
   task list in an issue, the checklist of a spec or of a single phase MR, plan steps, register entries (`P-`, `Q-`),
   acceptance criteria, measurements. Write `done_means` in the reader's words: “on production”, “merged and tagged”,
   “ticked in the phase checklist, deploys at the end of the phase”, “accepted by the owner”, “it runs locally”.
   The total is the written scope. With no written list, build it from the plan, registers and journal, say so in a
   note with the date, and do not pad it; if the plan ends before the stage's goal, add the goal as an item.
3. **Establish each item's status from the evidence its `done_means` points at**: deploy or release tags, merged
   changes, MR/PR state and CI, ticked boxes in the spec or issue, the tracker, a run or test you can repeat, data you
   can re-read, the owner's recorded acceptance, the hub journal, handoffs, `ask summary`, live agents
   (`<plugin-root>/bin/agent-top --json`, skill `status`). Resolve the plugin root from `PLUGIN_ROOT`,
   `CLAUDE_PLUGIN_ROOT` or this skill's location; delegate wide reading by the session's rules. Record the sources.
4. **Map to the statuses.** `done` meets `done_means`; `review` is finished and awaiting a check (review, CI, test
   window, deploy) — when one MR carries the whole phase, say in the label or a note that it is checked as one;
   `active` is being done now; `planned` is not started; `blocked` waits on someone outside the reader's control
   (another team or hub, a vendor, a delivery); `decision` waits on the reader or owner; `unknown` could not be
   verified — never `done`; `dropped` left the scope (label it, e.g. “→ next phase”; it is excluded from the total).
   An item's `label` refines its pill without changing its status.
5. **Fill the template.** Copy `<plugin-root>/skills/progress-report/resources/template.html`, set `<title>` (two to
   four words) and replace only the JSON in `<script id="report">`:
   - `lang`, `eyebrow` (scope · date and time with zone), `headline` with `{count}`, `count_format` (any status key,
     `total` and `dropped` are available, also in `lede` and `track_count_format`), `done_means`, `lede`;
   - `show_bar`: `false` when progress is not a share of items — a measurement, an incident window, a single
     deliverable; the headline then states the result in words and `metrics` carry the figures;
   - `metrics[]`: `label`, `value`, `source` (where it was read, and when) — money, scores, times, sizes; a figure
     without a source is flagged on the page;
   - `statuses`: pill and legend labels in the reader's language;
   - `tracks[]`: `title`, `summary`, `items[]` of optional `code`, `title`, `status`, optional `label`; optional `wide`;
   - `previous`: `date` and `items` copied from the previous report's saved JSON (each with `code` or `title` and
     `status`), with `changes_format` (`{date}`, `{done_delta}`, `{added}`, `{removed}`): the page computes what
     moved and how the scope changed, so a grown total does not read as regression;
   - `road[]`: steps with `kind` `now` / `soon` / `next` / `blocked` / `decision`, `when`, `title`, `items[]`;
   - `notes[]`: gaps the reader must know (no exit criterion, a reconstructed list, stale roadmap); `foot`: sources.
   Text is plain; `backticks` render as code. Write for the reader: outcomes, not process; leave out what the reader
   must not see (another person's pending decisions, internal topology) rather than relying on the page being private.
6. **Check before showing.** Render the page (built-in browser, or at least `python3 -m json.tool` on the JSON) and
   confirm: no red problem banner; the total is the scope from step 2; every typed number in the lede, labels and
   `metrics` was re-read from its source in this run; it reads at phone width.
7. **Deliver where the reader is.** Save the HTML and its JSON side by side (the JSON feeds the next `previous`):
   `<stage>/coordinator/progress-<YYYY-MM-DD>.html` in a hub stage, otherwise next to the work. Then: for the owner in
   Claude Code, a private page via the Artifact tool; for a reader in a tracker issue or chat, a phone-width
   screenshot or a short markdown summary with the file; for anyone else, the self-contained HTML file (it renders
   offline with system fonts). Money, personal data, production topology or a stage rule against publishing — ask
   the owner before any hosted copy. Sending anything outside the company is the owner's call.

# Codex hubs and Codex executors

Read this at start when you run in Codex, and whenever an executor runs on Codex. A Codex hub also reads
[autopilot.md](autopilot.md) (Desktop native launch, the automatic successor prompt). The sections below were moved
whole from the hub skill; the core `SKILL.md` keeps the Claude path.

## Engine, models and hook trust

The text below is the full engine choice of *Host and engine* (the core `SKILL.md` keeps a short form), then the Codex model and CLI checks moved from *Executors*.

Choose the executor engine before choosing a model. Offer the owner one engine choice during initial stage planning:
Codex, Claude, or a mixed team, with the coordinator's current host as the default. An existing explicit choice
already answers this question; otherwise proceed with the host default while awaiting an optional preference.
Record the choice in the stage's `hub-rules.md` and carry it into briefs and handoffs. A Codex hub defaults to
Codex executors; a Claude hub defaults to Claude executors. Choose each worker's model and effort within that
engine. Claude model names in general task-sizing advice apply to Claude workers; using such advice to switch
engines requires an explicit engine choice from the owner. Reviewer engines may follow an explicitly configured
review policy.

Pass the chosen engine explicitly with `agent spawn --engine claude|codex`. Without that flag, `AGENT_HUB_ENGINE`
can supply a configured default; otherwise the launcher detects a Codex host through `CODEX_THREAD_ID` and falls
back to Claude in an ordinary terminal. Native subagents run in their host; mixed teams use detached executors.
Codex uses its configured model when `--model` is omitted; pass an actual available model id or an explicit
`AGENT_HUB_CODEX_MODEL_MAP` alias. Claude aliases stay Claude-only. Read `docs/codex.md` for installation,
hook trust, full access, and native worker setup. Full access keeps the lock hooks active.

  Before the first detached Codex launch for a selected CLI/model in a stage, check that CLI's `--version` and
  `debug models` catalog (use `CODEX_BIN` when configured), including its configured default when omitting `--model`.
  Desktop model availability does not establish standalone CLI availability. Ordinary implementation uses an
  available Sol-family model, subject to the owner's explicit model choice. Resolve an unavailable Sol version by
  checking CLI compatibility or selecting an available Sol peer and reporting the fallback. Reserve Astra for a
  task whose judgement needs justify it, stating the reason before launch; a startup/model error is a compatibility
  issue rather than a reason to raise the task's model class. Keep the chosen engine through this recovery.

## Terminal follow-through

For Codex hubs, run this procedure after every executor terminal result (`MERGED`, `DONE`, `STOP`, `BLOCKED`, `EXIT`,
`ENDED`, `REVIEWED`), including results replayed at takeover. These are inputs to coordination, not proof
of success or automatic stage completion.

1. Consume the actual report/result and its evidence; establish what finished, failed or stopped.
2. Verify current resource ownership and the remaining approved Business DoD against its source and scope.
   An executor's artifact/call-budget STOP ends its brief; continuation remains hub-owned within actual authority.
   Actor-only SAFE_END describes that actor, not stage-wide resource freedom.
3. Start or resume the next independent authorized ready work before waiting or finalizing. Distinguish dependencies
   needed for preparation from those needed for final publication, merge, stage acceptance or production. A blocked
   lane leaves independent lanes ready; respect the shared DB slot, locks and agreed sequence.
4. If Business DoD remains and none is ready, record the exact remaining item, blocker, responsible owner or resource, and expected event
   that makes it actionable; wait through the canonical digest command. Missing reports/ownership evidence are
   concrete blockers to resolve, not successful completion. An empty handoff queue is a snapshot: reconcile it
   against Business DoD and recover remaining authorized work before declaring DONE.

The pass ends with work started/resumed, a concrete wait, or a verified stopping boundary: completed Business DoD,
explicit owner stop, or a genuine business/authority boundary recorded with its source. Preserve that boundary;
never fabricate READY, finance or production permission. A status or clarification message during active work
gets an answer and the same loop resumes unless the owner cancels or changes scope.

## Waiting on a Codex hub

The Claude Code wait is in the core `SKILL.md`; this is the Codex half of *Waiting*.

- **Codex:** use the shell tool's yielded execution session and its continuation/wait tool. Keep each blocking
  tool wait at most 60 seconds so the coordinator can respond, and do independent work before continuing it.
  Preserve the returned execution id; use the tool's exit code to distinguish an event, an alarm, and a failure.
  A terminal session that cannot continue a shell command asynchronously should use a bounded foreground
  `jwait` and handle its result before starting another. A detached successor uses the same foreground procedure.

On a Codex hub wake, apply [Terminal follow-through](#terminal-follow-through) to terminal results; start the next `jwait`
when waiting is justified. Journal waits and alarms use `jwait`; keep one waiter and continue it through the shell harness.

## Talking: tell delivery and direct messages on Codex

The Codex-only sentences of *Talking*; the journal `tell` of the core `SKILL.md` stays the first choice.

  **Codex only:** follow [Immediate Codex tell delivery](../../../docs/codex.md#immediate-codex-tell-delivery).
  Handle a `pending` native-caller handoff immediately, before waiting or another action: verify the current
  registry/full UUID, actual human authority for this communication and the supported native tool's current schema.
  Then send the literal recipient/message once through that tool.
  Record its real receipt against the request ID; an unknown result forbids retry. Tool acceptance alone proves
  neither active same-turn steer nor immediate delivery; retain pending when capability or human proof is absent.

  Codex: use the printed `agent send` for a detached hub. For immediate non-detached input, follow
  [Immediate Codex tell delivery](../../../docs/codex.md#immediate-codex-tell-delivery) and handle pending native-caller
  handoffs immediately. Explicit queued follow-ups may use `codex queue --thread <registered UUID> --message "…"`
  when supported; queue acceptance does not establish immediate steer. Use the UUID, never a display name.

## Grilling session on Codex

The Codex side of *Grilling in a session of its own* (`owner-and-planning.md`). In a Codex app thread `hub grill
--stage <S>` prints `create_thread` arguments whose `target.projectId` is a placeholder, and the `project_root`. The
owner's request to be grilled, in the current turn, is the explicit human authority for this one thread (pass their
words with `--owner-words`); it grants nothing else. Then, as the app agent: native `list_projects`, take the one saved
project whose path, normalized to its Git main checkout, is `project_root`, put its projectId into `target`, and call
native `create_thread` once. An unknown result is not retried — the new thread announces itself with a `grill join`
line in the journal; no matching project: tell the owner and run `hub grill --stage <S> --host manual --again`. In a
terminal Codex hub `hub grill` prints the command the owner runs in a terminal of their own. Either way the new thread
joins as role `grill` with its CODEX_THREAD_ID and reports with `@hub GRILLED …`.

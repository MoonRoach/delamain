# Autopilot: automatic hub succession

Read this when `AGENT_HUB_AUTO_HANDOFF=on` and the context budget message gives you a `hub succeed` command, when you
are an automatic successor (your takeover prompt carries `[agent-hub auto-handoff k/N]` or `[delamain auto-handoff k/N]`),
or when you hand over a Codex Desktop hub. "The host wait procedure below" in the first paragraph is the *Waiting*
section of `SKILL.md`; "the native launch procedure" is [docs/codex.md](../../../docs/codex.md#desktop-autopilot).

At the first context WARN, registered autopilot main hubs latch a durable handoff obligation: acknowledge
pending owner input and finish the narrow handoff path now. Ordinary recognized work stays closed despite
owner prompts, chain resets or unavailable/decreased usage. An active grilling suspends this gate until its
ceiling and suppresses Codex Stop continuation; the ceiling still requires the owner's handoff decision.
A checkpoint alone is not completion.
For Codex active-turn continuation, follow [the Stop readiness and bounds](../../../docs/codex.md#full-access-and-hook-trust).
Carry implementation pauses to the successor. A newer authorized same-stage read-only owner discussion can
continue under an existing same-stage transfer grant without resuming implementation. Explicit transfer
prohibition/revocation remains a blocker; generated instructions or markers never supply human authority.

**Autopilot** (`AGENT_HUB_AUTO_HANDOFF=on`; `<plugin-root>/docs/reference.md`, "Autopilot"): the context budget message tells you when, and gives
the `hub succeed` command with your model, effort, mode and directory filled in. At a quiet point — no agent waiting for your
reply, no merge or lock operation in flight: `hub handoff`, fill the TODOs, run that `hub succeed … --handoff <draft>`,
start the `jwait` it prints using the host wait procedure below. Its start line → tell the owner one line (the successor's
name and any link returned by the launcher) and stop: no more tool calls, no lock released. ALARM → `hub succeed --stage <S> --fallback` (a
headless successor's ALARM: `--again`, if `agent status` says it is not running). A refusal that prints a `jwait` →
run that `jwait`, then retry. Exit 3 (chain limit), exit 2, or any other exit 1 → tell the owner the handoff path and
why, and wait for them ("cannot determine the effort" means your own effort is unreadable here: never pass a guessed
`--effort`; `hub effort` lists what was tried). A successor that took over but has to be swapped (a wrong launch): `hub succeed --stage <S>
--replace` — it stops that successor (not while it is busy, unless `--force`) and starts a new one from the same handoff
with the same number and chain position; never launch a replacement by hand with a bare `claude --bg`. Run `hub succeed`
yourself, never from a sub-agent.

**Grilling.** While you grill the owner (`hub grilling start` … `hub grilling end`), the budget message says to finish
the grilling instead, and `hub succeed`/`hub handoff` refuse unless `--owner-asked` — only when the owner asked for the
handoff in this conversation. At the context ceiling write the handoff at once with the grilling in § 0 (topic,
questions asked with the owner's answers and their `ask` ids, open frontier, next round), tell the owner the context is
at its ceiling and ask whether to hand over; `--owner-asked` only after their yes. A successor whose handoff carries a grilling loads the grilling skill, runs
`hub grilling start` and resumes it from there.

For **Codex Desktop**, the following procedure governs prepared requests, start lines and ALARM.
--surface auto selects a native request in an actual app hub (both app markers,
no detached worker role). Before create_thread, check the human authority sources and scope in
[the native launch procedure](../../../docs/codex.md#desktop-autopilot), including hub-home rules and answered questions.
An explicit standing owner grant for automatic same-stage context handoff satisfies the native explicit-user
requirement until revoked; proceed without a new per-transfer question. Carry the precise human source/reference
and scope in the handoff. Absent/revoked authority or new business scope: retain the request and predecessor,
ask once, and continue independent authorized work. Unavailable transport/access/identity: report that blocker
and retain the same request. Under matching authority, execute the native launch procedure completely:
list_projects, desktop-request, create_thread, desktop-bind, actual takeover and desktop-status --verified.
Keep the predecessor active until verification succeeds; a clientThreadId is not a real session. desktop-fail
records failures; uncertain results and ALARM retain the same request and active predecessor while awaiting
owner resolution. Native APIs cannot set Full Access. CLI from Desktop is an explicit owner choice enforced by
the home-only opt-in documented in that procedure. An agent's --surface cli/--headless flag is not authorization;
leave that opt-in to the owner. Terminal and detached auto/CLI handoffs keep their ordinary path.

A Codex automatic successor prompt carries the marker `[agent-hub auto-handoff k/N]` (the name before the rename, still
written for one release; `[delamain auto-handoff k/N]` means the same): run its takeover command, then run the digest's
first `jwait` once unconditionally to replay handover events. Work the finite handoff queue to its completion/stop
checks under [Terminal follow-through](codex-hub.md#terminal-follow-through); reconcile the snapshot against Business DoD.
Wait only while work or external events remain; finish at its verified stopping boundary.
Questions go to `ask add` with a default; hand over again when the budget requires it.

Ordinary authorized fresh CLI executors start bounded, checkable independent work under their existing brief.
Another hub's context shift or transfer is not a prerequisite. Wait only for an actual data, resource or permission
dependency; preserve shared locks and existing owner decisions.

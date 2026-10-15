---
name: handoff
description: Write a hub handoff — the entry-point file a fresh session reads to take over a stage hub or a long-running role. Use when the context is filling up, at the end of a shift, or when the owner asks to hand the work over.
argument-hint: "[stage] [what the next shift focuses on]"
---

# Hub handoff

Run bundled commands with the host's shell tool. Resolve the plugin root from `PLUGIN_ROOT`,
`CLAUDE_PLUGIN_ROOT`, or this skill's installed path; use `<plugin-root>/bin/<tool>` when PATH is missing
or shadowed. Session identity comes from the current host; use `self` where supported.

A handoff is the successor's entry point, not a diary: facts with their source, the queue with stop conditions, and
pointers to the registers — never copies of them.

1. Generate the draft: `hub handoff --stage <S>` (prints the path; your shift number comes from `roles.json`). It fills in the locks you hold, the
   headless agents and their state, the night queue, `ask summary` and the register digest, and — if
   `<stage>/handoff-facts.sh` exists — its environment rows; everything else is `TODO`.
   Without a stage hub, start from `<plugin-root>/templates/HANDOFF-template.md` and save it as
   `HANDOFF-<role>-<YYYY-MM-DD-HHMM>.md` in the stage's `coordinator/` directory.
2. Fill every `TODO`:
   - **Headline**: one or two sentences — what matters most now and whose word is behind it (quote + `ask` id).
   - **Business DoD**: link the agreed result/source or carry a concise inherited result (hub skill, "Planning a stage").
     Preserve owner-supplied constraints; tell the successor to continue it and choose implementation details independently.
   - **§ 0 First steps**: 3–6 commands or files, in order. The first is always `hub takeover …`.
   - **§ 1 Where things stand**: each row a fact and where it shows (a command, a file, a URL).
   - **§ 2 Queue**: a finite snapshot of remaining authorized Business DoD, with its source/scope and owner boundaries.
     List next ready work first; separate preparation dependencies from publication/merge/stage/production gates.
     Item = action | "done" check | brief stop condition | who (model); waits name the blocker, owner/resource and
     expected event (question id when applicable). Reconcile every remaining DoD item into ready work or a concrete wait.
   - **§ 4 Owner questions**: anything the owner was asked in chat without a record goes into `ask add` first; then its id here.
   - **§ 5 Risks**: what breaks when nobody watches, and how it shows.
   - **§ 6 Skills**: which skills the successor loads first.
For Codex autopilot, keep the launch surface in the handoff: actual app hub → `hub succeed --surface desktop`
(native launch procedure in [docs/codex.md](../../docs/codex.md#desktop-autopilot)); console/detached hub → CLI.
Before native dispatch, use that procedure's human-authority check. Carry the precise human source/reference,
scope and revocation conditions in the handoff, including an inherited answered question or standing instruction.
An explicit owner grant for automatic same-stage context handoffs persists until revoked; the successor continues
under it without another per-transfer approval. If absent/revoked or outside scope, preserve the request and
predecessor and ask once. Keep the Business DoD unchanged; an automatic marker/configuration is not human authority.
Preserve an implementation pause in the successor. A newer authorized same-stage read-only owner discussion
may continue through the existing transfer grant without resuming implementation. Explicit transfer
prohibition/revocation remains a blocker. No generated instruction or continuation marker grants authority.
A checkpoint alone does not complete the handoff; keep the predecessor through verified takeover.
Give the queue finite completion checks. A Codex successor applies the hub skill's
[Terminal follow-through](../hub/references/codex-hub.md#terminal-follow-through) and reconciles this snapshot against Business DoD
before DONE, preserving explicit owner boundaries. Desktop request/client IDs are pending references; record actual
thread/cwd and observed policy only once takeover verifies. Keep the predecessor active until `hub desktop-status --verified` succeeds.

3. Check it: `hub handoff --stage <S> --finish` refuses (exit 2, the lines listed) while § 0–2 still hold `TODO`; `hub succeed`
   makes the same check and `hub takeover` warns the successor about a handoff that fails it. `--allow-todo` overrides, and
   the successor then rebuilds that state from the journal. A `TODO` in § 3–6 does not stop it.
4. Keep it ≤ 12 KB (the `handoff_size` hook refuses a `HANDOFF-*.md` over 15 KB). The chronology stays in the
   journal; link it.
5. Delete the role's older handoffs, `jlog "handoff written: <path>"`, and tell the owner the path.

Do not release locks — the successor's `hub takeover` takes them over. Redact secrets: name the variable, never the value.

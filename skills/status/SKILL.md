---
name: status
description: Answer questions about Delamain agents, stages and hubs, their tasks, owner questions, locks and idle stages. Use for “what is running”, “which agents are alive”, “task status”, “who needs an answer”, “что сейчас работает”, “какие агенты живы”, “что с задачами”, “кто ждёт ответа”, “какие блокировки” and “какие хабы можно закрыть”. Not for version-control working-tree state, build/CI state, system processes/ports, or tickets/issue trackers.
---

# Running work

1. Resolve the plugin root from `PLUGIN_ROOT` (Codex), `CLAUDE_PLUGIN_ROOT` (Claude), or this skill's canonical location
   (resolve symlinks first, then go two directories above `skills/status`). Run that root's `bin/agent-top --json` through the host's shell tool;
   an unrelated command may shadow it on PATH. This reads the shared hub home and session logs without changing them.
   Use `--stage <stage>` for a named or clearly implied stage (repeatable), otherwise cover every stage.
   Use `--all` only when the user asks about finished or old work; `--json --agent <role> --feed 10` gives recent activity.
   On the owner's data, snapshots take 20–45 s, `--all` up to ~160 s. In Codex, wait through execution continuation
   tools. In Claude Code, set the shell tool timeout to at least 5 min, or run in background and wait for completion.
   After a timeout, rerun with a longer timeout and wait for a fresh completed snapshot; use no stale data and do
   not report unavailable merely because collection timed out.
2. Read the fresh snapshot before answering. Group by stage: live agents with role, task/current action and duration,
   relevant finished/failed work since the previous snapshot in this conversation, owner questions and held locks.
   Use `action.elapsed_s` for action duration and `started_at` for run duration; `age_s` is time since the last log
   event, not runtime. Describe native sessions' activity-based liveness as approximate. An unread inbox is a message
   awaiting the agent, not an owner question. `questions_ok: false` means the question register is unavailable.
   Report missing data or non-timeout command failure as unavailable; an empty successful snapshot means no observed work.
   `stage_info.<S>.idle` marks an open stage with no live agent and no activity for `idle_after_s`: name such stages
   once as candidates to close (`hub close`, skill `hub`; the owner decides). `closed_hidden` lists closed stages left
   out of the snapshot: they run nothing; mention them only when asked about old or closed work.
   `desktop_idle`: idle Desktop sessions holding memory; archiving: skills/hub/references/stage-lifecycle.md § Idle Desktop sessions.
   Whether a hub lives is `roles.<S>[role=hub].last_written_age_s`: when it last wrote itself, a journal line signed with
   its tag or (`last_written_via: transcript`) a write of its session's transcript, whichever is fresher; `null` is no sign
   at all. `last_addressed_age_s` is when someone last wrote *to* it (`[pace] @hub …`, a broadcast, a worker's `@hub DONE`):
   never read it as the hub's activity. A hub with a large `last_written_age_s` and a small `last_addressed_age_s` is
   likely dead or asleep, not working; say "likely" (the age is a sign, not a process check).
   Infer tasks only from titles, activity, last words or the journal; compare snapshots only when a previous one exists.
3. Answer in a few plain-text lines in the user's language, prioritizing running work and anything needing attention.
   Summarize large stages and offer detail on request. Include question ids when they help the owner answer.
   Keep raw JSON and command names out of the answer unless requested. In Claude Code terminal 2.1.287+, add:
   “`/agent-top` opens the live pane” (in the user's language). Finish after the text answer; status is read-only.
   Omit the pane hint in Codex, VS Code chat, `claude -p` and Remote Control views.

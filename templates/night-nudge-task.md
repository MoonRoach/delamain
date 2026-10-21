# Deprecated: use the watchdog

The watchdog (`watchdog install`, [docs/monitoring.md](../docs/monitoring.md#watchdog-a-hub-that-sleeps-is-woken)) replaces
this task: it counts open night-queue items inside `AGENT_HUB_NIGHT` as waiting work, finds the hub in `roles.json` and wakes
it when it can be woken (including a confirmed idle Codex app hub registered from its current thread), and notifies you
otherwise; see the linked host conditions. This
task still works as described below; if you created it, you may delete it in Claude Desktop (`~/.claude/scheduled-tasks/night-nudge`).
New installs do not need it.

# Optional: the night-nudge scheduled task

A scheduled task that wakes a silent coordinator while the owner sleeps. It needs Claude Desktop (the
`scheduled-tasks` MCP server and the session-management tools); without them, skip it — the night queue still works
as a plain checklist.

Create it from the owner's own session (not from a sub-agent) with `create_scheduled_task`:

- taskId: `night-nudge`
- title: `Night: wake coordinators from the night queue`
- cronExpression: `*/30 23,0-7 * * *` (every 30 minutes, 23:00–08:00 local time; match `AGENT_HUB_NIGHT`)
- notifyOnCompletion: `false`
- prompt: the text below, with `NIGHTQ` replaced by the absolute path that `command -v nightq` prints in your
  session (a scheduled run may not have the plugin's `bin/` on its PATH).

After creating: `list_scheduled_tasks` shows `night-nudge`; a manual `run_scheduled_task night-nudge` with empty queues
answers "queues are empty, woke nobody" and writes nothing to `night-log.md`. The first night run may ask to approve
tools — approve them during the day with a manual run.

## Prompt

You are the night alarm for hub coordinators. Use only the commands below and the session tools. Your final answer is one line.

0. The session tools are deferred in a scheduled run: load them first with ToolSearch
   `select:mcp__ccd_session_mgmt__get_session,mcp__ccd_session_mgmt__send_message` (names may differ by version —
   search "get_session send_message" if the select finds nothing). Take the current time from Bash
   `date -u +%Y-%m-%dT%H:%M:%SZ`; do not guess it.
1. Run in Bash: `NIGHTQ status --json; echo "exit=$?"` (no pipe). Exit ≠ 0 or unreadable JSON → run
   `NIGHTQ log --stage <any stage from the error or "default"> "night-nudge: nightq status failed: <first error line>"` and answer "ERROR nightq".
   Below, `nightq` means the same `NIGHTQ` path.
2. Take the stages with `open > 0`. None → answer "queues are empty, woke nobody" and stop (write no log).
3. `in_night_window` is false → answer "outside the night window, queues: <stage: open>" and stop (write no log).
4. For each stage with `open > 0`:
   a. `coordinator` is empty → `nightq log --stage <stage> "night-nudge: queue not empty (<open>), no coordinator set — woke nobody"`; next stage.
   b. Otherwise look the session up (`get_session` with `session_id` = `coordinator`). Not found or archived →
      `nightq log … "night-nudge: coordinator <id> not found/archived — woke nobody"`; next stage.
   c. Silent: `lastActivityAt` older than 30 minutes before the time from step 0. Not silent → do nothing and write no log.
   d. Silent → send it a message (`SendMessage` to `coordinator`; if that tool is missing or fails, the session tool
      `send_message` with `session_id` = `coordinator`): "Night queue: continue with <hub home>/<stage>/night-queue.md
      (open <open>, next: <next>). The permission matrix is in the file; anything outside it — `ask add` with a default
      action, then move on." If `invalid` is not empty, add "the queue format is broken: `nightq check --stage <stage>`".
      Then `nightq log --stage <stage> "night-nudge: woke <id> (silent since <lastActivityAt>), open <open>"`; not
      delivered → `nightq log … "night-nudge: NOT delivered to <id>: <error of both tools>"`.
5. Answer in one line, per stage: "<stage>: woke / silent < 30 min / no coordinator / not delivered".
Your only side effects are the message to the coordinator and the line in night-log.md.

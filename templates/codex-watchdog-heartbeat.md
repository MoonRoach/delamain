# Codex app-native watchdog heartbeat

Use this prompt for the existing Codex app automation after the reviewed runtime is installed. Update that automation
with supported `automation_update`; keep its automation id. This is a model-assisted native consumer, separate from
the shell watchdog tick. Use the installed plugin's absolute `bin/watchdog` path (`$HUB_BIN` if supplied by this session).
It must run in a confirmed app session with supported native `wait_threads`, `read_thread` and
`send_message_to_thread`; a detached worker is not a substitute. Do not create another user chat, launch a daemon,
open a private pipe, or run `exec resume`.

1. Run `watchdog native-plan --json`. It returns a pure JSON list with only `stage`, `session`, `fingerprint`,
   `reason`, `waiting_since`, `count` and `message`. Empty means finish silently. The planner does **not** establish idle.
   Before selecting a target, read that stage's current role registry and resolve the active hub's exact UUID
   (`cli_session_id` when present, otherwise `session`). Match it to the candidate; after replacement or retirement,
   discard the stale candidate and re-plan. Display names, hub numbers and previously remembered UUIDs are not targets.
2. For each currently registered candidate UUID, first use supported native `wait_threads` with `timeoutMs: 0`
   for current status and `latestTurn`. An active runtime or an `inProgress` current turn means no message, even if
   `read_thread` exposes an older completed turn. Then use `read_thread` for the history needed to assess the latest
   request, including turn timestamps, fresh commentary, later user input, outcomes and interruptions. Page/array
   order is not chronological proof; fetch enough history to reconcile it with the current status/latestTurn, or
   skip when uncertain. Confirm explicit current native idle status and actionable unfinished work.
   Active, unknown, interrupted or ambiguous runtime/actionability means no message.
3. Check that real work still needs this hub: inspect the candidate stage's journal and its digest/queue/register
   as needed. An old REVIEWED followed by the final merge and completed latest owner request is not unfinished work.
   A DONE/MERGED word alone does not close a multi-item stage. Follow the current request and timestamped work;
   a different MR number or an older final response does not prove that this hub is asleep or its work is complete.
   For R4 require the same final typed overload, no later user/turn boundary, and genuine unfinished work. Completed stages get no nudge merely to refresh host provenance.
4. If idle/actionability are established, immediately run:

   ```sh
   watchdog native-claim --stage <stage> --session <exact UUID> --fingerprint <plan fingerprint>
   ```

   A refusal means skip: identity, work, policy or another UUID-wide attempt changed. The receipt contains the same
   candidate and an `attempt` token; unknown delivery is saved **before** any native send. Immediately before send,
   re-read the current registry and refresh status/latestTurn with `wait_threads` (`timeoutMs: 0`); use `read_thread`
   again if history needs reconciling. A changed/active/unknown state gets no send; ack `failed` only when certain
   no message was submitted. Do not retry a failed preflight with a different UUID or manufacture idle evidence.
   For R4 the receipt also carries `failed_turn` (turn id, timestamp, typed error): compare it with the actual latest
   native terminal turn before sending. A mismatched/superseded turn gets no retry, even if the current thread is idle.
5. If the verified latest request is complete and the local candidate is stale, claim that exact fingerprint but
   send nothing; ack `completed-skip`. This suppresses only that stale work fingerprint. New pending work re-arms.
   Otherwise call supported `send_message_to_thread` with exactly the receipt UUID and its literal `message`.
6. Record the actual outcome:

   ```sh
   watchdog native-ack --stage <stage> --session <exact UUID> --fingerprint <receipt fingerprint> \
     --attempt <receipt token> --outcome sent
   ```

   Use `sent` for explicit acceptance, `failed` for explicit no-delivery rejection, `unknown` for an ambiguous
   result/timeout, or `completed-skip` for verified stale completed work without any send. A lost or unknown receipt
   holds the UUID across stages and actor replacement in a shared native/CLI receipt ledger until a new own turn
   proves recipient activity; new journal work, expired backoff, file touches or re-registration alone do not release
   it. The standalone CLI tick checks the same guard before queueing and also persists an unknown receipt before
   queue; an unresolved CLI outcome blocks native claims.
   An unacknowledged original receipt can still record a verified delivery outcome. Never call a second transport.
   Ack may refuse if the hub was retired/replaced, quieted or entered a pending handoff; report that receipt outcome
   to the coordinator, without retrying the native send. A duplicate ack of the same outcome is harmless.

Files and the native API are separate systems: the read/check/send interval is bounded, not atomic. Keep the claim
and final native idle check adjacent to the send. Receipt protection depends on retained local state; malformed
receipt state blocks Codex wakes until repaired. If identity or policy changes during that interval, stop when
observed; never claim a global writer lock. Missing native tools, unknown history or uncertain delivery do not justify
a fallback. The heartbeat consumes model limits; a pure shell tick does not. Installation/live validation belongs to
the current app coordinator, not this prompt's author.

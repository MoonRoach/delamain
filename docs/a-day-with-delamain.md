# A day with Delamain

A synthetic example: stage `payments` — a stream of work, here a payments release — on the day of its third hub shift.
The hub is an interactive Claude Code session; every command below is what the hub (Claude, with the `hub` skill
loaded) runs in Bash.

Set-up behind the example: the repository ran `delamain:setup` once, so `.agent-hub/lock-rules.json` names the
project's shared resources, and the first hub of the stage began with
`hub start --stage payments --goal "Ship the payments release" --session "$CLAUDE_CODE_SESSION_ID"`. A day that needs less can drop `ask`, `lock` and the
handoff and keep `agent`, `jlog` and `jwait` (see [Minimal mode](reference.md#minimal-mode)).

1. **Morning: take over the shift.** Yesterday's hub left a handoff.
   ```bash
   hub takeover --stage payments --session "$CLAUDE_CODE_SESSION_ID"
   ```
   The shift number is derived (the registered hub's plus one, here 3; `--n` overrides it). The previous hub's locks move
   to you, `roles.json` names you `hub` with tag `hub-3`, the journal gets a start line, and a ≤ 3 KB digest prints § 0
   of the handoff, the owner-question register, locks, roles and the first `jwait`.

2. **Check what the owner already decided** before planning anything that touches it.
   ```bash
   ask search export
   ask list --stage payments --pending      # answers given but not yet executed
   ```

3. **Start the long work as headless agents**, one brief each (`templates/brief-executor-template.md`). An agent that
   writes code gets its own worktree; a reviewer that only reads can share the checkout.
   ```bash
   agent spawn --role builder  --tag hub-3-builder  --cwd ~/code/webapp --model opus   --worktree --brief work/brief-builder.md
   agent spawn --role reviewer --tag hub-3-reviewer --cwd ~/code/webapp --model sonnet --brief work/brief-review-41.md
   ```
   The builder runs in `~/code/webapp/.worktrees/agent/builder` on the branch `agent/builder`.

4. **Wait without polling.** One background waiter; the harness wakes the hub when it exits.
   ```bash
   jwait --journal --stage payments --tag hub-3 --tag hub \
         --match '\b(MERGED|STOP|DONE|BLOCKED|EXIT|ENDED|REVIEWED|QUESTION)\b' --for 50m --note "scheduled round"
   ```

5. **An agent asks.** The journal shows `[hub-3-reviewer] @hub QUESTION is the Parquet export on by default?` and
   the reviewer ends its turn with `BLOCKED`. The owner has not decided this yet:
   ```bash
   ask add --stage payments --blocks "PR 41" --default "ship with the flag off" --due 2026-10-01T18:00 \
           "Turn the new export on by default?"
   agent send reviewer "Not decided yet (Q-A-001): review assuming the flag is off by default."
   ```
   `agent send` resumes the finished session with the message; the reviewer continues where it stopped.

6. **Merge under a lock.** Only the holder of `main-merge` may merge; the hook refuses anyone else. A resource the
   project named in `lock-rules.json` works the same way, for example `staging` before a rollout there.
   ```bash
   lock take main-merge --repo webapp --until +4h --why "merging the payments release"
   gh pr merge 41 --squash
   ```

7. **Look at everything at once.**
   ```bash
   agent-top            # in Claude Code, /agent-top opens the same as a side pane
   ```

8. **The owner answers in chat** ("yes, on by default"):
   ```bash
   ask close Q-A-001 --answer "yes, on by default"
   agent send builder "Q-A-001: the export is on by default — flip the flag before the release build."
   ask done Q-A-001 --evidence "flag flipped in PR 43"
   ```

9. **Evening, optional: leave work for the night** in `payments/night-queue.md`
   (`templates/night-queue-template.md`), each line with a stop condition and a permission class, then check it:
   ```bash
   nightq check --stage payments
   ```
   Skip this step unless you run the hub overnight. With `watchdog install` a silent hub that can be woken is woken for
   open items inside `AGENT_HUB_NIGHT`; otherwise you get a notification.

10. **Hand over.** The context is getting long; write the handoff and stop.
    ```bash
    hub handoff --stage payments              # fill the TODOs, then tell the owner the path
    ```
    The agents keep running. Finished worktrees go with `agent worktrees --prune` (look first with `--dry-run`).
    Tomorrow's hub starts at step 1 and becomes `hub-4` without being told.

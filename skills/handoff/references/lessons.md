# § 7 Lessons of this shift

Read this when the draft has a `## 7. Lessons of this shift` (the hub home's `AGENT_HUB_HANDOFF_LESSONS` is on). At a
handoff your context still holds the whole shift; after it that is gone and the journal keeps only events. A lesson is
what you would tell the next hub about how to work, with the moment it rests on.

## Procedure

1. Open `<hub home>/<stage>/lessons.md` (the draft prints the path; create it if absent). It is kept across handoffs —
   never delete it with them. You edit it by hand; there is no command.
2. Judge the lessons listed under "Open lessons to judge". For each that actually acted in your shift, append a
   `verdict:` line (below). A lesson that did not come up gets none.
3. Write 0–3 new entries. "No lesson" is a valid answer: write `none: <reason>` in § 7. A lesson without `evidence`
   is not written.
4. Fill § 7 of the draft: the new ids (or `none: <reason>`) and the verdicts (or `none`). `hub handoff --finish` only
   warns while § 7 holds `TODO`; it never refuses for it.

## Entry format

```markdown
## L-001 — <cue: when the lesson applies, one line>
- status: proposed        (proposed | confirmed: DATE hub-N | promoted: <file> DATE (ask id) | retired: DATE hub-N — reason)
- by: hub-3, 2026-10-22
- lesson: one or two sentences, an instruction the next hub can follow
- evidence: the moment it rests on — a journal line (time + tag), an MR/PR, an ask id, a session id
- confidence: low | medium | high
- verdict: hub-4 2026-10-23 helped — evidence     (appended by later shifts; repeatable)
```

Ids run on from the last one in the file. A verdict is `helped | hurt | no effect | confounded`; use `confounded` when
something else changed in the same shift and you cannot tell.

## What a verdict does

| verdict | effect on `status` |
|---|---|
| `helped`, with its own evidence | `confirmed: DATE hub-N` |
| `hurt` | `retired: DATE hub-N — reason` |
| `no effect`, `confounded` | none |

A confirmed lesson that should hold for every hub is proposed to the owner with `ask add`, for `hub-rules.md`. That file
is the owner's: never write it yourself. On the owner's yes the entry becomes `promoted: <file> DATE (ask id)`. A verdict
of `hurt` on a rule of `hub-rules.md` itself is likewise an `ask add`, never an edit.

## Writing a good lesson

- The cue says WHEN: a situation the next hub can recognise ("before merging a PR that touches the lock board"), not a
  topic.
- The lesson is an instruction the next hub can follow, not a description of what happened.
- The evidence is a pointer, not a story: a journal line (time and tag), an MR/PR, an `ask` id, a session id.
- If it would read "be more careful" or "check more", it is not a lesson; leave it out.
- When the lesson is mechanical (the same slip can be caught by a check), prefer a hook, a script or a skill change
  over a prose rule: propose it with `ask add` or put it in the queue, and write the lesson as a pointer to that.

# Proposal: slim `~/agent-hub/hub-rules.md`

Status: proposal only. Nothing in `~/agent-hub` was edited; the owner or the hub applies it.

Why: every hub reads the hub home's `hub-rules.md` at every takeover (the takeover digest names it, and the Codex
Desktop authority check reads it). It is 8,008 bytes, and 4,656 of them (58%) are one section, the record of how the
Codex plugin 1.0.2 was installed: commit and CI links, file counts, hashes, one observed watchdog run, the ids of the
native consumer. A hub needs that only when it updates Codex or repairs a native request, and only the rules inside it
are needed every time.

## What is in the file

| Section | Bytes | Kind | Needed at every takeover |
|---|---|---|---|
| Installed released Codex coordination and watchdog | 4,656 | six paragraphs: evidence (1, 4, 5 in part) and rules (2, 3, 4, 5, 6) | the rules only, and only for a Codex hub |
| Owner-authorized automatic native handoff | 1,502 | the owner's standing grant, with its source and scope | yes: the Codex Desktop authority check reads this file for it |
| Local test runs on the owner's laptop | 1,825 | current rule for every stage and engine | yes |

## What moves

The six paragraphs of the first section move **verbatim** to `~/agent-hub/history/codex-1.0.2-install.md` (4,752 bytes
with a two-line header): the installation record is kept whole, nothing is paraphrased away. In `hub-rules.md` the
section shrinks to the block below: the rules a hub follows without reading the record, each one traceable to a
paragraph of the history file, and a line saying when to read it. The other two sections stay as they are.

| Original paragraph | Starts with | Where it goes |
|---|---|---|
| 1 (898 B) | "This rule applies while the owner's Claude and Codex plugins use released v1.0.2…" | history file only (release commit, CI run, file counts, trust evidence) |
| 2 (908 B) | "For new Codex coordination commands…" | history file; rule kept as bullets 1 and 2 |
| 3 (743 B) | "For a known completed legacy native request damaged by that old refresh…" | history file; rule kept as bullet 3 |
| 4 (1,034 B) | "The existing shell watchdog job uses…" | history file; rule kept as bullet 4 (the observed run, the automation id and the chat id stay only in the history file) |
| 5 (512 B) | "The Codex updater still temporarily deletes old cache paths…" | history file; rule kept as bullet 5 (helper hashes and the count of fault controls stay only in the history file) |
| 6 (494 B) | "A different source directory's watchdog status may recommend installation…" | history file; rule kept as bullets 1 and 4 |

### Replacement for the first section

```markdown
## Installed released Codex coordination and watchdog

Full text and the installation evidence: `history/codex-1.0.2-install.md`. Read it when updating Codex or its plugin cache, changing the watchdog job or the native consumer, or repairing a native request.

- New Codex coordination commands (hub start/takeover/succeed/native request/recovery, agent, tell) run from `/Users/ikozyrev/.codex/plugins/cache/delamain-codex/delamain/1.0.2/bin/` explicitly; existing executors may finish under their old paths. Keep older caches and snapshots while live sessions use them.
- Before a host refresh, verify this session is the current registered hub and run from its verified Git worktree. A pure native self-refresh preserves UUID/tag/set_at/request/chain and transfers nothing.
- A completed legacy request damaged by an old refresh: only its CURRENT native hub runs `hub desktop-recover --stage <stage> --request <request>` from the original verified cwd, then `hub desktop-status ... --verified`. Never edit JSON, impersonate a UUID, create a new thread or retake the stage. Desktop-to-CLI stays off unless the owner sets the home-only opt-in.
- The watchdog job and the native consumer (`codex-watchdog`) already exist: check the job path and its ticks with that runtime's `bin/watchdog status` first; never reconstruct, retarget or duplicate either, and never widen hook trust or access. Change a coordination pin only after independent review, exact-head CI and preserved SOURCE provenance.
- The Codex updater deletes old cache paths for a while: keep update and restore in one invocation, with verified backups; never make cleanup depend on another host tool call.
```

## Result

| File | Before | After |
|---|---|---|
| `hub-rules.md` | 8,008 B | 5,023 B (−37%) |
| `history/codex-1.0.2-install.md` | — | 4,752 B, read on demand |

The saving is smaller than the first impression of "mostly history": about 3 KB leaves the file, because the rules
inside the section are real and stay. The remaining 5 KB are rules, two of which (the native handoff grant and the
Codex block) concern only Codex hubs; a Claude hub still reads them.

## Apply

The sizes above come from this extraction, run against a copy of the file (the paragraph numbers are the table's):

```python
import re
src = open('hub-rules.md', encoding='utf-8').read()
title, s1, s2, s3 = re.split(r'(?m)^(?=## )', src)
paras = s1.split('\n\n')            # paras[0] is the heading, paras[1:7] the six paragraphs
history = ('# Codex 1.0.2 installation: full text and evidence\n\n'
           'Moved verbatim from `hub-rules.md`, section "Installed released Codex coordination and watchdog".\n\n'
           + '\n\n'.join(paras[1:]))
# write `history` to history/codex-1.0.2-install.md; write title + <replacement above> + '\n' + s2 + s3 to hub-rules.md
```

Check before applying, with a positive control: `ls ~/.codex/plugins/cache/delamain-codex/delamain/` shows which
version the Codex cache holds now. The file pins 1.0.2 and the repository has since released 1.0.3 and 1.0.4, so if
the installed cache moved, the path in bullet 1 (and the watchdog job's) is the thing to refresh, not copy.

## Not proposed, and the price

- **A separate Codex-only file** (`hub-rules-codex.md`) with a one-line pointer in `hub-rules.md`, which would take
  the Codex block out of every Claude hub's read (another ~1.7 KB; the native handoff grant would have to stay, see
  below). Price: the plugin reads only `hub-rules.md` from each layer, so a Codex hub would depend on following the
  pointer; moving the grant too (1.5 KB more) is not possible, because the Desktop authority check looks for it there. Recommended only if Claude hubs' baseline still matters after
  the skill split.
- **Deleting the history file after the pin changes.** Not recommended: it is the only record of what was installed
  and checked in 1.0.2.

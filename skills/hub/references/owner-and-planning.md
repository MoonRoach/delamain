# Talking to the owner and other hubs; planning a stage

Read this when you plan a stage (the full recipe behind the short one in `SKILL.md`), put a question to the owner, check
or record a standing permission, open a reply with the owner digest, run a grilling, or write into another stage's
journal. The Codex-only delivery rules are in [codex-hub.md](codex-hub.md#talking-tell-delivery-and-direct-messages-on-codex).

## Talking, in full

- `jlog "text"` — a journal line with your tag (`--tag`, `$HUB_TAG` or the registry). The journal is append-only:
  never rewrite or delete a line; correct it with a new line that says what it corrects. When you write into another
  stage's journal, do not sign as `hub`: that stage's `jwait --tag hub` treats `hub` lines as its own and does not wake.
  `jlog` signs a foreign-journal line `<your stage>-<tag>` (`[core-c-hub-30]`); your `jwait --tag hub-30` hears the
  answer `@core-c-hub-30`.
- To another stage's hub write in its journal: `tell <stage> "…"` (`--question` for a question) — it addresses `@hub`
  and signs you correctly. The answer reaches you only in your own journal: the other hub answers with
  `tell <your stage> "…"`; its `jwait` does not read your journal. A headless agent reads its inbox, so `tell` hands
  the text to `agent send` itself.

  Codex: [codex-hub.md](codex-hub.md#talking-tell-delivery-and-direct-messages-on-codex) holds the immediate-delivery rules.

- A direct cross-session message only when the journal cannot do (for example the other hub must act before its next
  wake-up), and only to the address from `tell <stage> --address` / `roles --stage <stage> get hub` — never to a session
  chosen by its name in a list (`ListAgents` or `codex agents`): a replaced hub can still run under the same name.

- `roles list | get <role> | set <role> <id> | retire` — the stage's role registry with full session ids; `set` infers
  the kind from the id (`local_…` = Claude Desktop, a uuid = terminal). For Claude cross-session messaging, resolve the address with `roles get <role>`.
  For detached workers of either engine, use `agent send`; Codex has no Claude `SendMessage` API. `roles broadcast --to r1,r2|--all "text"` — registered recipients and one journal line `@r1 @r2 text`.
- Owner-question register: `ask search <words…>` — decisions the owner already took on a topic; `ask digest` — the
  whole register, one line per decision; `ask add … --default … --due …` — a new question with the action you will
  take if nobody answers; `ask decided` — a decision you took yourself on a matter the owner normally decides;
  `ask close <id> --answer …` — the owner answered; `ask done <id> --evidence "…"` — the answer was executed;
  `ask list --pending` — answers without `done`.
- Standing permissions (`<plugin-root>/docs/standing-permissions.md`): `ask allow --list --stage <S>` — what the owner
  already allowed for this stage's repository, recorded in any stage (the start/takeover digest lists them); `ask allow
  --stage <S> --class "<keywords>" --words "<the owner's words>" "<the class of action>"` — record one (`--repo` when
  the action touches another repository — its path or remote URL; `--scope stage|all`; `--until`); `ask revoke
  <A-id>`. Use specific keywords (`deploy-staging`, not `deploy`, when the words are about staging). Ask with `ask add
  --repo <each repository the action touches> --class <every class of the action>`: a question the permissions cover
  on every repository is refused (exit 3) and prints the owner's words — act under them only if they cover this
  case's specifics (environment, scope, what is touched) and journal the id; if they do not, `--override "why"`.
  Money, migrations and permissions/RBAC are covered only by a permission that names them.
- Owner digest: on the owner's first message after a long silence run `ask inbox --if-quiet` and open your reply with
  its output, then answer; it prints nothing while the owner's last recorded answer is newer than
  `AGENT_HUB_OWNER_DIGEST_AFTER` (3h by default), so empty output means go straight to the reply. Show it once per
  silence, not on every message; `ask inbox` on request at any time (`--stage S` for one stage, `--since 6h`). Every
  question you put to the owner says what each answer changes: "A: …; B: …" with the consequence of each, and the
  default you take if no answer comes.
- Grilling on request: when the owner asks for grilling in any words (грилинг, погриль, грилл ми, grill me), load the
  companion `grilling` skill before replying and run it as written — rounds of numbered questions, each with a
  recommended answer, until the frontier of the topic the owner named is empty. A question you record with `ask add`
  keeps the recommendation as a recommendation: its default is waiting for the owner's answer, never acting on
  silence. The planning limit below ("stop once the business result is clear") and the A/B question
  format do not shorten it. A set of open owner questions is put as such a round too, not as one "accept all?" item.
- Grilling in a session of its own: when the owner asks to be grilled over the stage's open questions, the hub does not
  run it in its own context — a long grilling would fill it and push the hub into a handoff mid-conversation. Run
  `hub grill --stage <S>` (other stages' questions only when the owner names them: `--also-stage S2`; chosen entries:
  `--questions ID,…`; the owner's words: `--owner-words "…"`). It writes a brief and launches by host:
  - Claude Desktop: it prints `start_session` arguments with `initiation: "user_asked"`. Call
    `mcp__ccd_session__start_session` with them in this same turn — the app starts a session only in a turn the owner
    typed, and the hook lets `user_asked` through in a hub. Refused anyway: `hub grill --stage <S> --host bg --again`.
  - Claude in a terminal or a background session: it starts `claude --bg --remote-control <S>-grill` itself; give the
    owner the Remote Control link it prints.
  - Codex: `references/codex-hub.md` (*Grilling session on Codex*).
  After a native launch returns, or the owner confirms the full id of the manually started terminal session, run `hub grill bind --stage <S> --launch <id> --session <full returned id>`.
  The launcher result and the new session's own join must match; either may arrive first. A waiting join cannot grill
  until registered (repeat join after binding). An unknown result stays pending until verified; never guess an id.
  Background launches resolve their handle to a full sessionId themselves. Every generated command pins the hub's
  absolute `AGENT_HUB_HOME`, including in a fresh native session. A successful open clears the calling hub's grilling
  marker; failed launches and dry runs preserve it. If an uncertain bg launch is recovered with bind/join, activation
  clears only the saved original marker (same hub and grilling), preserving a newer grilling or successor. The interactive role is not an autopilot hub and has no automatic
  successor, so it does not need a hub grilling marker.
  The new session registers as role `grill` (`hub grill join` with the launch id of its brief), grills with the companion skill, records every answer
  in the register (`ask close`, `ask withdraw`, `ask add --by grill`, `ask decided` only when the owner delegates)
  and ends with `hub grill done`, which writes one line `@hub GRILLED <answered, withdrawn, open, new> — <summary>` and
  retires the role. That line wakes your `jwait`; act on the answers (the `ask list --pending` it names, then `ask
  done`). One grilling session per stage: `hub grill` refuses while one is registered or a launch has not joined yet
  (30 min; `--again` replaces a launch that never joined; `hub grill done --stage <S> --why "…"` ends one that went
  away; cancelling a pending launch also needs its matching `--launch <id>`). A grilling about a new topic the owner raises in the hub stays in the hub, unless the owner says otherwise.

## Planning a stage, in full

**Business DoD** is a short, ordinary-language description of the expected user or business result, clear enough
for the owner to leave the work to autopilot. Usually a short paragraph is enough. Use the owner's useful constraints
and any detailed specification they supplied; a full scenario, button design, numeric target or fixed schema is not
required. Detailed UI, scenario and technical design belong to the hub and executor unless supplied by the owner.
This recipe applies to Claude and Codex, in the console and app.

1. `ask search <topic words>` and `ask allow --list --stage <S>` — decisions and permissions already on record are
   settled; do not ask them again. For a successor or executor, preserve the inherited Business DoD and its source.
   When the stage's repository has no standing permission, run the short analysis of
   `<plugin-root>/skills/setup/SKILL.md` § 5 (what the project merges, deploys and releases; the owner's level) and add
   one grilling round about them; record each answer with `ask allow`.
2. If the expected business result is unclear, use the companion `grilling` skill (`mattpocock-skills`, see `<plugin-root>/docs/install.md#recommended-companion-grilling`):
   rounds of numbered questions, each with a recommended answer. **For this hub workflow, limit its exhaustive
   decision-tree method to ambiguity whose answer materially changes the business result; stop once that result is
   clear.** This limit is the hub's own choice; it never shortens a grilling the owner asked for (see "Grilling on request" above). Facts and implementation choices are agent-owned: research them and proceed with work that has no
   business blocker. If the companion is unavailable, mention its installation instructions once and use
   the same question method yourself.
3. Record owner answers with `ask add` then `ask close --answer …`; meaningful unresolved product branches go to
   the owner and register. Follow the existing register/default policy for blocked work. Agent decisions remain
   agent-owned; record the hub's choices with `ask decided` so they remain contestable.
4. Put the agreed Business DoD in the existing plan or brief, with a source link or register reference. A clear owner
   request can itself be the agreed DoD: restate it briefly and proceed within its authorization, without another
   interview or approval solely for adding a DoD heading or file. If your proposal materially changes the business
   scope or result, obtain owner agreement first. Before spawning, have a plan the owner said yes to: a clear,
   detailed request counts as that yes. Honor an explicit request to approve the plan before starting. Record the
   approved plan with `ask plan --stage <S> "<plan in one line>"` (`agent spawn` warns when the stage has none).
5. Brief executors with that source or a concise inherited result. Keep implementation steps, technical verification
   and stop/permission conditions separate. Later executors and hub shifts carry the same result through handoffs;
   they choose details independently and raise only new ambiguity that materially changes the business result.

For an owner who is not technical, one question is mandatory: "How will you open the result, and where should it live?",
with a recommendation. For something that runs in a browser, recommend a static site (for example GitHub Pages),
not "run a server on your Mac": a server dies with the laptop and the owner cannot restart it. Hand the result over
with a clickable local file or web link, or open it yourself (`open <path>` on macOS).

Put questions in the owner's words, about the product and what they will see. Purely technical choices (canvas or
DOM, localStorage, branch names) belong to the hub: decide and record them with `ask decided`.

Completion is judged against the agreed business result. Reports state what users actually received and how that
matches the result, with executor-owned technical evidence separately. Green CI alone does not prove business
completion. Existing merge, production, money and external-action permission policies still apply.

Ask the owner nothing about process: agents or not, worktrees, commits. Pick the launch by the criteria of "Choosing
how to launch work". If you write a change yourself, say why in one line and record it with `ask decided`.

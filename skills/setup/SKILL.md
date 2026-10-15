---
name: setup
description: Set up Delamain for a repository — ask which shared resources the project has (protected branches, environments, deploys, migrations, anything else), which commands touch each, write <repo>/.agent-hub/lock-rules.json and config.json, prove the lock hook with positive and negative checks, then propose standing permissions from what the project and the person show. Use right after installing the plugin, when a repository has no .agent-hub/ yet, or when the project gains a new shared resource.
argument-hint: "[repository path] [--defaults]"
---

# Delamain setup for a repository

Run bundled commands with the host's shell tool. Resolve the plugin root from `PLUGIN_ROOT`,
`CLAUDE_PLUGIN_ROOT`, or this skill's installed path; use `<plugin-root>/bin/<tool>` when PATH is missing
or shadowed. Session identity comes from the current host; use `self` where supported.

Two outcomes: lock rules for the shared resources (§§ 1–4), and standing permissions — which merges, deploys and
releases the hubs may do without asking each time (§ 5).

The lock hook refuses a command that touches a shared resource while another session holds that resource's lock.
It knows one resource by itself — `main-merge`: merges into, and pushes to, the protected branches. Everything else
(a production deploy, a staging environment, a migration chain, a shared test database) exists only if this setup
names it. A project with no deployment at all ends with `main-merge` only, and that is a complete setup.

Work in the repository's main checkout (or the path the user gave). Tools: `lock rules`, `lock rules init`,
`lock rules add`, `lock rules check`, `hub home` (all on PATH with the plugin; `--help` on each).

## 1. Look before you ask

Gather what the repository already says, so every question comes with a recommended answer:
- `lock rules` — what applies here now (an existing `.agent-hub/lock-rules.json` is extended, never replaced);
- `hub home` — where the hub keeps its files for this repository now and why (the legacy `~/.claude/agent-hub` is
  reported there, with the grant lines for a session started elsewhere);
- the default branch (`git symbolic-ref --short refs/remotes/origin/HEAD`, else `main`/`master`) and other long-lived
  branches (`release/*`, `production`);
- how the project deploys and migrates: CI files (`.github/workflows/`, `.gitlab-ci.yml`), `Makefile` targets, `scripts/`,
  Helm charts / Terraform / `fly.toml` / `Procfile`, migration directories (`migrations/`, `alembic/`, `prisma/`).
  Note the exact commands (`make deploy-prod`, `gh workflow run deploy.yml`, `helm upgrade … -n staging`,
  `alembic upgrade head`, `glab ci play deploy:prod`).

## 2. Grill the user, one round

Ask in one message, every question numbered, each with your recommended answer and the evidence behind it; the user
replies "ok" or corrects by number. Use the `grilling` skill if it is installed; the format is the same either way.
1. Protected branches — merges and pushes to them need `main-merge`. *Recommended:* the default branch (+ any release
   branch you found).
2. Environments other agents or people share (staging, preview, production) — one resource per environment that two
   sessions must not change at once. *Recommended:* from what you found, or "none".
3. For each resource: the commands that touch it, as you would type them. You turn each into a Python regex matched
   against the command's words joined by single spaces (anchor with `^` or `\b`; allow a path prefix like
   `^(?:\S*/)?glab …` when the tool may be called by full path).
4. Migrations — a resource for the migration chain? *Recommended:* yes if two branches can add migrations at once, as
   an informational resource (`migration-head`, no commands: the holder records the expected head with `--value`).
5. Anything else shared and single-user: a test database, a rate-limited API key, a release window. *Recommended:* none
   unless you saw one.
6. Should a hub hold `main-merge` by default (`AGENT_HUB_TAKE_MAIN_MERGE=true` in `config.json`: a free lock, and on
   takeover one held by an earlier hub of the same stage; another stage's lock needs an explicit `--take-main-merge`)?
   *Recommended:* yes when more than one agent may merge; no for a solo repository.
7. Where should the hub keep its files? One folder for all your projects, `~/agent-hub` (recommended: hubs of different
   projects can talk and share locks) / inside this project (nothing outside the repository; projects do not see each
   other, and `git clean -fdx` deletes that folder). *Recommended:* the shared folder, unless the user wants nothing
   outside the repository; say what `hub home` showed.
8. Autopilot — should a stage hub hand its shift to a background successor by itself when its context grows large, so
   the stage runs while you are away (`AGENT_HUB_AUTO_HANDOFF=on`, in the hub home's `config.json`, not the
   repository's)? Check the selected engine first: Claude uses `claude auth status` (`"loggedIn": true`) and an accepted
   directory trust prompt; Codex uses `codex login status` and the hook setup in `docs/codex.md`.
   Codex successors are detached sessions reached through `agent send`, not Claude Remote Control. *Recommended:* on if the user wants to leave stages running and both
   checks pass; off otherwise (say which check failed and the command that fixes it).
9. Watchdog — a job every 5 minutes (`watchdog`, launchd on macOS, cron elsewhere; no daemon, no model) that writes
   `EXIT … killed (no result)` for agents that died, and wakes a hub that sleeps without a waiter while lines addressed
   to it have waited 15 minutes (or a night-queue item waits inside `AGENT_HUB_NIGHT`). It wakes a headless hub and an
   idle `claude --bg` hub, and a confirmed idle Codex app hub registered from its current thread; terminal and unknown
   hosts get a notification instead ([host conditions](../../docs/monitoring.md#which-host-is-woken-how)). It never
   starts a successor. `AGENT_HUB_WATCHDOG` lives in the hub home's `config.json`. *Recommended:* on if autopilot is on
   or you leave stages running while you are away; off otherwise.
   Codex app wake requires a reachable CLI runtime or a separately configured app-native heartbeat; the native
   automation consumer may use model calls. `watchdog install` alone does not install that native consumer.
10. MCP servers of headless agents — `AGENT_HUB_SPAWN_MCP` in `config.json`: `inherit` (the default) or `none`?
   *Recommended:* `none` unless the project's agents use an MCP server (a GitLab or database one, say); the default stays `inherit`.

`--defaults` (or a headless run with nobody to answer): take the recommended answers, say so in the report, and list
what the user should confirm. Autopilot and the watchdog stay off in that case: nobody asked for background sessions or
a scheduled job, and the user's settings are not edited (question 7): list the edit for the user to confirm.

## 3. Write

```bash
lock rules init [--protected main release]             # .agent-hub/lock-rules.json + config.json (repo name)
lock rules add deploy-window --about "a production rollout is in progress" \
    --match '^make deploy-prod\b' --action "production deploy"
lock rules add staging --about "the shared staging environment" \
    --match '^helm upgrade\b.* -n staging\b' --action "staging rollout"
lock rules add migration-head --about "expected head of the migration chain"    # informational
```
Resource names are lowercase letters, digits and hyphens; pick names the team will say aloud. `add` refuses a bad
regex and leaves the file as it was. For question 6, add `"AGENT_HUB_TAKE_MAIN_MERGE": "true"` to
`.agent-hub/config.json` by hand. For question 7:
- *inside this project:* add `"AGENT_HUB_HOME": "project"` to `.agent-hub/config.json` (the home becomes
  `<main checkout>/.agent-hub/local/`, kept out of git by the tools; a session in the repository needs no grant);
- *one shared folder:* nothing to write in the repository, `~/agent-hub` is the default. A session started outside it
  may need the folder granted. In Claude, OFFER to add it to the user settings: run `hub home`, show the exact edit — the path
  `hub home` prints added to `permissions.additionalDirectories` in `~/.claude/settings.json`, other keys and entries
  kept — and ask first. In Codex sandboxed sessions, use `--add-dir <hub-home>` or the documented sandbox settings; full access needs
  no directory grant. Show a concrete settings edit before changing user settings. With `--defaults` or headless, list it.
- if `hub home` showed the legacy `~/.claude/agent-hub`, say so and mention `hub home migrate` (a dry run first, then
  `--apply`).

For question 8, add `"AGENT_HUB_AUTO_HANDOFF": "on"` to the hub home's `config.json` (the hub home is where `hub home`
points; create the file as `{}` first, keep its other keys) — a repository's `config.json` cannot turn it on.

Idle compaction (Claude only, whatever the answers): Claude Code 2.1.290+ compacts a conversation over 200K tokens
left idle ~54 minutes (on by default since 2.1.299), and a hub waiting on `jwait` would go on from a summary instead of
handing over. Read `idleCompaction` in the managed settings, the project's `.claude/settings.local.json` and
`.claude/settings.json`, and `~/.claude/settings.json` (the first file that sets it decides). Unless it is `false`,
OFFER to add `"idleCompaction": false` to `~/.claude/settings.json` (other keys kept): show the exact edit and ask first;
with `--defaults` or headless, list it. `hub start` and `hub takeover` print the same warning from the same check.

For question 9, on yes (the hub home's settings are hub-wide; a repository's `config.json` cannot set them):
1. `watchdog install` — writes the job (`<hub home>/.state/watchdog/run.sh`, a launchd plist or one crontab line) and
   sets `"AGENT_HUB_WATCHDOG": true` in the hub home's `config.json`; `watchdog status` shows it.
2. Ask for a remote channel: none, or a phone push. For an ntfy topic of the person's own, show the edit first, then add
   to the hub home's `config.json` (keep its other keys):
   `"AGENT_HUB_NOTIFY_CMD": ["curl", "-fsS", "-d", "{message}", "https://ntfy.sh/<topic>"]`. The command runs without a
   shell; `{message}` is the stage name, minutes and counts only.
3. `watchdog notify-test` sends `delamain: test notification` through every channel; ask the person whether it
   arrived (on macOS the local one is sent with `osascript` and may need the notification permission).
4. `watchdog run --dry-run` prints what the watchdog would do now and writes nothing; show it.
5. If `~/.claude/scheduled-tasks/night-nudge` exists, tell the person that the watchdog replaces that Desktop task and
   they may delete it. List it, never delete it.

With `--defaults` or headless nothing is installed: list `watchdog install`, the `AGENT_HUB_NOTIFY_CMD` edit,
`watchdog notify-test` and `watchdog run --dry-run` for the person to run. After a plugin update the person runs
`watchdog install` again (the job points at the plugin version that was installed).

### Native Codex worker definitions

For a Codex host, offer to copy `resources/codex-agents/worker-*.toml` from this skill to the project's
`.codex/agents/` (or `~/.codex/agents/` if the owner requests personal scope). Keep existing definitions unless
an update was requested. These files pin effort and inherit the model selected at spawn; set a real available
model id when a persistent pin is required. Installed Claude `agents/*.md` are not native Codex definitions.
The plugin manifest loads skills and hooks; it does not register these TOML files automatically.
Check that `python3` is 3.11+ before enabling Codex hooks or workers; TOML discovery needs the standard-library parser.

## 4. Prove it

For every resource, one command that must be guarded and one look-alike that must not:
```bash
lock rules check "git push origin main" --expect main-merge
lock rules check "make deploy-prod" --expect deploy-window
lock rules check "make deploy-preview" --expect-none
lock rules check "git push origin feature/x" --expect-none
```
`check` runs the plugin's real hook against a scratch board where every resource is held by someone else; it never
touches the real board. Every line must exit 0. A failed positive means the regex misses the real command; a failed
negative means it catches too much — fix the rule (`lock rules add` the corrected `--match`, then remove the wrong one
from the file by hand) and re-run all checks.

## 5. Standing permissions: read the project and the person, then grill

A standing permission is the owner's word that a class of action needs no question each time ("merge after green CI
and a review", "deploy to staging") — recorded once with `ask allow`, bound to the repository the action touches and
seen by the hubs of every stage (`<plugin-root>/docs/standing-permissions.md`). There is no fixed list to offer: the
classes come from this project and this person. A hub whose stage's repository has no permission runs this section
too, as one grilling round.

1. **Read the project** (reuse § 1): what gates a merge (required CI checks, reviews, branch protection); which
   environments exist and how each is reached (deploy on merge, a manual job, a script); how a release is cut and
   published; migrations and who applies them; code that touches money (payments, billing, payroll, invoices) and
   anything that leaves the company (mail, messages to customers, publishing a package, external APIs).
2. **Read the person**: their level and how they like to work — the global instructions (`~/.claude/CLAUDE.md`;
   Codex: `~/.codex/AGENTS.md`), the project's `AGENTS.md` / `CLAUDE.md`, a profile in memory if there is one. A person
   who reviews every merge gets different recommendations from one who wants to hear only about production.
3. **Check what is on record**: `ask allow --list --repo <repository>` and `ask search merge deploy release` (and the
   person's own words for them). What is recorded is not asked again.
4. **Grill**: rounds of numbered questions, one per class of action you found, each with a recommendation and the
   evidence (the CI file, the deploy job). Recommend the scope (the repository by default; one stage; all
   repositories) and an end date only when the person hints at one. Money and anything that leaves the company get no
   recommended permission: ask about them only if the project has them, and recommend they stay with the person.
5. **Record each yes** with the person's own words, from the stage you run in (outside a stage, `--stage setup`):
   ```bash
   ask allow --stage <S> --repo <repository> --class "merge" --words "«…their reply…»" --source "setup, <date>" \
       "merge a PR after green CI and one review"
   ```
   `--class` is a few comma-separated keywords, as specific as the words (`deploy-staging` when the yes was about
   staging); questions about the same class are asked with `ask add --class` and the same keywords, so say them in
   the report. Money, migrations and permissions/RBAC need a permission that names them in `--class`. `ask allow --list --repo <repository>` must show every entry.

`--defaults` (or headless, nobody to answer): record no permission — a permission needs the person's words. List the
proposed ones, with the `ask allow` lines, in the report for the person to confirm.

## 6. Report

A short table: resource — what it guards — the checks that passed — and the answers you took by default that the
user should confirm; then the standing permissions recorded (§ 5, `ask allow --list`) or proposed. Then suggest
committing `.agent-hub/` (it is the team's shared convention); commit only if the user asked you to. Other files there are optional: `brief-footer.md`, `hub-rules.md`, `HUB-NOTES.md`,
`handoff-facts.sh`, `takeover.sh` — see `<plugin-root>/docs/reference.md#configuration-layers`. Locks themselves live on the board, not in the repository:
`lock take <resource> --until … --why …` when work starts.

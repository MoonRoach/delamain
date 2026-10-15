# Contributing

Read this when changing this repository, including documentation, skills and templates.
For using the product, return to the [agent entry point](README.md#install-or-operate).

1. Read the repository's `AGENTS.md` and applicable instructions. Inspect the relevant source and CLI `--help`
   before changing a command example or capability claim. Tools live in `bin/`, hooks in `hooks/`, skills in
   `skills/`, briefs and handoffs in `templates/`. File protocols are in [Architecture](../architecture.md).
   Done when each changed claim has a source and each changed file is within assigned ownership.
2. Keep code, docs and comments in English; commit messages and PR descriptions follow the owner's Russian
   convention. Record user-visible changes in `CHANGELOG.md`. When editing agent docs, use precise branch
   pointers, checkable completion criteria and one authoritative home per meaning. Resolve installed skill
   pointers from the plugin root; repository-only operational paths are not installation paths.
   Done when new or moved content has a discoverable entry and existing inbound pointers resolve.
   The hub skill is loaded whole by every hub and re-read on every call: `skills/hub/SKILL.md` is a core, and a
   procedure used only in some situations (Codex Desktop, a handoff, a review) goes to `skills/hub/references/` with a
   "read … when …" pointer in the core. `tests/t_hub_skill_layout.sh` holds its size budget and its pointers.
3. Run checks appropriate to the change from the repository root. Read actual exit codes from the execution
   harness or redirected output, rather than the final command of a pipe.

   ```bash
   git diff --check
   bash tests/run_all.sh "$(mktemp -d)"
   claude plugin validate .claude-plugin/plugin.json --strict
   ```

   The suite runs scripts in parallel (`TEST_JOBS` bounds concurrency). Tests use throwaway homes and stand-in
   CLIs; no model is called. Allow up to ten minutes in the shell harness. For one script, run
   `bash tests/t_<name>.sh`. For mod changes, `claude plugin test .` runs `hooks/agent-top.test.tsx`;
   `tests/t_mod.sh` checks packaging and runs it if a mods-capable CLI is available (`MOD_CLAUDE` can select it),
   otherwise reports SKIP. See [CI workflow](../../.github/workflows/tests.yml) for configured jobs.
   For doc moves, also check local link targets, assets and heading anchors across the tracked Markdown,
   with known valid and invalid controls. Done when applicable checks pass and unavailable checks are recorded.
4. Report changed behavior, evidence, validation and unresolved limitations in the PR. Follow the task's
   authorization and stop boundary for review, merge and release. Done when the requested deliverable and
   check results are reviewable; an open PR does not itself authorize merge or deployment.

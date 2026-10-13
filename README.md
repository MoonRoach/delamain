# Delamain

One coordinator. An autonomous fleet. Coding work that keeps moving across chat sessions.

Delamain coordinates long-running coding work with **Claude Code or Codex**: dispatch workers from briefs,
follow their progress, and hand the next coordinator the records it needs to continue.

The name is a nod to [Delamain, the AI cab-fleet operator in Cyberpunk 2077](https://cyberpunk.fandom.com/wiki/Delamain_%28AI%29):
one dispatcher, independent workers with distinct roles, and a service that keeps moving when the coordinator changes.

**Ask your agent first:** [Should we install this? Agent guide →](docs/agents/README.md#assess-fit-before-installing)

## Is it for you?

Install it when work needs to continue across chat sessions, you need to manage several workers
by role, or you want recorded decisions and a handoff for the next coordinator.

It gives you:

- **Workers you can reach later:** start from a brief, check progress, message or resume by role.
- **Shared memory for the work:** journals, inboxes, owner questions and handoff files.
- **Coordination for shared resources:** locks on protected branches and shared environments.
- **A progress view:** `agent-top` in a terminal for both engines; a live pane in Claude Code.

Skip it for a small task one session can finish, or when built-in subagents already cover your needs.
It runs locally for **one person on one machine**.

![Delamain's blue AI dispatcher assigns coding, testing, review, documentation and assembly tasks to five autonomous cabs; their reports converge on a shared journal.](docs/assets/delamain-fleet.png)

## Start

1. **Install for your host.** On macOS or Linux, with Python and the selected CLI available:

   **Claude Code** (2.1.287+; Python 3.10+), in its chat:

   ```text
   /plugin marketplace add ilya-kozyrev/delamain
   /plugin install delamain@delamain
   ```

   Confirm `/delamain:hub` is available after installation. [Installation and permissions →](docs/install.md)

   **Codex** (Python 3.11+): [clone, install and trust hooks →](docs/codex.md#install-in-codex).

   **Native Windows Codex with WSL2:** [follow the task from setup to the user result →](docs/windows-workflow.md).
   The original core runs in Linux through the [Desktop transport](docs/windows-desktop.md).
   A [WSL terminal coordinator](docs/windows-wsl.md) is a separate explicit mode.

   Detached workers default to broad permissions. Review the linked permission settings before launching them.

2. **Set up your project.** Open your repository in the chosen host and ask:

   ```text
   Use delamain:setup for this repository.
   ```

3. **Give the hub a job.** In Claude Code, start with `/delamain:hub`; in Codex, ask to use
   `delamain:hub`. For example:

   ```text
   Use delamain:hub to plan a stage called csv-export: add CSV export to the reports page.
   Wait for my approval of the plan. Stop at open PRs with green CI; ask before merging.
   ```

The hub preserves your Business DoD across handoffs; a clear request already supplies it.
[Planning recipe →](skills/hub/SKILL.md#planning-a-stage-agree-the-business-result-before-autonomous-work)
Answer open decisions and approve the plan when you asked the hub to wait. Check progress with `/agent-top` in Claude Code,
or ask the session what is running: the `status` skill answers from `agent-top` data. [Use your own terminal →](docs/install.md#what-installing-changes)
The hub tells you when results need your attention.

## Read more when you need it

- [For agents: assess fit, operate, or contribute](docs/agents/README.md)
- [Getting started: a human walkthrough](docs/getting-started.md)
- [Codex setup and engine differences](docs/codex.md)
- [Commands, configuration and limits](docs/reference.md)
- [Monitoring and screenshots](docs/monitoring.md)
- [Why use a hub?](docs/why.md) · [Comparison with built-in facilities](docs/comparison.md)
- [Architecture](docs/architecture.md) · [Launch choices](docs/launch-modes.md) · [Reviewers](docs/reviewers.md)
- [Roadmap](ROADMAP.md) · [Changelog](CHANGELOG.md) · [Contributing and tests](docs/agents/contributing.md)

MIT — [License](LICENSE).

# Agent entry point

Use this page when a user asks whether to install Delamain, when operating an installed plugin,
or when changing this repository. Select the matching branch below before loading more documents.
Paths resolve from this page; installed tools and resources resolve from the **plugin root**,
two directories above `skills/hub/SKILL.md`. The same files are readable on GitHub before cloning.

## Assess fit before installing

1. Identify what coordination the task needs beyond the selected host's existing tools. Recommend **skip**
   when native subagents with separate worktrees satisfy the work within one session, or a standalone background
   task is sufficient. Consider installation for the added protocol actually needed: workers reachable by role
   across hub changes, persistent decisions and handoffs, or configured shared-resource coordination.
   Done when each requested need is marked as covered by existing tools or requiring the added protocol.
2. Check prerequisites and limitations against that need:

   | Capability | Prerequisite or limit | Source to inspect if relevant |
   |---|---|---|
   | Detached workers, status, inbox and resume by role | Authenticated selected CLI; workers default to broad permissions; writers need separate worktrees, which require a Git commit | [Installation](../install.md), [Codex permissions](../codex.md#full-access-and-hook-trust), `<plugin-root>/bin/agent spawn --help` |
   | Journals, questions, reports and hub handoffs | Writable hub home; local to one person and machine; handoff contents are written by the agent | [Home resolution](../reference.md#where-the-hubs-files-live), [Architecture](../architecture.md) |
   | Resource locks | Configured rules and enabled, trusted hooks; only recognised commands are guarded; hook errors fail open | [Hook scope](../architecture.md#hook-scope), [Setup skill](../../skills/setup/SKILL.md) |
   | Terminal monitor for both engines | macOS or Linux; Python 3.10+ for Claude, 3.11+ for Codex; CLI on PATH | [Monitoring](../monitoring.md), [Codex](../codex.md) |
   | Claude Code pane | Claude Code 2.1.287+ with mods; unavailable in Codex and the other views listed in its guide | [Pane support](../monitoring.md#agent-top-inside-claude-code-a-live-pane) |
   | Automatic hub succession | Opt-in; selected CLI authenticated and trusted; engine-specific successor and access settings | [Autopilot](../reference.md#autopilot-the-hub-hands-over-by-itself), [Codex differences](../codex.md#coordination-and-platform-differences) |
   | Watchdog: wakes a sleeping hub, notifies the owner, writes `EXIT` for dead agents | Opt-in (`watchdog install`); launchd on macOS or cron elsewhere; headless and idle `claude --bg` hubs are woken, Desktop, terminal and Codex hubs only notified; never starts a successor | [Watchdog](../monitoring.md#watchdog-a-hub-that-sleeps-is-woken), [Settings](../reference.md#configuration) |

   The core requires macOS or Linux. Native Windows Codex is conditionally supported through the
   [Windows workflow](../windows-workflow.md) and its WSL2 transport prerequisites, within the documented
   validation boundary. The [WSL terminal](../windows-wsl.md) is a separate explicit Linux coordinator mode.
   Native Windows Claude integration is not established. Brief turn limits are instructions, not enforced budgets.
   Done when every capability the user needs has its prerequisites satisfied or a named missing prerequisite.
3. Return **install**, **skip**, or **defer setup** with a short reason. Install when existing tools leave a protocol need from step 1 unmet
   and its prerequisites are satisfied; defer when that need exists but a prerequisite is missing.
   State the needed permissions before recommending a detached launch. Describe benefits as verified
   capabilities: continuity, reachability and recorded decisions. State the scope as local to one person and
   machine; support any cost claim with evidence. Done when the user has a recommendation and one concrete next action.

## Install or operate

1. For a new installation, follow [Claude installation](../install.md) or [Codex installation](../codex.md#install-in-codex)
   for the selected host. Confirm its installed skills are available; review the permissions and hook trust there.
   Done when the host can load `delamain:setup` and `delamain:hub`.
2. For repository setup, load [the setup skill](../../skills/setup/SKILL.md). It owns resource discovery,
   configuration and positive/negative lock controls. Done when its report accounts for each configured resource
   and both controls pass.
3. For a new stage or an existing shift, load [the hub skill](../../skills/hub/SKILL.md) and follow its matching
   start or takeover branch. It owns planning, authorization, worker launch and waiting. Use the selected host's
   shell tool and `<plugin-root>/bin/<tool>` if PATH is missing or shadowed. Done when the stage is registered,
   existing decisions are checked, and the skill's next action is identified.

Load only the branch reference needed for the next action:

| Task | Read |
|---|---|
| Decide native versus detached launch | [Launch modes](../launch-modes.md) |
| Select or configure a reviewer | [Reviewers](../reviewers.md) |
| Record or check what the owner allowed without asking each time | [Standing permissions](../reference.md#standing-permissions) |
| Configure a setting, migrate home, inspect lifecycle or limits | [Reference](../reference.md) (matching heading); CLI `--help` for exact syntax |
| Inspect progress or diagnose a missing pane | [Monitoring](../monitoring.md); [Codex monitor](../codex.md#terminal-monitor-and-older-installations) |
| End a shift | [Handoff skill](../../skills/handoff/SKILL.md) |
| Report a stage's progress to the owner or the team as an infographic page | [Progress report skill](../../skills/progress-report/SKILL.md) |
| Change delegation level | [Delegation skill](../../skills/delegation/SKILL.md) |
| Finish a task from native Windows Codex | [Windows workflow](../windows-workflow.md) |
| Explain the workflow to a person | [Getting started](../getting-started.md) |

## Contribute to the repository

Read [Contributing](contributing.md) before editing plugin files. These are contributor checks;
they are distinct from the workflow for users installing the plugin in their own projects.

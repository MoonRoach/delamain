# Brief: <what to do, one sentence>

<!-- Short template for a headless agent's brief. Facts and paths, not a retelling of the conversation.
`agent spawn` appends a footer that tells the agent how to report (journal tag, report file, inbox, status words), so
this file only says what to do. More controls (production permissions, size limits, evidence rules):
brief-executor-advanced.md. -->

## Why
<The problem and what it costs, in a few lines, with a source (an issue, a journal line, a report).>

## Decisions already made — do not reopen
<One line each, from `ask search <topic words>`; or "none on record (ask search <words>)".>

## Business DoD
<Agreed user/business result or its source in the plan/register; inherit it without reopening.
See skills/hub/SKILL.md, "Planning a stage". Preserve owner-supplied constraints and detailed specs.>

## Steps
1. <Step> — done when <a check: a command, a number, a test>.
2. <…>

## Technical verification
<What proves it works: the tests to run, and one check that would fail if the change were wrong.>

## Tools
MCP servers needed? (none by default) <A browser check, docs lookup, a GitLab/DB server: name it, and launch with `--mcp inherit` or `--mcp FILE`.>

## Stop
Report the delivered result against the Business DoD, with technical evidence separately.
<Where to stop: e.g. "push the branch and open a PR; do not merge". What not to touch.> At most <N> turns.
Commit work in progress before long test runs. List the processes you started in the background (servers, watchers)
in your report and stop them before DONE.

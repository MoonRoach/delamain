#!/usr/bin/env python3
"""Veto Codex PreCompact; registration selects the event, not session metadata.

Do not read stdin, transcripts, settings or identifiers: missing data must not
allow compaction. This standalone handler is registered only for PreCompact.
"""
import json


if __name__ == "__main__":
    print(json.dumps({
        "continue": False,
        "stopReason": "Delamain forbids automatic and manual compaction. Save a checkpoint and follow the existing handoff policy.",
        "systemMessage": "Delamain blocked compaction. If the automatic context limit has been reached, this session may stop before an answer; continue from its checkpoint with a fresh coordinator for the same stage under existing authority. Repeating prompts in an overfull session will not help. Below that limit, normal prompts and tools can continue.",
    }))

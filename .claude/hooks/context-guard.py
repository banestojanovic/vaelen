#!/usr/bin/env python3
"""Non-blocking Claude context guard described in docs/WORKFLOW.md."""
import json
import os
import sys
import tempfile

WARN = int(os.environ.get("VAELEN_CONTEXT_WARN", 150_000))
HANDOFF = int(os.environ.get("VAELEN_CONTEXT_HANDOFF", 200_000))
STEP = 50_000
TAIL_BYTES = 4 * 1024 * 1024


def context_tokens(path):
    with open(path, "rb") as stream:
        stream.seek(0, os.SEEK_END)
        stream.seek(max(0, stream.tell() - TAIL_BYTES))
        lines = stream.read().splitlines()
    for raw in reversed(lines):
        try:
            entry = json.loads(raw)
        except ValueError:
            continue
        message = entry.get("message") if isinstance(entry, dict) else None
        if entry.get("isSidechain") or not isinstance(message, dict) or message.get("role") != "assistant":
            continue
        usage = message.get("usage")
        if isinstance(usage, dict):
            return sum(int(usage.get(key) or 0) for key in
                       ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
    return None


def level(tokens):
    return 2 + (tokens - HANDOFF) // STEP if tokens >= HANDOFF else (1 if tokens >= WARN else 0)


def main():
    payload = json.load(sys.stdin)
    if payload.get("agent_id"):
        return
    path = payload.get("transcript_path")
    session = payload.get("session_id", "unknown")
    event = payload.get("hook_event_name")
    if not path or not os.path.exists(path) or event not in ("PostToolUse", "UserPromptSubmit"):
        return
    tokens = context_tokens(path)
    if tokens is None:
        return
    state_dir = os.path.join(tempfile.gettempdir(), "vaelen-context-guard")
    os.makedirs(state_dir, exist_ok=True)
    state_path = os.path.join(state_dir, f"{session}.json")
    try:
        with open(state_path) as stream:
            fired = json.load(stream).get("level", 0)
    except (OSError, ValueError):
        fired = 0
    now = level(tokens)
    if now < fired:  # /clear or compaction shrank the context: re-arm.
        fired = now
    if now <= fired:
        with open(state_path, "w") as stream:
            json.dump({"level": fired}, stream)
        return
    with open(state_path, "w") as stream:
        json.dump({"level": now}, stream)
    count = tokens // 1000
    if now == 1:
        note = (f"Context guard: this session is about {count}k tokens. Finish the current item, run its checks, "
                "and do not start another queue item.")
    else:
        note = (f"Context guard: context is about {count}k tokens. Stop new work, leave nothing running, "
                "rewrite the Current block in docs/HANDOFF.md per docs/WORKFLOW.md, then end with the shift report.")
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": note}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass

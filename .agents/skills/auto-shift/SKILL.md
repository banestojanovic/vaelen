---
name: auto-shift
description: Run the Vaelen queue unattended, one fresh Claude /shift session per item. Use for /auto-shift, $auto-shift, or "run auto-shift N".
---

Run `Scripts/auto-shift.sh [rounds]` in the background (default 5). It requires the Claude CLI and starts a fresh session for each item. Do not perform queue work in parallel or inspect logs while it runs. It reports through the current Rex terminal when available, opens no tabs, and never pushes. It stops on a STOP report, failure, a round without a commit, a report without CONTINUE, or the round limit.

When it exits, report the stop reason, commits since start, and the next item from `docs/HANDOFF.md` in at most five lines. Read a log only if a round failed. Do not run it while another writer is editing this checkout.

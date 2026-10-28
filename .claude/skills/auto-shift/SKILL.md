---
name: auto-shift
description: Run the Vaelen queue unattended, one fresh /shift session per item. Use for /auto-shift or /auto-shift 3.
disable-model-invocation: true
---

Run `Scripts/auto-shift.sh [rounds]` in the background (default 5). It updates the nearest Rex terminal status when one exists and does not open tabs. Do not do queue work in parallel and do not inspect logs while it is running. It stops when a round reports STOP, fails, makes no commit, omits CONTINUE, or reaches its limit. When it exits, report the stop reason, commits since start, and the next item from `docs/HANDOFF.md` in at most five lines. Open a log only when a round failed.

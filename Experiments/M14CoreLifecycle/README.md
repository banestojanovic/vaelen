# M14 Core Lifecycle Experiment

This is a disposable, non-production macOS ServiceManagement experiment.

It is deliberately independent of Vaelen Core. It does not import Vaelen
modules, use the Vaelen socket, open SQLite, or touch any Vaelen resource.

## Fixed identity

```text
Bundle ID:     dev.vaelen.m14-lifecycle-experiment
Agent label:   dev.vaelen.m14-lifecycle-experiment.agent
Agent plist:   dev.vaelen.m14-lifecycle-experiment.agent.plist
Root:          ~/Library/Application Support/M14CoreLifecycleExperiment
App:           ~/Library/Application Support/M14CoreLifecycleExperiment/App/M14CoreLifecycleExperiment.app
```

The production identifier `dev.vaelen.core` is rejected by the controller.

The experiment controller and LaunchAgent are separate executables:

```text
Contents/MacOS/M14CoreLifecycleExperiment
Contents/Resources/M14CoreLifecycleAgent
Contents/Library/LaunchAgents/dev.vaelen.m14-lifecycle-experiment.agent.plist
```

The embedded plist uses Apple's bundle-relative `BundleProgram` declaration;
it does not use an absolute `ProgramArguments` executable path.

## Build and prepare

Run from the repository root on macOS with full Xcode:

```bash
Experiments/M14CoreLifecycle/prepare-experiment.sh
```

The script builds the disposable app, copies it to the fixed experiment root,
fills the plist's absolute experiment-only paths, and signs the final
development artifact. It does not register or load the agent. It refuses
ad-hoc signing; set `M14_SIGNING_IDENTITY` to a stable local identity returned
by `security find-identity`.

Inspect the result:

```bash
APP="$HOME/Library/Application Support/M14CoreLifecycleExperiment/App/M14CoreLifecycleExperiment.app"
"$APP/Contents/MacOS/M14CoreLifecycleExperiment" status
"$APP/Contents/MacOS/M14CoreLifecycleExperiment" evidence
codesign -dvvv "$APP" 2>&1
codesign -dvvv "$APP/Contents/MacOS/M14CoreLifecycleExperiment" 2>&1
codesign -dvvv "$APP/Contents/Resources/M14CoreLifecycleAgent" 2>&1
```

## Human lifecycle procedure

Do not run `register` or `unregister` until reviewing the prepared bundle.
These are the only commands in this harness that call ServiceManagement
mutation APIs.

```bash
ROOT="$HOME/Library/Application Support/M14CoreLifecycleExperiment"
APP="$ROOT/App/M14CoreLifecycleExperiment.app"
BIN="$APP/Contents/MacOS/M14CoreLifecycleExperiment"

# 1. Initial state; no registration mutation.
"$BIN" status
"$BIN" evidence

# 2. Register through SMAppService.agent.
"$BIN" register
"$BIN" status
"$BIN" evidence

# 3. Confirm agent UID, path, launch count, and PID.
"$BIN" evidence

# 4. Quit this controller Terminal process. The agent must remain alive.
#    Open a new Terminal, then inspect again:
"$BIN" status
"$BIN" evidence

# 5. Safely terminate only the exact PID recorded by the experiment.
#    The command verifies UID and executable path before sending SIGKILL.
PID="$("$BIN" agent-pid)"
"$BIN" terminate-agent "$PID"

# 6. Observe relaunch and record the new PID/generation.
sleep 5
"$BIN" status
"$BIN" evidence

# 7. Optional: repeat one or two verified terminations, with observation
#    between each. Do not create an extended crash loop.
PID="$("$BIN" agent-pid)"
"$BIN" terminate-agent "$PID"
sleep 5
"$BIN" evidence

# 8. Unregister through SMAppService. This must leave the agent off.
"$BIN" unregister
"$BIN" status
"$BIN" evidence
sleep 5
"$BIN" status

# 9. Repeat unregister to capture the platform's actual repeated-operation
#    result, if safe.
"$BIN" unregister
"$BIN" evidence

# 10. Optional repeated-register test, followed by final unregister.
"$BIN" register
"$BIN" register
"$BIN" evidence
"$BIN" unregister
sleep 3
"$BIN" status
"$BIN" evidence
```

Do not manually edit launchd databases or use the production Vaelen label.

## Optional variants

Do not perform these for the first run. They require rebuilding/preparing a
fresh copy and must be followed by the same exact-identity cleanup procedure:

- copy the prepared app to a second experiment-only path and inspect status;
- replace only the experiment executable, re-sign the experiment app, and
  observe status/launch behavior;
- change only the experiment plist, re-sign the experiment app, and observe
  status/launch behavior.

If ownership becomes ambiguous, stop and preserve the artifact.

## Cleanup

After the final unregister and a bounded observation period:

```bash
ROOT="$HOME/Library/Application Support/M14CoreLifecycleExperiment"
APP="$ROOT/App/M14CoreLifecycleExperiment.app"
BIN="$APP/Contents/MacOS/M14CoreLifecycleExperiment"
"$BIN" status
"$BIN" evidence
```

Only when status proves the experiment is unregistered and no experiment PID
is alive may the experiment root be removed:

```bash
rm -rf "$ROOT"
```

The harness itself never removes the root automatically.

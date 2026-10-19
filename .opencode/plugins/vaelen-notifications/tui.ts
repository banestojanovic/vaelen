import { Plugin } from "@opencode/plugin/tui"

export default Plugin.define({
  id: "vaelen.notifications.tui",
  setup(context) {
    const notify = async (
      sessionID: string | undefined,
      kind: "complete" | "failed" | "decision",
    ) => {
      if (!sessionID) return

      const route = context.ui.router.current()
      if (route?.type !== "session" || route.sessionID !== sessionID) return

      const result = await context.attention.notify({
        title:
          kind === "complete"
            ? "Vaelen task complete"
            : kind === "failed"
              ? "Vaelen task failed"
              : "Vaelen task needs a decision",
        message: "Review the current OpenCode session.",
        notification: { when: "always" },
      })

      if (result.notification) {
        context.ui.toast.show({
          message: "Completion notification sent.",
          variant: "success",
          duration: 3000,
        })
      }
    }

    const stopComplete = context.data.on(
      "session.execution.succeeded",
      (event) => void notify(event.data.sessionID, "complete"),
    )
    const stopFailure = context.data.on(
      "session.error",
      (event) => void notify(event.data.sessionID, "failed"),
    )
    const stopDecision = context.data.on(
      "permission.asked",
      (event) => void notify(event.data.sessionID, "decision"),
    )

    return () => {
      stopComplete()
      stopFailure()
      stopDecision()
    }
  },
})

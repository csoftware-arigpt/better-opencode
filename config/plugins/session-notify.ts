// session-notify — портирован с termux-notify.ts станции (termux-notification → notify-send).
// Уведомления GNOME по событиям сессии: завершение ответа и ошибки.
import { Plugin } from "@opencode/plugin"

export default Plugin.define({
  id: "session-notify",
  async setup(ctx) {
    const notify = (title: string, body: string, critical = false) => {
      try {
        Bun.spawn(["notify-send", "-a", "OpenCode", ...(critical ? ["-u", "critical"] : []), title, body], {
          stdout: "ignore",
          stderr: "ignore",
        })
      } catch { /* нет notify-send — тихо живём */ }
    }

    const abort = new AbortController()
    const task = (async () => {
      for await (const ev of ctx.event.subscribe({ signal: abort.signal })) {
        try {
          const type = String((ev as any)?.type ?? "")
          if (type === "session.idle") {
            notify("opencode: ответ готов", "сессия свободна")
          } else if (type === "session.error") {
            notify("opencode: ошибка сессии", "смотри лог", true)
          }
        } catch { /* не роняем стрим */ }
      }
    })()

    return async () => {
      abort.abort()
      try { await task } catch { /* teardown */ }
    }
  },
})

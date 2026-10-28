// garble-guard — детектор дегенеративных повторов в ответах LLM (glm-free и не только).
// Смотрит события сообщений, накапливает текст, при повторе буквенного фрагмента ×4 → notify-send.
// Детектор: фрагмент 3-12 симв. с буквами, повторсBLE подряд ≥4 — мусор, markdown-разделители игнор.
import { Plugin } from "@opencode/plugin";
import { appendFileSync } from "node:fs";

const LETTER = /[a-zа-яё0-9\u4e00-\u9fff]/i;
const LOG = process.env.HOME + "/.local/state/garble-guard.log";

function detect(s: string): string | null {
  for (let len = 3; len <= 12; len++)
    for (let i = 0; i + len * 4 <= s.length; i++) {
      const frag = s.slice(i, i + len);
      if (!LETTER.test(frag)) continue;
      let n = 0, j = i;
      while (s.startsWith(frag, j)) { n++; j += len; }
      if (n >= 4) return frag;
    }
  return null;
}

export default Plugin.define({
  id: "garble-guard",
  async setup(ctx) {
    const abort = new AbortController();
    const parts = new Map<string, string>(); // msgID/partID → накопленный текст
    let lastToast = 0;

    const toast = (body: string) => {
      try {
        Bun.spawn(["notify-send", "-a", "OpenCode", "-u", "critical", "garble-guard", body], { stdout: "ignore", stderr: "ignore" });
      } catch { /* нет notify-send — живём без тоста */ }
    };

    const task = (async () => {
      try {
        for await (const ev of ctx.event.subscribe({ signal: abort.signal })) {
          const e = ev as any;
          const type = String(e?.type ?? "");
          if (!type.startsWith("message.part.updated")) continue;
          try {
            const raw = JSON.stringify(e);
            // msgID/partID вытаскиваем робастно из сериализации (форма полей зависит от версии)
            const id = (raw.match(/"id":"([^"]{8,40})"/) || [])[1]?.slice(0, 24) ?? "unknown";
            // текст прибавляем только инкрементально: JSON может нести сухой полный текст части
            const prev = parts.get(id) ?? "";
            // ищем ПРИБАВКУ: строковые значения длиннее прошлой хвостик грубо — накапливаем значения текстовых полей
            const texts: string[] = [];
            for (const m of raw.matchAll(/"text":"((?:[^"\\]|\\.){40,})"/g)) texts.push(JSON.parse(`"${m[1]}"`).replace(/\\n/g, " "));
            if (!texts.length) continue;
            const joined = texts.join("\n");
            const acc = joined.length >= prev.length && joined.startsWith(prev.slice(0, Math.min(prev.length, 30)))
              ? joined
              : prev + "\n" + joined;
            parts.set(id, acc.length > 120_000 ? acc.slice(-100_000) : acc);
            const hit = detect(acc);
            if (hit) {
              const now = Date.now();
              if (now - lastToast > 60_000) {
                lastToast = now;
                toast(`🤮 LLM деградация (${hit.slice(0, 8)}…) — сделай /redo или /models → deepseek`);
              }
              try { appendFileSync(LOG, `${new Date().toISOString()} ${hit} msgid=${id}\n`); } catch { /* ignore */ }
            }
          } catch { /* одна часть не роняет стрим */ }
        }
      } catch (error) {
        if (!abort.signal.aborted) console.warn("[garble-guard] event stream упал:", error);
      }
    })();

    return async () => {
      abort.abort();
      try { await task; } catch { /* teardown */ }
    };
  },
});

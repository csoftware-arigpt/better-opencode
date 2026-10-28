// memory-rag — плагин OpenCode v2 (Plugin.define API): граф-RAG память проекта.
// ВСЕ операции идут через rust-бинар ~/.local/bin/memrag (fallback: memrag-node).
// Пруф API: community-плагин joshuadavidthomas/opencode-agent-memory v0.3 (Plugin.define,
// ctx.tool.transform + editor.add, ctx.session.hook("context") → event.system, event.subscribe).
import { Plugin } from "@opencode/plugin";
import type { Info as ToolInfo } from "@opencode/plugin/promise/tool";
import { existsSync } from "node:fs";
import { join } from "node:path";

const HOME = process.env.HOME || "/data/data/com.termux/files/home";
const CANDIDATES = [join(HOME, ".local/bin/memrag"), join(HOME, ".local/bin/memrag-node")];

let cachedBin: string | null | undefined;
function resolveBin(): string | null {
  if (cachedBin !== undefined) return cachedBin;
  cachedBin = CANDIDATES.find((p) => existsSync(p)) ?? null;
  return cachedBin;
}

/** Спавн memrag с cwd=проект; stdout строкой, код!=0 → Error с хвостом stderr. */
async function memrag(dir: string, args: string[]): Promise<string> {
  const bin = resolveBin();
  if (!bin) throw new Error("memrag не найден: выполни ~/projects/opencode-memory-rag/install.sh");
  const cmd = bin.endsWith(".mjs") ? ["node", bin, ...args] : [bin, ...args];
  const proc = Bun.spawn(cmd, {
    cwd: dir,
    env: { ...process.env, MEMRAG_DIR: dir },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  const [out, err] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
  const code = await proc.exited;
  if (code !== 0) throw new Error(`memrag ${args[0]} провалился (exit ${code}): ${err.trim().slice(0, 400) || out.trim().slice(0, 200)}`);
  return out;
}

async function memragQuiet(dir: string, args: string[]): Promise<void> {
  try { await memrag(dir, args); } catch { /* фон-индексация не роняет сессию */ }
}

/** query --json → человекочитаемая выдача для агента. */
function formatQueryJson(json: string, k: number): string {
  let data: { query?: string; items?: any[]; graph?: any[] };
  try { data = JSON.parse(json); } catch { return json.trim(); }
  const items = data.items ?? [];
  if (!items.length) return `Память пуста по запросу «${data.query ?? ""}».`;
  const lines = [`Память проекта | запрос: «${data.query ?? ""}»`];
  items.forEach((h, i) => {
    if (h.kind === "note") {
      lines.push(`${i + 1}. 💭 НОТА id:${h.ref} | score ${Number(h.score).toFixed(1)}\n${h.title}\n${h.body}`);
    } else {
      lines.push(`${i + 1}. 📄 ${h.ref} | score ${Number(h.score).toFixed(1)}\n${h.snip ?? ""}`);
    }
  });
  if (data.graph?.length) {
    lines.push("— граф-контекст —");
    data.graph.forEach((g) => lines.push(`  d${g.depth} w${Number(g.weight).toFixed(1)} [${g.kind}] ${g.id}`));
  }
  lines.push(`(k=${k}; подробные ноты — ключи через memory_query, сохранение — memory_save)`);
  return lines.join("\n");
}

/** brain → «мозги» текстом. */
async function brainText(dir: string): Promise<string> {
  const out = await memrag(dir, ["brain"]);
  return out.trim();
}

export default Plugin.define({
  id: "memory-rag",
  async setup(ctx) {
    const dir: string = (ctx.location as any).directory || process.cwd();
    const touched = new Set<string>();
    let lastAutoNote = 0;
    let brainCache = { text: "", at: 0 };

    // === кастомные tools через rust-CLI ===
    await ctx.tool.transform((editor) => {
      const tools: ToolInfo[] = [
        {
          name: "memory_query",
          description:
            "[ПРОТОКОЛ ПАМЯТИ — вызывать ЧАСТО] BM25-поиск по памяти проекта (код+ноты) + граф-контекст. " +
            "Обязателен ДО утверждений о коде/статусе/архитектуре, перед планированием и повторным использованием прошлого опыта. Дёшево — спрашивай смело.",
          input: {
            type: "object",
            properties: {
              query: { type: "string", description: "поисковый запрос (слова-термины)" },
              k: { type: "integer", minimum: 1, maximum: 20, description: "сколько результатов (по умолчанию 6)" },
            },
            required: ["query"],
            additionalProperties: false,
          },
          async execute(input) {
            const args = input as { query: string; k?: number };
            const k = Math.min(20, Math.max(1, args.k ?? 6));
            const json = await memrag(dir, ["query", args.query, "-k", String(k), "--json"]);
            return { content: formatQueryJson(json, k) };
          },
        },
        {
          name: "memory_save",
          description:
            "[ПРОТОКОЛ ПАМЯТИ — вызывать после каждого значимого шага] Сохранить факт/решение/корень бага/шпаргалку в долговременную память проекта. " +
            "Нота сама свяжется с файлами/символами/тегами в графе. Теги помогают будущим query.",
          input: {
            type: "object",
            properties: {
              title: { type: "string", description: "короткий заголовок" },
              body: { type: "string", description: "суть: решение, факт, порядок действий (без «::» в заголовке)" },
              tags: { type: "string", description: "теги через запятую: arch,api,bash" },
              pinned: { type: "boolean", description: "закрепить в мозгах (всегда в system-промпте)" },
            },
            required: ["title", "body"],
            additionalProperties: false,
          },
          async execute(input) {
            const args = input as { title: string; body: string; tags?: string; pinned?: boolean };
            const title = args.title.replaceAll("::", "∶∶");
            const out = await memrag(dir, [
              "note", `${title}::${args.body}`,
              ...(args.tags ? ["--tags", args.tags] : []),
            ]);
            const nid = /id:([0-9a-fA-F]+)/.exec(out)?.[1];
            if (args.pinned && nid) await memrag(dir, ["pin", nid, "1"]);
            return { content: `${out.trim()}${args.pinned && nid ? `\n → pinned(true)` : ""}` };
          },
        },
        {
          name: "memory_index",
          description:
            "Проиндексировать проект в память (свой rust-движок: walk+чанкинг+FTS5-BM25, инкрементально по mtime). " +
            "Запускай в начале работы над незнакомым проектом или после массовых правок.",
          input: { type: "object", properties: {}, additionalProperties: false },
          async execute() {
            const json = await memrag(dir, ["index"]);
            let r: any = null;
            try { r = JSON.parse(json); } catch { /* не крутится — вернём сырое */ }
            if (!r) return { content: json.trim() };
            return {
              content: `индекс: файлов найдено ${r.files} (изменено ${r.filesChanged}), удалено ${r.gone}; чанков всего ${r.total}, нот ${r.notes} — за ${r.durationMs}мс`,
            };
          },
        },
        {
          name: "memory_brain",
          description:
            "Сводка «мозгов»: счётчики памяти, закреплённые ноты, горячие узлы графа (reinforcement), свежие ноты. " +
            "Показывает, ЧТО агент уже помнит — заглядывай при входе в проект или после серии сохранений.",
          input: { type: "object", properties: {}, additionalProperties: false },
          async execute() {
            return { content: await brainText(dir) };
          },
        },
      ];
      for (const t of tools) editor.add(t);
    });

    // === события: авто-индекс на старте сессии + авто-нота на простое ===
    const abort = new AbortController();
    const eventsTask = (async () => {
      try {
        for await (const ev of ctx.event.subscribe({ signal: abort.signal })) {
          const e = ev as any;
          const type = String(e?.type ?? e?.properties?.type ?? "");
          try {
            if (type === "session.created") {
              await memragQuiet(dir, ["index"]);
            } else if (type === "session.idle") {
              if (touched.size === 0) continue;
              const now = Date.now();
              if (now - lastAutoNote < 10 * 60_000) continue;
              lastAutoNote = now;
              const files = [...touched].slice(0, 12).map((f) => f.replace(dir + "/", ""));
              const body =
                `Авто-нота сессии (${new Date().toISOString().slice(0, 16)}).\n` +
                `Изменённые файлы:\n${files.join("\n")}\n` +
                `Содержимое изменений не анализировалось — при работе с ними сделай memory_query или прочитай diff.`;
              await memragQuiet(dir, ["note", `auto: сессия трогала ${files.length} файл(ов)::${body}`, "--tags", "session-auto"]);
              touched.clear();
            }
          } catch { /* отдельное событие не роняет стрим */ }
        }
      } catch (error) {
        if (!abort.signal.aborted) console.warn("[memory-rag] event stream упал:", error);
      }
    })();

    // === перехват правок: какие файлы трогала сессия (для авто-ноты) ===
    await ctx.tool.hook("execute.after", async (n: any) => {
      try {
        const inp = n?.input ?? {};
        const p = inp.filePath ?? inp.file_path ?? inp.path;
        if (typeof p === "string" && p) touched.add(p);
      } catch { /* не роняем инструменты */ }
    });

    // === инжект «мозгов» в system-промпт сессии (замена старого compacting-хука) ===
    await ctx.session.hook("context", async (event: any) => {
      try {
        if (!resolveBin()) return;
        const now = Date.now();
        if (now - brainCache.at > 60_000) {
          brainCache = { text: await brainText(dir), at: now };
        }
        if (!brainCache.text) return;
        const brief = brainCache.text.split("\n").slice(0, 2).join(" | ");
        event.system.splice(event.system.length > 0 ? 1 : 0, 0, {
          type: "text",
          text:
            `## Память проекта (memrag, автоматически)\n${brief}\n${brainCache.text}\n` +
            `Протокол: факты о коде — memory_query; значимые шаги — memory_save.`,
        });
      } catch { /* память не должна ронять сессию */ }
    });

    return async () => {
      abort.abort();
      try { await eventsTask; } catch { /* teardown */ }
    };
  },
});

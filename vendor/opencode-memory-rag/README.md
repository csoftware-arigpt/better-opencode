# opencode-memory-rag

Граф-RAG память проектов для OpenCode на телефоне (Termux).

- **Движок**: **Rust** (`rust/`, rusqlite bundled SQLite 3.46 + FTS5/BM25, CLI `memrag`) — бинарь заменяет node-CLI; `cli.mjs` остаётся node-fallback (`memrag-node`) и движком плагина.
- **Граф**: узлы `note|file|tag|symbol` + типизированные симметричные рёбра (mentions/tagged/depends_on/…), BFS-расширение от сидов BM25, reinforcement весов («мозги» укрепляют то, что использует агент).
- **Автопамять**: плагин OpenCode индексирует проект при создании сессии, пишет авто-ноту «что трогала сессия» при простое, инжектит состояние памяти при компакции контекста.

## Установка
```sh
~/projects/opencode-memory-rag/install.sh
```
Плагин подхватится при следующем запуске OpenCode (tools: `memory_query`, `memory_save`, `memory_index`, `memory_brain`). После правки `core.mjs` в проекте — перезапусти `install.sh` и OpenCode.

## CLI
```sh
memrag index [--force]      # индексировать cwd (инкрементально)
memrag query "..." [-k 8] [--depth 2]  # поиск + граф-контекст
memrag note "Title::текст" [--tags a,b]  # сохранить ноту (+связи графа)
memrag notes | pin | forget | read <id>
memrag link <src> <dst> [type]
memrag graph | brain | stats
```

## Где данные
`~/.local/share/opencode-memory-rag/<проект>.db` (per-проект). `MEMRAG_HOME`, `MEMRAG_DIR` — переопределение.

## Стек
| Слой | Чем сделано |
|---|---|
| Индексация | обход проекта, чанки ≤800 символов, mtime-инкремент |
| Retrieval | FTS5 `bm25()` + snippet, ноты с приоритетом (×1.6 + pinned) |
| Граф | рекурсивный CTE BFS (глубина ≤2), симметричные рёбра |
| Мозги | веса узлов (доступ повышает, min(w+δ,20)), brain-сводка |
| Автоматика | plugin: session.created → index; idle → auto-note; compacting → инжект |

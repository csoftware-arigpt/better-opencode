# opencode-memory-rag

Graph-RAG project memory for OpenCode: per-project SQLite (FTS5/BM25) plus a typed knowledge graph, with reinforcement weighting that favors what the agent actually uses.

- **Engine**: Rust (`rust/`, rusqlite with bundled SQLite 3.46 + FTS5/BM25, CLI `memrag`). `cli.mjs` remains the node fallback (`memrag-node`).
- **Graph**: nodes `note | file | tag | symbol` + typed symmetric edges (`mentions`/`tagged`/`depends_on`/...), BFS expansion from BM25 seeds, reinforcement weights ("brains" strengthen nodes the agent touches).
- **Auto memory**: the OpenCode plugin indexes the project at session creation, writes an idle auto-note ("what the session touched"), and injects memory state during context compaction.

## Install

```sh
cargo build --release --manifest-path rust/Cargo.toml
ln -s "$PWD/rust/target/release/memrag" ~/.local/bin/memrag
bash install.sh   # wires the OpenCode plugin (tools: memory_query, memory_save, memory_index, memory_brain)
```

Linking needs a C compiler for the bundled SQLite; on NixOS run the build inside `nix-shell -p gcc cargo`. The plugin picks up on the next OpenCode start; after editing `core.mjs`, rerun `install.sh` and restart OpenCode.

## CLI

```sh
memrag index [--force]                    # index cwd (incremental, mtime-based)
memrag query "..." [-k 8] [--depth 2]     # BM25 search + graph context
memrag note "Title::body" [--tags a,b]    # save a note (+graph links)
memrag notes | pin | forget | read <id>
memrag link <src> <dst> [type]
memrag graph | brain | stats
```

## Where the data lives

`~/.local/share/opencode-memory-rag/<project>.db` — one database per project. `MEMRAG_HOME` / `MEMRAG_DIR` override the location.

## Stack

| Layer | How it works |
|---|---|
| Indexing | walks the project, chunks <= 800 chars, incremental by mtime |
| Retrieval | FTS5 `bm25()` + snippet, notes ranked higher (x1.6 + pinned) |
| Graph | recursive-CTE BFS (depth <= 2), symmetric edges |
| Brains | node weights (access raises, `min(w+delta, 20)`), `brain` summary |
| Automation | plugin: session.created -> index; idle -> auto-note; compacting -> inject |

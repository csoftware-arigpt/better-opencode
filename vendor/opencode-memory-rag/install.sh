#!/bin/sh
# install.sh — поставить memrag в конфиг OpenCode (плагин + команды + скилл + CLI-bin)
set -eu
H="${1:-$HOME}"
CFG="$H/.config/opencode"
PROJ="$H/projects/opencode-memory-rag"

mkdir -p "$CFG/plugins" "$CFG/commands" "$CFG/skills/memrag" "$H/.local/bin"

# плагин: источник истины остаётся в проекте (плагин импортирует core.mjs проекта)
cp "$PROJ/plugin/memory-rag.ts" "$CFG/plugins/memory-rag.ts"
cp "$PROJ/commands/recall.md" "$PROJ/commands/note.md" "$CFG/commands/"
cp "$PROJ/skills/memrag/SKILL.md" "$CFG/skills/memrag/SKILL.md"
cp "$PROJ/core.mjs" "$CFG/skills/memrag/core.mjs"   # копия для прозрачности (плагин берёт из проекта)

# CLI-бин: rust-версия, node-CLI остаётся fallback-ом под именем memrag-node
BIN="$PROJ/rust/target/release/memrag"
if [ -x "$BIN" ]; then
  ln -sf "$BIN" "$H/.local/bin/memrag"
  ln -sf "$PROJ/cli.mjs" "$H/.local/bin/memrag-node"
else
  echo "warn: rust-бинарь не собран (cd $PROJ/rust && cargo build --release) — ставлю node-fallback"; 
  ln -sf "$PROJ/cli.mjs" "$H/.local/bin/memrag"
fi
chmod +x "$PROJ/cli.mjs"

echo "installed:"
ls -l "$H/.local/bin/memrag" "$CFG/plugins/memory-rag.ts" "$CFG/commands/recall.md" "$CFG/commands/note.md"
echo "скилл: $CFG/skills/memrag/SKILL.md"
echo "память проекта будет в ~/.local/share/opencode-memory-rag/<проект>.db"

#!/usr/bin/env node
// memrag core — RAG-движок памяти проекта для OpenCode.
// Хранение: node:sqlite (built-in) + FTS5/BM25. Ноль нативных зависимостей.
// Слой эмбеддингов зарезервирован: schema допускает расширение, а сейчас
// retrieval = BM25 по чанкам кода + curated-заметкам (ноты с приоритетом).

import { DatabaseSync } from 'node:sqlite';
import { createHash, randomUUID } from 'node:crypto';
import { readdir, stat, readFile, mkdir } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import os from 'node:os';

const DATA_HOME = process.env.MEMRAG_HOME || path.join(homedir(), '.local', 'share', 'opencode-memory-rag');

// ---------- проект-ключ и путь к базе ----------
export function projectKey(dir) {
  const abs = path.resolve(dir);
  const hash = createHash('sha1').update(abs).digest('hex').slice(0, 12);
  const base = path.basename(abs).replace(/[^A-Za-z0-9_-]/g, '_') || 'proj';
  return { abs, id: `${base}-${hash}` };
}

function dbPathFor(dir) {
  const { id } = projectKey(dir);
  return path.join(DATA_HOME, `${id}.db`);
}

// ---------- схема ----------
const SCHEMA = `
CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(
  kind UNINDEXED, ref UNINDEXED, idx UNINDEXED, title, body,
  tokenize = 'unicode61 remove_diacritics 2'
);
CREATE TABLE IF NOT EXISTS files (
  path TEXT PRIMARY KEY, mtime INTEGER, size INTEGER, nchunks INTEGER
);
CREATE TABLE IF NOT EXISTS chunk_ids (
  ref TEXT, rid INTEGER, PRIMARY KEY (ref, rid)
);
CREATE TABLE IF NOT EXISTS notes_meta (
  nid TEXT PRIMARY KEY, title TEXT, created INTEGER, pinned INTEGER DEFAULT 0,
  tags TEXT DEFAULT '', source TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS nodes (
  id TEXT PRIMARY KEY, kind TEXT, label TEXT,
  weight REAL DEFAULT 1.0, created INTEGER
);
CREATE TABLE IF NOT EXISTS edges (
  src TEXT, dst TEXT, type TEXT, weight REAL DEFAULT 1.0, created INTEGER,
  PRIMARY KEY (src, dst, type)
);
CREATE INDEX IF NOT EXISTS edges_src_idx ON edges(src);
CREATE INDEX IF NOT EXISTS edges_dst_idx ON edges(dst);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
`;

export function openDb(dir) {
  mkdir(DATA_HOME, { recursive: true });
  const db = new DatabaseSync(dbPathFor(dir));
  db.exec(`PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;`);
  db.exec(SCHEMA);
  return { db, abs: projectKey(dir).abs };
}

function absPath(dir) {
  return path.resolve(dir);
}

// ---------- обход проекта ----------
const SKIP_DIRS = new Set([
  'node_modules', '.git', '.omo', '.npm', '.cache', '.local', 'dist', 'build', 'out',
  'coverage', '__pycache__', '.venv', 'venv', '.cargo', '.bun', 'vendor', 'target',
  '.next', '.turbo', '.gradle', '.idea', '.vscode', '.termux', '.snapshot', '.recluse',
]);
const SKIP_FILES = new Set(['.DS_Store', 'CHANGELOG.tmp']);
const MAX_FILE_SIZE = 400_000; // 400 KB — всё крупнее это данные, а не код
const MAX_CHUNK_CHARS = 800;

const TEXT_EXTS = new Set([
  'js', 'mjs', 'cjs', 'ts', 'tsx', 'jsx', 'json', 'jsonc', 'md', 'mdx', 'txt', 'toml',
  'yaml', 'yml', 'ini', 'conf', 'cfg', 'sh', 'bash', 'fish', 'zsh', 'py', 'rb', 'pl',
  'go', 'rs', 'c', 'h', 'cc', 'cpp', 'hpp', 'cxx', 'hxx', 'java', 'kt', 'kts', 'swift',
  'php', 'lua', 'vim', 'sql', 'html', 'htm', 'css', 'scss', 'less', 'vue', 'svelte',
  'astro', 'graphql', 'gql', 'env', 'properties', 'xml', 'svg', 'proto', 'nix', 'hs',
  'ml', 'ex', 'exs', 'erl', 'clj', 'lisp', 'el', 'scm', 'r', 'jl', 'dart', 'zig', 'v',
  'pas', 'asm', 's', 'cmake', 'mk', 'service', 'socket', 'timer', 'desktop',
]);
const TEXT_NAMES = new Set([
  'Makefile', 'Dockerfile', 'docker-compose.yml', 'CMakeLists.txt', 'README', 'LICENSE',
  'GITIGNORE', '.gitignore', '.env.example', 'tsconfig.json', 'package.json', 'AGENTS.md',
  'CLAUDE.md', 'justfile', '.editorconfig', '.npmrc', 'Procfile', 'Vagrantfile',
]);

function isTextFile(name, ext) {
  const base = path.basename(name);
  if (TEXT_NAMES.has(base) || TEXT_NAMES.has(base.toUpperCase())) return true;
  if (base.startsWith('.env')) return true;
  return TEXT_EXTS.has(ext);
}

/** Рекурсивный обход с фильтрами. Возвращает [{path, mtimeMs, size}] относительно root. */
async function walk(root) {
  const out = [];
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    let entries;
    try { entries = await readdir(dir, { withFileTypes: true }); } catch { continue; }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) {
        if (SKIP_DIRS.has(e.name) || e.name.startsWith('.git')) continue;
        stack.push(p);
      } else if (e.isFile()) {
        const ext = path.extname(e.name).slice(1).toLowerCase();
        if (SKIP_FILES.has(e.name)) continue;
        if (!isTextFile(e.name, ext)) continue;
        try {
          const s = await stat(p);
          if (s.size === 0 || s.size > MAX_FILE_SIZE) continue;
          out.push({ file: path.relative(root, p).split(path.sep).join('/'), absp: p, mtimeMs: s.mtimeMs, size: s.size });
        } catch { /* гонка изменений — пропускаем */ }
      }
    }
  }
  return out;
}

/** Чанкинг по строкам: ≤ MAX_CHUNK_CHARS символов, разрыв на строке. */
export function chunkText(text, file) {
  const lines = text.split(/\r?\n/).map((l) => l.replace(/\t/g, '  '));
  const chunks = [];
  let buf = [];
  let len = 0;
  let start = 1;
  const flush = () => {
    if (!buf.length) return;
    const body = `file: ${file} | lines ${start}-${start + buf.length - 1}\n${buf.join('\n')}`;
    chunks.push({ start, end: start + buf.length - 1, body });
  };
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i];
    // строка длиннее лимита — режем жёстко
    while (line.length > MAX_CHUNK_CHARS * 0.9) {
      flush();
      const piece = line.slice(0, Math.floor(MAX_CHUNK_CHARS * 0.9));
      chunks.push({ start: i + 1, end: i + 1, body: `file: ${file} | line ${i + 1}\n${piece}` });
      line = line.slice(Math.floor(MAX_CHUNK_CHARS * 0.9));
    }
    buf.push(line);
    len += line.length + 1;
    if (len >= MAX_CHUNK_CHARS) { flush(); buf = []; len = 0; start = i + 2; }
  }
  flush();
  return chunks;
}

// ---------- индексация ----------
/** Инкрементальная индексация проекта. files: mtime+size — ключ новизны. */
export async function indexProject(dir, { force = false, log = () => {} } = {}) {
  const root = absPath(dir);
  const { db } = openDb(dir);
  const t0 = Date.now();
  db.prepare(`INSERT OR REPLACE INTO meta(key,value) VALUES('project_path',?)`).run(root);

  const found = await walk(root);
  const delByRids = db.prepare(`DELETE FROM docs WHERE rowid IN (SELECT rid FROM chunk_ids WHERE ref=?)`);
  const delMap = db.prepare(`DELETE FROM chunk_ids WHERE ref=?`);
  const countMap = db.prepare(`SELECT count(*) AS n FROM chunk_ids WHERE ref=?`);
  const delAllRows = db.prepare(`DELETE FROM docs WHERE kind='chunk' AND ref=?`); // легаси-строки без карты (редкий full-scan)
  const insChunk = db.prepare(`INSERT INTO docs(kind, ref, idx, title, body) VALUES('chunk',?,?,?,?)`);
  const insRid = db.prepare(`INSERT INTO chunk_ids(ref,rid) VALUES(?,?)`);
  const upsertFile = db.prepare(`INSERT INTO files(path,mtime,size,nchunks) VALUES(?,?,?,?)
    ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime, size=excluded.size, nchunks=excluded.nchunks`);
  if (force) {
    // FTS5 'delete-all' — разовая полная очистка за O(1) вместо full-scan на каждый файл
    db.prepare(`INSERT INTO docs(docs,rank) VALUES('delete-all',1)`).run();
    db.exec(`DELETE FROM chunk_ids; DELETE FROM files;`);
  }

  let filesChanged = 0, chunksAdded = 0, chunksRemoved = 0;
  for (const { file, absp, mtimeMs, size } of found) {
    const row = db.prepare(`SELECT mtime,size FROM files WHERE path=?`).get(file);
    if (row && !force && row.mtime === Math.round(mtimeMs) && row.size === size) continue;
    let text = '';
    try { text = await readFile(absp, 'utf8'); } catch { continue; }
    // бинарный мусор на видимости utf8
    if (/\u0000/.test(text.slice(0, 2048))) continue;

    const chunks = chunkText(text, file);
    const old = db.prepare(`SELECT nchunks FROM files WHERE path=?`).get(file);
    if (old?.nchunks) chunksRemoved += old.nchunks;
    db.exec(`BEGIN`);
    try {
      const mapped = countMap.get(file)?.n ?? 0;
      if (mapped > 0) { delByRids.run(file); delMap.run(file); }
      else if (old?.nchunks > 0) { delAllRows.run(file); }
      chunks.forEach((c, i) => {
        const info = insChunk.run(file, String(i), `${file}:${c.start}-${c.end}`, c.body);
        insRid.run(file, info.lastInsertRowid);
      });
      upsertFile.run(file, Math.round(mtimeMs), size, chunks.length);
      db.exec(`COMMIT`);
      filesChanged++; chunksAdded += chunks.length;
    } catch (e) { db.exec(`ROLLBACK`); log(`slide fail ${file}: ${e.message}`); }
  }

  // чистка файлов, исчезнувших с диска
  const known = db.prepare(`SELECT path FROM files`).all().map((r) => r.path);
  const seen = new Set(found.map((f) => f.file));
  let gone = 0;
  for (const p of known) {
    if (!seen.has(p)) {
      const mapped = countMap.get(p)?.n ?? 0;
      if (mapped > 0) delByRids.run(p); else delAllRows.run(p);
      delMap.run(p);
      db.prepare(`DELETE FROM files WHERE path=?`).run(p);
      gone++;
    }
  }

  db.prepare(`INSERT OR REPLACE INTO meta(key,value) VALUES('last_index',?)`).run(String(Date.now()));
  const total = db.prepare(`SELECT count(*) AS n FROM docs WHERE kind='chunk'`).get().n;
  const notesN = db.prepare(`SELECT count(*) AS n FROM docs WHERE kind='note'`).get().n;
  const res = { project: root, db: dbPathFor(dir), files: found.length, filesChanged, chunksAdded, chunksRemoved, chunksDeleted_gone: gone, total, notes: notesN, durationMs: Date.now() - t0 };
  return res;
}

// ---------- граф памяти ----------
// Узлы: note:<nid> | file:<relpath> | tag:<tag> | sym:<Identifier>
// Рёбра: двусторонние — addEdge пишет и прямую пару (src,dst,type), и обратную (dst,src,type~)
const SYM_STOP = new Set([
  'true', 'false', 'null', 'undefined', 'const', 'function', 'return', 'import', 'export',
  'class', 'default', 'error', 'message', 'string', 'number', 'string', 'create', 'update',
  'delete', 'select', 'insert', 'async', 'await', 'type', 'write', 'read', 'open', 'file',
  'path', 'node', 'title', 'body', 'tags', 'index', 'project', 'memory', 'result', 'results',
  'value', 'params', 'options', 'context', 'args', 'data', 'state', 'status', 'version',
]);

function ensureNode(db, id, kind, label) {
  db.prepare(`INSERT INTO nodes(id,kind,label,weight,created) VALUES(?,?,?,1.0,?)
              ON CONFLICT(id) DO NOTHING`).run(id, kind, label, Date.now());
}

/** Добавить типизированное ребро; обратная сторона помечается суффиксом ~. */
export function addEdge(db, src, dst, type, weight = 1.0) {
  const created = Date.now();
  db.prepare(`INSERT INTO edges(src,dst,type,weight,created) VALUES(?,?,?,?,?)
              ON CONFLICT(src,dst,type) DO UPDATE SET weight = weight + 0.25`).run(src, dst, type, weight, created);
  db.prepare(`INSERT INTO edges(src,dst,type,weight,created) VALUES(?,?,?,?,?)
              ON CONFLICT(src,dst,type) DO NOTHING`).run(dst, src, `${type}~`, weight, created);
}

const PATH_RE = /\b[\w\-./@]+\.(?:js|ts|tsx|jsx|mjs|cjs|py|go|rs|md|json|toml|ya?ml|sh|fish|c|h|cpp|hpp|lua|sql|html|css|vue|svelte|astro|rb|php|kt|swift|dart|java|lock)\b/g;
const SYM_RE = /\b[a-z]+(?:[A-Z][a-z0-9]+){1,}\b|\b[a-z]+(?:_[a-z0-9]+){1,}\b|\b[A-Z]{2,}[A-Z0-9_]{2,}\b/g;

function extractMentions(text, rootAbs) {
  const paths = new Set(); const syms = new Map();
  for (const m of (text.match(PATH_RE) || []).slice(0, 10)) {
    const clean = m.replace(/^[./]+/, '');
    paths.add(clean);
  }
  for (const m of (text.match(SYM_RE) || [])) {
    const low = m.toLowerCase();
    if (SYM_STOP.has(low) || low.length < 4) continue;
    syms.set(m, (syms.get(m) || 0) + 1);
  }
  const topSyms = [...syms.entries()].sort((a, b) => b[1] - a[1]).slice(0, 6).map(([s]) => s);
  return { paths: [...paths].slice(0, 6), syms: topSyms };
}

/** Связать ноту с графом: file/sym/tag узлы + рёбра mentions/tagged/related. */
export function linkNoteToGraph(db, nid, { title, body, tags }) {
  ensureNode(db, `note:${nid}`, 'note', title);
  const text = `${title}\n${body}`;
  const { paths, syms } = extractMentions(text);
  for (const p of paths) {
    ensureNode(db, `file:${p}`, 'file', p);
    addEdge(db, `note:${nid}`, `file:${p}`, 'mentions');
  }
  for (const s of syms) {
    ensureNode(db, `sym:${s}`, 'symbol', s);
    addEdge(db, `note:${nid}`, `sym:${s}`, 'mentions');
  }
  for (const t of (tags || [])) {
    const tag = t.trim(); if (!tag) continue;
    const id = `tag:${tag.toLowerCase()}`;
    ensureNode(db, id, 'tag', tag);
    addEdge(db, `note:${nid}`, id, 'tagged');
  }
  return { paths, syms };
}

/** Расширение: BFS от сидов по графу (глубина 2), рёбра симметричны. */
export function graphExpand(db, seedIds, { depth = 2, limit = 8, excludeSeeds = true } = {}) {
  if (!seedIds.length) return [];
  const placeholders = seedIds.map(() => '?').join(',');
  const rows = db.prepare(`
    WITH RECURSIVE walk(id, d) AS (
      SELECT id, 0 FROM nodes WHERE id IN (${placeholders})
      UNION
      SELECT e.dst, walk.d + 1 FROM walk JOIN edges e ON e.src = walk.id WHERE walk.d < ?
    )
    SELECT w.id, MIN(w.d) AS d, n.kind, n.label, n.weight
    FROM walk w JOIN nodes n ON n.id = w.id
    WHERE w.d > 0
    GROUP BY w.id ORDER BY n.weight DESC, d ASC LIMIT ?
  `).all(...seedIds, depth, limit + 16);
  const seedSet = new Set(seedIds);
  return rows
    .filter((r) => !(excludeSeeds && seedSet.has(r.id)))
    .slice(0, limit)
    .map((r) => ({ id: r.id, kind: r.kind, label: r.label, weight: r.weight, depth: r.d, via: r.via ?? null }));
}

/** «Мозги»: сводка состояния памяти — закреплённые, свежие, самые «нагруженные» узлы графа. */
export async function brainSummary(dir) {
  const { db } = openDb(dir);
  const pinned = db.prepare(`SELECT nid,title,tags FROM notes_meta WHERE pinned=1 ORDER BY created DESC LIMIT 10`).all();
  const recent = db.prepare(`SELECT nid,title,created FROM notes_meta ORDER BY created DESC LIMIT 5`).all();
  const hot = db.prepare(`SELECT id,kind,label,weight FROM nodes ORDER BY weight DESC, created DESC LIMIT 12`).all();
  const edgesN = db.prepare(`SELECT count(*) AS n FROM edges`).get().n;
  const nodesN = db.prepare(`SELECT count(*) AS n FROM nodes`).get().n;
  const st = await stats(dir);
  return { ...st, graph: { nodes: nodesN, edges: edgesN, pinned, recent, hot } };
}

// reinforcement: доступ к узлу повышает вес («мозги» укрепляют важное)
function bumpWeights(db, ids, amount = 0.15) {
  if (!ids.length) return;
  const ph = ids.map(() => '?').join(',');
  db.prepare(`UPDATE nodes SET weight = MIN(weight + ?, 20.0) WHERE id IN (${ph})`).run(amount, ...ids);
}
// ---------- BM25 запрос ----------
function ftsEscape(term) {
  // каждая лексема — quoted phrase в FTS5 query syntax
  return `"${term.replace(/"/g, '""')}"`;
}

async function searchChunks(dir, q, k) {
  const { db } = openDb(dir);
  const terms = q.split(/[\s,;:!?().]+/).filter((t) => t.length >= 2).slice(0, 12);
  if (!terms.length) return [];
  const AND = terms.map(ftsEscape).join(' AND ');
  const OR = terms.map(ftsEscape).join(' OR ');
  const run = (match) => {
    try {
      return db.prepare(
        `SELECT rowid, idx, title, bm25(docs) AS rank,
                snippet(docs, 4, '[', ']', '…', 10) AS snip,
                ref
         FROM docs WHERE docs MATCH ? AND kind='chunk'
         ORDER BY bm25(docs) LIMIT ?`
      ).all(match, k);
    } catch { return []; }
  };
  let rows = run(AND);
  if (rows.length === 0) rows = run(OR);
  return rows.map((r) => ({
    kind: 'chunk',
    ref: r.ref,
    chunkIdx: Number(r.idx),
    title: r.title,
    snip: r.snip,
    rank: r.rank,
  }));
}

async function searchNotes(dir, q, k) {
  const { db } = openDb(dir);
  const terms = q.split(/[\s,;:!?().]+/).filter((t) => t.length >= 2).slice(0, 12);
  if (!terms.length) return [];
  const AND = terms.map(ftsEscape).join(' AND ');
  const OR = terms.map(ftsEscape).join(' OR ');
  const run = (match) => {
    try {
      return db.prepare(
        `SELECT rowid, ref, idx, title, bm25(docs) AS rank,
                body, snippet(docs, 4, '[', ']', '…', 10) AS snip
         FROM docs WHERE docs MATCH ? AND kind='note'
         ORDER BY bm25(docs) LIMIT ?`
      ).all(match, k);
    } catch { return []; }
  };
  let rows = run(AND);
  if (rows.length === 0) rows = run(OR);
  const meta = await listNotes(dir);
  const byNid = new Map(meta.map((m) => [m.nid, m]));
  return rows.map((r) => ({
    kind: 'note',
    ref: r.ref,
    title: r.title,
    snip: r.snip,
    body: r.body,
    pinned: byNid.get(r.ref)?.pinned ?? 0,
    tags: byNid.get(r.ref)?.tags ?? '',
    rank: r.rank,
  }));
}

/** Основной retrieval: BM25 сиды → расширение по граф → reinforcement весов. */
export async function query(dir, q, { k = 6, depth = 2 } = {}) {
  const root = absPath(dir);
  const notes = await searchNotes(root, q, k);
  const chunks = await searchChunks(root, q, k);
  const items = [
    ...notes.map((n) => ({ ...n, score: Math.abs(n.rank) * 1.6 + (n.pinned ? 5 : 0) })),
    ...chunks.map((c) => ({ ...c, score: Math.abs(c.rank) })),
  ];
  items.sort((a, b) => b.score - a.score);
  const top = items.slice(0, k);

  // сиды графа: ноты → note:<nid>, чанки → file:<ref>, теги нот → tag:<t>
  const { db, abs } = openDb(dir);
  const seeds = [];
  for (const it of top) {
    if (it.kind === 'note') seeds.push(`note:${it.ref}`);
    if (it.kind === 'chunk') { seeds.push(`file:${it.ref}`); for (const t of (it.tags || '').split(',')) if (t) seeds.push(`tag:${t.toLowerCase()}`); }
  }
  const graph = graphExpand(db, seeds, { depth, limit: 8 });
  bumpWeights(db, seeds);                       // «мозги»: сиды
  bumpWeights(db, graph.map((g) => g.id), 0.05); // и чуть-чуть их окружению
  return { project: root, query: q, items: top, graph };
}

// ---------- ноты ----------
export async function saveNote(dir, { title, body, tags = [], pinned = false, source = 'agent' }) {
  const { db } = openDb(dir);
  const nid = randomUUID().slice(0, 8);
  db.prepare(`INSERT INTO notes_meta(nid, title, created, pinned, tags, source)
              VALUES(?,?,?,?,?,?)`).run(nid, title, Date.now(), pinned ? 1 : 0, tags.join(','), source);
  db.prepare(`INSERT INTO docs(kind, ref, idx, title, body) VALUES('note',?,?,?,?)`).run(nid, '0', title, body);
  const links = linkNoteToGraph(db, nid, { title, body, tags });
  return { nid, title, links };
}

export async function listNotes(dir) {
  const { db } = openDb(dir);
  return db.prepare(`SELECT nid, title, created, pinned, tags, source FROM notes_meta ORDER BY pinned DESC, created DESC LIMIT 200`).all();
}

export async function getNote(dir, nid) {
  const { db } = openDb(dir);
  const m = db.prepare(`SELECT nid,title,created,pinned,tags,source FROM notes_meta WHERE nid=?`).get(nid);
  if (!m) return null;
  const d = db.prepare(`SELECT body FROM docs WHERE kind='note' AND ref=?`).get(nid);
  return { ...m, body: d?.body ?? '' };
}

export async function setPin(dir, nid, pinned) {
  const { db } = openDb(dir);
  db.prepare(`UPDATE notes_meta SET pinned=? WHERE nid=?`).run(pinned ? 1 : 0, nid);
}

export async function forgetNote(dir, nid) {
  const { db } = openDb(dir);
  db.prepare(`DELETE FROM notes_meta WHERE nid=?`).run(nid);
  db.prepare(`DELETE FROM docs WHERE kind='note' AND ref=?`).run(nid);
}

export async function stats(dir) {
  const { db } = openDb(dir);
  const filesN = db.prepare(`SELECT count(*) AS n FROM files`).get().n;
  const chunksN = db.prepare(`SELECT count(*) AS n FROM docs WHERE kind='chunk'`).get().n;
  const notesN = db.prepare(`SELECT count(*) AS n FROM docs WHERE kind='note'`).get().n;
  let project = '', last = '';
  try {
    project = db.prepare(`SELECT value FROM meta WHERE key='project_path'`).get()?.value ?? '';
    last = db.prepare(`SELECT value FROM meta WHERE key='last_index'`).get()?.value ?? '';
  } catch { /* пустая база */ }
  return { project, db: dbPathFor(dir), files: filesN, chunks: chunksN, notes: notesN, lastIndexMs: last ? Number(last) : 0 };
}

// ---------- вывод для агента ----------
export function formatHit(h, i) {
  if (h.kind === 'note') {
    return `«${i}» НОТА (id:${h.ref}${h.pinned ? ' 📌' : ''}${h.tags ? ' #' + h.tags : ''}) ${h.title}\n${h.body}\n`;
  }
  return `«${i}» CHUNK ${h.ref} (${h.chunkIdx})\n${h.snip}\n`;
}

export function formatResults(r) {
  if (!r.items.length) return `Пусто: ничего не найдено в памяти проекта «${r.project}» по запросу «${r.query}».`;
  return [
    `Память проекта ${r.project} | запрос: «${r.query}»`,
    ...r.items.map((h, i) => formatHit(h, i + 1)),
  ].join('\n');
}

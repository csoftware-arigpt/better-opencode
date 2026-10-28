#!/usr/bin/env node
// memrag — CLI для RAG-графовой памяти проектов (движок: core.mjs).
// Синтаксис: memrag <cmd> [args]   (работает по cwd = текущий проект)
import { resolve } from 'node:path';
import process from 'node:process';

const CORE = `${process.env.HOME}/projects/opencode-memory-rag/core.mjs`;
const core = await import(CORE);

const cwd = process.env.MEMRAG_DIR ? resolve(process.env.MEMRAG_DIR) : process.cwd();
const args = process.argv.slice(2);
const cmd = args[0] || 'help';

function flags(list) {
  const f = { k: 6, depth: 2, force: false, json: false, pinned: false };
  for (let i = 0; i < list.length; i++) {
    const a = list[i];
    if (a === '-k' || a === '--k') f.k = Number(list[++i]) || 6;
    if (a === '--depth') f.depth = Number(list[++i]) || 2;
    if (a === '--force') f.force = true;
    if (a === '--json') f.json = true;
    if (a === '--pinned') f.pinned = true;
    if (a === '--tags') f.tags = (list[++i] || '').split(',').filter(Boolean);
  }
  return f;
}

async function main() {
  const f = flags(args.slice(1));
  const rest = args.slice(1).filter((a) => !a.startsWith('-') && a !== String(f.k) && a !== String(f.depth));
  switch (cmd) {
    case 'index': {
      const r = await core.indexProject(cwd, { force: f.force });
      console.log(JSON.stringify(r, null, 2));
      break;
    }
    case 'query': {
      const q = rest[0];
      if (!q) { console.error('usage: memrag query "запрос" [-k N] [--depth N]'); process.exitCode = 1; break; }
      const r = await core.query(cwd, q, { k: f.k, depth: f.depth });
      if (f.json) { console.log(JSON.stringify(r)); break; }
      console.log(core.formatResults(r));
      if (r.graph.length) {
        console.log(`\n— граф-контекст (соседи сидов, depth ${f.depth}) —`);
        for (const g of r.graph) console.log(` d${g.depth} w${g.weight.toFixed(1)} ${g.kind.padEnd(6)} ${g.id}`);
      }
      break;
    }
    case 'note': {
      const text = rest.join(' ') || '';
      const [title, ...rest2] = text.split('::').map((s) => s.trim());
      const body = rest2.length ? rest2.join('::') : title;
      const t = rest2.length ? title : (body.split(/[.\n]/)[0] || 'note').slice(0, 80);
      const r = await core.saveNote(cwd, { title: t, body, tags: f.tags, pinned: false, source: 'cli' });
      console.log(`нота сохранена id:${r.nid} | связи: ${r.links.paths.length} файлов, ${r.links.syms.length} символов`);
      break;
    }
    case 'notes': {
      const notes = await core.listNotes(cwd);
      for (const n of notes) console.log(`${n.pinned ? '📌' : '  '} id:${n.nid} [${n.tags}] ${n.title}`);
      if (!notes.length) console.log('нот нет');
      break;
    }
    case 'pin': {
      const nid = rest[0]; const val = rest[1] !== '0';
      await core.setPin(cwd, nid, val);
      console.log(`id:${nid} pinned=${val}`);
      break;
    }
    case 'forget': {
      await core.forgetNote(cwd, rest[0]);
      console.log(`нота id:${rest[0]} удалена`);
      break;
    }
    case 'read': {
      const n = await core.getNote(cwd, rest[0]);
      console.log(n ? JSON.stringify(n, null, 2) : 'нет такой ноты');
      break;
    }
    case 'link': {
      const [s, d, t = 'related_to'] = rest;
      if (!s || !d) { console.error('usage: memrag link <src-node-id> <dst-node-id> [type]'); process.exitCode = 1; break; }
      const { openDb } = await import(CORE);
      const { db } = openDb(cwd);
      core.addEdge(db, s, d, t);
      console.log(`edge добавлен: ${s} -[${t}]-> ${d}`);
      break;
    }
    case 'graph': {
      const { openDb } = await import(CORE);
      const { db } = openDb(cwd);
      const nodes = db.prepare(`SELECT id,kind,label,weight FROM nodes ORDER BY weight DESC LIMIT 40`).all();
      const edges = db.prepare(`SELECT src,dst,type,weight FROM edges WHERE type NOT LIKE '%~' ORDER BY weight DESC LIMIT 40`).all();
      for (const n of nodes) console.log(`[${n.kind}] w${n.weight.toFixed(1)} ${n.id}`);
      console.log('— edges —');
      for (const e of edges) console.log(`${e.src} -[${e.type}]-> ${e.dst} (w${e.weight})`);
      break;
    }
    case 'brain': {
      const b = await core.brainSummary(cwd);
      if (f.json) { console.log(JSON.stringify(b)); break; }
      console.log(`ПАМЯТЬ: ${b.project}`);
      console.log(` файлов:${b.files} чанков:${b.chunks} нот:${b.notes} | граф: узлов ${b.graph.nodes}, рёбер ${b.graph.edges}`);
      if (b.graph.pinned.length) {
        console.log('\n📌 закреплённые:');
        for (const n of b.graph.pinned) console.log(`  id:${n.nid} [${n.tags}] ${n.title}`);
      }
      if (b.graph.hot.length) {
        console.log('\n🔥 горячие узлы графа:');
        for (const h of b.graph.hot.slice(0, 8)) console.log(`  w${h.weight.toFixed(1)} [${h.kind}] ${h.id}`);
      }
      if (b.graph.recent.length) {
        console.log('\nсвежие ноты:');
        for (const n of b.graph.recent) console.log(`  id:${n.nid} ${n.title}`);
      }
      break;
    }
    case 'stats': {
      console.log(JSON.stringify(await core.stats(cwd), null, 2));
      break;
    }
    default:
      console.log(`memrag — RAG-графовая память проекта (FTS5/BM25 + граф нод-рёбер)
команды:
  index [--force]              проиндексировать cwd (инкрементально)
  query "..." [-k N] [--depth] поиск по памяти + граф-контекст
  note "Заголовок::текст" [--tags a,b]   сохранить ноту и связать с графом
  notes | read <id> | pin <id> 1|0 | forget <id>
  link <src> <dst> [type]      вручную добавить ребро графа
  graph | brain | stats        обзор графа, сводка «мозгов», статистика
env: MEMRAG_DIR, MEMRAG_HOME`);
  }
}

main().catch((e) => { console.error('memrag error:', e.message); process.exitCode = 1; });

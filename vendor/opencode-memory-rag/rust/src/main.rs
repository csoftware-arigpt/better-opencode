// memrag — граф-RAG память проектов (Rust). CLI: index|query|note|notes|read|pin|forget|link|graph|brain|stats.
use anyhow::Result;
use rusqlite::Connection;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

// ---------- путь к базе per-проект ----------
fn data_home() -> PathBuf {
    match std::env::var("MEMRAG_HOME") {
        Ok(h) if !h.is_empty() => PathBuf::from(h),
        _ => dirs_home().join(".local/share/opencode-memory-rag"),
    }
}
fn dirs_home() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/data/data/com.termux/files/home"))
}
fn project_dir() -> PathBuf {
    match std::env::var("MEMRAG_DIR") {
        Ok(d) if !d.is_empty() => abs_path(Path::new(&d)),
        _ => match std::env::current_dir() {
            Ok(cwd) => abs_path(&cwd),
            Err(_) => dirs_home(),
        },
    }
}
fn abs_path(p: &Path) -> PathBuf {
    let h: PathBuf = dirs_home();
    let joined = if p.is_absolute() {
        p.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| h.clone())
            .join(p)
    };
    match p.strip_prefix("~/") {
        Ok(rel) => h.join(rel),
        Err(_) => joined.canonicalize().unwrap_or(joined),
    }
}

// ---------- SHA-1 (только для ключа проекта) ----------
fn sha1(data: &[u8]) -> [u8; 20] {
    let mut h: [u32; 5] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
    let bitlen = (data.len() as u64) * 8;
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bitlen.to_be_bytes());
    for block in msg.chunks(64) {
        let mut w = [0u32; 80];
        for (i, wi) in w.iter_mut().take(16).enumerate() {
            *wi = u32::from_be_bytes([
                block[i * 4],
                block[i * 4 + 1],
                block[i * 4 + 2],
                block[i * 4 + 3],
            ]);
        }
        for i in 16..80 {
            let a = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
            w[i] = a.rotate_left(1);
        }
        let (mut a, mut b, mut c, mut d, mut e) = (h[0], h[1], h[2], h[3], h[4]);
        for (i, wi) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | ((!b) & d), 0x5A827999u32),
                20..=39 => (b ^ c ^ d, 0x6ED9EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1BBCDC),
                _ => (b ^ c ^ d, 0xCA62C1D6),
            };
            let tmp = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(*wi);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = tmp;
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
    }
    let mut out = [0u8; 20];
    for (i, x) in h.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&x.to_be_bytes());
    }
    out
}
fn sha1_hex(data: &[u8]) -> String {
    sha1(data).iter().map(|b| format!("{b:02x}")).collect()
}

fn db_path_for(dir: &Path) -> PathBuf {
    let s = dir.to_string_lossy().into_owned();
    let hash = &sha1_hex(s.as_bytes())[..12];
    let base: String = dir
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect();
    let base = if base.is_empty() {
        "proj".to_string()
    } else {
        base
    };
    data_home().join(format!("{base}-{hash}.db"))
}

// ---------- база ----------
const SCHEMA: &str = r#"
CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(
  kind UNINDEXED, ref UNINDEXED, idx UNINDEXED, title, body,
  tokenize = 'unicode61 remove_diacritics 2'
);
CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, mtime INTEGER, size INTEGER, nchunks INTEGER);
CREATE TABLE IF NOT EXISTS chunk_ids (ref TEXT, rid INTEGER, PRIMARY KEY(ref, rid));
CREATE TABLE IF NOT EXISTS notes_meta (nid TEXT PRIMARY KEY, title TEXT, created INTEGER, pinned INTEGER DEFAULT 0, tags TEXT DEFAULT '', source TEXT DEFAULT '');
CREATE TABLE IF NOT EXISTS nodes (id TEXT PRIMARY KEY, kind TEXT, label TEXT, weight REAL DEFAULT 1.0, created INTEGER);
CREATE TABLE IF NOT EXISTS edges (src TEXT, dst TEXT, type TEXT, weight REAL DEFAULT 1.0, created INTEGER, PRIMARY KEY (src, dst, type));
CREATE INDEX IF NOT EXISTS edges_src_idx ON edges(src);
CREATE INDEX IF NOT EXISTS edges_dst_idx ON edges(dst);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
"#;

fn open_db(dir: &Path) -> Result<Connection> {
    fs::create_dir_all(data_home())?;
    let conn = Connection::open(db_path_for(dir))?;
    let _ = conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;");
    conn.execute_batch(SCHEMA)?;
    Ok(conn)
}

// ---------- обход ----------
const SKIP_DIRS: &[&str] = &[
    "node_modules",
    ".git",
    ".omo",
    ".npm",
    ".cache",
    ".local",
    "dist",
    "build",
    "out",
    "coverage",
    "__pycache__",
    ".venv",
    "venv",
    ".cargo",
    ".bun",
    "vendor",
    "target",
    ".next",
    ".turbo",
    ".gradle",
    ".idea",
    ".vscode",
    ".termux",
    ".snapshot",
    ".recluse",
];
const SKIP_FILES: &[&str] = &[".DS_Store", "CHANGELOG.tmp"];
const MAX_FILE_SIZE: u64 = 400_000;
const MAX_CHUNK_CHARS: usize = 800;

const TEXT_EXTS: &[&str] = &[
    "js",
    "mjs",
    "cjs",
    "ts",
    "tsx",
    "jsx",
    "json",
    "jsonc",
    "md",
    "mdx",
    "txt",
    "toml",
    "yaml",
    "yml",
    "ini",
    "conf",
    "cfg",
    "sh",
    "bash",
    "fish",
    "zsh",
    "py",
    "rb",
    "pl",
    "go",
    "rs",
    "c",
    "h",
    "cc",
    "cpp",
    "hpp",
    "cxx",
    "hxx",
    "java",
    "kt",
    "kts",
    "swift",
    "php",
    "lua",
    "vim",
    "sql",
    "html",
    "htm",
    "css",
    "scss",
    "less",
    "vue",
    "svelte",
    "astro",
    "graphql",
    "gql",
    "env",
    "properties",
    "xml",
    "svg",
    "proto",
    "nix",
    "hs",
    "ml",
    "ex",
    "exs",
    "erl",
    "clj",
    "lisp",
    "el",
    "scm",
    "r",
    "jl",
    "dart",
    "zig",
    "v",
    "pas",
    "asm",
    "s",
    "cmake",
    "mk",
    "service",
    "socket",
    "timer",
    "desktop",
];
const TEXT_NAMES: &[&str] = &[
    "Makefile",
    "Dockerfile",
    "docker-compose.yml",
    "CMakeLists.txt",
    "README",
    "LICENSE",
    "GITIGNORE",
    ".gitignore",
    ".env.example",
    "tsconfig.json",
    "package.json",
    "AGENTS.md",
    "CLAUDE.md",
    "justfile",
    ".editorconfig",
    ".npmrc",
    "Procfile",
    "Vagrantfile",
];

fn is_text_file(name: &str, ext: &str) -> bool {
    if TEXT_NAMES.iter().any(|n| n.eq_ignore_ascii_case(name)) {
        return true;
    }
    if name.starts_with(".env") {
        return true;
    }
    TEXT_EXTS.contains(&ext)
}

struct Found {
    file: String,
    absp: PathBuf,
    mtime_ms: u64,
    size: u64,
}

fn walk(root: &Path) -> Result<Vec<Found>> {
    let mut out = Vec::new();
    let mut stack: Vec<PathBuf> = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let entries = match fs::read_dir(&dir) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for e in entries.flatten() {
            let ft = match e.file_type() {
                Ok(t) => t,
                Err(_) => continue,
            };
            let p = e.path();
            let name = e.file_name().to_string_lossy().into_owned();
            if ft.is_symlink() {
                continue;
            }
            if ft.is_dir() {
                if SKIP_DIRS.contains(&name.as_str()) || name.starts_with(".git") {
                    continue;
                }
                stack.push(p);
            } else if ft.is_file() {
                let ext = p
                    .extension()
                    .map(|x| x.to_string_lossy().to_lowercase())
                    .unwrap_or_default();
                if SKIP_FILES.contains(&name.as_str()) || !is_text_file(&name, &ext) {
                    continue;
                }
                let md = match e.metadata() {
                    Ok(m) => m,
                    Err(_) => continue,
                };
                if md.len() == 0 || md.len() > MAX_FILE_SIZE {
                    continue;
                }
                let (secs, nanos) = md
                    .modified()
                    .map(|m| {
                        let d = m.duration_since(UNIX_EPOCH).unwrap_or_default();
                        (d.as_secs(), d.subsec_millis() as u64)
                    })
                    .unwrap_or((0, 0));
                let rel = p
                    .strip_prefix(root)
                    .unwrap_or(&p)
                    .to_string_lossy()
                    .into_owned()
                    .replace('\\', "/");
                out.push(Found {
                    file: rel,
                    absp: p,
                    mtime_ms: secs * 1000 + nanos,
                    size: md.len(),
                });
            }
        }
    }
    Ok(out)
}

// ---------- чанкинг ----------
struct Chunk {
    start: usize,
    end: usize,
    body: String,
}

fn chunk_text(text: &str, file: &str) -> Vec<Chunk> {
    let text = text.replace('\t', "  ");
    let mut chunks = Vec::new();
    let mut buf: Vec<String> = Vec::new();
    let mut len = 0usize;
    let mut start = 1usize;
    let limit = MAX_CHUNK_CHARS - MAX_CHUNK_CHARS / 10;
    let flush = |buf: &mut Vec<String>, start: usize, chunks: &mut Vec<Chunk>| {
        if buf.is_empty() {
            return;
        }
        let end = start + buf.len() - 1;
        let body = format!("file: {file} | lines {start}-{end}\n{}", buf.join("\n"));
        chunks.push(Chunk { start, end, body });
        buf.clear();
    };
    let lines: Vec<&str> = text.split('\n').collect();
    for (i, line) in lines.iter().enumerate() {
        let mut line = (*line).to_string();
        while line.len() > limit {
            flush(&mut buf, start, &mut chunks);
            let piece: String = line.chars().take(limit).collect();
            chunks.push(Chunk {
                start: i + 1,
                end: i + 1,
                body: format!("file: {file} | line {}\n{piece}", i + 1),
            });
            line = line.chars().skip(limit).collect();
        }
        buf.push(line.clone());
        len += line.len() + 1;
        if len >= MAX_CHUNK_CHARS {
            flush(&mut buf, start, &mut chunks);
            buf.clear();
            len = 0;
            start = i + 2;
        }
    }
    flush(&mut buf, start, &mut chunks);
    chunks
}

// ---------- индексация ----------
fn index_project(dir: &Path, force: bool) -> Result<String> {
    let root = abs_path(dir);
    let conn = open_db(&root)?;
    let t0 = std::time::Instant::now();
    conn.execute("INSERT INTO meta(key,value) VALUES('project_path',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", rusqlite::params![root.to_string_lossy()])?;
    let found = walk(&root)?;

    let mut files_changed = 0usize;
    let mut chunks_added = 0usize;
    let mut chunks_removed = 0usize;
    let mut since_commit = 0usize;
    let seen: HashSet<String> = found.iter().map(|f| f.file.clone()).collect();
    if force {
        // --force: разово чистим все чанки — FTS5 'delete-all' за O(1) вместо full-scan на каждый файл
        let total: i64 = conn
            .query_row("SELECT count(*) FROM docs WHERE kind='chunk'", [], |r| {
                r.get(0)
            })
            .unwrap_or(0);
        chunks_removed = total as usize;
        conn.execute("INSERT INTO docs(docs,rank) VALUES('delete-all',1)", [])?;
        conn.execute("DELETE FROM chunk_ids", [])?;
        conn.execute("DELETE FROM files", [])?;
    }
    conn.execute_batch("BEGIN")?;
    let mut in_txn = true;
    for f in &found {
        let old: Option<(i64, i64, i64)> = conn
            .query_row(
                "SELECT mtime,size,nchunks FROM files WHERE path=?",
                [&f.file],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .ok();
        if let Some((m, s, _)) = old {
            if !force && m.to_string() == f.mtime_ms.to_string() && s as u64 == f.size {
                continue;
            }
        }
        let text = match fs::read_to_string(&f.absp) {
            Ok(t) => t,
            Err(_) => continue,
        };
        if text.as_bytes().iter().take(2048).any(|&b| b == 0) {
            continue;
        }
        let chunks = chunk_text(&text, &f.file);
        let res = (|| -> Result<()> {
            if let Some((_, _, nch)) = old {
                chunks_removed += nch as usize;
                // прежние чанки сносим по карте rowid (индекс по ref); легаси-строки node-версии — редким full-scan'ом
                let mapped: i64 = conn.query_row(
                    "SELECT count(*) FROM chunk_ids WHERE ref=?",
                    [&f.file],
                    |r| r.get(0),
                )?;
                if mapped > 0 {
                    conn.execute(
                        "DELETE FROM docs WHERE rowid IN (SELECT rid FROM chunk_ids WHERE ref=?)",
                        [&f.file],
                    )?;
                    conn.execute("DELETE FROM chunk_ids WHERE ref=?", [&f.file])?;
                } else if nch > 0 {
                    conn.execute("DELETE FROM docs WHERE kind='chunk' AND ref=?", [&f.file])?;
                }
            }
            for (i, c) in chunks.iter().enumerate() {
                conn.execute(
                    "INSERT INTO docs(kind,ref,idx,title,body) VALUES('chunk',?,?,?,?)",
                    rusqlite::params![
                        f.file,
                        i.to_string(),
                        format!("{}:{}-{}", f.file, c.start, c.end),
                        c.body
                    ],
                )?;
                conn.execute(
                    "INSERT INTO chunk_ids(ref,rid) VALUES(?,?)",
                    rusqlite::params![f.file, conn.last_insert_rowid()],
                )?;
            }
            conn.execute("INSERT INTO files(path,mtime,size,nchunks) VALUES(?,?,?,?) ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime,size=excluded.size,nchunks=excluded.nchunks",
                rusqlite::params![f.file, f.mtime_ms as i64, f.size as i64, chunks.len() as i64])?;
            Ok(())
        })();
        match res {
            Ok(()) => {
                files_changed += 1;
                chunks_added += chunks.len();
                since_commit += 1;
                if since_commit >= 256 {
                    conn.execute_batch("COMMIT")?;
                    in_txn = false;
                    conn.execute_batch("BEGIN")?;
                    in_txn = true;
                    since_commit = 0;
                }
            }
            Err(e) => {
                if in_txn {
                    let _ = conn.execute_batch("ROLLBACK");
                }
                return Err(e.context(format!("index {}", f.file)));
            }
        }
    }
    if in_txn {
        conn.execute_batch("COMMIT")?;
    }

    let known: Vec<String> = {
        let mut st = conn.prepare("SELECT path FROM files")?;
        let rows = st
            .query_map([], |r| r.get(0))?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    let mut gone = 0usize;
    for p in known {
        if !seen.contains(&p) {
            let mapped: i64 = conn
                .query_row("SELECT count(*) FROM chunk_ids WHERE ref=?", [&p], |r| {
                    r.get(0)
                })
                .unwrap_or(0);
            if mapped > 0 {
                conn.execute(
                    "DELETE FROM docs WHERE rowid IN (SELECT rid FROM chunk_ids WHERE ref=?)",
                    [&p],
                )?;
            } else {
                conn.execute("DELETE FROM docs WHERE kind='chunk' AND ref=?", [&p])?;
            }
            conn.execute("DELETE FROM chunk_ids WHERE ref=?", [&p])?;
            conn.execute("DELETE FROM files WHERE path=?", [&p])?;
            gone += 1;
        }
    }
    let now = now_ms();
    conn.execute("INSERT INTO meta(key,value) VALUES('last_index',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", rusqlite::params![now.to_string()])?;
    let total: i64 = conn.query_row("SELECT count(*) FROM docs WHERE kind='chunk'", [], |r| {
        r.get(0)
    })?;
    let notes: i64 = conn.query_row("SELECT count(*) FROM docs WHERE kind='note'", [], |r| {
        r.get(0)
    })?;
    Ok(format!(
        "{{\"project\":\"{}\",\"db\":\"{}\",\"files\":{},\"filesChanged\":{},\"chunksAdded\":{},\"chunksRemoved\":{},\"gone\":{},\"total\":{},\"notes\":{},\"durationMs\":{}}}",
        j(&root.to_string_lossy()),
        j(&db_path_for(&root).to_string_lossy()),
        found.len(),
        files_changed,
        chunks_added,
        chunks_removed,
        gone,
        total,
        notes,
        t0.elapsed().as_millis()
    ))
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
fn j(s: &std::borrow::Cow<str>) -> String {
    json_escape(&s)
}
fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

// ---------- BM25 ----------
fn fts_escape(term: &str) -> String {
    format!("\"{}\"", term.replace('"', "\"\""))
}
fn terms(q: &str) -> Vec<String> {
    q.split(|c: char| c.is_whitespace() || ",;:!?()".contains(c))
        .filter(|t| t.chars().count() >= 2)
        .take(12)
        .map(fts_escape)
        .collect()
}
fn search(conn: &Connection, kind: &str, q: &str, k: usize) -> Result<Vec<Hit>> {
    let t = terms(q);
    if t.is_empty() {
        return Ok(Vec::new());
    }
    let and = t.join(" AND ");
    let or = t.join(" OR ");
    let sql = format!(
        "SELECT rowid, ref, idx, title, bm25(docs) AS rank, body, snippet(docs,4,'[',']','…',10) AS snip FROM docs WHERE docs MATCH ? AND kind='{kind}' ORDER BY bm25(docs) LIMIT {k}"
    );
    let mut run = |m: &str, conn: &Connection, sql: &str, k: usize| -> Vec<Hit> {
        let mut st = match conn.prepare(sql) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        let rows = st.query_map([m], |r| {
            Ok(Hit {
                kind: kind.to_string(),
                ref_: r.get::<_, String>(1)?,
                chunk_idx: r.get::<_, String>(2)?.parse::<usize>().unwrap_or(0),
                title: r.get(3)?,
                rank: r.get(4)?,
                body: r.get(5)?,
                snip: r.get(6)?,
                pinned: false,
                tags: String::new(),
                score: 0.0,
            })
        });
        match rows {
            Ok(r) => r.filter_map(|x| x.ok()).collect(),
            Err(_) => Vec::new(),
        }
    };
    let mut hits = run(&and, conn, &sql, k);
    if hits.is_empty() {
        hits = run(&or, conn, &sql, k);
    }
    Ok(hits)
}

#[derive(Clone)]
struct Hit {
    kind: String,
    ref_: String,
    chunk_idx: usize,
    title: String,
    rank: f64,
    body: String,
    snip: String,
    pinned: bool,
    tags: String,
    score: f64,
}

// ---------- граф ----------
fn ensure_node(conn: &Connection, id: &str, kind: &str, label: &str) -> Result<()> {
    conn.execute("INSERT INTO nodes(id,kind,label,weight,created) VALUES(?,?,?,1.0,?) ON CONFLICT(id) DO NOTHING",
        rusqlite::params![id, kind, label, now_ms()])?;
    Ok(())
}
fn add_edge(conn: &Connection, src: &str, dst: &str, type_: &str) -> Result<()> {
    let now = now_ms();
    conn.execute("INSERT INTO edges(src,dst,type,weight,created) VALUES(?,?,?,1.0,?) ON CONFLICT(src,dst,type) DO UPDATE SET weight=weight+0.25",
        rusqlite::params![src, dst, type_, now])?;
    conn.execute(
        "INSERT OR IGNORE INTO edges(src,dst,type,weight,created) VALUES(?,?,?,1.0,?)",
        rusqlite::params![dst, src, format!("{type_}~"), now],
    )?;
    Ok(())
}

const PATH_RE_PAT: &str = r#"/\b[\w\-./@]+\.(?:js|ts|tsx|jsx|mjs|cjs|py|go|rs|md|json|toml|ya?ml|sh|fish|c|h|cpp|hpp|lua|sql|html|css|vue|svelte|astro|rb|php|kt|swift|dart|java|lock)\b/"#;
const SYM_STOP: &[&str] = &[
    "true",
    "false",
    "null",
    "undefined",
    "const",
    "function",
    "return",
    "import",
    "export",
    "class",
    "default",
    "error",
    "message",
    "string",
    "number",
    "create",
    "update",
    "delete",
    "select",
    "insert",
    "async",
    "await",
    "write",
    "read",
    "open",
    "file",
    "path",
    "node",
    "title",
    "body",
    "tags",
    "index",
    "project",
    "memory",
    "result",
    "results",
    "value",
    "params",
    "options",
    "context",
    "args",
    "data",
    "state",
    "status",
    "version",
];

fn extract_mentions(text: &str) -> (Vec<String>, Vec<String>) {
    let mut paths = Vec::new();
    // указатель пути без regex-крейта: токенизируем по границе не-slug
    let mut cur = String::new();
    let mut push_cur = |cur: &mut String, out: &mut Vec<String>| {
        if !cur.is_empty() {
            out.push(cur.clone());
            cur.clear();
        }
    };
    for (i, c) in text.char_indices() {
        let is_word = c.is_alphanumeric() || matches!(c, '/' | '.' | '_' | '-' | '@');
        if is_word {
            cur.push(c);
            if cur.len() > 128 {
                push_cur(&mut cur, &mut paths);
            }
        } else {
            push_cur(&mut cur, &mut paths);
        }
        if paths.len() > 2000 {
            break;
        }
        let _ = i;
    }
    push_cur(&mut cur, &mut paths);
    let mut path_hits: HashSet<String> = HashSet::new();
    for tok in paths {
        // разрезаем токен на под-токены и ищем с расширением
        for seg in tok.split(|c: char| c == ' ' || c == '"') {
            if let Some(dot) = seg.find('.') {
                let tail = &seg[dot..];
                if tail.len() <= 6
                    && tail[1..].chars().all(|c| c.is_ascii_alphanumeric())
                    && TEXT_EXTS.contains(&&tail[1..])
                    && !tail.contains("--")
                {
                    let clean = seg.trim_start_matches(|c: char| c == '/' || c == '.');
                    if !clean.is_empty() {
                        path_hits.insert(clean.to_string());
                    }
                }
            }
        }
        if path_hits.len() >= 6 {
            break;
        }
    }
    let _ = PATH_RE_PAT;

    // символы: camelCase / snake_case / UPPER
    let mut sym_hits: HashMap<String, usize> = HashMap::new();
    for raw in text.split(|c: char| !(c.is_alphanumeric() || c == '_')) {
        let w = raw;
        if w.chars().count() < 4 {
            continue;
        }
        let has_upper_after_lower = w.chars().enumerate().any(|(i, ch)| {
            i > 0
                && ch.is_uppercase()
                && w.chars()
                    .nth(i - 1)
                    .map(|p| p.is_lowercase())
                    .unwrap_or(false)
        });
        let has_snake =
            w.contains('_') && w.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_');
        let is_upper = w.bytes().all(|b| !b.is_ascii_lowercase())
            && w.bytes().any(|b| b.is_ascii_alphabetic());
        let ok = has_upper_after_lower
            || (has_snake && !w.contains("__"))
            || (is_upper && w.chars().count() >= 3);
        if ok && !SYM_STOP.iter().any(|s| s.eq_ignore_ascii_case(w)) {
            *sym_hits.entry(w.to_string()).or_default() += 1;
        }
        if sym_hits.len() > 2000 {
            break;
        }
    }
    let mut top: Vec<(String, usize)> = sym_hits.into_iter().collect();
    top.sort_by(|a, b| b.1.cmp(&a.1));
    let syms: Vec<String> = top.into_iter().take(6).map(|(s, _)| s).collect();
    (path_hits.into_iter().take(6).collect(), syms)
}

fn link_note_to_graph(
    conn: &Connection,
    nid: &str,
    title: &str,
    body: &str,
    tags: &str,
) -> Result<(usize, usize)> {
    let note_id = format!("note:{nid}");
    ensure_node(conn, &note_id, "note", title)?;
    let (paths, syms) = extract_mentions(&format!("{title}\n{body}"));
    for p in &paths {
        let id = format!("file:{p}");
        ensure_node(conn, &id, "file", p)?;
        add_edge(conn, &note_id, &id, "mentions")?;
    }
    for s in &syms {
        let id = format!("sym:{s}");
        ensure_node(conn, &id, "symbol", s)?;
        add_edge(conn, &note_id, &id, "mentions")?;
    }
    for t in tags.split(',').filter(|t| !t.trim().is_empty()) {
        let tag = t.trim().to_lowercase();
        let id = format!("tag:{tag}");
        ensure_node(conn, &id, "tag", &tag)?;
        add_edge(conn, &note_id, &id, "tagged")?;
    }
    Ok((paths.len(), syms.len()))
}

fn graph_expand(
    conn: &Connection,
    seeds: &[String],
    depth: i64,
    limit: i64,
) -> Result<Vec<(String, String, String, f64, i64)>> {
    if seeds.is_empty() {
        return Ok(Vec::new());
    }
    let ph = seeds.iter().map(|_| "?").collect::<Vec<_>>().join(",");
    let sql = format!(
        "WITH RECURSIVE walk(id,d) AS (\
           SELECT id, 0 FROM nodes WHERE id IN ({ph}) \
           UNION \
           SELECT e.dst, w.d+1 FROM walk w JOIN edges e ON e.src = w.id WHERE w.d < ? \
         ) SELECT w.id, MIN(w.d), n.kind, n.label, n.weight FROM walk w JOIN nodes n ON n.id = w.id \
           WHERE w.d > 0 GROUP BY w.id ORDER BY n.weight DESC, w.d ASC LIMIT {limit}"
    );
    let mut st = conn.prepare(&sql)?;
    let mut params: Vec<&dyn rusqlite::ToSql> =
        seeds.iter().map(|s| s as &dyn rusqlite::ToSql).collect();
    params.push(&depth);
    let rows = st.query_map(rusqlite::params_from_iter(params.iter().map(|p| *p)), |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, f64>(4)?,
            r.get::<_, i64>(1)?,
        ))
    })?;
    let out = rows.filter_map(|r| r.ok()).collect();
    Ok(out)
}

fn bump_weights(conn: &Connection, ids: &[String], amount: f64) -> Result<()> {
    if ids.is_empty() {
        return Ok(());
    }
    let ph = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
    let sql = format!("UPDATE nodes SET weight = MIN(weight + ?, 20.0) WHERE id IN ({ph})");
    let mut params: Vec<&dyn rusqlite::ToSql> = vec![&amount];
    for id in ids {
        params.push(id);
    }
    let mut st = conn.prepare(&sql)?;
    st.execute(rusqlite::params_from_iter(params.iter().map(|p| *p)))?;
    Ok(())
}

// ---------- операции ----------
fn save_note(
    dir: &Path,
    title: &str,
    body: &str,
    tags: &str,
    pinned: bool,
    source: &str,
) -> Result<(String, usize, usize)> {
    let conn = open_db(dir)?;
    let nid = format!("{}", now_ms()).chars().take(0).collect::<String>()
        + &format!("{:08x}", rand_u32());
    conn.execute(
        "INSERT INTO notes_meta(nid,title,created,pinned,tags,source) VALUES(?,?,?,?,?,?)",
        rusqlite::params![nid, title, now_ms(), pinned as i64, tags, source],
    )?;
    conn.execute(
        "INSERT INTO docs(kind,ref,idx,title,body) VALUES('note',?,?,?,?)",
        rusqlite::params![nid, "0", title, body],
    )?;
    let (np, ns) = link_note_to_graph(&conn, &nid, title, body, tags)?;
    Ok((nid, np, ns))
}
fn rand_u32() -> u32 {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(7);
    nanos ^ std::process::id()
}
fn list_notes(dir: &Path) -> Result<Vec<(String, String, i64, i64, String)>> {
    let conn = open_db(dir)?;
    let mut st = conn.prepare("SELECT nid,title,created,pinned,tags FROM notes_meta ORDER BY pinned DESC, created DESC LIMIT 200")?;
    let rows = st.query_map([], |r| {
        Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
    })?;
    Ok(rows.filter_map(|r| r.ok()).collect())
}
fn get_note(dir: &Path, nid: &str) -> Result<Option<(String, String, i64, i64, String, String)>> {
    let conn = open_db(dir)?;
    let row = match conn.query_row(
        "SELECT n.nid,n.title,n.created,n.pinned,n.tags,d.body FROM notes_meta n LEFT JOIN docs d ON d.ref=n.nid AND d.kind='note' WHERE n.nid=?",
        [nid], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?))) {
        Ok(row) => Some(row),
        Err(rusqlite::Error::QueryReturnedNoRows) => None,
        Err(e) => Err(e)?,
    };
    Ok(row)
}
fn set_pin(dir: &Path, nid: &str, pinned: bool) -> Result<()> {
    let conn = open_db(dir)?;
    conn.execute(
        "UPDATE notes_meta SET pinned=? WHERE nid=?",
        rusqlite::params![pinned as i64, nid],
    )?;
    Ok(())
}
fn forget_note(dir: &Path, nid: &str) -> Result<()> {
    let conn = open_db(dir)?;
    conn.execute("DELETE FROM notes_meta WHERE nid=?", [nid])?;
    conn.execute("DELETE FROM docs WHERE kind='note' AND ref=?", [nid])?;
    Ok(())
}
fn query(
    dir: &Path,
    q: &str,
    k: usize,
    depth: i64,
) -> Result<(Vec<Hit>, Vec<(String, String, String, f64, i64)>)> {
    let conn = open_db(dir)?;
    let notes: Vec<Hit> = search(&conn, "note", q, k)?;
    let notes_meta: HashMap<String, (i64, String)> = {
        let mut st = conn.prepare("SELECT nid, pinned, tags FROM notes_meta")?;
        let rows = st.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?;
        rows.filter_map(|r| r.ok())
            .map(|(n, p, t)| (n, (p, t)))
            .collect()
    };
    let chunks: Vec<Hit> = search(&conn, "chunk", q, k)?;
    let mut items: Vec<Hit> = Vec::with_capacity(notes.len() + chunks.len());
    for n in notes {
        let (p, t) = notes_meta
            .get(&n.ref_)
            .cloned()
            .unwrap_or((0, String::new()));
        let pinned = p > 0;
        items.push(Hit {
            score: n.rank.abs() * 1.6 + if pinned { 5.0 } else { 0.0 },
            pinned,
            ..n
        });
    }
    for c in chunks {
        items.push(Hit {
            score: c.rank.abs(),
            ..c
        });
    }
    items.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    items.truncate(k);

    let mut seeds: Vec<String> = Vec::new();
    for h in &items {
        if h.kind == "note" {
            seeds.push(format!("note:{}", h.ref_));
        }
        if h.kind == "chunk" {
            seeds.push(format!("file:{}", h.ref_));
            for t in h.tags.split(',').filter(|t| !t.is_empty()) {
                seeds.push(format!("tag:{t}"));
            }
        }
    }
    bump_weights(&conn, &seeds, 0.15)?;
    let graph = graph_expand(&conn, &seeds, depth, 8)?;
    bump_weights(
        &conn,
        &graph.iter().map(|g| g.0.clone()).collect::<Vec<_>>(),
        0.05,
    )?;
    Ok((items, graph))
}
fn brain_summary(dir: &Path) -> Result<Vec<String>> {
    let conn = open_db(dir)?;
    let files: i64 = conn.query_row("SELECT count(*) FROM files", [], |r| r.get(0))?;
    let chunks: i64 = conn.query_row("SELECT count(*) FROM docs WHERE kind='chunk'", [], |r| {
        r.get(0)
    })?;
    let notes: i64 = conn.query_row("SELECT count(*) FROM docs WHERE kind='note'", [], |r| {
        r.get(0)
    })?;
    let nodes: i64 = conn.query_row("SELECT count(*) FROM nodes", [], |r| r.get(0))?;
    let edges: i64 = conn.query_row("SELECT count(*) FROM edges", [], |r| r.get(0))?;
    let project: String = conn
        .query_row("SELECT value FROM meta WHERE key='project_path'", [], |r| {
            r.get(0)
        })
        .unwrap_or_default();
    let mut out = vec![
        format!("ПАМЯТЬ: {project}"),
        format!(" файлов:{files} чанков:{chunks} нот:{notes} | граф: узлов {nodes}, рёбер {edges}"),
    ];
    let mut st = conn.prepare(
        "SELECT nid,title,tags FROM notes_meta WHERE pinned=1 ORDER BY created DESC LIMIT 10",
    )?;
    let pinned: Vec<String> = st
        .query_map([], |r| {
            Ok(format!(
                "📌 id:{} [{}] {}",
                r.get::<_, String>(0)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(1)?
            ))
        })?
        .filter_map(|r| r.ok())
        .collect();
    if !pinned.is_empty() {
        out.push("\nзакреплённые:".to_string());
        out.extend(pinned.into_iter().map(|p| format!("  {p}")));
    }
    drop(st);
    let mut st = conn.prepare("SELECT id,kind,weight FROM nodes ORDER BY weight DESC LIMIT 8")?;
    let hot: Vec<String> = st
        .query_map([], |r| {
            Ok(format!(
                "🔥 w{:.1} [{}] {}",
                r.get::<_, f64>(2)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(0)?
            ))
        })?
        .filter_map(|r| r.ok())
        .collect();
    if !hot.is_empty() {
        out.push("\n🔥 горячие узлы:".to_string());
        out.extend(hot.into_iter().map(|h| format!("  {h}")));
    }
    drop(st);
    Ok(out)
}
fn graph_cmd(dir: &Path) -> Result<Vec<String>> {
    let conn = open_db(dir)?;
    let mut out = Vec::new();
    let mut st =
        conn.prepare("SELECT id,kind,label,weight FROM nodes ORDER BY weight DESC LIMIT 40")?;
    let nodes: Vec<String> = st
        .query_map([], |r| {
            Ok(format!(
                "[{}] w{:.2} {}",
                r.get::<_, String>(1)?,
                r.get::<_, f64>(3)?,
                r.get::<_, String>(0)?
            ))
        })?
        .filter_map(|r| r.ok())
        .collect();
    drop(st);
    out.extend(nodes);
    out.push("— edges —".to_string());
    let mut st = conn.prepare("SELECT src,dst,type,weight FROM edges WHERE type NOT LIKE '%~' ORDER BY weight DESC LIMIT 40")?;
    let edges: Vec<String> = st
        .query_map([], |r| {
            Ok(format!(
                "{} -[{}]-> {} (w{:.2})",
                r.get::<_, String>(0)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(1)?,
                r.get::<_, f64>(3)?
            ))
        })?
        .filter_map(|r| r.ok())
        .collect();
    out.extend(edges);
    Ok(out)
}
fn stats_json(dir: &Path) -> Result<String> {
    let conn = open_db(dir)?;
    let files: i64 = conn.query_row("SELECT count(*) FROM files", [], |r| r.get(0))?;
    let chunks: i64 = conn.query_row("SELECT count(*) FROM docs WHERE kind='chunk'", [], |r| {
        r.get(0)
    })?;
    let notes: i64 = conn.query_row("SELECT count(*) FROM docs WHERE kind='note'", [], |r| {
        r.get(0)
    })?;
    let project: String = conn
        .query_row("SELECT value FROM meta WHERE key='project_path'", [], |r| {
            r.get(0)
        })
        .unwrap_or_default();
    Ok(format!(
        "{{\"project\":\"{}\",\"db\":\"{}\",\"files\":{},\"chunks\":{},\"notes\":{}}}",
        json_escape(&project),
        json_escape(&db_path_for(&abs_path(dir)).to_string_lossy()),
        files,
        chunks,
        notes
    ))
}

// ---------- вывод ----------
fn format_results(
    q: &str,
    items: &[Hit],
    graph: &[(String, String, String, f64, i64)],
    depth: i64,
) -> String {
    if items.is_empty() {
        return format!("Пусто: ничего не найдено по запросу «{q}».");
    }
    let mut out = format!("Память проекта | запрос: «{q}»");
    for (i, h) in items.iter().enumerate() {
        if h.kind == "note" {
            out.push_str(&format!(
                "\n«{}» НОТА (id:{}{}) {}\n{}\n",
                i + 1,
                h.ref_,
                if h.pinned { " 📌" } else { "" },
                h.title,
                h.body
            ));
        } else {
            out.push_str(&format!(
                "\n«{}» CHUNK {} ({})\n{}\n",
                i + 1,
                h.ref_,
                h.chunk_idx,
                h.snip
            ));
        }
    }
    if !graph.is_empty() {
        out.push_str(&format!(
            "\n— граф-контекст (соседи сидов, depth {depth}) —\n"
        ));
        for g in graph {
            out.push_str(&format!(" d{} w{:.1} {} {}\n", g.4, g.3, g.1, g.0));
        }
    }
    out
}

fn usage() -> String {
    "memrag (rust) — RAG-графовая память проекта

  index [--force]   проиндексировать cwd (инкрементально)
  query \"...\" [-k N] [--depth N] [--json]  поиск + граф-контекст
  note \"Title::body\" [--tags a,b]  сохранить ноту (+связи графа)
  notes | read <id> | pin <id> 1|0 | forget <id>
  link <src> <dst> [type]
  graph | brain | stats
env: MEMRAG_DIR, MEMRAG_HOME"
        .to_string()
}

fn try_main() -> Result<i32> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let dir = project_dir();
    let cmd = args.first().map(String::as_str).unwrap_or("help");
    let mut rest: Vec<String> = args[1.min(args.len())..].to_vec();
    let take_flag = |rest: &mut Vec<String>, names: &[&str]| -> Option<String> {
        for n in names {
            if let Some(pos) = rest.iter().position(|a| a == n) {
                if pos + 1 < rest.len() {
                    let v = rest[pos + 1].clone();
                    rest.drain(pos..=pos + 1);
                    return Some(v);
                }
            }
        }
        None
    };
    let take_bool = |rest: &mut Vec<String>, names: &[&str]| -> bool {
        let mut hit = false;
        for n in names {
            while let Some(pos) = rest.iter().position(|a| a == n) {
                rest.remove(pos);
                hit = true;
            }
        }
        hit
    };
    match cmd {
        "index" => {
            let force = take_bool(&mut rest, &["--force"]);
            println!("{}", index_project(&dir, force)?);
        }
        "query" => {
            let k: usize = take_flag(&mut rest, &["-k", "--k"])
                .and_then(|v| v.parse().ok())
                .unwrap_or(6);
            let depth: i64 = take_flag(&mut rest, &["--depth"])
                .and_then(|v| v.parse().ok())
                .unwrap_or(2);
            let json_mode = take_bool(&mut rest, &["--json"]);
            let q = rest.join(" ");
            if q.is_empty() {
                println!("usage: memrag query \"запрос\" [-k N] [--depth N]");
                return Ok(1);
            }
            let (items, graph) = query(&dir, &q, k, depth)?;
            if json_mode {
                let mut out = String::from("{\"query\":");
                out.push_str(&format!("\"{}\"", json_escape(&q)));
                out.push_str(",\"items\":[");
                for (i, h) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    out.push_str(&format!("{{\"kind\":\"{}\",\"ref\":\"{}\",\"title\":\"{}\",\"snip\":\"{}\",\"body\":\"{}\",\"score\":{:.3}}}",
                        h.kind, json_escape(&h.ref_), json_escape(&h.title), json_escape(&h.snip), json_escape(&h.body), h.score));
                }
                out.push_str("],\"graph\":[");
                for (i, g) in graph.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    out.push_str(&format!("{{\"id\":\"{}\",\"kind\":\"{}\",\"label\":\"{}\",\"weight\":{:.2},\"depth\":{}}}",
                        json_escape(&g.0), g.1, json_escape(&g.2), g.3, g.4));
                }
                out.push_str("]}");
                println!("{out}");
            } else {
                println!("{}", format_results(&q, &items, &graph, depth));
            }
        }
        "note" => {
            let tags = take_flag(&mut rest, &["--tags"]).unwrap_or_default();
            let text = rest.join(" ").trim().to_string();
            if text.is_empty() {
                println!("usage: memrag note \"Заголовок::текст\" [--tags a,b]");
                return Ok(1);
            }
            let (t, b) = match text.split_once("::") {
                Some((t, b)) => (t.trim().to_string(), b.trim().to_string()),
                None => {
                    ((
                        text.split(|c| c == '.' || c == '\n')
                            .next()
                            .unwrap_or(&text)
                            .chars()
                            .take(80)
                            .collect::<String>(),
                        text,
                    ))
                }
            };
            let (nid, np, ns) = save_note(&dir, &t, &b, &tags, false, "cli")?;
            println!("нота сохранена id:{nid} | связи: {np} файлов, {ns} символов");
            // пометка: при отсутствии :: заголовок = первые 80 символов
        }
        "notes" => {
            for (nid, title, _c, pinned, tags) in list_notes(&dir)? {
                println!(
                    "{} id:{nid} [{tags}] {title}",
                    if pinned == 1 { "📌" } else { "  " }
                );
            }
        }
        "read" => {
            let nid = rest.first().cloned().unwrap_or_default();
            match get_note(&dir, &nid)? {
                Some((nid, t, _c, p, tg, b)) => println!(
                    "{{\"nid\":\"{nid}\",\"title\":\"{}\",\"tags\":\"{tg}\",\"pinned\":{},\"body\":\"{}\"}}",
                    json_escape(&t),
                    p,
                    json_escape(&b)
                ),
                None => {
                    println!("нет такой ноты");
                    return Ok(1);
                }
            }
        }
        "pin" => {
            let nid = rest.get(0).cloned().unwrap_or_default();
            let val = rest.get(1).map(|v| v != "0").unwrap_or(true);
            set_pin(&dir, &nid, val)?;
            println!("id:{nid} pinned={val}");
        }
        "forget" => {
            let nid = rest.first().cloned().unwrap_or_default();
            forget_note(&dir, &nid)?;
            println!("нота id:{nid} удалена");
        }
        "link" => {
            let (s, d, t) = (
                rest.get(0).cloned().unwrap_or_default(),
                rest.get(1).cloned().unwrap_or_default(),
                rest.get(2)
                    .cloned()
                    .unwrap_or_else(|| "related_to".to_string()),
            );
            if s.is_empty() || d.is_empty() {
                println!("usage: memrag link <src-node-id> <dst-node-id> [type]");
                return Ok(1);
            }
            let conn = open_db(&dir)?;
            add_edge(&conn, &s, &d, &t)?;
            println!("edge добавлен: {s} -[{t}]-> {d}");
        }
        "graph" => {
            for l in graph_cmd(&dir)? {
                println!("{l}");
            }
        }
        "brain" => {
            for l in brain_summary(&dir)? {
                println!("{l}");
            }
        }
        "stats" => {
            println!("{}", stats_json(&dir)?);
        }
        "help" | _ => {
            println!("{}", usage());
            if cmd != "help" {
                return Ok(1);
            }
        }
    }
    Ok(0)
}

fn main() {
    match try_main() {
        Ok(code) => std::process::exit(code),
        Err(e) => {
            eprintln!("memrag error: {e:#}");
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sha1_abc() {
        assert_eq!(sha1_hex(b"abc"), "a9993e364706816aba3e25717850c26c9cd0d89d");
    }
    #[test]
    fn chunking_limits() {
        let text = (0..100)
            .map(|i| format!("line {i} padding padding padding"))
            .collect::<Vec<_>>()
            .join("\n");
        let cs = chunk_text(&text, "t.txt");
        assert!(cs.len() > 1);
        for c in &cs {
            assert!(c.body.len() <= 900);
        }
    }
    #[test]
    fn mentions_extract() {
        let (paths, syms) =
            extract_mentions("see src/foo.ts and graphExpand and my_var_name, !! UPPER");
        assert!(paths.iter().any(|p| p.ends_with("src/foo.ts")));
        assert!(
            syms.iter()
                .any(|s| s == "graphExpand" || s == "my_var_name")
        );
    }
}

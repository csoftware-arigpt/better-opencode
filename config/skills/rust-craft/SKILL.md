---
name: rust-craft
description: Rust style and verification discipline sourced from official rust-lang guidelines and Cargo docs (researched 2026-10, Rust 1.99 / edition 2024). Load when writing, reviewing or testing Rust code.
---

# Rust on this station (official rules, verified 2026-10-29)

## Facts
- Stable Rust 1.99.1 (1.99.0 - Oct 2026); newest edition `2024`, `cargo new` writes it by default; edition "2024" enables resolver v3 behavior (>= 1.84) with MSRV-aware dependency fallback (https://blog.rust-lang.org/2026/10/01/Rust-1.99.0/, https://doc.rust-lang.org/cargo/reference/resolver.html)
- Station: cargo/rustc via nix profile; gcc NOT on PATH.

## Check ladder
1. `cargo fmt --all` (rustfmt is first-party) (https://www.rust-lang.org/tools)
2. `cargo check` - NOT `cargo build` by default
3. Targeted `cargo test <name>`, full suite on request
4. `cargo clippy` on request (first-party); no `-D warnings` automatically

## Style (official distillation, each with source)
- Casing per RFC 430: `snake_case` fns/modules/locals (btree_map), `UpperCamelCase` types/traits (acronyms as ONE word: `Uuid`), `SCREAMING_SNAKE_CASE` consts, type params one letter, lifetimes short (https://rust-lang.github.io/api-guidelines/naming.html)
- Conversions by cost/ownership: `as_` = free borrowed->borrowed, `to_` = expensive, `into_` = consumes; setters/getters without `get_` prefix; unsafe twins named `_unchecked` (https://rust-lang.github.io/api-guidelines/naming.html)
- Implement the obvious set of traits on purpose: `Copy Clone Eq PartialEq Ord PartialOrd Hash Debug Display Default`; conversions via `From/AsRef/AsMut`, collections via `FromIterator/Extend` (https://rust-lang.github.io/api-guidelines/checklist.html)
- Minimize assumptions through generics (`impl Into` params); no out-params; give the caller control over copying (https://rust-lang.github.io/api-guidelines/checklist.html)
- Meaning via types, not bools: newtypes, `bitflags`, builders for complex construction, private struct fields, sealed traits (https://rust-lang.github.io/api-guidelines/checklist.html)
- Document everything: crate-level docs with examples; every public item gets a runnable rustdoc example; examples use `?`, never `try!`/`unwrap` (https://rust-lang.github.io/api-guidelines/checklist.html)
- Library fallible functions return `Result`; destructor does not fail (https://rust-lang.github.io/api-guidelines/checklist.html)
- Errors in libraries: concrete error type + `std::error::Error` via `thiserror` derive (`#[error]` Display, `#[from]` implies `#[source]`) - derive is invisible in the public API (https://docs.rs/thiserror/latest/thiserror/)
- `anyhow` ONLY at application level: `anyhow::Result` + `?` + `.context()`; do not derive app error types with it - use thiserror (https://docs.rs/anyhow/latest/anyhow/)
- `unwrap` is reserved for `Option/Result` (and asserts); your own panic-free "unwraps" must be named `into_foo`/`into_inner` (https://github.com/rust-lang/rfcs/blob/master/text/0430-finalizing-naming-conventions.md)
- Edition 2024 lint `unsafe_op_in_unsafe_fn` is warn-by-default: a body of `unsafe fn` still needs an explicit `unsafe {}` block with a `// SAFETY:` justification (https://doc.rust-lang.org/edition-guide/rust-2024/unsafe-op-in-unsafe-fn.html)
- Set `rust-version` (MSRV) in Cargo.toml; pin `[lints]` (e.g. `unsafe_code = "forbid"`) instead of scattered crate attributes (https://doc.rust-lang.org/cargo/reference/manifest.html)
- Do not hand-unwind leaked memory: for deliberate ownership transfer use `Box::into_raw` (Rust 1.99 docs) (https://blog.rust-lang.org/2026/10/01/Rust-1.99.0/)

## Gotchas of this machine (NixOS)
- Native C deps / linking need `nix-shell -p gcc` (verified here: the memrag rust binary fails without it); ssl/pkg-config -> `nix-shell -p gcc pkg-config openssl`.
- target/ cache: do not wipe casually; keep it in .gitignore.
- `cargo fetch` after Cargo.toml edits, separately from build.

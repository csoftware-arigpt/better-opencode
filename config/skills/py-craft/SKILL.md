---
name: py-craft
description: Python style and verification discipline sourced from official PEPs/docs (researched 2026-10, Python 3.15). Load when writing, reviewing or testing Python code.
---

# Python on this station (official rules, verified 2026-10-29)

## Facts
- Current stable: **Python 3.15** (3.15.2, Oct 2026); 3.12+ syntax (PEP 695 generics, `type` aliases) is default-usable (https://www.python.org/downloads/release/python-3152/)
- Python on the station: `python`/`python3` from nix profile; gcc NOT on PATH.

## Check ladder
1. `python -m py_compile file.py` / `python -m compileall .` - instant syntax gate
2. `ruff check .` (default rules F,E,B,UP,RUF; incl. B904 raise-from, B006 mutable defaults), autofix `ruff check --fix`
3. `ruff check --select I --fix` then `ruff format` (formatter does NOT sort imports; `ruff format` is a Black drop-in) (https://docs.astral.sh/ruff/formatter/)
4. Targeted `pytest path/to/test.py -x -q`, full suite on request

## Style (official distillation, each with source)
- PEP 8 layout: 4 spaces, 79 chars (72 docstrings; teams may relax); module order: docstring -> dunders -> imports (stdlib/third-party/local groups) -> code; 2 blank lines around top-level defs (https://peps.python.org/pep-0008/)
- Names: `lowercase_with_underscores` functions/vars, `CapWords` classes, `UPPER_CASE` constants, exceptions end in `Error`; `self`/`cls` first args (https://peps.python.org/pep-0008/)
- Absolute imports, one module per line, never wildcard `from x import *` (https://peps.python.org/pep-0008/)
- Never bare `except:` (catches SystemExit/KeyboardInterrupt); catch specific classes, at minimum `except Exception:` (https://peps.python.org/pep-0008/)
- Chain errors: `raise NewError(...) from exc` (ruff B904); `from None` only for deliberate replacement (https://peps.python.org/pep-0008/)
- Keep `try:` minimal - guard only the vulnerable statement (https://peps.python.org/pep-0008/)
- Singletons via `is None`; type checks via `isinstance()`; never `== True` (https://peps.python.org/pep-0008/)
- No mutable defaults: no `def f(x=[])`, no mutable field defaults on dataclasses - `None` sentinel or `field(default_factory=list)` (ruff B006) (https://docs.python.org/3/library/dataclasses.html)
- Annotate public API fully; `__init__ -> None`; `X | None` explicit for None-defaulted params (PEP 484) (https://peps.python.org/pep-0484/)
- Modern typing: `X | Y` unions (valid in isinstance too), built-in generics `list[int]`, `collections.abc.Callable/Iterable` over deprecated `typing.*` (https://docs.python.org/3/library/typing.html)
- `type X = ...` alias statement (3.12+) - `TypeAlias` deprecated; generics via `def first[T](...) -> T` (PEP 695) (https://docs.python.org/3/library/typing.html)
- `Self` for methods returning self, fluent builders, `__enter__` (https://docs.python.org/3/library/typing.html)
- `@dataclass` over hand-written `__init__`/`__repr__` boilerplate (https://docs.python.org/3/library/dataclasses.html)
- `pathlib.Path` for filesystem (`/`-join, `read_text`, `glob`), not `os.path` string surgery (https://docs.python.org/3/library/pathlib.html)
- f-strings for interpolation (https://docs.python.org/3/tutorial/inputoutput.html)

## Gotchas of this machine (NixOS)
- Global pip is rejected (PEP 668): the venv is the only way (`python -m venv .venv`).
- C extensions with no wheel -> run pip inside `nix-shell -p gcc python3`.
- nixpkgs python packages (`nix profile install nixpkgs#python3Packages.<name>`) when venv refuses.

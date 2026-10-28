---
name: precise-work
description: Surgical edit and verification discipline for coding tasks. Load whenever editing existing code, refactoring, fixing bugs, or doing anything where a wrong edit is expensive.
---

# Precise Work Protocol

1. **Read the exact area before editing.** Never edit from memory or from a file name. After every edit re-read the changed piece - confirm the intended change landed and nothing nearby broke.
2. **Minimal correct diff.** `edit` over rewrite; keep the style, indentation and naming of the surroundings; drive-by "improvements" (reformatting, off-topic renames) are forbidden.
3. **Understand -> Change -> Verify.** After each change run a fast check: JS/TS `node --check`, python `python -m py_compile`, shell `bash -n`, go `go build ./...` or `go vet`, rust `cargo check`. At the end of the task - the integration checks planned at the start.
4. **Evidence, not vibes.** "Done" is sayable only with the attached output of checks. Do not say "should work" - show that it works.
5. **Fail loudly.** The same check failing twice in a row - stop: state the hypothesis, make a plan, ask the user. No stacks of workarounds and "// fix later" comments. If the edit is dead-ended - roll back (git restore / backup), do not pile on.
6. **Delete nothing without understanding.** Unfamiliar files and odd code fragments - find out whose they are first; they may be user work.

---
name: go-craft
description: Go style and verification discipline sourced from official Go wiki/code-review and Google style guide (researched 2026-10). Load when writing, reviewing or testing Go code.
---

# Go on this station (official rules, dist-2026-10-29)

## Check ladder (official tooling only; gofumpt/golangci-lint = third-party)
1. `gofmt -s -l .` (prefer `goimports`) - -s simplifies composite literals
2. `go vet ./...` - catches Printf mismatches, copylocks, lostcancel, loopclosure; `go test` already auto-runs vet's high-confidence subset (https://pkg.go.dev/cmd/vet)
3. `go build ./...` then targeted `go test ./pkg/... -run TestName -count=1`, full suite on request

## Style (official distillation, each with source)
- MixedCaps only; consistent initialism casing (`URL`, `ID`); getters carry no `Get` prefix; no underscores, no SCREAMING constants (https://go.dev/doc/effective_go)
- Package names: lowercase, short, never `util`/`common`/`misc`; cut redundancy with the package name (`chubby.File`, not `chubby.ChubbyFile`) (https://google.github.io/styleguide/go/decisions)
- Interfaces at the CONSUMER side, small, only when a real need exists; accept interfaces, return concrete types; one-method interfaces take `-er` names; do not squat canonical names (`Read`, `Close`, `String`) unless signature matches (https://go.dev/wiki/CodeReviewComments)
- Receivers: short consistent abbreviations; pointer for mutation/mutex/large, value for small POD; never mix across methods (https://go.dev/wiki/CodeReviewComments)
- Error strings: lowercase start, no trailing punctuation, an origin prefix is good (`image: unknown format`) (https://go.dev/wiki/CodeReviewComments)
- Wrap with `fmt.Errorf("...: %w", err)` so `errors.Is/As` traverse; match via `errors.Is/As`, never `==`; `%w` is an API commitment - use `%v` for internal details (https://go.dev/blog/go1.13-errors)
- Check every returned error; never `_`-discard; failures as `(value, error)` with error last; return type `error`, not a concrete type (typed-nil trap) (https://go.dev/wiki/CodeReviewComments)
- Indent the error path: handle + return first, happy path unindented, no `else` after terminal branches (https://go.dev/wiki/CodeReviewComments)
- No panic for normal errors; `Must*` helpers only for init/startup; in tests `t.Fatal`, not panic )— lifecycle: doc comment start with the name, full sentence, period; ONE package comment above `package` (https://google.github.io/styleguide/go/decisions)
- `ctx context.Context` first parameter including test helpers; store ctx in struct - never; custom context types - never (https://go.dev/wiki/CodeReviewComments)
- Keep goroutine lifetimes obvious (ctx + `wg.Wait()`); goroutines leak on channel block; sends to closed channels panic (https://google.github.io/styleguide/go/decisions)
- Prefer nil slices (`var t []string`); emptiness via `len()`, never `== nil`; zero values usable without init (`bytes.Buffer`); `make` only for slices/maps/chans (https://go.dev/wiki/CodeReviewComments)
- `defer` release at acquisition; tests: got/want messages (`Foo(%q) = %d; want %d`), table-driven (https://go.dev/doc/effective_go)
- Keys/entropy: `crypto/rand`, never `math/rand` (https://go.dev/wiki/CodeReviewComments)

## Gotchas of this machine (NixOS)
- Go is NOT installed yet: `nix profile install nixpkgs#go` when needed (stable line 1.27.x as of 2026-10).
- GOPATH defaults to ~/go; GOPROXY=direct on proxy failures.
- Long watch processes live in tmux, not agent background.

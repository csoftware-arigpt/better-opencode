---
name: ux-ui-craft
description: Frontend craft - design system, typography, spacing, contrast, states and accessibility for web UI. Load when building or reviewing ANY user-facing interface - pages, dashboards, widgets, DOM-testing flows.
---

# UX/UI at the bench

## First principles (always)
- **Mobile-first**: lay out for 360-420px, then add `min-width` steps. Touch targets >= 44x44px; gaps between targets >= 8px.
- **Typography**: at most 2 fonts (system stack is fine: `system-ui`); scale 12/14/16/20/25/32/40; body line-height 1.5-1.6; line length 45-75 chars.
- **Spacing**: 4px grid, steps 4/8/12/16/24/32/48; remember margin-collapse, diagonal pills not allowed.
- **Color**: 60-30-10; a single accent; background vs text contrast >= 4.5:1 (WCAG AA); grey-on-black is not "grey text" - judge by contrast.
- **Theming via CSS custom properties**: `--bg`, `--fg`, `--accent`, `--danger`; `prefers-color-scheme` + a manual switch.
- **Motion**: respect `prefers-reduced-motion`; transitions <= 200ms, transform/opacity only.

## Component states (never forget)
idle -> loading (skeletons, not full-screen spinners) -> empty (meaningful empty) -> error (text + a way out) -> success. A missing state is a bug.

## Accessibility (minimum, no fanaticism)
- Semantic HTML first (button/nav/main/h3); aria only where semantics cannot save you.
- A label on every input; autocomplete on login/register fields; do not remove focus styles.
- Think of the keyboard: tab order is logical; esc closes the modal.

## Verification on this device
- Open: `termux-open index.html` (system browser); local server: `python -m http.server 8000 -d .` + `termux-open-url http://localhost:8000`.
- No headless browsers - after edits ask the user's eyes; but check yourself: HTML validity (by eye), tile sizing against CSS calc errors, no console.log litter in production code.
- A dev-server (vite/next) on the phone is heavy: default to plain html/css/js + esbuild (`npx esbuild` in an instant) if a bundle is required.

# gtex62-core — Project Instructions

## Role

This is the shared engine and provider library for all gtex62 Conky suites
(gtex62-osa, LCARS, Tech-HUD, Tri-HUD, Clean Suite). Changes here affect
every suite built on this engine.

## Two Repos — Always Separate

- Engine: `~/.config/conky/gtex62-core/`
- Active suite: `~/.config/conky/gtex62-osa/`

Commit and push each repo independently. Do not mix suite-specific code
into core, and do not put engine/provider code into a suite repo.

## Hard Rules

- Do not refactor while fixing a bug. Smallest safe change only.
- Do not rename files, dirs, or public paths unless explicitly requested.
- Commit messages: no Co-Authored-By or AI attribution lines.
- Changes to providers affect all suites — be conservative.

## Provider Pattern

```text
providers/<domain>/fetch_<domain>.sh <profile>
  → ~/.cache/gtex62-core/shared/<domain>/<profile>/
```

Profile TOML: `~/.config/gtex62-core/profiles/<domain>/<profile>.toml`
Example TOML: `examples/runtime/profiles/<domain>/<profile>.toml.example`

## Bootstrap Gap

When a new provider is added, its example TOML must be created under
`examples/runtime/` and bootstrap must be re-run to install the profile:

```bash
bash ~/.config/conky/gtex62-core/bin/gtex62-core-bootstrap-runtime
```

Missing profile TOML → 60s TTL fallback → meters appear frozen in suites.

## Full Project Docs

- `docs/architecture.md` — two-repo structure, provider pattern, cache layout, TTL table, design principles

## Key Paths

| Area | Path |
|---|---|
| Providers | `providers/<domain>/` |
| Launcher | `bin/gtex62-core-launch` |
| Example profiles | `examples/runtime/profiles/<domain>/` |
| Docs | `docs/` |
| Shared cache | `~/.cache/gtex62-core/shared/<domain>/<profile>/` |
| Runtime profiles | `~/.config/gtex62-core/profiles/<domain>/<profile>.toml` |

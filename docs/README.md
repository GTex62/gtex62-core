# Core Docs

This directory is the canonical home for shared core architecture, normalized
schemas, and future suite conversion references.

`gtex62-core` is the shared Lua/Conky foundation for gtex62 desktop suites.
See the rename roadmap for rationale, compatibility requirements, and the
staged migration plan from the previous `gtex62-conky-engine` name.

## Architecture

- [Architecture](architecture.md)
- [Next Generation Model](next-generation-model.md)
- [Core-Driven Suite Notes](core-driven-suite-notes.md)
- [gtex62 Core Rename Roadmap](gtex62-core-rename-roadmap.md)
- [V1 Audit and OSA Contract](v1-audit-and-osa-contract.md)

## Schemas

- [System Schema](system-schema.md)
- [Astro Schema](astro-schema.md)

## Tools

- `../scripts/generate_palette_pdf.py`: generates `docs/palette-reference.pdf`
  for engine-driven suites that declare `[theme].palette_catalog` and
  `[theme].palette_format` in `suite.toml`.

OSA-specific render/cache projection notes live in
`../../gtex62-osa/docs/`.

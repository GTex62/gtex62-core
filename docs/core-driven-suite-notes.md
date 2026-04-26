# Core-Driven Conky Suites Notes

This note captures the substantive architecture discussion from the Codex task `Discuss core-driven conky suites`, whose UI thread currently fails to render even though the local session data still exists.

## Core Rule

The core owns runtime and data.

The suite owns presentation and composition.

More concretely:

- Core defines how things work.
- Suite defines how things look and where they go.

## Scope

For core v1:

- `gtex62-osa` is the reference core-native suite.
- `gtex62-clean-suite`, `gtex62-lcars`, `gtex62-tech-hud`, and `gtex62-tri-hud` are legacy suites.
- Legacy suites should coexist with the core era, but they should not shape the initial core contract.

## Core Responsibilities

The core should own:

- path resolution
- suite discovery and registration
- core and suite compatibility checks
- launcher and process orchestration
- cache and data lifecycle
- shared collectors
- normalized shared datasets
- generic Lua helpers
- optional shared drawing primitives

The core should not parse or understand suite-specific layout schema.

It should not know about suite-local concepts such as OSA or LCARS chassis internals.

## Suite Responsibilities

Each suite should own:

- manifest and identity
- theme and palette defaults
- layout schema
- widget selection and composition
- suite-only assets
- optional suite-specific derived data

For OSA specifically, that means the repo should stay thin and focused on visual identity, panel composition, and suite-local rendering.

## Recommended Contract

The target contract discussed for core-native suites was:

- `suite manifest`: id, name, version, `core_requirement`, declared Conky instances, declared data needs, defaults
- `core runtime`: resolves paths, exports environment, validates compatibility, schedules collectors, launches instances
- `suite entrypoints`: theme, widget modules, optional suite hooks

The important part is that the core can launch a suite without needing to understand the suite's internal folder politics or rendering model.

## Data Model

The preferred data layering is:

1. Raw collector output
2. Normalized shared model
3. Suite-derived view data

That keeps weather, air, network, astronomy, and similar domains from being reimplemented in every suite.

The core should own fetching and normalization.

The suite should own rendering and any suite-specific transformation needed for its visual language.

## OSA as the First Proof

`gtex62-osa` should prove only the core-native contract, not legacy migration.

Success criteria discussed for OSA:

- install core once
- install `gtex62-osa` separately
- core discovers the suite through a manifest
- core validates `core_requirement`
- core manages XDG-style config, data, and cache roots
- core runs shared collectors and exposes normalized data
- `gtex62-osa` contributes suite config, layout, widgets, assets, and optional suite-specific transforms
- updating the suite should not require core changes unless the contract itself changes
- adding a second future core-native suite should mostly mean a new suite repo, not core surgery

## Migration Guidance

The lowest-risk migration path discussed was:

1. Build the core around paths, cache, registry, launcher, and collectors first.
2. Keep the first core-native suite thin, but let it still own all rendering and layout decisions.
3. Leave legacy suites standalone for now, or add compatibility shims later.
4. Only extract shared UI and drawing code after two or more core-native suites genuinely need the same primitive.

The recommendation was to treat the core as an operating substrate, not a UI framework.

## What Not To Centralize Early

The discussion specifically cautioned against centralizing these too early:

- palette catalogs unless they are truly shared
- suite scaffolds that encode one suite's structure
- suite widget composition
- suite-specific art direction
- anything that forces future suites into LCARS-shaped assumptions

## Repo Structure Implication For OSA

Keeping OSA theme files under `theme/` was considered the right core-native structure:

- `theme/osa-theme.lua`
- `theme/osa-layout.lua`
- `theme/panels.lua`

This keeps theme, layout, and panel definitions together and separates suite styling/config from Lua rendering code.

## Practical Summary

- Build the core as shared infrastructure, not as a shared visual framework.
- Keep OSA thin and core-native.
- Preserve a hard boundary between core concerns and suite concerns.
- Do not let legacy suite assumptions define core v1.

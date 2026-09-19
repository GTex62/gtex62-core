# gtex62-core

Shared Lua/Conky foundation for core-native gtex62 desktop suites.

Built for Conky; not affiliated with or part of the Conky project.

## Table of Contents

- [Purpose](#purpose)
- [Repository Boundary](#repository-boundary)
- [Runtime Roots](#runtime-roots)
- [Configuration Model](#configuration-model)
- [Provider Toggles](#provider-toggles)
- [Provider Model](#provider-model)
- [Bootstrap and Launch](#bootstrap-and-launch)
- [Shared Assets](#shared-assets)
- [Core-Native Suite Template](#core-native-suite-template)
- [Repository Layout](#repository-layout)
- [Docs](#docs)

## Purpose

`gtex62-core` is the common engine layer for new gtex62 Conky suites. It owns
the runtime conventions and shared data contracts so each suite can focus on
presentation instead of carrying duplicate providers, config examples, cache
helpers, fonts, and local setup files.

The first native consumer is [`gtex62-osa`](../gtex62-osa/README.md). OSA is the
reference suite for this model and should be used as the practical example for
future engine-driven suites.

## Repository Boundary

Core-owned concerns:

- runtime/config/cache root conventions
- runtime bootstrap templates
- suite launch and profile orchestration
- shared provider scripts
- normalized shared cache schemas
- common Lua helpers
- reusable diagnostics and status files
- conversion architecture for future core-native suites

Suite-owned concerns:

- visual identity
- panel composition
- theme and layout files
- suite-specific Lua drawing code
- suite-specific derived view models over engine cache
- Conky widget entrypoints
- suite-level documentation and visual references

Shared asset concerns:

- fonts
- wallpapers
- reusable icons
- shared data assets such as geo/coastline data

## Runtime Roots

Default engine roots:

```text
config  ~/.config/gtex62-core/
data    ~/.local/share/gtex62-core/
cache   ~/.cache/gtex62-core/
assets  ~/.config/conky/gtex62-shared-assets/
```

Suite repos remain under:

```text
~/.config/conky/<suite-name>/
```

Preferred environment variables:

- `GTEX62_CONFIG_DIR`
- `GTEX62_CACHE_DIR`
- `GTEX62_CORE_DIR`
- `GTEX62_SHARED_ASSETS`
- `GTEX62_SUITE_ID`

Compatibility aliases such as `GTEX62_CONKY_CACHE_DIR` may still be exported so
converted helpers keep working during the transition.

## Configuration Model

New users should normally edit one file first:

```text
~/.config/gtex62-core/site.toml
```

`site.toml` is the host/site-level source of truth for values shared by
multiple suites and providers:

- home location and timezone
- API keys
- network interface
- VLAN labels and hosts
- speedtest baseline/fallback tier
- aviation stations
- pfSense SSH target and interface mapping

Domain profiles live under:

```text
~/.config/gtex62-core/profiles/
```

Profiles are for per-domain overrides. They should inherit from `site.toml`
where practical so a new install does not require editing many files.

Suite bindings live under:

```text
~/.config/gtex62-core/suites/
```

For example, OSA uses:

```text
~/.config/gtex62-core/suites/osa.toml
```

To turn providers on or off, see [Provider Toggles](#provider-toggles) — that
is a separate file, `core.toml`, not `site.toml`.

## Provider Toggles

Which providers run is controlled in three different places, depending on the
domain. `site.toml` is not one of them.

### `core.toml [providers]` — opt-in domains

```text
~/.config/gtex62-core/core.toml
```

| Flag | Domain | Also requires |
| --- | --- | --- |
| `vpn`, `ap`, `modem`, `alerts`, `mtr`, `pihole` | VPN, AP, MODEM, ALERTS, MTR, PIHOLE | The launching suite lists the domain in its own `suites/<id>.toml` `[domains]` |
| `media` | MEDIA (lyrics) | — |
| `[providers.pfsense]` `status`, `router`, `pfblockerng`, `ifaces` | PFSENSE sub-caches | — |

- **Dual-gated** (`vpn`/`ap`/`modem`/`alerts`/`mtr`/`pihole`): the flag **and**
  the launching suite's `[domains]` `required`/`optional` list must both name
  the domain. `core.toml` is one global file, so the suite list is what keeps a
  suite with no consumer for these from polling a modem, VPN, AP or Pi5 for
  nothing.
- **Flag-only** (`media` and the `[providers.pfsense]` sub-flags): the flag
  alone decides.
- All flags ship `false` in `core.toml.example`. A missing `core.toml`, missing
  section or missing key counts as `false` — everything this file governs is
  off.
- Flipping a flag to `false` stops that domain's fetch loop entirely.

Pi-hole is a top-level `[providers]` flag, not a `[providers.pfsense]` one, even
though it borrows the pfSense profile's `[pihole]` section and cache directory —
it runs on a separate host with its own script and SSH gate.

To enable one, for example MTR under SitRep:

```toml
# core.toml
[providers]
mtr = true
```

```toml
# suites/sitrep.toml
[domains]
required = ["pfsense", "vpn", "ap", "modem", "alerts", "mtr"]
```

### Profile `enabled` — everything else

AIR, ASTRO, AVIATION, CALENDAR, CONNECT, NET, NETWORK, SOLAR, SYSTEM, TIME and
WEATHER have no `core.toml` entry. Each is turned off through the `enabled` key
in its own profile:

```text
~/.config/gtex62-core/profiles/<domain>/<profile>.toml
```

```toml
enabled = false
```

The launcher still runs the loop; the fetch script sees `enabled` is anything
other than `true`, writes `state:"disabled"` to its `status.json` and exits.
These profiles ship `enabled = true`, and a missing profile file counts as
enabled. The profile TOMLs are installed by `gtex62-core-bootstrap-runtime`
from `examples/runtime/profiles/*.toml.example`.

### `core.toml` is partial on purpose

`core.toml [providers]` does not list every domain, and it is not going to. Those
eleven domains are universal infrastructure: every suite needs them, so there is
no "does this suite use it?" question to gate on. Listing them in `core.toml` as
well would keep two live copies of the same on/off state — one in the profile,
one in `core.toml` — that can disagree. The domains that do get a `core.toml`
flag are the ones where running them is a per-install, per-suite decision.

The domains in `core.toml` also honor their own profile `enabled` key, which
works the same way as above. The `core.toml` flag is the one that stops the loop.

### Special cases

- **GITHUB** has no `core.toml` flag and no launcher path at all. It runs from
  a systemd timer (`gtex62-github-traffic.timer`), and its only toggle is
  `enabled` in `profiles/github/<profile>.toml`, which ships `false`.
- **ORB** currently has no disable mechanism at all — no `core.toml` flag and
  no profile `enabled` key. It always runs. Open item.
- **MTR** ships with `profiles/mtr/pi5.toml.example` set to `enabled = false`;
  a missing MTR profile is treated as disabled.

## Provider Model

Providers write normalized cache below:

```text
~/.cache/gtex62-core/shared/<domain>/<profile>/
```

Suites should read the shared cache and render their own compact view models.
Provider scripts should not live in suite repos unless the logic is truly
suite-specific.

Current provider domains include:

- `air`
- `alerts`
- `ap`
- `astro`
- `aviation`
- `calendar`
- `connectivity`
- `github`
- `media`
- `modem`
- `mtr`
- `net`
- `network`
- `orb`
- `pfsense`
- `solar` — UV index and shortwave radiation via Open-Meteo (no key required);
  geometric synthetic model as fallback
- `system`
- `time`
- `vpn`
- `weather`

Provider status files use the same basic shape:

```json
{
  "state": "ok",
  "profile": "local",
  "collector": "system",
  "generated_at": "2026-04-30T00:00:00Z",
  "note": ""
}
```

Suites can surface those status files inline instead of dedicating a whole
doctor widget to normal operation.

## Bootstrap and Launch

Runtime templates live in:

```text
examples/runtime/
```

Bootstrap helper:

```bash
bin/gtex62-core-bootstrap-runtime
```

Suite wrappers can delegate to it. OSA does this from:

```text
gtex62-osa/scripts/bootstrap-runtime-root.sh
```

Core-only bootstrap (no suite installed):

```bash
scripts/bootstrap-runtime-root.sh
```

Builds `~/.config/gtex62-core/` standalone, with no suite dir passed — suite-specific
templates (e.g. `suites/osa.toml`) are skipped automatically when no suite is
present. Use this for a core-only setup, or for a future core-native suite before
its own bootstrap wrapper exists. Pass `--suite-dir <path>` (as suite wrappers do)
to also install that suite's binding.

Core launcher:

```bash
bin/gtex62-core-launch --suite <suite_id>
```

Suite `start-conky.sh` scripts should prepare suite-specific environment
values, optionally apply wallpaper/theme choices, and then hand off to the core
launcher.

Consolidated suite dispatcher (planned — see `docs/core-launcher-design.md`):
`bin/gtex62-conkystart` will be installed and updated by bootstrap, replacing today's
untracked personal `~/.local/bin/conkystart`. Bootstrap does not create a symlink for
it. Anyone who wants to invoke it by name instead of full path can add one themselves:

```bash
ln -s ~/.config/conky/gtex62-core/bin/gtex62-conkystart ~/.local/bin/conkystart
```

Running the script directly, unlinked, works identically — the symlink is optional
convenience, not a required setup step.

## Shared Assets

Shared binary and data assets belong in:

```text
~/.config/conky/gtex62-shared-assets/
```

Expected subdirectories:

```text
fonts/
icons/
wallpapers/
data/
```

Suites should reference shared assets through `suite.toml` and the
`GTEX62_SHARED_ASSETS` environment variable rather than carrying duplicate
`assets/`, `fonts/`, or `wallpapers/` trees.

To install all shared fonts into `~/.local/share/fonts/` and rebuild the font
cache, run the font helper (optional, but required fonts for each suite must be
installed):

```bash
bash scripts/install-fonts.sh
```

The script is idempotent and writes a manifest at
`~/.local/share/fonts/.gtex62-core-fonts.manifest`. Specific required fonts for
each suite are documented in that suite's README.

## Core-Native Suite Template

A core-native suite should generally look like this:

```text
gtex62-example-suite/
├── suite.toml
├── README.md
├── design/
├── docs/
├── lua/
│   ├── suite/
│   ├── ui/
│   └── widgets/
├── scripts/
├── theme/
└── widgets/
```

Suite README responsibilities:

- describe the visible suite and panel/widget map
- list suite entrypoints
- document suite-owned customization files
- link to this core README for runtime/config/provider behavior
- document only suite-specific troubleshooting

Core README responsibilities:

- runtime roots
- `site.toml` and profile model
- provider/cache contracts
- bootstrap/launcher behavior
- conversion rules for future suites

Avoid in new suite repos:

- `legacy/config/`
- provider scripts duplicated from core
- runtime `examples/`
- local copies of shared fonts, wallpapers, icons, or shared data assets
- large architecture sections copied from core docs

## Repository Layout

```text
gtex62-core/
├── bin/          # bootstrap and suite launcher entrypoints
├── docs/         # architecture, schemas, migration notes
├── examples/     # runtime templates copied into ~/.config/gtex62-core
├── lua/          # common Lua helpers
├── providers/    # shared provider scripts by domain
└── scripts/      # shared setup helpers (font install, palette generation)
```

## Docs

- [Architecture](docs/architecture.md)
- [Next Generation Model](docs/next-generation-model.md)
- [Core-Driven Suite Notes](docs/core-driven-suite-notes.md)
- [gtex62 Core Rename Roadmap](docs/gtex62-core-rename-roadmap.md)
- [V1 Audit and OSA Contract](docs/v1-audit-and-osa-contract.md)
- [System Provider Status](docs/system-provider-status.md)
- [Astro Provider Status](docs/astro-provider-status.md)

OSA-specific render/cache notes live in the OSA repo:

- [gtex62-osa README](../gtex62-osa/README.md)
- [OSA Docs](../gtex62-osa/docs/README.md)

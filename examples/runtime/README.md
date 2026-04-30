# Runtime Templates

These files are example templates for the core runtime root.

They are intended to be copied into:

- `~/.config/gtex62-core/`

The bootstrap helper:

- `bin/gtex62-core-bootstrap-runtime`

copies these templates into the local runtime root, fills in machine-local path placeholders, and avoids overwriting existing files unless `--force` is used.

These templates are safe to commit because they do not contain live credentials.

Most new installs should edit `site.toml` first. It contains shared local facts
that multiple providers need:

- home latitude, longitude, and timezone
- OpenWeather and AirNow API keys
- primary network interface
- VLAN labels and gateway hosts
- speedtest tier and optional server id
- aviation station ids
- pfSense SSH target

The profile files under `profiles/` are still supported, but they are now mostly
domain-specific overrides. Provider profiles win when a value is set there;
otherwise the core providers fall back to `site.toml`.

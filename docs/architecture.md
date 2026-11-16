# Architecture

## Goals

- Uniform check contract (NHC-style) that is trivial to extend.
- Native OpenNebula integration: emit IM monitoring attributes.
- Actions only in a central controller; the probe stays read-only.
- No gems and no extra daemons on the hypervisor.

## Components

### Probe (host)

`one-nhc probe` runs the enabled checks and prints `KEY="VALUE"` attributes:

```text
NHC_STATUS="CRIT"
NHC_CHECK_COUNT="3"
NHC_DATASTORE_MOUNTS="CRIT"
NHC_DATASTORE_MOUNTS_MSG="/var/lib/one/datastores missing"
```

The wrapper `probes/kvm-probes.d/host/one_nhc.rb` delegates to the binary. It is
installed in the frontend remotes and synced to the hosts with `onehost sync`.

The probe must be fast because it runs on every monitoring cycle. Heavy checks
(SMART, RAID scrub, NFS write test) will run from a timer (M2) and the probe
will read their cached result.

### CLI

`one-nhc check` prints the human report. `--json` is meant for automation,
`--only` selects checks and `-c` picks a configuration file.

### Controller (M2, frontend)

Reads `MONITORING/NHC_STATUS` for every host through the official Ruby bindings
(`OpenNebula::Client`, `HostPool`), applies hysteresis (N consecutive `CRIT`)
and a cooldown, then calls `onehost disable` / `onehost enable`. It must refuse
to disable the last healthy host.

## Check contract

Every check is registered with `OneNHC.check` and receives a `Context`:

```ruby
OneNHC.check(id: "x", description: "...", severity: :crit, timeout: 5) do |ctx|
  ctx.crit!("message", metrics: { "k" => 1 })
end
```

Helpers: `ok!`, `warn!`, `crit!`, `skip!`, `unknown!`. The first call ends the
check.

Rules:

- `SKIP` means "not applicable" (for example, no InfiniBand hardware) and never
  quarantines.
- `UNKNOWN` means "could not determine" (timeout or unexpected error).
- Checks must be read-only and must not hang: every check has a timeout.

## Status mapping

| one-nhc | IM attribute |
|---------|--------------|
| ok      | OK           |
| warn    | WARN         |
| crit    | CRIT         |
| skip    | SKIP         |
| unknown | UNKNOWN      |

`NHC_STATUS` is the worst status (`crit` > `warn` > `unknown` > `ok`; `skip` is
ignored unless every check was skipped).

## Portability

- Prefer `sysfs`/`procfs` over vendor CLIs, which change between versions.
- Detect capabilities and report `SKIP` when a tool or the hardware is absent.
- Never fail a check because an optional tool is missing.

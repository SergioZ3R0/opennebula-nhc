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
NHC_TIMESTAMP="1794909479"
NHC_CHECK_COUNT="3"
NHC_DATASTORE_MOUNTS="CRIT"
NHC_DATASTORE_MOUNTS_MSG="/var/lib/one/datastores missing"
```

The wrapper `probes/kvm-probes.d/host/system/one_nhc.rb` delegates to the binary. It is
installed in the frontend remotes and synced to the hosts with `onehost sync`.

The probe must be fast because it runs on every monitoring cycle. Heavy checks
(`smart`, `gpu-fabric`) declare `heavy: true` and a TTL: the probe reads
`/var/lib/one-nhc/cache.json`, `one-nhc cache` runs them and writes the cache
atomically, and the `one-nhc-cache.timer` refreshes it. A missing or stale entry
is reported as `UNKNOWN`, never `CRIT`, so a missing timer cannot quarantine a
host. The GPU count (`gpu`) is fast and runs on every probe cycle; only Fabric
(`gpu-fabric`) is cached.

### CLI

`one-nhc check` prints the human report and runs heavy checks on demand.
`one-nhc cache` refreshes the heavy-check cache. `--json` is meant for
automation, `--only` selects checks and `-c` picks a configuration file.

### Controller (frontend)

`one-nhc controller` runs on the OpenNebula frontend and is the only component
that loads the official Ruby bindings. It reads `TEMPLATE/NHC_STATUS` for every
host through `OpenNebula::Client` and `HostPool`, applies hysteresis and a
cooldown, and then:

| Mode | Effect |
|---|---|
| `monitor` | log only (default) |
| `notify` | log and notify (command and/or webhook) |
| `act` | notify and `onehost disable/enable` (unless `dry_run`) |

Safety: only `CRIT` starts the counter (`SKIP`, `WARN` and `UNKNOWN` never
quarantine), counters advance once per distinct `NHC_TIMESTAMP` sample (not per
controller cycle), decisions are announced once per episode, and the controller
refuses to disable when fewer than `min_healthy_hosts` healthy monitored hosts
would remain. It also tracks whether it disabled each host, so an operator
enabling a host outside one-nhc resets the state instead of fighting the
operator.

A disabled host is not monitored, so its monitoring attributes do not change.
`reenable_after` optionally enables it again after a delay as a trial, and
`monitor_grace` ignores the stale `CRIT` value until the probe has had time to
report fresh data.

State lives in `/var/lib/one-nhc/state.json` and is written atomically. A lock
file next to it keeps a single controller per state, so the systemd timer and a
manual `--watch` cannot run at the same time. The systemd timer runs `--once
--quiet` every two minutes; `--watch` runs the same loop in the foreground.

Notifications go to a command, a JSON webhook and/or email. The email body is
rendered from the host `NHC_*` attributes (summary counts and the failed
checks) as HTML plus a plain-text alternative. Email uses either an
authenticated SMTP relay (credentials from `password_file` or `password_env`,
never from the YAML) or a local MTA through `transport: sendmail`, which needs
no credentials. `one-nhc notify-test` sends a test message without waiting for
a host failure.

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

## Targeting

Every check can be scoped to hosts with clush/dsh-style hostlists:

```yaml
groups:
  gpu: "gpu[01-02]"
checks:
  infiniband:
    hosts: "@gpu"
    exclude: "gpu02"
```

The probe evaluates the expression against the local node name (the short
hostname, `node_name` in the config, or the `ONE_NHC_NODE` environment
variable). A check that is not targeted is not executed and not reported, so
monitoring does not fill with `SKIP` for checks that do not apply.

Monitoring attributes persist until `HOST_MONITORING_EXPIRATION_TIME`. When
targeting changes, set `report_not_targeted: true` to emit
`NHC_<ID>="SKIP"` with a "not targeted" message and clear the previous value.

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

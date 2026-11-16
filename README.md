# opennebula-nhc

NHC-style health checks for OpenNebula hypervisors, with native Information
Manager output and an optional quarantine controller.

> **Community project.** Not affiliated with, endorsed by, or sponsored by
> OpenNebula Systems.

## Why

OpenNebula monitoring (IM) reports CPU, RAM and datastore usage, but it does not
tell you whether a hypervisor is *healthy*: a filesystem remounted read-only, a
missing or stale datastore mount, a dead libvirt, a degraded RAID array, SMART
errors or a broken InfiniBand port.

`opennebula-nhc` fills that gap with a small, uniform set of checks inspired by
the classic HPC Node Health Check (NHC) and designed to plug into OpenNebula:

- **Probe (host)** runs the checks and emits `NHC_*` attributes that the
  Information Manager merges into the host `MONITORING INFORMATION`.
- **CLI** gives human and JSON output for manual checks and automation.
- **Controller (roadmap)** applies hysteresis on the frontend and quarantines
  unhealthy hosts with `onehost disable/enable`.

## Architecture

```text
 host hypervisor                         frontend (oned)
+-----------------------------+        +------------------------------+
| one-nhc probe               |        | one-nhc controller (M2)      |
|  checks.d/*.rb              |  MON   |  reads NHC_STATUS from       |
|  -> NHC_STATUS="..."        | -----> |  onehost show, hysteresis,   |
|  (kvm-probes.d/host)        |        |  onehost disable/enable      |
+-----------------------------+        +------------------------------+
```

The probe must be fast because it runs on every monitoring cycle. Slow checks
(RAID scrub, SMART, NFS write test) are planned to run from a timer and be
served from a cache.

## Requirements

- Ruby, which OpenNebula hypervisors already ship for the IM probes.
- No gems: the probe uses the Ruby standard library only.

## Quick start

```bash
git clone https://github.com/SergioZ3R0/opennebula-nhc.git
cd opennebula-nhc

./bin/one-nhc list
./bin/one-nhc check        # human report
./bin/one-nhc probe        # OpenNebula IM attributes
./bin/one-nhc check --json # machine readable
```

## Install

```bash
sudo make install   # /usr/local/bin/one-nhc, /usr/local/lib/one-nhc, /etc/one-nhc
sudo make probe     # installs the IM probe wrapper
```

Then, on the OpenNebula frontend:

```bash
onehost sync --admin
# attributes appear after the next monitoring cycle
onehost show <host-id> | grep NHC_
```

## Checks

| Check              | Severity | What it detects                                            |
|--------------------|----------|------------------------------------------------------------|
| `fs-ro`            | crit     | real filesystems remounted read-only                       |
| `datastore-mounts` | crit     | datastore mounts missing, not writable or not a mountpoint |
| `libvirt`          | crit     | libvirt/qemu not responding to `virsh`                     |

Statuses: `OK`, `WARN`, `CRIT`, `SKIP` (not applicable) and `UNKNOWN` (could not
determine). `SKIP` never triggers a quarantine.

## Configuration

`/etc/one-nhc/one-nhc.conf` is YAML and is merged with the built-in defaults:

```yaml
proc_mounts: /proc/mounts
checks:
  fs-ro:
    enabled: true
    allowlist: [/snap, /var/lib/snapd/snap]
  datastore-mounts:
    enabled: true
    mounts:
      - {path: /var/lib/one/datastores, must_be_mount: false}
  libvirt:
    enabled: true
    uri: qemu:///system
    timeout: 6
```

## Simulating failures

```bash
# Pretend /data is read-only.
printf 'proc /proc proc rw 0 0\n/dev/sdb1 /data ext4 ro 0 0\n' > /tmp/mounts
cat > /tmp/demo.conf <<EOF
proc_mounts: /tmp/mounts
checks:
  fs-ro: {enabled: true}
  datastore-mounts: {enabled: false}
  libvirt: {enabled: false}
EOF
./bin/one-nhc check -c /tmp/demo.conf   # -> CRIT
```

## Safety

The probe is read-only: it never modifies the host. Any action (quarantine,
evacuation) belongs to the controller, which must implement hysteresis,
cooldowns, `--dry-run` and must never disable the last healthy host.

## Roadmap

- **M1 (this):** probe framework, 3 checks, human/JSON/IM adapters.
- **M2:** frontend controller with hysteresis and `onehost disable/enable`.
- **M3:** hooks, notifications and optional evacuation.
- **M4:** docs/blog and an upstream docs PR.

## Development

```bash
make test   # ruby -Ilib -Itests tests/run.rb
```

## Contributors

See [CONTRIBUTORS](CONTRIBUTORS).

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

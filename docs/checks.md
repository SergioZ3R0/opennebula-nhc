# Checks, heavy checks and the cache

This document is the contract for check authors and operators. It explains why
there are two kinds of checks, how the probe, the cache and the controller fit
together, and how to add a new check without breaking the monitoring cycle.

## Goals

- The probe runs inside the OpenNebula Information Manager on every
  `SYSTEM_HOST` cycle (600 s by default). It must be **fast**, **read-only** and
  must never block host monitoring.
- Every check has a hard timeout and finishes with `OK`, `WARN`, `CRIT`, `SKIP`
  or `UNKNOWN`.
- Slow, privileged or potentially blocking work is isolated in a **per-host
  cache** refreshed by a systemd timer.
- A stale cache is reported as `UNKNOWN`, never `CRIT`. It must never quarantine
  a host.

## The two kinds of checks

| | Fast check | Heavy check |
|---|---|---|
| Runs in | `one-nhc probe` (every monitoring cycle) | `one-nhc cache` (systemd timer) |
| Data source | sysfs/procfs, one small command | SMART, GPU Fabric, NFS write test, RAID scrub, firmware inventory |
| Typical duration | < 1 s | seconds to minutes |
| Privileges | `oneadmin` | may need `root`/`sudo` |
| Freshness | every probe sample | up to the check TTL |
| Probe behaviour | executed | read from the cache; missing/stale → `UNKNOWN` |
| Metadata | `heavy: false` (default) | `heavy: true, ttl: <seconds>` |

### Current fast checks

`fs-ro`, `datastore-mounts`, `libvirt`, `fs-usage`, `network-interface`,
`infiniband`, `service`, `raid`, `gpu` (count only) and `ofed-version`.
`ofed-version` carries the `network` tag, so it appears in the Network group in
grouped emails.

### Current heavy checks

| Check | TTL | Why |
|---|---|---|
| `smart` | 1800 s | `smartctl` can take seconds per disk and often needs root |
| `gpu-fabric` | 1800 s | `nvidia-smi -q` per GPU is expensive |

`gpu` is deliberately **fast**: it only runs `nvidia-smi -L`, so a GPU that
disappears is detected in the next probe sample. It counts physical GPUs and,
by default, MIG partitions (`count_mig: true`); set `count_mig: false` to count
only physical GPUs. Only Fabric is cached.

Future heavy candidates: NFS write tests, RAID scrub status, firmware inventory.

## Why not run heavy checks in the probe?

- The IM cycle has a deadline. A slow check delays all host monitoring.
- `smartctl` can take seconds per disk; `nvidia-smi -q` scales with the number
  of GPUs; NFS can hang.
- Repeating heavy I/O every 10 minutes is wasteful. Disk health and Fabric
  status do not change that fast.
- SMART often needs `root`/`CAP_SYS_RAWIO`; the probe runs as `oneadmin` and
  should not need extra privileges.
- A timeout in the probe can make the host look unhealthy for the wrong reason.

The cache separates the cadence: the probe stays cheap and the heavy work runs
on its own schedule.

## Cache lifecycle

```text
host hypervisor
  one-nhc-cache.timer (every 15 min)
        |
        v
  one-nhc cache --quiet  --->  /var/lib/one-nhc/cache.json
                                      ^
                                      |
  OpenNebula IM (SYSTEM_HOST) ---> one-nhc probe ---> reads cache
                                      |
                                      v
                               NHC_* attributes in oned

frontend
  one-nhc controller ---> reads NHC_STATUS ---> notify / disable / enable
```

1. `one-nhc cache` selects the enabled and targeted **heavy** checks, runs them
   and writes the cache atomically.
2. `one-nhc probe` runs the fast checks and, for each heavy check, calls
   `Cache#result(id, ttl:)`.
3. A fresh entry is returned as a normal `Result`; its message gets a
   `(cached <N>s ago)` suffix.
4. A missing, stale or corrupt entry becomes
   `UNKNOWN` with `heavy check cache missing or stale`.
5. `UNKNOWN` never triggers a quarantine: the controller only acts on `CRIT`.
6. `one-nhc check` runs heavy checks **directly**, bypassing the cache, for
   manual diagnostics.
7. `one-nhc cache --quiet` refreshes the cache without output;
   `one-nhc cache --json` prints the results.

The cache is rewritten from each run. A heavy check that is disabled or no
longer targeted is removed from the file. Use `report_not_targeted: true` to
clear its old `NHC_*` attribute immediately instead of waiting for
`HOST_MONITORING_EXPIRATION_TIME`.

## Cache file

Default path: `/var/lib/one-nhc/cache.json` (`cache_file` in the config).

```json
{
  "schema_version": 1,
  "generated_at": 1794946094,
  "host": "node1",
  "checks": {
    "smart": {
      "id": "smart",
      "status": "OK",
      "message": "2 disk(s) SMART healthy",
      "metrics": { "disks": 2 },
      "at": 1794946094
    },
    "gpu-fabric": {
      "id": "gpu-fabric",
      "status": "OK",
      "message": "4 GPU(s) Fabric healthy",
      "metrics": { "gpus": 4 },
      "at": 1794946094
    }
  }
}
```

- `schema_version` is written by `one-nhc cache`. Legacy files without it are
  still accepted; a different schema version is ignored and treated as a stale
  cache until the next refresh.
- `at` is per check; `ttl` is a property of the check, not stored in the file.
- Writes are atomic: temporary file + rename.
- The cache is local to each host and contains no secrets.
- `StateDirectory=one-nhc` creates `/var/lib/one-nhc` with mode `0750` and
  owner `oneadmin`.
- A missing or corrupt file is treated as an empty cache. The probe reports
  heavy checks as `UNKNOWN`; the next `one-nhc cache` repairs it.

## TTL and timer

- `smart`: `ttl: 1800`; `gpu-fabric`: `ttl: 1800`.
- `one-nhc-cache.timer`: every 15 minutes, first run 5 minutes after boot.
- Keep `ttl >= timer interval + margin`. If the timer takes longer than the TTL,
  the probe will see stale data before the next refresh and report `UNKNOWN`.
- If you change a TTL, adjust the timer in `systemd/one-nhc-cache.timer`.
- If the timer is stopped or broken, heavy checks go `UNKNOWN`; the host is not
  quarantined.

## Fast or heavy? Decision guide

Make the check **heavy** if any of these is true:

- It can take more than roughly one second, or scales with disks/GPUs/nodes.
- It needs `root`/`sudo` or a privileged device.
- It can block on network or slow storage (NFS, SMART, scrub).
- Its data changes slowly and 15–30 minutes of staleness is acceptable.

Keep it **fast** if:

- It reads sysfs/procfs or runs one small command.
- It does not need privileged access.
- Freshness matters on every probe sample (GPU count, filesystem usage,
  InfiniBand state, network link state).
- It can be made safe with a hard timeout.

If in doubt, keep it fast with a tight timeout; if it can hang or needs
privileges, make it heavy and cache it.

## Adding a check

1. Create `checks.d/<NN>-<id>.rb`.
2. Register it with the uniform contract:

```ruby
OneNHC.check(
  id: "example",
  description: "What it detects",
  severity: :crit,
  timeout: 5,
  tags: %w[storage],
  heavy: false,
  ttl: 0
) do |ctx|
  # ...
  ctx.ok!("message")
end
```

For a heavy check:

```ruby
OneNHC.check(
  id: "nfs-write",
  description: "NFS datastore accepts a small write",
  severity: :crit,
  timeout: 30,
  heavy: true,
  ttl: 3600,
  tags: %w[storage]
) do |ctx|
  # ...
end
```

`ttl` defaults to `1800` when `heavy: true` and `ttl` is `0`.

3. Follow the rules:
   - Read-only. Never modify the host.
   - Use `OneNHC::Shell.capture` with a hard timeout. Never use backticks,
     `system` or unbounded `Open3`.
   - Use `OneNHC::Shell.which` before optional commands.
   - `skip!` when the hardware or tool is not applicable.
   - `unknown!` when the state cannot be determined.
   - `crit!` only for a configured resource that is actually unhealthy.
   - Never put secrets in commands or messages.
4. Add tests:
   - Use sysfs/procfs fixtures or stub `OneNHC::Shell.which` and
     `OneNHC::Shell.capture`.
   - Do not depend on real hardware, GPUs, SMART or InfiniBand.
5. Add a commented example to `etc/one-nhc.conf` and a row to the README table.
6. For heavy checks:
   - Set `heavy: true` and a `ttl`.
   - Make sure the cache timer interval is shorter than the TTL.
   - Test `one-nhc cache` and `one-nhc probe` with the cache.
   - Test that a missing cache produces `UNKNOWN`, not `CRIT`.
   - Document privileges (`sudo`, device access) and what happens without them.
7. Run `make test` and `./scripts/check-style.sh`.
8. Update this document and `docs/architecture.md` if you change the contract.

## Systemd units

| Unit | Where | What |
|---|---|---|
| `one-nhc-cache.service` + `.timer` | every hypervisor | `one-nhc cache --quiet` every 15 minutes |
| `one-nhc-controller.service` + `.timer` | OpenNebula frontend | `one-nhc controller --once --quiet` every 2 minutes |

Install the cache timer on each host:

```bash
sudo make install
sudo make install-cache-systemd
sudo systemctl daemon-reload
sudo systemctl enable --now one-nhc-cache.timer

systemctl list-timers one-nhc-cache.timer
journalctl -u one-nhc-cache.service -n 50
```

The cache service runs as `oneadmin` and uses `StateDirectory=one-nhc`.
`SuccessExitStatus=0 1 2 3` is intentional: `one-nhc cache` exits with the worst
check status (OK/WARN/CRIT/UNKNOWN) after writing the cache. Check statuses are
expected; operational errors still appear in the journal.

Do not run the cache timer on the frontend unless the frontend is also a
hypervisor. The controller timer is a frontend unit.

## Simulation and tests

There are two layers:

1. **Unit tests** (`tests/test_*.rb`) stub `OneNHC::Shell` or use temporary
   sysfs/procfs fixtures. They are fast and do not need hardware.
2. **Integration simulator** (`tests/test_integration_checks.rb`) runs the real
   `one-nhc` binary as a subprocess with:
   - a fake `PATH` containing `df`, `smartctl`, `nvidia-smi`, `systemctl`,
     `pgrep`, `virsh` and `rpm`,
   - fake sysfs trees for network, InfiniBand and md,
   - a fake `mdstat` and `proc_mounts`.

   It asserts that **every check reports `OK`** in the healthy simulation,
   that **each check can report `CRIT`** when its condition is broken, and that
   the heavy cache path works (`cache` → `probe` → `OK`; missing cache →
   `UNKNOWN`; fast `gpu` count still `OK` without cache).

`make test` runs both. When you add a check, extend the simulator with its
healthy and failing cases if it depends on sysfs or external commands.

## Troubleshooting

### A heavy check is UNKNOWN in `onehost show`

1. Is the timer installed and running?

   ```bash
   systemctl list-timers one-nhc-cache.timer
   journalctl -u one-nhc-cache.service -n 50
   ```

2. Does the cache file exist and have the right owner/path?

   ```bash
   ls -la /var/lib/one-nhc/cache.json
   cat /var/lib/one-nhc/cache.json
   ```

3. Does `one-nhc cache` work manually?

   ```bash
   one-nhc cache -c /etc/one-nhc/one-nhc.conf
   ```

4. Is the check enabled and targeted at this node?

   ```bash
   one-nhc check -c /etc/one-nhc/one-nhc.conf --only smart
   ```

5. Is the cache older than the TTL? Refresh it.

### SMART permission denied

`smartctl` often needs root. Either:

- set `smart.sudo: true` and add a sudoers rule (adjust the path to the output
  of `command -v smartctl`):

  ```text
  oneadmin ALL=(root) NOPASSWD: /usr/sbin/smartctl -H *
  ```

- or run the cache service with the privileges your disks need and make sure
  `/var/lib/one-nhc` and the cache file remain readable by `oneadmin`.

A permission problem is reported as `UNKNOWN`, never `CRIT`.

### `gpu` is CRIT but `gpu-fabric` is OK

That is expected: `gpu` checks the count on every probe, while Fabric is cached.
A missing GPU (or a MIG partition, when `count_mig` is enabled) is detected in
the next probe sample; Fabric can be up to its TTL old.

### Cache is corrupt or from another schema

Delete or rewrite it with `one-nhc cache`. The probe treats a corrupt file as an
empty cache and reports `UNKNOWN` for heavy checks until it is repaired. The same
happens when `schema_version` does not match: the file is ignored, not trusted.

### Clock skew

If a cached `at` is in the future, the age is negative and the entry is treated
as stale. The probe reports `UNKNOWN`; fix the host clock.

## Design decisions and limitations

- The cache is **per host** and local. There is no distributed cache.
- Heavy results can be up to the TTL old. Choose TTLs accordingly.
- The cache has no history and no signatures. It is a local, oneadmin-owned file
  with no secrets.
- Fast checks are limited by `SYSTEM_HOST` (600 s by default). Lower it in
  `/etc/one/monitord.conf` for faster detection.
- The controller has its own hysteresis (`consecutive_crit`/`consecutive_ok`).
  The probe attribute changes on the next sample; notification/quarantine waits
  for the configured number of samples.
- `UNKNOWN` and `SKIP` never trigger a quarantine.

## See also

- [Architecture](architecture.md)
- [Production runbook](runbook.md)
- [Contributing](../CONTRIBUTING.md)
- [README](../README.md)

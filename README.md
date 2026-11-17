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
- **Controller (frontend)** applies hysteresis on the frontend and, depending on
  the configured mode, notifies or quarantines unhealthy hosts with
  `onehost disable/enable`.

## Architecture

```text
 host hypervisor                         frontend (oned)
+-----------------------------+        +------------------------------+
| one-nhc probe               |        | one-nhc controller           |
|  checks.d/*.rb              |  MON   |  reads NHC_STATUS from       |
|  -> NHC_STATUS="..."        | -----> |  TEMPLATE, hysteresis,       |
|  (kvm-probes.d/host/system) |        |  cooldown, notify/disable    |
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
# On every hypervisor and on the frontend:
sudo make install

# On every hypervisor: refresh the heavy checks (smart, gpu) every 15 minutes
sudo make install-cache-systemd
sudo systemctl daemon-reload
sudo systemctl enable --now one-nhc-cache.timer

# On the frontend (installs the wrapper in the IM remotes):
sudo make probe

# On the frontend: push the wrapper to the hosts
onehost sync --force --ssh

# Optional: refresh the host monitoring now
onehost forceupdate <host-id>
onehost show <host-id> | grep NHC_
```

The wrapper lives in `kvm-probes.d/host/system`, so attributes refresh on the
`SYSTEM_HOST` cycle (600s by default). Lower it in `/etc/one/monitord.conf`
(for example `SYSTEM_HOST = 120`) if you need faster health checks.

### Controller (frontend, optional)

The controller only runs on the frontend and uses the OpenNebula Ruby
bindings. It starts in `monitor` mode, so it is safe to install and observe
before you let it notify or act.

```bash
# On the frontend:
sudo make install-systemd
sudo systemctl daemon-reload
sudo systemctl enable --now one-nhc-controller.timer
journalctl -u one-nhc-controller.service -f
```

The timer runs `one-nhc controller --once --quiet` every two minutes. For a foreground
loop instead, run `one-nhc controller --watch`.

## Checks

| Check              | Severity | What it detects                                            |
|--------------------|----------|------------------------------------------------------------|
| `fs-ro`            | crit     | real filesystems remounted read-only                       |
| `datastore-mounts` | crit     | datastore mounts missing, not writable or not a mountpoint |
| `libvirt`          | crit     | libvirt/qemu not responding to `virsh`                     |
| `fs-usage`         | warn/crit| filesystem space or inode usage above the thresholds       |
| `network-interface`| crit     | interface down, missing or below the expected link speed   |
| `infiniband`       | crit     | IB port down, rate below the minimum or firmware mismatch  |
| `service`          | crit     | configured systemd units or processes not running          |
| `raid`             | crit     | software RAID (`md`) array degraded or failed              |
| `smart`            | crit     | SMART health of configured disks (heavy, cached)           |
| `gpu`              | crit     | NVIDIA GPU count or Fabric state/status not healthy (cached) |
| `package-version`  | crit     | installed package version does not match the expected one  |

Statuses: `OK`, `WARN`, `CRIT`, `SKIP` (not applicable) and `UNKNOWN` (could not
determine). `SKIP` never triggers a quarantine.

The optional checks (`fs-usage`, `network-interface`, `infiniband`, `service`,
`raid`, `smart`, `gpu`, `package-version`) are **disabled by default** and have
commented examples in `etc/one-nhc.conf`. Use `hosts:`/`exclude:` to enable them
only on the relevant nodes.

### Heavy checks and cache

`smart` and `gpu` are heavy: they declare a TTL and the probe **does not run
them**. The probe reads the cache file (default
`/var/lib/one-nhc/cache.json`); `one-nhc cache` runs the heavy checks and writes
it atomically, and `one-nhc-cache.timer` refreshes it every 15 minutes.

If the cache entry is missing or stale, the probe reports `UNKNOWN`, never
`CRIT`, so a missing timer cannot quarantine a host. `one-nhc check` still runs
the heavy checks on demand, and `one-nhc cache --quiet` refreshes the cache
without printing anything.

`smartctl` often needs root. If the disks are not readable as `oneadmin`, set
`smart.sudo: true` and add a sudoers rule for `smartctl`, or the check reports
`UNKNOWN` instead of a false `CRIT`.

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

## Targeting checks to hosts and groups

By default every enabled check runs on every host. Scope a check with
clush/dsh-style hostlists:

```yaml
groups:
  compute: "node[01-10]"
  gpu: "gpu[01-02]"

checks:
  fs-ro:
    enabled: true
    hosts: all
  infiniband:
    enabled: true
    hosts: "@gpu"
  datastore-mounts:
    enabled: true
    hosts: "@compute,stor[01,03]"
    exclude: "node05"
```

| Expression | Matches |
|---|---|
| `all` or `*` | every host |
| `node01` | that host |
| `node[01-10]` | node01 to node10 (zero padding preserved) |
| `node[01,08]` | node01 and node08 |
| `node[01-03,08,10-12]` | ranges and single values |
| `node*` | glob (`File.fnmatch`) |
| `@group` | expansion of `groups.<group>` |

A check that is not targeted at the local host is **not executed and not
reported**, so monitoring does not fill with `SKIP` for checks that do not
apply. Use `one-nhc check --node node05` to evaluate another host and
`one-nhc list` to list the available checks.

Monitoring attributes persist until `HOST_MONITORING_EXPIRATION_TIME`, so if
you change the targeting of a check that already ran, set
`report_not_targeted: true` to emit `NHC_<ID>="SKIP"` (with a "not targeted"
message) and clear the stale value immediately.

The local node name is the short hostname by default. Override it with
`node_name:` in the config or the `ONE_NHC_NODE` environment variable when the
OpenNebula host name differs from the OS hostname.

## Controller

The controller reads `TEMPLATE/NHC_STATUS` for every host and decides what to
do. The mode is the main safety switch:

| Mode | Logs | Notifies | `onehost disable/enable` |
|---|---|---|---|
| `monitor` | yes | no | no |
| `notify` | yes | yes | no |
| `act` | yes | yes | yes (unless `dry_run`) |

`dry_run: true` keeps `act` mode but only logs the decision.

```yaml
controller:
  mode: act          # monitor | notify | act
  dry_run: false
  consecutive_crit: 3
  consecutive_ok: 2
  cooldown: 300
  reenable_after: 0
  monitor_grace: 900
  never_disable_last: true
  min_healthy_hosts: 1
  include_hosts: all
  # exclude_hosts: "stor[01-02]"
  interval: 60
  state_file: /var/lib/one-nhc/state.json
  notify:
    # command: /usr/local/bin/nhc-alert
    # webhook: https://hooks.example.com/services/XXX
```

Safety rules:

- **Hysteresis:** a host is quarantined after `consecutive_crit` consecutive
  `CRIT` samples and re-enabled after `consecutive_ok` consecutive `OK`
  samples. Samples are identified by `NHC_TIMESTAMP`, so running the controller
  more often than the probe does not speed up (or fake) the counter.
- **Cooldown:** at least `cooldown` seconds between actions on the same host.
- **Minimum healthy hosts:** it refuses to disable when fewer than
  `min_healthy_hosts` healthy monitored hosts would remain. Setting
  `never_disable_last: false` disables the safeguard entirely.
- **Single controller:** a lock file next to the state prevents the systemd
  timer and a manual `--watch` from running at the same time; the second
  process skips the cycle.
- **One announcement per episode:** a decision is logged/notified once; a
  recovery resets the episode.
- **External changes:** if an operator enables a host outside one-nhc, the
  controller notices and clears its own state.
- **Stale monitoring:** a disabled host is not monitored, so its `NHC_STATUS`
  does not change. `reenable_after` (opt-in, 0 = never) enables it again after
  that delay as a trial, and `monitor_grace` ignores the stale `CRIT` value
  for a while so the probe can report again.
- **Targeting:** only hosts in `include_hosts` (minus `exclude_hosts`) are ever
  touched; the same clush/dsh-style hostlists as the checks are supported.

`SKIP`, `WARN` and `UNKNOWN` never quarantine a host. Only `CRIT` starts the
hysteresis counter.

The state file is JSON and tracks counters, cooldown, whether the host was
disabled by one-nhc and the last announced action. It is written atomically.

Each probe run also emits `NHC_TIMESTAMP`; the controller uses it to count
distinct samples. Probes without that attribute (older installations) are
evaluated on every controller cycle.

### Notifications

In `notify` and `act` modes the controller can run a command and/or POST a
webhook for each decision (including `refuse_disable`).

The command receives:

| Variable | Meaning |
|---|---|
| `NHC_MESSAGE` | one-line decision message |
| `NHC_HOST` | host name |
| `NHC_HOST_ID` | OpenNebula host id |
| `NHC_STATUS` | `NHC_STATUS` value (`CRIT`, `OK`, …) |
| `NHC_ACTION` | `disable`, `enable`, `reenable` or `refuse_disable` |
| `NHC_APPLIED` | `true` when the action was applied |

The webhook receives a JSON object with the same fields plus `time`, `sample`
and `details` (the host `NHC_*` attributes). Failures are logged and never
abort the controller cycle.

#### Email

Email notifications send one message per decision with an HTML and plain-text
body: status colour, host, action, summary counts, a table with every check and
its message, and the decision message.

```yaml
controller:
  notify:
    email:
      to: ops@example.com          # string or list
      from: one-nhc@example.com
      host: smtp.example.com
      port: 587
      user: one-nhc@example.com
      password_file: /etc/one-nhc/smtp.password
      tls: starttls                # starttls | ssl | none
```

Never put the password in the YAML. Use `password_file` (recommended) or
`password_env` (for a systemd `EnvironmentFile`). The password file must be
readable only by oneadmin:

```bash
sudo install -m 600 -o oneadmin -g oneadmin /dev/null /etc/one-nhc/smtp.password
sudo -u oneadmin sh -c 'read -r -s -p "SMTP password: " p; printf "%s" "$p" > /etc/one-nhc/smtp.password'
```

For Gmail or Google Workspace use an app password with
`smtp.gmail.com:587` and STARTTLS; `from` must be the authenticated account.
Test the configuration without waiting for a host failure:

```bash
one-nhc notify-test
one-nhc notify-test --to oncall@example.com
```

For a local MTA (`postfix`, `sendmail`, `msmtp`, …) use the `sendmail`
transport. It needs **no SMTP user or password**: the MTA already has the relay
and credentials, as in Icinga/Nagios.

```yaml
controller:
  notify:
    email:
      transport: sendmail
      to: ops@example.com
      from: one-nhc@example.com
      sendmail_path: /usr/sbin/sendmail   # default
      sendmail_args: ["-t", "-i"]         # default
```

`notify-test` works with both transports. With `sendmail`, the local MTA must
be installed and able to deliver (for Gmail/Workspace, configure it with a
relay or use `msmtp`).

```bash
one-nhc controller --once --mode notify
one-nhc controller --once --mode act --dry-run
one-nhc controller --once --quiet
one-nhc controller --once --json
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
evacuation) belongs to the controller. The controller implements hysteresis, a
cooldown, `--dry-run`, host targeting and refuses to disable the last healthy
host; it only changes hosts in `act` mode. Start in `monitor`, move to `notify`
and only then to `act` with `dry_run: true` before enabling real actions.

## Roadmap

- **M1 (done):** probe framework, 3 checks, human/JSON/IM adapters.
- **M2 (done):** frontend controller with hysteresis, notifications and
  `onehost disable/enable`.
- **M3:** cached heavyweight checks (RAID, SMART, InfiniBand), hooks and
  optional evacuation.
- **M4:** docs/blog and an upstream docs PR.

## Development

```bash
make test   # ruby -Ilib -Itests tests/run.rb
```

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the rules (read-only probes, no
runtime gems, uniform check contract, SPDX headers, tests and Conventional
Commits). Contributors are listed in [CONTRIBUTORS](CONTRIBUTORS).

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

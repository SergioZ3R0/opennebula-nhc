# Production runbook

This runbook covers a controlled rollout of `opennebula-nhc` on an existing
OpenNebula installation: probe on hypervisors, controller on the frontend,
canary validation and rollback.

It assumes two safety rules:

1. The controller starts in `monitor` mode and only touches hosts explicitly
   listed in `include_hosts`.
2. Clusters and hosts that must never be quarantined stay out of
   `include_hosts`, even during the canary.

Do not enable post-action hooks or real evacuation during the first rollout.

## 1. Components and cadence

| Component | Where | Cadence |
|---|---|---|
| `one-nhc probe` | hypervisors, via the IM wrapper | every `SYSTEM_HOST` (600 s by default) |
| `one-nhc cache` | hypervisors, systemd timer | every 15 min |
| `one-nhc controller` | frontend, systemd timer | every 2 min |

The probe is read-only. Only the controller in `act` mode changes hosts.

## 2. Preflight

On the frontend, as `oneadmin`:

```bash
onehost list
onecluster list
oneversion
```

Record:

- the canary hosts and their OpenNebula IDs;
- the clusters that must not be touched (for example, `1` and `15`);
- whether the canary hosts run production VMs;
- the current `onehost show <id>` output, as a baseline.

Back up the configuration and the state before changing anything:

```bash
sudo tar czf /root/one-nhc-backup-$(date +%F).tgz \
  /etc/one-nhc /var/lib/one-nhc 2>/dev/null || true
```

On the hypervisors:

```bash
ruby --version
df -h /var/lib/one
systemctl is-active opennebula
```

## 3. Install the probe on the canary hypervisors

From the release tarball or the checkout:

```bash
sudo make install
sudo make install-cache-systemd
sudo systemctl daemon-reload
sudo systemctl enable --now one-nhc-cache.timer
```

Edit `/etc/one-nhc/one-nhc.conf` on each host:

- keep only the checks that make sense for that host;
- use `hosts:`/`exclude:` to scope them;
- set `node_name:` only if the OpenNebula host name differs from the OS
  hostname;
- leave `controller` untouched on hypervisors.

Validate on the host:

```bash
sudo -u oneadmin one-nhc check
sudo -u oneadmin one-nhc cache
sudo -u oneadmin one-nhc probe
systemctl list-timers one-nhc-cache.timer
journalctl -u one-nhc-cache.service -n 50 --no-pager
```

`one-nhc check` may report `SKIP` for hardware that does not exist. That is
normal and never quarantines.

## 4. Install the frontend wrapper and sync it

On the frontend:

```bash
sudo make probe
onehost sync --force --ssh
onehost forceupdate <canary-host-id>
onehost show <canary-host-id> | grep NHC_
```

If non-canary hosts do not have `one-nhc` installed, the wrapper reports
`NHC_STATUS="UNKNOWN"` on those hosts. That is safe: the controller never
quarantines on `UNKNOWN`. Install `one-nhc` on all hosts before the final
rollout if you do not want those attributes.

Expected attributes on a canary host:

```text
NHC_STATUS="OK"
NHC_CHECK_COUNT="3"
NHC_TIMESTAMP="..."
```

If the attributes do not appear, check the IM logs and that the wrapper exists
in `/var/lib/one/remotes/im/kvm-probes.d/host/system/` on the host.

## 5. Controller rollout phases

Use `one-nhc controller --once` for manual checks and the systemd timer for the
real rollout.

### Phase 0: monitor (at least one monitoring cycle, preferably 24 h)

```yaml
controller:
  mode: monitor
  include_hosts: "canary[01-02]"
  state_file: /var/lib/one-nhc/state.json
```

Install and start:

```bash
sudo make install-systemd
sudo systemctl daemon-reload
sudo systemctl enable --now one-nhc-controller.timer
journalctl -u one-nhc-controller.service -f
```

Verify that only the canary hosts appear in the log and that the decisions make
sense.

### Phase 1: notify (24 h)

```yaml
controller:
  mode: notify
```

Check that email arrives and that it contains the host, the cluster, the status,
the decision message and the per-check table.

### Phase 2: act with dry-run (24 h)

```yaml
controller:
  mode: act
  dry_run: true
```

The log says `(dry-run)` and no host changes. Confirm that only the intended
hosts are evaluated.

### Phase 3: act on the canary hosts

```yaml
controller:
  mode: act
  dry_run: false
  consecutive_crit: 3
  consecutive_ok: 2
  cooldown: 300
  reenable_after: 1800
  monitor_grace: 900
  never_disable_last: true
  min_healthy_hosts: 2
  min_healthy_hosts_scope: cluster
  include_hosts: "canary[01-02]"
  exclude_hosts: "prod[01-99]"
```

Keep `include_hosts` limited to the canary. Expand it only after the canary
checks in section 6 pass.

`reenable_after` is a trial: the controller enables the host after that delay
and ignores the old `CRIT` value for `monitor_grace` seconds. Use `0` if you
prefer a manual `onehost enable`.

### Phase 4: expand

Add hosts or groups to `include_hosts` one cluster at a time. Keep the
`exclude_hosts` for clusters `1` and `15` explicit while you validate.

## 6. Canary test matrix

Run these tests on a host that is allowed to be quarantined. Do not use a host
from clusters `1` or `15`.

### 6.1 OK path

```bash
onehost show <id> | grep NHC_STATUS     # OK
one-nhc controller --once --json
```

Expected: no action.

### 6.2 WARN path

Use a real, non-destructive warning on the canary. For example, lower the
`fs-usage` warning threshold temporarily:

```yaml
checks:
  fs-usage:
    enabled: true
    hosts: "canary01"
    warn: 1
    crit: 99
```

Wait for the next `SYSTEM_HOST` sample. Expected:

- `NHC_STATUS="WARN"`;
- one email/webhook for the episode;
- no disable and no hooks;
- no duplicate notification while it stays WARN.

Restore the thresholds afterwards.

### 6.3 CRIT path

Stop a disposable service or make a non-critical filesystem read-only on the
canary. Expected:

- `NHC_STATUS="CRIT"`;
- notification after `consecutive_crit` samples;
- quarantine only after hysteresis and only if the healthy-host guard allows it.

If the controller refuses, the log says `refuse_disable` and includes the
cluster and the remaining healthy hosts.

### 6.4 Quarantine and re-enable

On the canary:

```bash
onehost list                       # state dsbl
onehost show <id> | grep NHC_DISABLED   # yes
```

Running VMs should keep running. New VMs should stay `PEND` until the host is
enabled again.

With `reenable_after` set, wait for the delay. Expected:

```bash
onehost list                       # state on
onehost show <id> | grep NHC_DISABLED   # no
```

### 6.5 State loss

On the canary only:

```bash
sudo systemctl stop one-nhc-controller.timer
sudo mv /var/lib/one-nhc/state.json /root/state.json.bak
sudo -u oneadmin one-nhc controller --once
```

Expected: `recovered from NHC_DISABLED` and no immediate re-enable (unless
`reenable_after` has elapsed). Restore the timer afterwards.

### 6.6 Webhook

Point the controller at a test endpoint:

```yaml
controller:
  notify:
    webhook: http://127.0.0.1:18080/hook
    webhook_retries: 2
    webhook_retry_delay: 1
    webhook_min_interval: 0.2
```

A receiver that returns `500` twice and then `200` should see three POSTs and
the controller should keep running. A `400` should not be retried.

### 6.7 Email

```bash
one-nhc notify-test
one-nhc notify-test --to oncall@example.com
```

Check the HTML and text bodies, the cluster row and the grouped check table.

## 7. Validation commands

```bash
systemctl status one-nhc-controller.timer
systemctl list-timers one-nhc-controller.timer
journalctl -u one-nhc-controller.service -n 100 --no-pager
cat /var/lib/one-nhc/state.json
one-nhc controller --once --json
onehost show <id> | grep NHC_
```

A healthy state entry looks like:

```json
{
  "hosts": {
    "node01": {
      "crit_count": 0,
      "ok_count": 3,
      "disabled_by_nhc": false,
      "last_action": 0,
      "last_enable": 0,
      "last_sample": 1794964503,
      "warn_notified": false,
      "notified_action": null,
      "last_status": "OK"
    }
  }
}
```

## 8. Rollback

### Stop the controller

```bash
sudo systemctl disable --now one-nhc-controller.timer
sudo systemctl stop one-nhc-controller.service
```

This is the fastest way to stop all notifications and actions. The probe can
stay installed: it is read-only.

### Enable hosts disabled by one-nhc

```bash
onehost list
onehost enable <id>
onehost show <id> | grep NHC_DISABLED
```

Use the state file and `NHC_DISABLED="yes"` to identify hosts disabled by
one-nhc. Do not delete the state before enabling the hosts.

### Remove the probe wrapper

On the frontend:

```bash
sudo rm -f /var/lib/one/remotes/im/kvm-probes.d/host/system/one_nhc.rb
onehost sync --force --ssh
onehost forceupdate <id>
```

The old `NHC_*` attributes expire after
`HOST_MONITORING_EXPIRATION_TIME`; use `report_not_targeted: true` if you need
to clear them sooner.

### Uninstall

```bash
sudo make uninstall
sudo systemctl daemon-reload
```

Restore `/etc/one-nhc` from the backup if needed.

## 9. Emergency stop

If a host is disabled unexpectedly:

```bash
sudo systemctl disable --now one-nhc-controller.timer
onehost enable <id>
```

If the state file is intact, the controller will notice the external enable and
clear its own state on the next run. If it is not intact, `NHC_DISABLED` lets it
recover after you re-enable the timer.

## 10. Known limitations and guardrails

- A disabled host is not monitored, so its `NHC_STATUS` becomes stale.
  `reenable_after` and `monitor_grace` handle this; otherwise enable it
  manually.
- With `min_healthy_hosts: 2` and `min_healthy_hosts_scope: cluster`, a
  two-host cluster can never have a host quarantined by one-nhc.
- The controller counts samples by `NHC_TIMESTAMP`, not by controller cycles.
  Lowering the controller interval does not speed up the hysteresis.
- Webhook retries and rate limiting apply within one controller run. Separate
  runs use a fresh limiter.
- one-nhc does not evacuate VMs. Evacuation is an optional external hook and
  must be validated separately.
- Clusters `1` and `15` must stay out of `include_hosts` until they are
  explicitly approved.

## 11. Final production checklist

- [ ] `one-nhc check` and `one-nhc probe` pass on every canary host.
- [ ] `NHC_*` attributes appear in `onehost show`.
- [ ] `include_hosts` contains only approved hosts.
- [ ] Clusters `1` and `15` are excluded.
- [ ] `mode: monitor` observed for at least one full cycle.
- [ ] Phase 1 notify tested with a real email.
- [ ] Phase 2 dry-run observed.
- [ ] Canary quarantine and re-enable tested.
- [ ] `NHC_DISABLED` set and cleared.
- [ ] State-loss recovery tested.
- [ ] WARN notification tested once per episode.
- [ ] Webhook retries tested or webhook left disabled.
- [ ] Hooks left disabled until evacuation is validated.
- [ ] Rollback steps and emergency stop known by the on-call person.

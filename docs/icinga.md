# Icinga / Nagios integration

`opennebula-nhc` can be used in two ways with Icinga:

1. **As a local check plugin** on each hypervisor (`one-nhc check --nagios`).
2. **As a central API check** on the frontend (`one-nhc status --nagios`), reading
   the `NHC_*` attributes that the probe publishes in OpenNebula.

The controller is not required for either. Keep it in `monitor` mode, or do not
install it, if Icinga is your alerting system.

## Exit codes

Both commands use the standard Nagios/Icinga exit codes:

| Code | Status |
|---|---|
| `0` | OK |
| `1` | WARNING |
| `2` | CRITICAL |
| `3` | UNKNOWN |

`SKIP` is reported as OK.

## Local check plugin

On the hypervisor:

```bash
/usr/local/bin/one-nhc check --nagios
```

Example with a failed network interface:

```text
CRITICAL - 1/4 check(s) not OK (network-interface) | checks=4 ok=3 warn=0 crit=1 skip=0 unknown=0
network-interface: CRIT eth1 is down (expected up)
```

The first line is the short output, followed by the long output and the
performance data after `|`.

To run only selected checks:

```bash
/usr/local/bin/one-nhc check --nagios --only fs-ro,datastore-mounts,libvirt,network-interface
```

`--only` does not enable checks that are disabled in
`/etc/one-nhc/one-nhc.conf`; they must be `enabled: true`.

### Fast and heavy checks

`smart` and `gpu-fabric` can be slow. Split them into two Icinga services:

```bash
# Every 1-5 minutes
/usr/local/bin/one-nhc check --nagios \
  --only fs-ro,datastore-mounts,libvirt,fs-usage,network-interface,infiniband,service,raid,gpu,ofed-version

# Every 15 minutes, longer timeout
/usr/local/bin/one-nhc check --nagios --only smart,gpu-fabric
```

## Icinga 2 with check_by_ssh

```icinga2
object CheckCommand "one-nhc" {
  command = [
    "/usr/lib/nagios/plugins/check_by_ssh",
    "-H", "$host.address$",
    "-l", "oneadmin",
    "-t", "60",
    "-C", "/usr/local/bin/one-nhc check --nagios"
  ]
}

apply Service "one-nhc" {
  import "generic-service"
  check_command = "one-nhc"
  assign where host.vars.one_nhc
  check_interval = 5m
  retry_interval = 1m
  max_check_attempts = 3
}
```

Set `vars.one_nhc = true` on the hypervisor hosts. Use a longer `-t` for the
heavy service.

## NRPE

On the hypervisor:

```text
command[check_one_nhc]=/usr/local/bin/one-nhc check --nagios
command[check_one_nhc_fast]=/usr/local/bin/one-nhc check --nagios --only fs-ro,datastore-mounts,libvirt,fs-usage,network-interface,infiniband,service,raid,gpu,ofed-version
command[check_one_nhc_heavy]=/usr/local/bin/one-nhc check --nagios --only smart,gpu-fabric
```

On Icinga:

```icinga2
object CheckCommand "one-nhc-nrpe" {
  command = [
    "/usr/lib/nagios/plugins/check_nrpe",
    "-H", "$host.address$",
    "-c", "check_one_nhc"
  ]
}
```

## Central API check

On the frontend, with the OpenNebula Ruby bindings and `ONE_AUTH` configured:

```bash
one-nhc status --nagios
```

This reads `NHC_STATUS` from every host and returns the worst status:

```text
CRITICAL - 1/1 host(s) not OK (node1) | hosts=1 ok=0 warn=0 crit=1 skip=0 unknown=0
node1: CRIT network-interface: nhc-test0 is down (expected up)
```

Filter one host by name or ID:

```bash
one-nhc status --nagios --host node1
one-nhc status --nagios --host 0
```

Or use JSON:

```bash
one-nhc status --json
```

`status` is read-only: it never disables or enables hosts. It is useful when
Icinga runs on the frontend and you do not want SSH or NRPE to every
hypervisor.

For Icinga:

```icinga2
object CheckCommand "one-nhc-status" {
  command = [ "/usr/local/bin/one-nhc", "status", "--nagios" ]
}

apply Service "opennebula-nhc" {
  import "generic-service"
  check_command = "one-nhc-status"
  check_interval = 5m
  assign where host.vars.opennebula_frontend
}
```

The command runs on the Icinga master or on the frontend, wherever `ONE_AUTH`
and the bindings are available.

## Performance data

Both modes emit standard performance data:

```text
checks=12 ok=11 warn=0 crit=1 skip=0 unknown=0
hosts=1 ok=0 warn=0 crit=1 skip=0 unknown=0
```

These are counts, so no warning/critical thresholds are attached. They can be
graphed directly in Icinga/Grafana.

## Notifications

You have two independent layers:

- **one-nhc notifications:** `controller.notify` command/webhook/email, only in
  `notify` or `act` mode.
- **Icinga notifications:** the normal Icinga notification objects.

If Icinga is the alerting system, keep the one-nhc emails off:

```yaml
controller:
  notify:
    enabled: false
```

This keeps the channels configured but silences all of them. `one-nhc
notify-test` still sends a test email, because it is an explicit command.

Alternatively, leave `controller.notify` empty or keep the controller in
`monitor` mode. `mode: monitor` never notifies and never changes hosts.

If you want one-nhc to quarantine hosts while Icinga handles alerts:

```yaml
controller:
  mode: act
  dry_run: false
  notify:
    enabled: false
```

Then the controller only does `onehost disable/enable`, and Icinga alerts on
`NHC_STATUS` through `one-nhc status --nagios`.

## Permissions and timeouts

- With `check_by_ssh`, use `oneadmin`: it already has access to `virsh`, sysfs
  and the one-nhc binary.
- With NRPE, the `nagios`/`icinga` user needs `virsh` access (libvirt group) and
  read access to the configured sysfs paths. For `smart`, use
  `smart.sudo: true` and a sudoers rule.
- `check_by_ssh` has its own timeout (`-t`). Set it longer than the sum of the
  check timeouts, especially for `smart` and `gpu-fabric`.
- The probe attributes refresh on the `SYSTEM_HOST` cycle. If `status` looks
  stale, run `onehost forceupdate <id>` or lower `SYSTEM_HOST`.

## When to use which

| Scenario | Recommended |
|---|---|
| Icinga agent/NRPE on each hypervisor | `one-nhc check --nagios` |
| Icinga master with OpenNebula API access | `one-nhc status --nagios` |
| Alerts only, no host changes | controller in `monitor` or not installed |
| Alerts in Icinga, quarantine by one-nhc | `act` + `notify.enabled: false` |

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.9.0] - 2026-11-18

First release with the complete probe, cache and controller feature set.

### Added

- Probe framework with fast and heavy checks, human/JSON/OpenNebula IM output.
- Checks: `fs-ro`, `datastore-mounts`, `libvirt`, `fs-usage`,
  `network-interface`, `infiniband`, `service`, `raid`, `smart`, `gpu`,
  `gpu-fabric` and `ofed-version`.
- Heavy-check cache with `one-nhc cache` and systemd timer units.
- Frontend controller with `monitor`, `notify` and `act` modes, `dry_run`,
  hysteresis, cooldown, single-controller lock, host targeting and
  `NHC_TIMESTAMP` sample tracking.
- Notification channels: command, webhook and email (SMTP or sendmail), with
  HTML and plain-text bodies, grouping by tag and failures first.
- Webhook retries for connection errors, timeouts, `5xx` and `429`, with
  exponential backoff and `Retry-After` support, plus a per-run minimum
  interval between POSTs.
- WARN notifications once per episode (`notify_on_warn`), without quarantine or
  hooks.
- Nested host groups flattened to `cluster/role` (`@default/gpu`).
- Per-cluster healthy-host safeguard (`min_healthy_hosts_scope: cluster`).
- State recovery through `NHC_DISABLED` on the host template, surviving a lost
  state file or a host rename.
- Post-action hooks (`on_disable`, `on_enable`, `on_reenable`) with an
  evacuation example that only selects running VMs.
- `schema_version` in the heavy-check cache.
- Rediscovery of MIG partitions in the `gpu` count (`count_mig`, default true).
- Production runbook and a complete `default`/`LLM` example configuration.

### Changed

- Grouped emails no longer show an empty Packages group.
- `gpu` reports physical and MIG counts separately in its metrics.
- The CLI prefers the checkout over an installed copy when both exist.

### Removed

- The generic `package-version` check. Use a specific check such as
  `ofed-version` as a template.

### Fixed

- Controller state is no longer lost when the state file is deleted or a host is
  renamed.
- Webhook failures no longer disappear without a retry or a clear log message.

## 0.8.1 - 2026-11-18

- Added `ofed-version` under the Network group.
- Moved the decision message near the top of notification emails.

## 0.8.0 - 2026-11-18

- Added grouped email notifications (`group_by: tags`, `failures_first`).

[Unreleased]: https://github.com/SergioZ3R0/opennebula-nhc/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/SergioZ3R0/opennebula-nhc/releases/tag/v0.9.0

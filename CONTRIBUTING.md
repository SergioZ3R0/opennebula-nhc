# Contributing to opennebula-nhc

Thanks for taking the time to contribute.

This document explains **how changes are made** and the rules that keep the
project consistent. These rules are not suggestions: a pull request that does
not follow them will be asked to change before it is merged.

## Ground rules

1. **The probe is read-only.** Checks must never modify the host, create files
   outside a temporary directory, restart services or call the OpenNebula API.
   Actions belong to the controller.
2. **No gems at runtime.** Runtime code (probe, CLI, checks) uses the Ruby
   standard library only. Development tooling may use gems.
3. **Every check has a timeout.** No check may hang the monitoring cycle.
4. **Unknown is not failure.** Report `SKIP` when something is not applicable
   (no hardware, tool missing) and `UNKNOWN` only when the state cannot be
   determined. Never quarantine a host because an optional tool is missing.
5. **Uniform contract.** Every check is registered with `OneNHC.check` and
   finishes with `ok!`, `warn!`, `crit!`, `skip!` or `unknown!`.
6. **Headers are mandatory.** Every source file starts with the SPDX header and
   every Ruby file includes `# frozen_string_literal: true`.
7. **Tests are mandatory.** New behaviour comes with tests and `make test` must
   pass.
8. **Conventional Commits.** Commit messages follow Conventional Commits and
   branches are named `type/kebab-case`.
9. **Targeting.** A check that does not apply to every host must declare
   `hosts:` (and optionally `exclude:`). A check that is not targeted must not
   run and must not be reported as `SKIP`.
10. **Controller safety.** Actions live in the controller and only run in `act`
    mode. Keep hysteresis, cooldown, `dry_run`, host targeting, the
    `min_healthy_hosts` safeguard and the single-controller lock.
11. **Secrets stay out of the YAML.** SMTP passwords and webhook tokens use
    `password_file`/`password_env` (or an equivalent secret store); never commit
    credentials.

## Code style (Ruby)

- Two spaces for indentation, LF line endings, UTF-8, no tabs (tabs only in the
  `Makefile`).
- `# frozen_string_literal: true` in every Ruby file.
- Prefer small, focused methods and modules.
- Double quotes for strings, consistent with the codebase.
- No monkey patching and no global mutable state beyond the check registry.
- Prefer `sysfs` and `procfs` over vendor CLIs, which change between versions.
- Detect capabilities with `OneNHC::Shell.which` and report `SKIP` when absent.
- Never shell out directly: use `OneNHC::Shell.capture`, which enforces a hard
  timeout.
- Keep messages short and on a single line: they end up in IM attributes.

A `.editorconfig` enforces indentation and charset for most editors, and
`scripts/check-style.sh` enforces the SPDX headers and `frozen_string_literal`
in CI.

## Adding a check

1. Create `checks.d/<NN>-<id>.rb`, where `NN` orders it (for example
   `40-raid.rb`).
2. Register it with the uniform contract:

```ruby
OneNHC.check(
  id: "raid",
  description: "RAID arrays are not degraded",
  severity: :crit,
  timeout: 5,
  tags: %w[storage]
) do |ctx|
  degraded = []
  # ... read /sys/block/md*/md/degraded ...
  if degraded.empty?
    ctx.ok!("no degraded arrays")
  else
    ctx.crit!("degraded: #{degraded.join(', ')}", metrics: { "degraded" => degraded.size })
  end
end
```

3. Read settings from `ctx.config.check("raid")`.
4. Add an example to `etc/one-nhc.conf` and document it in the README table.
5. If the check does not apply to every host, set `hosts:` (and optionally
   `exclude:`) in the config and document it in the README.
6. Add tests in `tests/test_<id>.rb`, using fixtures or stubbing
   `OneNHC::Shell`.
7. Run `make test` and `./scripts/check-style.sh`.

## Tests

- Framework: minitest (standard library).
- Tests must not depend on the host: write fixtures to a temporary directory or
  stub `OneNHC::Shell`.
- Tests must be deterministic and fast.

## Commits and pull requests

- Commit messages: Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`,
  `refactor:`, `chore:`).
- One logical change per commit.
- Pull request checklist:

  - [ ] `make test` passes
  - [ ] `./scripts/check-style.sh` passes
  - [ ] new checks are documented and tested
  - [ ] targeting (`hosts`/`exclude`) set where the check is not global
  - [ ] no runtime gems introduced
  - [ ] SPDX headers present

## License

By contributing you agree that your contributions are licensed under the
Apache License 2.0 (inbound = outbound). See `LICENSE`.

You will be added to `CONTRIBUTORS` once your first change is merged.

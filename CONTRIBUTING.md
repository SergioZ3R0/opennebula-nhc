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
12. **Heavy checks are cached.** A check that can take more than about one
    second, needs root/sudo or can block on storage/network must set
    `heavy: true` and a `ttl`, and must not run in the probe. See
    [docs/checks.md](docs/checks.md).

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

Read [docs/checks.md](docs/checks.md) first. It explains the fast/heavy split,
the cache contract and the tests expected for a new check.

1. Create `checks.d/<NN>-<id>.rb`, where `NN` orders it (for example
   `40-raid.rb`).
2. Decide whether it is **fast** (runs in the probe) or **heavy** (cached by
   `one-nhc cache`). See the decision guide in `docs/checks.md`.
3. Register it with the uniform contract:

```ruby
OneNHC.check(
  id: "raid",
  description: "RAID arrays are not degraded",
  severity: :crit,
  timeout: 5,
  tags: %w[storage],
  heavy: false,
  ttl: 0
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

For a heavy check use `heavy: true, ttl: <seconds>`. The TTL must be longer than
the cache timer interval; see `systemd/one-nhc-cache.timer`.

4. Read settings from `ctx.config.check("raid")`.
5. Add an example to `etc/one-nhc.conf` and document it in the README table.
6. If the check does not apply to every host, set `hosts:` (and optionally
   `exclude:`) in the config and document it in the README.
7. Add tests in `tests/test_<id>.rb`, using fixtures or stubbing
   `OneNHC::Shell`.
8. For heavy checks, also test:
   - `one-nhc cache` writes the result;
   - `one-nhc probe` reads it;
   - a missing/stale cache produces `UNKNOWN`, never `CRIT`.
9. Run `make test` and `./scripts/check-style.sh`.

## Tests

- Framework: minitest (standard library).
- Tests must not depend on the host: write fixtures to a temporary directory or
  stub `OneNHC::Shell`.
- Tests must be deterministic and fast.
- Heavy checks must test the cache path: fresh cache, missing/stale cache
  (`UNKNOWN`, never `CRIT`) and the direct `one-nhc check` path. See
  `tests/test_cache.rb`, `tests/test_runner_cache.rb` and
  `tests/test_smart.rb`.
- The integration simulator `tests/test_integration_checks.rb` runs the real CLI
  with fake commands and sysfs. Add the healthy and failing cases for a new
  check there when it uses external commands or sysfs.

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

# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

OneNHC.check(
  id: "service",
  description: "Configured systemd units or processes are running",
  severity: :crit,
  timeout: 30,
  tags: %w[services]
) do |ctx|
  options  = ctx.config.check("service")
  services = Array(options["services"])

  ctx.skip!("no services configured") if services.empty?

  problems = []
  skipped  = []
  checked  = 0

  services.each do |entry|
    name = entry["name"].to_s
    if name.empty?
      problems << "empty service name in config"
      next
    end

    type = (entry["type"] || "systemd").to_s

    case type
    when "systemd"
      _out, _err, status, state = OneNHC::Shell.capture(
        ["systemctl", "is-active", "--quiet", name], timeout: 5
      )

      case state
      when :notfound
        skipped << "#{name}: systemctl not found"
      when :timeout
        problems << "#{name} status timed out"
      else
        checked += 1
        problems << "#{name} is not active" unless status&.success?
      end
    when "process"
      pattern = entry["pattern"].to_s
      pattern = name if pattern.empty?

      _out, _err, status, state = OneNHC::Shell.capture(
        ["pgrep", "-f", pattern], timeout: 5
      )

      case state
      when :notfound
        skipped << "#{name}: pgrep not found"
      when :timeout
        problems << "#{name} pgrep timed out"
      else
        checked += 1
        problems << "#{name} process not found" unless status&.success?
      end
    else
      problems << "#{name} has unknown type '#{type}'"
    end
  end

  if problems.any?
    ctx.crit!(problems.join("; "), metrics: { "problems" => problems.size })
  elsif skipped.any? && checked.zero?
    ctx.skip!(skipped.join("; "))
  elsif skipped.any?
    ctx.unknown!(skipped.join("; "), metrics: { "skipped" => skipped.size })
  else
    ctx.ok!("#{checked} service(s) active", metrics: { "services" => checked })
  end
end

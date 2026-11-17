# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

OneNHC.check(
  id: "smart",
  description: "SMART health of configured disks",
  severity: :crit,
  timeout: 60,
  heavy: true,
  ttl: 1800,
  tags: %w[storage hardware]
) do |ctx|
  options  = ctx.config.check("smart")
  devices  = Array(options["devices"]).map(&:to_s).reject(&:empty?)
  required = options.fetch("required", false)
  timeout  = Integer(options.fetch("timeout", 15))
  use_sudo = options.fetch("sudo", false)

  ctx.skip!("no SMART devices configured") if devices.empty?

  unless OneNHC::Shell.which("smartctl")
    if required
      ctx.crit!("smartctl not installed")
    else
      ctx.skip!("smartctl not installed")
    end
  end

  parse_health = lambda do |output|
    if (match = output.match(/SMART overall-health self-assessment test result:\s*(\S+)/i))
      match[1]
    elsif (match = output.match(/SMART Health Status:\s*(.+)/i))
      match[1].strip
    end
  end

  problems = []
  unknowns = []
  skipped  = []
  checked  = 0

  devices.each do |device|
    command = ["smartctl", "-H", device]
    command.unshift("sudo", "-n") if use_sudo

    stdout, stderr, status, state = OneNHC::Shell.capture(
      command, timeout: timeout
    )

    case state
    when :notfound
      skipped << "smartctl not found"
      next
    when :timeout
      checked += 1
      unknowns << "#{device} smartctl timed out after #{timeout}s"
      next
    end

    checked += 1
    text   = "#{stdout}\n#{stderr}"
    health = parse_health.call(text)
    exit_code = status&.exitstatus.to_i

    if (exit_code & 8) != 0 || (exit_code & 16) != 0
      problems << "#{device} SMART failing (exit #{exit_code})"
      next
    end

    if health.nil?
      if text =~ /permission denied|operation not permitted/i
        unknowns << "#{device} smartctl permission denied"
      else
        message = stderr.to_s.strip.empty? ? stdout.to_s.strip : stderr.to_s.strip
        unknowns << "#{device} health unknown: #{message.lines.first.to_s.strip}"
      end
      next
    end

    value = health.to_s.upcase
    if value.include?("PASSED") || value == "OK"
      next
    elsif value.include?("FAILED") || value.include?("BAD")
      problems << "#{device} SMART #{health}"
    else
      unknowns << "#{device} SMART #{health}"
    end
  end

  if problems.any?
    ctx.crit!(problems.join("; "), metrics: { "problems" => problems.size })
  elsif unknowns.any?
    ctx.unknown!(unknowns.join("; "), metrics: { "unknowns" => unknowns.size })
  elsif skipped.any? && checked.zero?
    ctx.skip!(skipped.join("; "))
  elsif skipped.any?
    ctx.unknown!(skipped.join("; "), metrics: { "skipped" => skipped.size })
  else
    ctx.ok!("#{checked} disk(s) SMART healthy", metrics: { "disks" => checked })
  end
end

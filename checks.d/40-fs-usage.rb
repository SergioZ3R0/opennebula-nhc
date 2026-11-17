# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

OneNHC.check(
  id: "fs-usage",
  description: "Filesystem space and inode usage below thresholds",
  severity: :crit,
  timeout: 30,
  tags: %w[storage]
) do |ctx|
  options      = ctx.config.check("fs-usage")
  mounts       = Array(options["mounts"])
  default_warn = Integer(options.fetch("warn", 90))
  default_crit = Integer(options.fetch("crit", 95))
  check_inodes = options.fetch("check_inodes", false)
  cmd_timeout  = Integer(options.fetch("timeout", 5))

  ctx.skip!("no filesystems configured") if mounts.empty?

  warnings = []
  problems = []

  mounts.each do |entry|
    path = entry["path"].to_s
    if path.empty?
      problems << "empty filesystem path in config"
      next
    end

    warn_limit = Integer(entry.fetch("warn", default_warn))
    crit_limit = Integer(entry.fetch("crit", default_crit))
    inodes     = entry.fetch("check_inodes", check_inodes)

    checks = [["capacity", "-P"]]
    checks << ["inodes", "-Pi"] if inodes

    checks.each do |label, flag|
      stdout, stderr, status, state = OneNHC::Shell.capture(
        ["df", flag, path], timeout: cmd_timeout
      )

      case state
      when :notfound
        problems << "df not found"
        next
      when :timeout
        problems << "#{path} df timed out after #{cmd_timeout}s"
        next
      end

      unless status&.success?
        message = stderr.to_s.strip.empty? ? stdout.to_s.strip : stderr.to_s.strip
        problems << "#{path} df failed: #{message.lines.first.to_s.strip}"
        next
      end

      line = stdout.to_s.lines[1]
      if line.nil?
        problems << "#{path} #{label} output unparseable"
        next
      end

      usage_field = line.split.find { |field| field.end_with?("%") }
      usage       = usage_field&.delete_suffix("%")&.to_i
      if usage.nil?
        problems << "#{path} #{label} usage unparseable"
        next
      end

      if usage >= crit_limit
        problems << "#{path} #{label} #{usage}% >= #{crit_limit}%"
      elsif usage >= warn_limit
        warnings << "#{path} #{label} #{usage}% >= #{warn_limit}%"
      end
    end
  end

  if problems.any?
    ctx.crit!(problems.join("; "), metrics: { "problems" => problems.size })
  elsif warnings.any?
    ctx.warn!(warnings.join("; "), metrics: { "warnings" => warnings.size })
  else
    ctx.ok!("#{mounts.size} filesystem(s) ok", metrics: { "mounts" => mounts.size })
  end
end

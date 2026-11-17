# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

OneNHC.check(
  id: "package-version",
  description: "Installed package versions match the expected ones",
  severity: :crit,
  timeout: 15,
  tags: %w[packages]
) do |ctx|
  options  = ctx.config.check("package-version")
  packages = Array(options["packages"])

  ctx.skip!("no packages configured") if packages.empty?

  detect_manager = lambda do |requested|
    return requested unless requested == "auto"

    return "rpm" if OneNHC::Shell.which("rpm")
    return "dpkg" if OneNHC::Shell.which("dpkg-query")

    nil
  end

  problems = []
  skipped  = []
  checked  = 0

  packages.each do |entry|
    name     = entry["name"].to_s
    expected = entry["version"].to_s
    if name.empty? || expected.empty?
      problems << "package entry requires name and version"
      next
    end

    manager = detect_manager.call((entry["manager"] || "auto").to_s)
    if manager.nil?
      skipped << "#{name}: no package manager found"
      next
    end

    command = case manager
              when "rpm"
                ["rpm", "-q", "--qf", "%{VERSION}", name]
              when "dpkg"
                ["dpkg-query", "-W", "-f=${Version}", name]
              else
                problems << "#{name}: unknown package manager '#{manager}'"
                next
              end

    stdout, stderr, status, state = OneNHC::Shell.capture(command, timeout: 5)

    case state
    when :notfound
      skipped << "#{name}: #{manager} not found"
      next
    when :timeout
      checked += 1
      problems << "#{name} query timed out"
      next
    end

    checked += 1

    unless status&.success?
      message = stderr.to_s.strip.empty? ? stdout.to_s.strip : stderr.to_s.strip
      problems << "#{name} not installed (#{message.lines.first.to_s.strip})"
      next
    end

    actual = stdout.to_s.strip
    if actual.empty?
      problems << "#{name} returned an empty version"
      next
    end

    match = (entry["match"] || "exact").to_s
    matched = case match
              when "prefix" then actual.start_with?(expected)
              when "exact" then actual == expected
              else
                problems << "#{name}: unknown match mode '#{match}'"
                false
              end

    problems << "#{name} version #{actual} (expected #{expected})" unless matched
  end

  if problems.any?
    ctx.crit!(problems.join("; "), metrics: { "problems" => problems.size })
  elsif skipped.any? && checked.zero?
    ctx.skip!(skipped.join("; "))
  elsif skipped.any?
    ctx.unknown!(skipped.join("; "), metrics: { "skipped" => skipped.size })
  else
    ctx.ok!("#{checked} package(s) at the expected version", metrics: { "packages" => checked })
  end
end

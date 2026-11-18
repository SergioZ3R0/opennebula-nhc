# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

OneNHC.check(
  id: "ofed-version",
  description: "MLNX OFED version matches the expected one",
  severity: :crit,
  timeout: 10,
  tags: %w[network hardware]
) do |ctx|
  options  = ctx.config.check("ofed-version")
  package  = (options["package"] || "mlnx-ofa_kernel").to_s
  expected = options["version"].to_s
  manager  = (options["manager"] || "auto").to_s
  match    = (options["match"] || "exact").to_s

  ctx.skip!("no expected OFED version configured") if expected.empty?

  if manager == "auto"
    manager = if OneNHC::Shell.which("rpm")
                "rpm"
              elsif OneNHC::Shell.which("dpkg-query")
                "dpkg"
              else
                ""
              end
  end

  ctx.skip!("no package manager found") if manager.empty?

  command = case manager
            when "rpm"
              ["rpm", "-q", "--qf", "%{VERSION}", package]
            when "dpkg"
              ["dpkg-query", "-W", "-f=${Version}", package]
            else
              ctx.unknown!("unknown package manager '#{manager}'")
            end

  stdout, stderr, status, state = OneNHC::Shell.capture(command, timeout: 8)

  case state
  when :notfound
    ctx.skip!("#{manager} not found")
  when :timeout
    ctx.crit!("OFED version query timed out")
  end

  unless status&.success?
    message = stderr.to_s.strip.empty? ? stdout.to_s.strip : stderr.to_s.strip
    ctx.crit!("#{package} not installed: #{message.lines.first.to_s.strip}")
  end

  actual = stdout.to_s.strip
  ctx.crit!("#{package} returned an empty version") if actual.empty?

  matched = case match
            when "prefix" then actual.start_with?(expected)
            when "exact" then actual == expected
            else
              ctx.unknown!("unknown match mode '#{match}'")
            end

  if matched
    ctx.ok!("#{package} version #{actual}", metrics: { "version" => actual })
  else
    ctx.crit!(
      "#{package} version #{actual} (expected #{expected})",
      metrics: { "version" => actual }
    )
  end
end

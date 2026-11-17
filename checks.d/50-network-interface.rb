# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

OneNHC.check(
  id: "network-interface",
  description: "Network interfaces are up with the expected link speed",
  severity: :crit,
  timeout: 10,
  tags: %w[network]
) do |ctx|
  options    = ctx.config.check("network-interface")
  interfaces = Array(options["interfaces"])
  sysfs      = options["sysfs"] || "/sys/class/net"

  ctx.skip!("no interfaces configured") if interfaces.empty?
  ctx.crit!("network sysfs not available") unless File.directory?(sysfs)

  problems = []

  interfaces.each do |entry|
    name = entry["name"].to_s
    if name.empty?
      problems << "empty interface name in config"
      next
    end

    path = File.join(sysfs, name)
    unless File.directory?(path)
      problems << "#{name} missing"
      next
    end

    expected = (entry["state"] || "up").to_s.downcase
    state_file = File.join(path, "operstate")
    unless File.file?(state_file)
      problems << "#{name} operstate unreadable"
      next
    end

    actual = File.read(state_file).strip.downcase
    if actual != expected
      problems << "#{name} is #{actual} (expected #{expected})"
      next
    end

    next unless entry.key?("speed")

    expected_speed = entry["speed"].to_s.to_i
    if expected_speed <= 0
      problems << "#{name} invalid speed in config"
      next
    end

    speed_file = File.join(path, "speed")
    speed      = File.file?(speed_file) ? File.read(speed_file).strip.to_i : -1

    if speed.negative?
      problems << "#{name} speed unknown (expected #{expected_speed} Mb/s)"
    elsif speed < expected_speed
      problems << "#{name} speed #{speed} Mb/s < #{expected_speed} Mb/s"
    end
  end

  if problems.empty?
    ctx.ok!("#{interfaces.size} interface(s) up", metrics: { "interfaces" => interfaces.size })
  else
    ctx.crit!(problems.join("; "), metrics: { "problems" => problems.size })
  end
end

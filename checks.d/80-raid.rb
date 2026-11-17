# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

OneNHC.check(
  id: "raid",
  description: "Software RAID arrays are not degraded or failed",
  severity: :crit,
  timeout: 5,
  tags: %w[storage hardware]
) do |ctx|
  options = ctx.config.check("raid")
  sysfs   = options["sysfs"] || "/sys/block"
  mdstat  = options["mdstat"] || "/proc/mdstat"

  degraded_files = Dir.glob(File.join(sysfs, "md*", "md", "degraded")).sort

  md_lines = []
  if File.file?(mdstat)
    md_lines = File.readlines(mdstat).select { |line| line.start_with?("md") }
  end

  ctx.skip!("no software RAID arrays") if degraded_files.empty? && md_lines.empty?

  problems = []
  arrays   = 0

  degraded_files.each do |path|
    name     = File.basename(File.dirname(File.dirname(path)))
    degraded = File.read(path).strip.to_i
    arrays  += 1

    problems << "#{name} degraded (#{degraded} device(s))" if degraded.positive?
  end

  # Fallback for environments without md sysfs: parse mdstat directly.
  if degraded_files.empty?
    arrays = md_lines.size

    md_lines.each do |line|
      next unless line.include?("_") || line.include?("(F)")

      problems << "mdstat: #{line.strip}"
    end
  end

  if problems.empty?
    ctx.ok!("#{arrays} RAID array(s) healthy", metrics: { "arrays" => arrays })
  else
    ctx.crit!(problems.uniq.join("; "), metrics: { "problems" => problems.uniq.size })
  end
end

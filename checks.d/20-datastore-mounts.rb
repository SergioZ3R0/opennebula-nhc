# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

OneNHC.check(
  id: "datastore-mounts",
  description: "Datastore mounts present and writable",
  severity: :crit,
  timeout: 5,
  tags: %w[storage]
) do |ctx|
  options     = ctx.config.check("datastore-mounts")
  mounts      = Array(options["mounts"])
  mounts_path = ctx.config["proc_mounts"] || "/proc/mounts"

  ctx.skip!("no datastore mounts configured") if mounts.empty?

  mounted = lambda do |path|
    next false unless File.file?(mounts_path)

    File.foreach(mounts_path).any? { |line| line.split(" ")[1] == path }
  end

  problems = []

  mounts.each do |entry|
    path = entry["path"].to_s

    if path.empty?
      problems << "empty datastore path in config"
      next
    end

    unless File.directory?(path)
      problems << "#{path} missing"
      next
    end

    unless File.writable?(path)
      problems << "#{path} not writable"
      next
    end

    problems << "#{path} not a mountpoint" if entry["must_be_mount"] && !mounted.call(path)
  end

  if problems.empty?
    ctx.ok!("#{mounts.size} datastore mount(s) ok")
  else
    ctx.crit!(problems.join("; "), metrics: { "problems" => problems.size })
  end
end

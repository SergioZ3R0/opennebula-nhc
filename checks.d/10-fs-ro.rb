# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

OneNHC.check(
  id: "fs-ro",
  description: "No real filesystems remounted read-only",
  severity: :crit,
  timeout: 5,
  tags: %w[storage]
) do |ctx|
  options     = ctx.config.check("fs-ro")
  allowlist   = Array(options["allowlist"])
  mounts_path = ctx.config["proc_mounts"] || "/proc/mounts"

  # Pseudo and read-only-by-design filesystems are not interesting here.
  pseudo = %w[
    proc sysfs devtmpfs devpts tmpfs ramfs cgroup cgroup2 securityfs debugfs
    tracefs pstore bpf configfs fusectl mqueue hugetlbfs autofs efivarfs
    binfmt_misc rpc_pipefs nfsd squashfs iso9660 erofs
  ]

  allowlisted = lambda do |mountpoint|
    allowlist.any? do |entry|
      mountpoint == entry || mountpoint.start_with?("#{entry.chomp('/')}/")
    end
  end

  read_only = []

  File.foreach(mounts_path) do |line|
    _device, mountpoint, fstype, opts = line.split(" ")
    next if mountpoint.nil? || opts.nil?

    next unless opts.split(",").include?("ro")
    next if pseudo.include?(fstype)
    next if allowlisted.call(mountpoint)

    read_only << "#{mountpoint} (#{fstype})"
  end

  if read_only.empty?
    ctx.ok!("all real filesystems are read-write")
  else
    ctx.crit!(
      "read-only: #{read_only.join(', ')}",
      metrics: { "read_only_mounts" => read_only.size }
    )
  end
end

# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

OneNHC.check(
  id: "libvirt",
  description: "libvirt/qemu responds to virsh",
  severity: :crit,
  timeout: 10,
  tags: %w[compute]
) do |ctx|
  options     = ctx.config.check("libvirt")
  uri         = options["uri"] || "qemu:///system"
  cmd_timeout = Integer(options["timeout"] || 6)

  ctx.skip!("virsh not installed") unless OneNHC::Shell.which("virsh")

  stdout, stderr, status, state = OneNHC::Shell.capture(
    ["virsh", "-r", "-c", uri, "list", "--all"],
    timeout: cmd_timeout
  )

  case state
  when :notfound
    ctx.skip!("virsh not found")
  when :timeout
    ctx.crit!("virsh timed out after #{cmd_timeout}s")
  else
    if status&.success?
      domains = stdout.to_s.lines.count { |line| line =~ /^\s*\d+\s/ }
      ctx.ok!("libvirt ok (#{domains} domain(s))", metrics: { "domains" => domains })
    else
      message = stderr.to_s.strip.empty? ? stdout.to_s.strip : stderr.to_s.strip
      ctx.crit!("libvirt error: #{message.lines.first.to_s.strip}")
    end
  end
end

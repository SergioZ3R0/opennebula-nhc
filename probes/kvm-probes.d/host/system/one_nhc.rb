#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

# OpenNebula IM probe wrapper.
#
# Install in: /var/lib/one/remotes/im/kvm-probes.d/host/system/one_nhc.rb
# (frontend) and sync it to the hosts with `onehost sync --admin`.
#
# The Information Manager executes the probes in host/system on every
# SYSTEM_HOST cycle and merges their stdout (KEY="VALUE") into the host
# MONITORING INFORMATION.
#
# This wrapper never exits with a non-zero status: a failing probe must not
# break host monitoring. On failure it prints NHC_STATUS="UNKNOWN".

require "open3"

CANDIDATES = [
  ENV["ONE_NHC_BIN"],
  "/usr/local/bin/one-nhc",
  "/usr/bin/one-nhc",
  "/usr/local/lib/one-nhc/bin/one-nhc"
].compact.freeze

def sanitize(value)
  value.to_s.gsub(/["\\]/, "'").gsub(/\s+/, " ").strip[0, 200]
end

binary = CANDIDATES.find { |path| File.file?(path) && File.executable?(path) }

unless binary
  puts %(NHC_STATUS="UNKNOWN")
  puts %(NHC_ERROR="one-nhc binary not found")
  exit 0
end

begin
  stdout, stderr, status = Open3.capture3(binary, "probe", *ARGV)

  if stdout.strip.empty?
    reason = if stderr.strip.empty?
               "probe produced no output (exit #{status.exitstatus})"
             else
               stderr.strip
             end
    puts %(NHC_STATUS="UNKNOWN")
    puts %(NHC_ERROR="#{sanitize(reason)}")
  else
    print stdout
  end
rescue SystemCallError => e
  message = sanitize("#{e.class}: #{e.message}")
  puts %(NHC_STATUS="UNKNOWN")
  puts %(NHC_ERROR="#{message}")
end

exit 0

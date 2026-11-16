#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

# OpenNebula IM probe wrapper.
#
# Install in: /var/lib/one/remotes/im/kvm-probes.d/host/one_nhc.rb
# (frontend) and sync to the hosts with `onehost sync`.
#
# It delegates to the one-nhc binary and prints OpenNebula monitoring
# attributes (KEY="VALUE") on stdout, which the Information Manager merges
# into the host MONITORING INFORMATION.

binary = ENV.fetch("ONE_NHC_BIN", "/usr/bin/one-nhc")

begin
  exec(binary, "probe", *ARGV)
rescue SystemCallError => e
  message = "#{e.class}: #{e.message}".gsub(/["\\]/, "'").gsub(/\s+/, " ")
  puts %(NHC_STATUS="UNKNOWN")
  puts %(NHC_ERROR="#{message}")
  exit 1
end

# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

module OneNHC
  # OpenNebula bindings adapter for the controller.
  #
  # Only used on the OpenNebula frontend. It is loaded lazily so the probe and
  # the CLI keep working on hypervisors, where the bindings are not installed.
  class OnAPI
    def initialize
      load_bindings
      @client = OpenNebula::Client.new
    end

    def hosts
      pool = OpenNebula::HostPool.new(@client)
      rc   = pool.info
      raise rc.message if OpenNebula.is_error?(rc)

      list = []
      pool.each do |host|
        template = host.to_hash.dig("HOST", "TEMPLATE") || {}
        details  = template.select { |key, _| key.start_with?("NHC_") }
        cluster  = host["CLUSTER"].to_s
        cluster  = host["CLUSTER_ID"].to_s if cluster.empty?

        list << HostView.new(
          id: host.id,
          name: host.name,
          status: normalize(template["NHC_STATUS"]),
          state: host["STATE"].to_i,
          sample: template["NHC_TIMESTAMP"].to_i,
          details: details,
          cluster: cluster
        )
      end
      list
    end

    def disable(id)
      apply(id, :disable)
    end

    def enable(id)
      apply(id, :enable)
    end

    # Persist the fact that one-nhc disabled this host, so a lost state file or
    # a host rename does not leave it quarantined forever.
    def mark_disabled(id)
      set_flag(id, "yes")
    end

    def mark_enabled(id)
      set_flag(id, "no")
    end

    private

    def load_bindings
      candidates = [
        ENV["ONE_NHC_ON_RUBY"],
        ENV["ONE_LOCATION"] && File.join(ENV["ONE_LOCATION"], "lib", "ruby"),
        "/usr/lib/one/ruby",
        "/usr/share/one/ruby"
      ].compact

      candidates.each do |dir|
        next unless File.directory?(dir)

        $LOAD_PATH.unshift(dir) unless $LOAD_PATH.include?(dir)
        break
      end

      require "load_opennebula_paths"
      require "opennebula"
    end

    def normalize(value)
      text = value.to_s.strip.upcase
      text.empty? ? nil : text
    end

    # Use the binding methods instead of raw XML-RPC names: they are stable
    # across OpenNebula versions (the client prefixes methods with "one.").
    def apply(id, method)
      host = OpenNebula::Host.new_with_id(id, @client)
      rc   = host.public_send(method)

      raise rc.message if OpenNebula.is_error?(rc)

      true
    end

    def set_flag(id, value)
      host = OpenNebula::Host.new_with_id(id, @client)
      rc   = host.update(%(NHC_DISABLED = "#{value}"\n), true)

      raise rc.message if OpenNebula.is_error?(rc)

      true
    end
  end
end

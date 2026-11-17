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
        list << HostView.new(
          id: host.id,
          name: host.name,
          status: normalize(host["TEMPLATE/NHC_STATUS"]),
          state: host["STATE"].to_i,
          sample: host["TEMPLATE/NHC_TIMESTAMP"].to_i
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
  end
end

# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require "yaml"
require "uri"

module OneNHC
  # YAML configuration with defaults. Keys are strings (as parsed from YAML).
  class Config
    DEFAULTS = {
      "proc_mounts" => "/proc/mounts",
      "node_name" => nil,
      "groups" => {},
      "report_not_targeted" => false,
      "controller" => {
        "mode" => "monitor",
        "dry_run" => false,
        "consecutive_crit" => 3,
        "consecutive_ok" => 2,
        "cooldown" => 300,
        "reenable_after" => 0,
        "monitor_grace" => 900,
        "never_disable_last" => true,
        "min_healthy_hosts" => 1,
        "include_hosts" => "all",
        "exclude_hosts" => nil,
        "interval" => 60,
        "state_file" => "/var/lib/one-nhc/state.json",
        "notify" => {
          "command" => nil,
          "webhook" => nil
        }
      },
      "checks" => {
        "fs-ro" => {
          "enabled" => true,
          "allowlist" => []
        },
        "datastore-mounts" => {
          "enabled" => true,
          "mounts" => [
            { "path" => "/var/lib/one/datastores", "must_be_mount" => false }
          ]
        },
        "libvirt" => {
          "enabled" => true,
          "uri" => "qemu:///system",
          "timeout" => 6
        }
      }
    }.freeze

    def self.load(path = nil)
      merged = deep_dup(DEFAULTS)

      if path && !path.to_s.empty? && File.file?(path)
        user = YAML.safe_load(File.read(path, encoding: "UTF-8"), aliases: false) || {}
        raise ArgumentError, "config root must be a mapping" unless user.is_a?(Hash)

        merged = deep_merge(merged, user)
      end

      new(merged)
    end

    def self.deep_merge(base, override)
      base.merge(override) do |_key, old_value, new_value|
        if old_value.is_a?(Hash) && new_value.is_a?(Hash)
          deep_merge(old_value, new_value)
        else
          new_value
        end
      end
    end

    def self.deep_dup(hash)
      hash.each_with_object({}) do |(key, value), acc|
        acc[key] = value.is_a?(Hash) ? deep_dup(value) : value
      end
    end

    def initialize(hash)
      @hash = hash
    end

    def [](key)
      @hash[key]
    end

    def dig(*keys)
      @hash.dig(*keys)
    end

    def check(id)
      (@hash["checks"] || {})[id.to_s] || {}
    end

    # Validates every hosts/exclude expression, every group definition and the
    # controller settings. Raises ArgumentError with a clear message on unknown
    # groups, cycles, unbalanced brackets, invalid ranges or bad controller
    # values.
    def validate!
      groups     = @hash["groups"] || {}
      checks     = @hash["checks"] || {}
      controller = @hash["controller"] || {}

      checks.each do |_id, options|
        %w[hosts exclude].each do |key|
          expression = options[key]
          next if expression.nil? || expression.to_s.strip.empty?

          Hostlist.expand(expression, groups: groups)
        end
      end

      groups.each_key do |name|
        Hostlist.expand(groups[name], groups: groups, seen: [name])
      end

      validate_controller!(controller, groups)

      true
    end

    def to_h
      @hash
    end

    private

    MODES = %w[monitor notify act].freeze
    NON_NEGATIVE = %w[cooldown reenable_after monitor_grace].freeze
    POSITIVE     = %w[consecutive_crit consecutive_ok interval min_healthy_hosts].freeze

    def validate_controller!(controller, groups)
      unless controller.is_a?(Hash)
        raise ArgumentError, "controller must be a mapping"
      end

      # Config.new may be built without a controller section; Config.load
      # always merges the defaults. Only validate what is present.
      return if controller.empty?

      %w[dry_run never_disable_last].each do |key|
        value = controller[key]
        next if value.nil? || value == true || value == false

        raise ArgumentError, "controller.#{key} must be true or false"
      end

      mode = controller["mode"].to_s
      unless MODES.include?(mode)
        raise ArgumentError,
              "controller.mode must be one of #{MODES.join(', ')} (got '#{mode}')"
      end

      POSITIVE.each do |key|
        next if controller[key].nil?

        value = positive_integer(key, controller[key])
        raise ArgumentError, "controller.#{key} must be >= 1" if value < 1
      end

      NON_NEGATIVE.each do |key|
        next if controller[key].nil?

        value = positive_integer(key, controller[key])
        raise ArgumentError, "controller.#{key} must be >= 0" if value.negative?
      end

      %w[include_hosts exclude_hosts].each do |key|
        expression = controller[key]
        next if expression.nil? || expression.to_s.strip.empty?

        Hostlist.expand(expression, groups: groups)
      end

      state_file = controller["state_file"]
      unless state_file.is_a?(String) && !state_file.strip.empty?
        raise ArgumentError, "controller.state_file must be a non-empty path"
      end

      notify = controller["notify"] || {}
      raise ArgumentError, "controller.notify must be a mapping" unless notify.is_a?(Hash)

      %w[command webhook].each do |key|
        value = notify[key]
        next if value.nil? || value.to_s.strip.empty?

        if key == "webhook"
          begin
            URI.parse(value.to_s)
          rescue URI::InvalidURIError
            raise ArgumentError, "controller.notify.webhook is not a valid URL"
          end
        end
      end
    end

    def positive_integer(key, value)
      Integer(value)
    rescue ArgumentError, TypeError
      raise ArgumentError, "controller.#{key} must be an integer (got '#{value}')"
    end
  end
end

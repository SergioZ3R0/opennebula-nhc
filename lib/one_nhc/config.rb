# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require "yaml"

module OneNHC
  # YAML configuration with defaults. Keys are strings (as parsed from YAML).
  class Config
    DEFAULTS = {
      "proc_mounts" => "/proc/mounts",
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

    def to_h
      @hash
    end
  end
end

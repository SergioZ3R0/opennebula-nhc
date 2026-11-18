# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require "json"
require "fileutils"

module OneNHC
  # Per-host cache for heavy checks. The probe reads it and `one-nhc cache`
  # writes it from a systemd timer.
  class Cache
    # Bump when the on-disk layout changes in a way that old entries cannot be
    # trusted. Entries without a schema_version are legacy files and are still
    # accepted; entries written by a newer schema are ignored.
    SCHEMA_VERSION = 1

    def initialize(path)
      @path = path
    end

    # Returns a Result when the cached entry exists and is fresh, nil otherwise.
    def result(check_id, ttl:, now: Time.now.to_i)
      data  = load
      return nil if schema_mismatch?(data)

      entry = data.dig("checks", check_id)
      return nil unless entry.is_a?(Hash)

      at    = entry["at"].to_i
      ttl   = ttl.to_i
      age   = now - at

      return nil if at.zero? || ttl <= 0
      return nil if age.negative? || age > ttl

      status = entry["status"].to_s.downcase.to_sym
      return nil unless Result::STATUSES.include?(status)

      message = entry["message"].to_s
      message = "#{message} (cached #{age}s ago)" unless message.empty?
      metrics = entry["metrics"].is_a?(Hash) ? entry["metrics"] : {}

      Result.new(
        check_id: check_id,
        status: status,
        message: message,
        metrics: metrics.merge("cached_age" => age, "cached" => true)
      )
    end

    def write(results, host:, now: Time.now.to_i)
      checks = {}

      results.each do |result|
        checks[result.check_id] = result.to_h.merge(at: now)
      end

      data = {
        "schema_version" => SCHEMA_VERSION,
        "generated_at" => now,
        "host" => host.to_s,
        "checks" => checks
      }

      dir = File.dirname(@path)
      FileUtils.mkdir_p(dir) unless dir == "."

      tmp = "#{@path}.tmp.#{Process.pid}"
      File.write(tmp, "#{JSON.pretty_generate(data)}\n")
      File.rename(tmp, @path)
    end

    def load
      return {} unless File.file?(@path)

      data = JSON.parse(File.read(@path))
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError
      {}
    end

    # Missing schema_version means a legacy cache file: accept it. A different
    # value means the file was written by an incompatible version: ignore it.
    def schema_mismatch?(data)
      return false unless data.key?("schema_version")

      data["schema_version"].to_i != SCHEMA_VERSION
    end
  end
end

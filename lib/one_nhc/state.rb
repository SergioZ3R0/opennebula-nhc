# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require "json"
require "fileutils"

module OneNHC
  # Persistent per-host controller state (JSON).
  #
  # The file is rewritten atomically (temporary file + rename) so a crash in
  # the middle of a cycle cannot leave a truncated state.
  class State
    DEFAULTS = {
      "crit_count" => 0,
      "ok_count" => 0,
      "disabled_by_nhc" => false,
      "last_action" => 0,
      "last_enable" => 0,
      "last_sample" => 0,
      "warn_notified" => false,
      "notified_action" => nil,
      "last_status" => nil
    }.freeze

    def initialize(path)
      @path = path
      @data = load
    end

    # Returns the entry for a host, filling in any missing key in place so the
    # caller keeps a stable reference and state files written by older
    # versions keep working.
    def entry(name)
      @data["hosts"] = {} unless @data["hosts"].is_a?(Hash)
      hosts = @data["hosts"]

      current = hosts[name]
      current = {} unless current.is_a?(Hash)
      hosts[name] = current

      DEFAULTS.each do |key, value|
        current[key] = value unless current.key?(key)
      end

      current
    end

    def save
      dir = File.dirname(@path)
      FileUtils.mkdir_p(dir) unless dir == "."

      tmp = "#{@path}.tmp.#{Process.pid}"
      File.write(tmp, "#{JSON.pretty_generate(@data)}\n")
      File.rename(tmp, @path)
    end

    def to_h
      @data
    end

    private

    def load
      return { "hosts" => {} } unless File.file?(@path)

      data = JSON.parse(File.read(@path))
      data.is_a?(Hash) ? data : { "hosts" => {} }
    rescue JSON::ParserError
      { "hosts" => {} }
    end
  end
end

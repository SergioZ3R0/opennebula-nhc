# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

module OneNHC
  # Runs the registered checks against a configuration.
  class Runner
    def initialize(config, only: nil)
      @config = config
      @only   = only && Array(only).map(&:to_s)
    end

    def results
      selected.map { |check| check.call(@config) }
    end

    def selected
      OneNHC.checks.select do |check|
        check.enabled?(@config) && (@only.nil? || @only.include?(check.id))
      end
    end

    # Worst status across results: crit > warn > unknown > ok.
    # `skip` is ignored unless every result was skipped.
    def self.worst(results)
      return :ok if results.empty?

      statuses = results.map(&:status)
      return :skip if statuses.all? { |status| status == :skip }

      statuses.reject { |status| status == :skip }
              .max_by { |status| Result::RANK[status] } || :ok
    end

    def self.exit_code(results)
      case worst(results)
      when :crit then 2
      when :warn then 1
      when :unknown then 3
      else 0
      end
    end
  end
end

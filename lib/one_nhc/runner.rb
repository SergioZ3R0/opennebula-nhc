# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

module OneNHC
  # Runs the registered checks against a configuration.
  class Runner
    attr_reader :config, :node

    def initialize(config, only: nil, node: nil, cache: nil)
      @config = config
      @only   = only && Array(only).map(&:to_s)
      @node   = node || OneNHC.node_name
      @cache  = cache
    end

    def results(use_cache: false)
      selected.map { |check| run(check, use_cache: use_cache) }
    end

    # Runs only the heavy checks, for `one-nhc cache`.
    def heavy_results
      selected.select(&:heavy?).map { |check| check.call(@config) }
    end

    # Checks enabled and targeted at this node.
    def selected
      OneNHC.checks.select do |check|
        check.enabled?(@config) && targeted?(check) &&
          (@only.nil? || @only.include?(check.id))
      end
    end

    # Checks enabled but intentionally not run on this node.
    def not_targeted
      OneNHC.checks.select do |check|
        check.enabled?(@config) && !targeted?(check) &&
          (@only.nil? || @only.include?(check.id))
      end
    end

    # Results for the probe. By default it returns only the executed checks.
    # When report_not_targeted is true, checks that are enabled but not targeted
    # are reported as SKIP so the Monitoring Information does not keep a stale
    # value from a previous run.
    def probe_results
      executed = results(use_cache: true)
      return executed unless @config["report_not_targeted"]

      skipped = not_targeted.map do |check|
        Result.new(
          check_id: check.id,
          status: :skip,
          message: "not targeted on #{node}"
        )
      end

      executed + skipped
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

    private

    def run(check, use_cache:)
      return check.call(@config) unless use_cache && check.heavy?

      cached = @cache&.result(check.id, ttl: check.ttl)
      return cached if cached

      Result.new(
        check_id: check.id,
        status: :unknown,
        message: "heavy check cache missing or stale"
      )
    end

    def targeted?(check)
      check.targets_host?(@config, @node)
    rescue ArgumentError => e
      warn "one-nhc: #{check.id}: #{e.message}"
      false
    end
  end
end

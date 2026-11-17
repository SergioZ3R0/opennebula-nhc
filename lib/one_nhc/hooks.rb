# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

module OneNHC
  # Runs post-action hooks after the controller applies an action.
  #
  # Hooks are intentionally limited to applied actions in `act` mode. They do
  # not run in `monitor`, `notify` or `dry_run`, so they cannot perform
  # automation when the operator only asked for observation.
  class Hooks
    ACTIONS = %w[disable enable reenable].freeze

    def initialize(config)
      hooks     = config.dig("controller", "hooks") || {}
      @timeout  = Integer(hooks.fetch("timeout", 10))
      @commands = {}

      ACTIONS.each do |action|
        key = "on_#{action}"
        @commands[action] = Array(hooks[key]).map(&:to_s).reject(&:empty?)
      end
    end

    def run(payload)
      action   = payload[:action].to_s
      commands = @commands[action] || []
      return if commands.empty?

      commands.each { |command| run_command(command, payload) }
    end

    private

    def run_command(command, payload)
      env = {
        "NHC_MESSAGE" => payload[:message].to_s,
        "NHC_HOST" => payload[:host].to_s,
        "NHC_HOST_ID" => payload[:host_id].to_s,
        "NHC_STATUS" => payload[:status].to_s,
        "NHC_ACTION" => payload[:action].to_s,
        "NHC_APPLIED" => payload[:applied].to_s,
        "NHC_TIME" => payload[:time].to_s,
        "NHC_SAMPLE" => payload[:sample].to_s
      }

      _out, err, status, result = Shell.capture(
        ["sh", "-c", command], timeout: @timeout, env: env
      )
      return if result == :ok && status&.success?

      warn "one-nhc: hook #{payload[:action]} failed (#{result}): #{err.to_s.strip[0, 200]}"
    rescue StandardError => e
      warn "one-nhc: hook #{payload[:action]} failed: #{e.class}: #{e.message}"
    end
  end
end

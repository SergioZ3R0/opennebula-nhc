# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require "timeout"

module OneNHC
  # Base check. A check declares metadata and a block that receives a Context
  # and finishes with one of the ok!/warn!/crit!/skip!/unknown! helpers.
  #
  #   OneNHC.check(id: "fs-ro", description: "...", timeout: 5) do |ctx|
  #     ctx.ok!("all good")
  #   end
  class Check
    attr_reader :id, :description, :severity, :timeout, :tags

    def initialize(id:, description: "", severity: :crit, timeout: 5, tags: [], &block)
      raise ArgumentError, "check requires a block" unless block

      @id          = id.to_s
      @description = description.to_s
      @severity    = severity
      @timeout     = Integer(timeout)
      @tags        = Array(tags)
      @block       = block
    end

    def enabled?(config)
      config.check(id).fetch("enabled", true)
    end

    def call(config)
      ctx = Context.new(self, config)
      Timeout.timeout(timeout) { catch(:done) { @block.call(ctx) } }
      ctx.result || Context.ok(id)
    rescue Timeout::Error
      Result.new(check_id: id, status: :unknown, message: "timeout after #{timeout}s")
    rescue StandardError => e
      Result.new(check_id: id, status: :unknown, message: "#{e.class}: #{e.message}")
    end

    # Execution context handed to each check block.
    class Context
      attr_reader :check, :config, :result

      def self.ok(id)
        Result.new(check_id: id, status: :ok, message: "")
      end

      def initialize(check, config)
        @check  = check
        @config = config
      end

      def ok!(message = "", metrics: {})
        finish(:ok, message, metrics)
      end

      def warn!(message = "", metrics: {})
        finish(:warn, message, metrics)
      end

      def crit!(message = "", metrics: {})
        finish(:crit, message, metrics)
      end

      def skip!(message = "", metrics: {})
        finish(:skip, message, metrics)
      end

      def unknown!(message = "", metrics: {})
        finish(:unknown, message, metrics)
      end

      private

      def finish(status, message, metrics)
        @result = Result.new(
          check_id: check.id, status: status, message: message, metrics: metrics
        )
        throw :done
      end
    end
  end
end

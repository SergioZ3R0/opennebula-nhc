# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

module OneNHC
  # Immutable result of a single check.
  class Result
    STATUSES = %i[ok warn crit skip unknown].freeze

    # Severity ranking used to aggregate the worst status.
    # `skip` never wins the aggregate (see Runner.worst).
    RANK = { ok: 0, skip: 0, unknown: 1, warn: 2, crit: 3 }.freeze

    attr_reader :check_id, :status, :message, :metrics

    def initialize(check_id:, status:, message: "", metrics: {})
      unless STATUSES.include?(status)
        raise ArgumentError, "invalid status #{status.inspect}"
      end

      @check_id = check_id.to_s
      @status   = status
      @message  = message.to_s
      @metrics  = (metrics || {}).freeze
      freeze
    end

    def to_h
      {
        id: check_id,
        status: status.to_s.upcase,
        message: message,
        metrics: metrics
      }
    end
  end
end

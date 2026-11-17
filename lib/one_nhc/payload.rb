# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require "time"

module OneNHC
  # Payload shared by notifications, hooks and tests.
  module Payload
    module_function

    def build(message, host, decision, now: Time.now)
      {
        message: message,
        host: host.name,
        host_id: host.id,
        status: host.status,
        action: decision.action.to_s,
        applied: decision.applied,
        time: now.utc.iso8601,
        sample: host.respond_to?(:sample) ? host.sample : nil,
        details: host.respond_to?(:details) ? (host.details || {}) : {}
      }
    end
  end
end

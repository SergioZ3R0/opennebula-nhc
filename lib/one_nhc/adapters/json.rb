# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require "json"

module OneNHC
  module Adapters
    # JSON output for automation and notifications.
    module Json
      module_function

      def render(results)
        payload = {
          status: Runner.worst(results).to_s.upcase,
          checks: results.map(&:to_h)
        }

        "#{JSON.pretty_generate(payload)}\n"
      end
    end
  end
end

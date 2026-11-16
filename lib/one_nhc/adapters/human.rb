# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

module OneNHC
  module Adapters
    # NHC-style human readable output.
    module Human
      module_function

      def render(results)
        width = results.map { |result| result.check_id.length }.max || 10

        lines = results.map do |result|
          format(
            "%-*s [%-7s] %s",
            width, result.check_id,
            result.status.to_s.upcase, result.message
          )
        end

        counts = Hash.new(0)
        results.each { |result| counts[result.status] += 1 }

        lines << "-" * 56
        lines << format(
          "NHC_STATUS=%s (crit=%d warn=%d ok=%d skip=%d unknown=%d)",
          Runner.worst(results).to_s.upcase,
          counts[:crit], counts[:warn], counts[:ok], counts[:skip], counts[:unknown]
        )

        "#{lines.join("\n")}\n"
      end
    end
  end
end

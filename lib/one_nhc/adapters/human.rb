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

      # Host status read from the OpenNebula API (`one-nhc status`).
      def hosts(hosts)
        return "no hosts found\n" if hosts.empty?

        width = hosts.map { |host| host.name.to_s.length }.max || 10
        lines = hosts.map do |host|
          details = host.details || {}
          summary = format(
            "cluster=%s checks=%s crit=%s warn=%s ok=%s",
            host.cluster.to_s.empty? ? "default" : host.cluster,
            details.fetch("NHC_CHECK_COUNT", 0),
            details.fetch("NHC_CRIT", 0),
            details.fetch("NHC_WARN", 0),
            details.fetch("NHC_OK", 0)
          )
          format(
            "%-*s [%-7s] %s",
            width, host.name, host.status.to_s.upcase, summary
          )
        end

        "#{lines.join("\n")}\n"
      end
    end
  end
end

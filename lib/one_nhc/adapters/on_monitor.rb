# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

module OneNHC
  module Adapters
    # Emits OpenNebula IM monitoring attributes (KEY="VALUE").
    #
    # The Information Manager merges these attributes into the host
    # MONITORING INFORMATION, so they can be read with `onehost show`.
    module OnMonitor
      MAX_MESSAGE = 200

      module_function

      def render(results, now: Time.now)
        counts = Hash.new(0)
        results.each { |result| counts[result.status] += 1 }

        lines = []
        lines << kv("NHC_STATUS", Runner.worst(results).to_s.upcase)
        lines << kv("NHC_CHECK_COUNT", results.size)
        lines << kv("NHC_TIMESTAMP", now.to_i)

        %i[ok warn crit skip unknown].each do |status|
          lines << kv("NHC_#{status.to_s.upcase}", counts[status])
        end

        results.each do |result|
          key = attribute_name(result.check_id)
          lines << kv(key, result.status.to_s.upcase)
          lines << kv("#{key}_MSG", result.message) unless result.message.empty?
        end

        "#{lines.join("\n")}\n"
      end

      # IM expects ATTRIBUTE="value": single line, no double quotes.
      def sanitize(value)
        text = value.to_s.gsub(/["\\]/, "'").gsub(/\s+/, " ").strip
        text.length > MAX_MESSAGE ? text[0, MAX_MESSAGE] : text
      end

      def attribute_name(check_id)
        "NHC_#{check_id.to_s.upcase.gsub(/[^A-Z0-9_]/, '_')}"
      end

      def kv(key, value)
        %(#{key}="#{sanitize(value)}")
      end
    end
  end
end

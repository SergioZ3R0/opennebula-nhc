# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

module OneNHC
  module Adapters
    # Nagios/Icinga plugin output: one short line, optional long output and
    # performance data. Exit codes are handled by the CLI.
    module Nagios
      LABELS = {
        ok: "OK",
        warn: "WARNING",
        crit: "CRITICAL",
        unknown: "UNKNOWN",
        skip: "OK"
      }.freeze

      # NHC_* keys that are summary counters, not individual checks.
      SUMMARY_KEYS = %w[
        NHC_STATUS NHC_TIMESTAMP NHC_CHECK_COUNT NHC_OK NHC_WARN NHC_CRIT
        NHC_SKIP NHC_UNKNOWN NHC_ERROR NHC_DISABLED
      ].freeze

      module_function

      # Local check results (`one-nhc check --nagios`).
      def check(results)
        counts = counts_for(results.map(&:status))
        worst  = Runner.worst(results)
        failed = results.reject { |result| %i[ok skip].include?(result.status) }
        summary = if results.empty?
                    "no checks selected"
                  elsif failed.empty?
                    "#{results.size} check(s) OK"
                  else
                    "#{failed.size}/#{results.size} check(s) not OK " \
                      "(#{failed.map(&:check_id).join(', ')})"
                  end

        lines = [header(worst, summary, perfdata(counts, "checks"))]
        failed.each do |result|
          lines << "#{result.check_id}: #{result.status.to_s.upcase} " \
                   "#{result.message}".strip
        end
        lines << "All checks passed" if failed.empty? && !results.empty?
        "#{lines.join("\n")}\n"
      end

      # Host views read from the OpenNebula API (`one-nhc status --nagios`).
      def hosts(hosts)
        statuses = hosts.map { |host| normalize(host.status) }
        counts   = counts_for(statuses)
        worst    = worst_status(statuses)
        bad      = hosts.reject { |host| %i[ok skip].include?(normalize(host.status)) }
        summary  = if hosts.empty?
                     "no hosts found"
                   elsif bad.empty?
                     "all #{hosts.size} host(s) OK"
                   else
                     "#{bad.size}/#{hosts.size} host(s) not OK " \
                       "(#{bad.map(&:name).join(', ')})"
                   end

        lines = [header(worst, summary, perfdata(counts, "hosts"))]
        bad.each do |host|
          lines << "#{host.name}: #{host.status} #{failure(host)}".strip
        end
        lines << "All hosts OK" if bad.empty? && !hosts.empty?
        "#{lines.join("\n")}\n"
      end

      # Exit code for a list of NHC_STATUS values.
      def exit_code(statuses)
        case worst_status(statuses.map { |status| normalize(status) })
        when :crit then 2
        when :warn then 1
        when :unknown then 3
        else 0
        end
      end

      def normalize(value)
        status = value.to_s.strip.downcase.to_sym
        %i[ok warn crit skip unknown].include?(status) ? status : :unknown
      end

      def worst_status(statuses)
        return :unknown if statuses.empty?
        return :skip if statuses.all? { |status| status == :skip }

        statuses.reject { |status| status == :skip }
                .max_by { |status| Result::RANK[status] } || :ok
      end

      def counts_for(statuses)
        counts = Hash.new(0)
        statuses.each { |status| counts[status] += 1 }
        counts
      end

      def perfdata(counts, total_label)
        [
          "#{total_label}=#{counts.values.sum}",
          "ok=#{counts[:ok]}",
          "warn=#{counts[:warn]}",
          "crit=#{counts[:crit]}",
          "skip=#{counts[:skip]}",
          "unknown=#{counts[:unknown]}"
        ].join(" ")
      end

      def header(worst, summary, perfdata)
        "#{LABELS.fetch(worst, 'UNKNOWN')} - #{summary} | #{perfdata}"
      end

      # First non-OK NHC_* check in the host details, with its message.
      def failure(host)
        details = host.respond_to?(:details) ? (host.details || {}) : {}

        details.each do |key, value|
          next unless key.start_with?("NHC_")
          next if SUMMARY_KEYS.include?(key) || key.end_with?("_MSG")
          next if %w[OK SKIP].include?(value.to_s.upcase)

          id      = key.sub(/\ANHC_/, "").downcase.tr("_", "-")
          message = details["#{key}_MSG"].to_s
          return message.empty? ? "#{id} #{value}" : "#{id}: #{message}"
        end

        details["NHC_ERROR"].to_s
      end
    end
  end
end

# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require "cgi"
require "time"

module OneNHC
  # Renders the HTML and plain-text bodies of the controller emails.
  module EmailTemplate
    module_function

    STATUS_STYLES = {
      "CRIT" => { bg: "#fee2e2", fg: "#991b1b", accent: "#ef4444", label: "CRITICAL" },
      "WARN" => { bg: "#fef3c7", fg: "#92400e", accent: "#f59e0b", label: "WARNING" },
      "OK" => { bg: "#dcfce7", fg: "#166534", accent: "#22c55e", label: "HEALTHY" },
      "SKIP" => { bg: "#dbeafe", fg: "#1e40af", accent: "#3b82f6", label: "SKIPPED" },
      "UNKNOWN" => { bg: "#e5e7eb", fg: "#374151", accent: "#6b7280", label: "UNKNOWN" }
    }.freeze

    SUMMARY_KEYS = %w[
      NHC_CHECK_COUNT NHC_CRIT NHC_WARN NHC_OK NHC_SKIP NHC_UNKNOWN
      NHC_STATUS NHC_TIMESTAMP NHC_ERROR
    ].freeze

    ACTION_LABELS = {
      "disable" => "Host quarantine",
      "refuse_disable" => "Quarantine refused",
      "enable" => "Host enabled",
      "reenable" => "Trial re-enable",
      "test" => "Test notification"
    }.freeze

    def html(payload)
      details = payload[:details] || {}
      style   = style_for(payload[:status])
      checks  = check_rows(details)
      summary = summary_text(details)
      sample  = sample_string(payload)
      error   = details["NHC_ERROR"].to_s

      checks_section = if checks.empty?
                         ""
                       else
                         <<~SECTION
                           <div style="font-size:12px;font-weight:700;letter-spacing:0.08em;text-transform:uppercase;color:#6b7280;margin:24px 0 6px;">Checks</div>
                           <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:13px;line-height:1.5;">
                             #{checks}
                           </table>
                         SECTION
                       end

      summary_html = if summary.empty?
                       ""
                     else
                       %(<div style="margin-top:14px;font-size:13px;color:#6b7280;">#{escape(summary)}</div>)
                     end

      sample_row = if sample
                     "<tr><td style=\"padding:6px 0;color:#6b7280;\">Probe sample</td><td style=\"padding:6px 0;color:#111827;\">#{escape(sample)}</td></tr>"
                   else
                     ""
                   end

      error_note = if error.empty?
                     ""
                   else
                     <<~NOTE
                       <div style="margin-top:18px;padding:12px 14px;background:#fffbeb;border-left:3px solid #f59e0b;border-radius:6px;font-size:13px;line-height:1.5;color:#92400e;">Probe error: #{escape(error)}</div>
                     NOTE
                   end

      <<~HTML
        <!DOCTYPE html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
          </head>
          <body style="margin:0;padding:0;background:#f3f4f6;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#111827;">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f4f6;padding:24px 12px;">
              <tr>
                <td align="center">
                  <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:100%;max-width:600px;background:#ffffff;border-radius:10px;overflow:hidden;border-top:4px solid #{style[:accent]};box-shadow:0 1px 3px rgba(0,0,0,0.08);">
                    <tr>
                      <td style="background:#111827;padding:22px 26px;color:#ffffff;">
                        <div style="font-size:12px;letter-spacing:0.16em;text-transform:uppercase;color:#9ca3af;">one-nhc</div>
                        <div style="font-size:22px;font-weight:700;margin-top:6px;">Host health alert</div>
                      </td>
                    </tr>
                    <tr>
                      <td style="padding:24px 26px 0;">
                        <span style="display:inline-block;padding:5px 11px;border-radius:999px;background:#{style[:bg]};color:#{style[:fg]};font-size:12px;font-weight:700;letter-spacing:0.04em;">#{escape(payload[:status])}</span>
                        <span style="display:inline-block;padding:5px 11px;border-radius:999px;background:#f3f4f6;color:#374151;font-size:12px;font-weight:600;margin-left:6px;">#{escape(payload[:action])}</span>
                        <div style="font-size:20px;font-weight:700;margin:18px 0 2px;color:#111827;">#{escape(payload[:host])}</div>
                        <div style="font-size:14px;color:#6b7280;">OpenNebula host id #{escape(payload[:host_id])}</div>
                      </td>
                    </tr>
                    <tr>
                      <td style="padding:20px 26px;">
                        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:14px;line-height:1.6;">
                          <tr>
                            <td style="padding:6px 0;color:#6b7280;width:120px;">Status</td>
                            <td style="padding:6px 0;font-weight:600;color:#111827;">#{escape(payload[:status])} (#{escape(style[:label])})</td>
                          </tr>
                          <tr>
                            <td style="padding:6px 0;color:#6b7280;">Action</td>
                            <td style="padding:6px 0;font-weight:600;color:#111827;">#{escape(payload[:action])} (#{escape(action_label(payload[:action]))})</td>
                          </tr>
                          <tr>
                            <td style="padding:6px 0;color:#6b7280;">Applied</td>
                            <td style="padding:6px 0;font-weight:600;color:#111827;">#{escape(applied_label(payload[:applied]))}</td>
                          </tr>
                          <tr>
                            <td style="padding:6px 0;color:#6b7280;">Host</td>
                            <td style="padding:6px 0;font-weight:600;color:#111827;">#{escape(payload[:host])} (id #{escape(payload[:host_id])})</td>
                          </tr>
                          <tr>
                            <td style="padding:6px 0;color:#6b7280;">Time</td>
                            <td style="padding:6px 0;color:#111827;">#{escape(time_string(payload))}</td>
                          </tr>
                          #{sample_row}
                        </table>
                        #{summary_html}
                        #{checks_section}
                        <div style="margin-top:18px;padding:14px 16px;background:#f9fafb;border-left:3px solid #{style[:accent]};border-radius:6px;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:13px;line-height:1.55;color:#111827;white-space:pre-wrap;">#{escape(payload[:message])}</div>
                        #{error_note}
                      </td>
                    </tr>
                    <tr>
                      <td style="padding:0 26px 22px;color:#9ca3af;font-size:12px;line-height:1.5;">
                        Generated by one-nhc · #{escape(time_string(payload))}<br>
                        OpenNebula host health check.
                      </td>
                    </tr>
                  </table>
                </td>
              </tr>
            </table>
          </body>
        </html>
      HTML
    end

    def text(payload)
      details = payload[:details] || {}
      lines   = []
      lines << "one-nhc host health alert"
      lines << "========================="
      lines << ""
      lines << "Host:    #{payload[:host]} (id #{payload[:host_id]})"
      lines << "Status:  #{payload[:status]} (#{style_for(payload[:status])[:label]})"
      lines << "Action:  #{payload[:action]} (#{action_label(payload[:action])})"
      lines << "Applied: #{applied_label(payload[:applied])}"
      lines << "Time:    #{time_string(payload)}"

      sample = sample_string(payload)
      lines << "Sample:  #{sample}" if sample

      summary = summary_text(details)
      lines << ""
      lines << "Summary: #{summary}" unless summary.empty?

      checks = check_rows(details, html: false)
      unless checks.empty?
        lines << ""
        lines << "Checks:"
        checks.each do |check|
          lines << format("  %-6s %-20s %s", check[:status], check[:id], check[:message])
        end
      end

      error = details["NHC_ERROR"].to_s
      lines << "" << "Probe error: #{error}" unless error.empty?

      lines << ""
      lines << "Message:"
      lines << payload[:message].to_s
      lines << ""
      lines << "--"
      lines << "Generated by one-nhc. OpenNebula host health check."
      "#{lines.join("\n")}\n"
    end

    def check_rows(details, html: true)
      checks = details.reject do |key, _|
        SUMMARY_KEYS.include?(key) || key.end_with?("_MSG")
      end.map do |key, value|
        {
          id: key.sub(/\ANHC_/, "").downcase.tr("_", "-"),
          status: value.to_s.upcase,
          message: details["#{key}_MSG"].to_s
        }
      end.sort_by { |check| check[:id] }

      return checks unless html

      checks.map do |check|
        style = style_for(check[:status])
        <<~ROW
          <tr>
            <td style="padding:7px 0;width:86px;vertical-align:top;">
              <span style="display:inline-block;padding:3px 8px;border-radius:999px;background:#{style[:bg]};color:#{style[:fg]};font-size:11px;font-weight:700;letter-spacing:0.04em;">#{escape(check[:status])}</span>
            </td>
            <td style="padding:7px 0;vertical-align:top;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:13px;color:#111827;">#{escape(check[:id])}</td>
            <td style="padding:7px 0;vertical-align:top;font-size:13px;color:#6b7280;">#{escape(check[:message])}</td>
          </tr>
        ROW
      end.join
    end

    def summary_text(details)
      parts = []
      count = details["NHC_CHECK_COUNT"]
      parts << "#{count} checks" if count && !count.to_s.empty?

      %w[NHC_CRIT NHC_WARN NHC_OK NHC_SKIP NHC_UNKNOWN].each do |key|
        value = details[key]
        next if value.nil? || value.to_s.empty?

        parts << "#{value} #{key.sub('NHC_', '').downcase}"
      end

      parts.join(" · ")
    end

    def style_for(status)
      STATUS_STYLES.fetch(status.to_s.upcase, STATUS_STYLES["UNKNOWN"])
    end

    def action_label(action)
      ACTION_LABELS.fetch(action.to_s, action.to_s)
    end

    def applied_label(applied)
      applied == true ? "yes" : "no"
    end

    def time_string(payload)
      time = payload[:time]

      if time.is_a?(String)
        begin
          time = Time.iso8601(time)
        rescue ArgumentError
          return time
        end
      end

      if time.respond_to?(:utc) && time.respond_to?(:strftime)
        time.utc.strftime("%Y-%m-%d %H:%M:%S UTC")
      elsif time.respond_to?(:strftime)
        time.strftime("%Y-%m-%d %H:%M:%S UTC")
      else
        time.to_s
      end
    end

    def sample_string(payload)
      sample = payload[:sample].to_i
      return nil unless sample.positive?

      Time.at(sample).utc.strftime("%Y-%m-%d %H:%M:%S UTC")
    end

    def escape(value)
      CGI.escapeHTML(value.to_s)
    end
  end
end

# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

module OneNHC
  # Minimal host view used by the controller. It is decoupled from the
  # OpenNebula bindings so the logic can be tested with a fake API.
  #
  # `sample` is the probe timestamp (NHC_TIMESTAMP) used to apply hysteresis
  # to distinct monitoring samples instead of counting the same value on every
  # controller cycle. `details` is the NHC_* template hash used by the email
  # notification to list the checks.
  HostView = Struct.new(
    :id, :name, :status, :state, :sample, :details, :cluster,
    keyword_init: true
  )

  # Evaluates host health and optionally quarantines or re-enables hosts.
  #
  # Modes:
  #   monitor - evaluate and log only
  #   notify  - evaluate, log and notify (command and/or webhook)
  #   act     - evaluate, log, notify and onehost disable/enable
  #
  # Safety rules:
  #   - Hysteresis: N consecutive CRIT to act, M consecutive OK to re-enable.
  #   - Cooldown between actions on the same host.
  #   - Never disable when there is no other healthy monitored host.
  #   - Decisions are announced once per episode (no notification spam).
  #   - After re-enabling a host, stale CRIT values are ignored for
  #     `monitor_grace` seconds so the probe can report again.
  class Controller
    HOST_MONITORED = 2
    HOST_DISABLED  = 4
    MODES = %w[monitor notify act].freeze

    Decision = Struct.new(:host, :action, :reason, :applied, keyword_init: true)

    def initialize(config, api:, state:, notifier: nil, hooks: nil, now: -> { Time.now },
                   logger: nil, mode: nil, dry_run: nil)
      @config   = config
      @api      = api
      @state    = state
      @notifier = notifier
      @hooks    = hooks
      @now      = now
      @logger   = logger || ->(message) { puts message }

      @mode = (mode || setting("mode") || "monitor").to_s
      @mode = "monitor" unless MODES.include?(@mode)
      @dry_run = dry_run.nil? ? setting("dry_run") : dry_run
    end

    attr_reader :mode, :dry_run

    def run
      hosts   = @api.hosts
      healthy = hosts.count { |host| healthy?(host) }

      healthy_by_cluster = Hash.new(0)
      hosts.each do |host|
        healthy_by_cluster[cluster_key(host)] += 1 if healthy?(host)
      end

      decisions = []

      hosts.each do |host|
        next unless targeted?(host)

        begin
          decisions.concat(evaluate(host, healthy, healthy_by_cluster))
        rescue StandardError => e
          log("error evaluating #{host.name}: #{e.class}: #{e.message}")
        end
      end

      @state.save
      decisions
    end

    private

    def evaluate(host, healthy, healthy_by_cluster)
      entry     = @state.entry(host.name)
      decisions = []

      recover_disabled_state(host, entry)
      clear_external_enable(host, entry)

      if fresh_sample?(host, entry)
        decisions.concat(evaluate_status(host, entry, healthy, healthy_by_cluster))
      end

      if decisions.empty?
        decision = try_trial_reenable(host, entry)
        decisions << decision if decision
      end

      entry["last_status"] = host.status
      decisions
    end

    # Status counters only advance when the probe published a new sample
    # (NHC_TIMESTAMP). Old probes without the attribute are evaluated on every
    # cycle, preserving the previous behaviour.
    def fresh_sample?(host, entry)
      sample = host.sample.to_i
      return true unless sample.positive?
      return false if entry["last_sample"].to_i == sample

      entry["last_sample"] = sample
      true
    end

    def evaluate_status(host, entry, healthy, healthy_by_cluster)
      update_counters(entry, host.status)
      reset_notification(entry) if host.status == "OK" && !entry["disabled_by_nhc"]
      entry["warn_notified"] = false if host.status == "OK"

      decision = if host.status == "CRIT"
                   try_disable(host, entry, healthy, healthy_by_cluster)
                 elsif host.status == "OK"
                   try_enable(host, entry)
                 elsif host.status == "WARN"
                   notify_warn(host, entry)
                 end

      decision ? [decision] : []
    end

    def notify_warn(host, entry)
      return nil if setting("notify_on_warn") == false
      return nil if entry["warn_notified"]

      entry["warn_notified"] = true
      report(host, Decision.new(
               host: host,
               action: :warn,
               reason: "NHC_STATUS=WARN",
               applied: false
             ))
    end

    # A host can be disabled while the state file is lost or the host is
    # renamed. The NHC_DISABLED attribute on the host survives both.
    def recover_disabled_state(host, entry)
      return if entry["disabled_by_nhc"]

      details = host.respond_to?(:details) ? host.details : nil
      flag    = details.is_a?(Hash) && details["NHC_DISABLED"].to_s == "yes"
      return unless flag

      unless host.state == HOST_DISABLED
        # The host is enabled, so the flag is stale (for example, state was
        # lost after an external enable). Clear it instead of trusting it.
        mark_enabled(host.id)
        log("host #{host.name} has a stale NHC_DISABLED attribute, clearing it")
        return
      end

      entry["disabled_by_nhc"] = true
      entry["last_action"]     = @now.call.to_i
      log("host #{host.name} was disabled by one-nhc (recovered from NHC_DISABLED)")
    end

    # A host that was disabled by one-nhc but is monitored again was enabled
    # outside the controller (an operator, another tool): reset the episode.
    def clear_external_enable(host, entry)
      return unless entry["disabled_by_nhc"] && host.state != HOST_DISABLED

      entry["disabled_by_nhc"] = false
      entry["notified_action"] = nil
      entry["crit_count"]      = 0
      entry["ok_count"]        = 0
      entry["last_enable"]     = @now.call.to_i
      mark_enabled(host.id)
      log("host #{host.name} was enabled outside one-nhc, clearing state")
    end

    def update_counters(entry, status)
      case status
      when "CRIT"
        entry["crit_count"] = entry["crit_count"].to_i + 1
        entry["ok_count"]   = 0
      when "OK"
        entry["ok_count"]   = entry["ok_count"].to_i + 1
        entry["crit_count"] = 0
      end
    end

    def reset_notification(entry)
      entry["notified_action"] = nil
    end

    def try_disable(host, entry, healthy, healthy_by_cluster)
      return nil if entry["disabled_by_nhc"]
      return nil unless host.state == HOST_MONITORED
      return nil if within_grace?(entry)
      return nil if entry["crit_count"].to_i < integer("consecutive_crit", 3)
      return nil if cooling_down?(entry)

      min_healthy = minimum_healthy_hosts
      if min_healthy.positive?
        remaining = if cluster_scope?
                      healthy_by_cluster[cluster_key(host)]
                    else
                      healthy
                    end

        if remaining < min_healthy
          reason = if cluster_scope?
                     "would leave #{remaining} healthy host(s) in cluster " \
                       "#{cluster_key(host)}, minimum is #{min_healthy}"
                   else
                     "would leave #{remaining} healthy host(s), minimum is #{min_healthy}"
                   end

          return announce(host, entry, :refuse_disable, reason)
        end
      end

      return nil if entry["notified_action"] == "disable"

      decision = Decision.new(
        host: host,
        action: :disable,
        reason: "CRIT #{entry['crit_count']}/#{integer('consecutive_crit', 3)}",
        applied: false
      )

      if act? && !@dry_run
        @api.disable(host.id)
        decision.applied         = true
        entry["disabled_by_nhc"] = true
        entry["last_action"]     = @now.call.to_i
        mark_disabled(host.id)
      end

      entry["notified_action"] = "disable"
      report(host, decision)
    end

    def try_enable(host, entry)
      return nil unless entry["disabled_by_nhc"]
      return nil unless host.state == HOST_DISABLED
      return nil if entry["ok_count"].to_i < integer("consecutive_ok", 2)
      return nil if cooling_down?(entry)
      return nil if entry["notified_action"] == "enable"

      decision = Decision.new(
        host: host,
        action: :enable,
        reason: "OK #{entry['ok_count']}/#{integer('consecutive_ok', 2)}",
        applied: false
      )

      if act? && !@dry_run
        @api.enable(host.id)
        decision.applied         = true
        entry["disabled_by_nhc"] = false
        entry["last_action"]     = @now.call.to_i
        entry["last_enable"]     = @now.call.to_i
        entry["crit_count"]      = 0
        entry["ok_count"]        = 0
        mark_enabled(host.id)
      end

      entry["notified_action"] = "enable"
      report(host, decision)
    end

    # Opt-in trial re-enable: a disabled host is only monitored again after it
    # is enabled, so the probe cannot report a recovery. When `reenable_after`
    # is configured, enable it again after that delay and let `monitor_grace`
    # protect the fresh monitoring data.
    def try_trial_reenable(host, entry)
      return nil unless entry["disabled_by_nhc"]
      return nil unless host.state == HOST_DISABLED
      return nil unless integer("reenable_after", 0).positive?
      return nil if (@now.call.to_i - entry["last_action"].to_i) < integer("reenable_after", 0)
      return nil if entry["notified_action"] == "reenable"

      decision = Decision.new(
        host: host,
        action: :reenable,
        reason: "trial re-enable after #{integer('reenable_after', 0)}s",
        applied: false
      )

      if act? && !@dry_run
        @api.enable(host.id)
        decision.applied         = true
        entry["disabled_by_nhc"] = false
        entry["last_action"]     = @now.call.to_i
        entry["last_enable"]     = @now.call.to_i
        entry["crit_count"]      = 0
        entry["ok_count"]        = 0
        mark_enabled(host.id)
      end

      entry["notified_action"] = "reenable"
      report(host, decision)
    end

    def announce(host, entry, action, reason)
      return nil if entry["notified_action"] == action.to_s

      entry["notified_action"] = action.to_s
      report(host, Decision.new(
               host: host, action: action, reason: reason, applied: false
             ))
    end

    def report(host, decision)
      state = if decision.applied
                "applied"
              elsif decision.action == :refuse_disable
                "refused"
              elsif decision.action == :warn
                "warning"
              elsif act?
                "dry-run"
              else
                @mode
              end

      message = format(
        "host=%s id=%s status=%s action=%s (%s): %s",
        host.name, host.id, host.status || "-",
        decision.action, state, decision.reason
      )

      log(message)
      @notifier&.notify(message, host: host, decision: decision) if notify?

      if act? && !@dry_run && decision.applied
        @hooks&.run(OneNHC::Payload.build(message, host, decision))
      end

      decision
    end

    def healthy?(host)
      host.state == HOST_MONITORED && host.status == "OK"
    end

    def targeted?(host)
      groups       = @config["groups"] || {}
      include_expr = setting("include_hosts") || "all"

      return false unless Hostlist.match?(include_expr, host.name, groups: groups)

      exclude_expr = setting("exclude_hosts")
      return true if exclude_expr.nil? || exclude_expr.to_s.strip.empty?

      !Hostlist.match?(exclude_expr, host.name, groups: groups)
    end

    def within_grace?(entry)
      grace = integer("monitor_grace", 900)
      return false unless grace.positive?

      last_enable = entry["last_enable"].to_i
      return false if last_enable.zero?

      (@now.call.to_i - last_enable) < grace
    end

    def cooling_down?(entry)
      (@now.call.to_i - entry["last_action"].to_i) < integer("cooldown", 300)
    end

    def minimum_healthy_hosts
      return 0 if setting("never_disable_last") == false

      integer("min_healthy_hosts", 1)
    end

    def cluster_scope?
      setting("min_healthy_hosts_scope").to_s == "cluster"
    end

    def cluster_key(host)
      value = host.respond_to?(:cluster) ? host.cluster.to_s : ""
      value.empty? ? "default" : value
    end

    def mark_disabled(id)
      return unless @api.respond_to?(:mark_disabled)

      @api.mark_disabled(id)
    rescue StandardError => e
      log("could not set NHC_DISABLED on host #{id}: #{e.message}")
    end

    def mark_enabled(id)
      return unless @api.respond_to?(:mark_enabled)

      @api.mark_enabled(id)
    rescue StandardError => e
      log("could not clear NHC_DISABLED on host #{id}: #{e.message}")
    end

    def act?
      @mode == "act"
    end

    def notify?
      %w[notify act].include?(@mode)
    end

    def setting(key)
      (@config["controller"] || {})[key]
    end

    def integer(key, default)
      value = setting(key)
      value.nil? ? default : Integer(value)
    end

    def log(message)
      @logger.call("[one-nhc] #{message}")
    end
  end
end

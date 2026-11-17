# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"

class TestController < Minitest::Test
  MONITORED = OneNHC::Controller::HOST_MONITORED
  DISABLED  = OneNHC::Controller::HOST_DISABLED

  # Minimal stand-in for OneNHC::OnAPI.
  class FakeAPI
    attr_reader :hosts, :disabled, :enabled

    def initialize(hosts)
      @hosts    = hosts
      @disabled = []
      @enabled  = []
    end

    def disable(id)
      @disabled << id
      @hosts.find { |host| host.id == id }&.state = DISABLED
    end

    def enable(id)
      @enabled << id
      @hosts.find { |host| host.id == id }&.state = MONITORED
    end
  end

  class FakeNotifier
    attr_reader :messages

    def initialize
      @messages = []
    end

    def notify(message, host:, decision:)
      @messages << { message: message, host: host.name, action: decision.action }
    end
  end

  class Clock
    attr_reader :now

    def initialize(now = Time.at(1_000_000))
      @now = now
    end

    def call
      @now
    end

    def advance(seconds)
      @now += seconds
    end
  end

  def setup
    @dir      = Dir.mktmpdir
    @logs     = []
    @clock    = Clock.new
    @notifier = FakeNotifier.new
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def host(id:, name:, status:, state: MONITORED, sample: nil)
    OneNHC::HostView.new(
      id: id, name: name, status: status, state: state, sample: sample
    )
  end

  def config(controller = {})
    defaults = OneNHC::Config::DEFAULTS["controller"]
    OneNHC::Config.new(
      "groups" => {},
      "checks" => {},
      "controller" => defaults.merge(controller)
    )
  end

  def state_store(path = File.join(@dir, "state.json"))
    OneNHC::State.new(path)
  end

  def controller(api, cfg: config, store: state_store, mode: nil, dry_run: nil)
    OneNHC::Controller.new(
      cfg,
      api: api,
      state: store,
      notifier: @notifier,
      now: @clock,
      logger: ->(message) { @logs << message },
      mode: mode,
      dry_run: dry_run
    )
  end

  def run_times(controller, times)
    decisions = []
    times.times { decisions.concat(controller.run) }
    decisions
  end

  def test_monitor_mode_logs_but_does_not_disable
    api = FakeAPI.new([
                        host(id: 1, name: "node01", status: "CRIT"),
                        host(id: 2, name: "node02", status: "OK")
                      ])

    decisions = run_times(controller(api, mode: "monitor"), 3)

    assert_empty api.disabled
    assert_equal 1, decisions.size
    assert_equal :disable, decisions.first.action
    refute decisions.first.applied
    assert(@logs.any? { |line| line.include?("(monitor)") })
    assert_empty @notifier.messages
  end

  def test_notify_mode_notifies_once_per_episode
    api = FakeAPI.new([
                        host(id: 1, name: "node01", status: "CRIT"),
                        host(id: 2, name: "node02", status: "OK")
                      ])

    run_times(controller(api, mode: "notify"), 4)

    assert_empty api.disabled
    assert_equal 1, @notifier.messages.size
    assert_equal :disable, @notifier.messages.first[:action]
  end

  def test_notification_resets_after_recovery
    api = FakeAPI.new([
                        host(id: 1, name: "node01", status: "CRIT"),
                        host(id: 2, name: "node02", status: "OK")
                      ])
    ctl = controller(api, mode: "notify")

    run_times(ctl, 3)
    api.hosts.first.status = "OK"
    run_times(ctl, 2)
    api.hosts.first.status = "CRIT"
    run_times(ctl, 3)

    assert_equal 2, @notifier.messages.size
  end

  def test_act_mode_disables_after_hysteresis
    api = FakeAPI.new([
                        host(id: 1, name: "node01", status: "CRIT"),
                        host(id: 2, name: "node02", status: "OK")
                      ])

    decisions = run_times(controller(api, mode: "act"), 3)

    assert_equal [1], api.disabled
    assert_equal :disable, decisions.last.action
    assert decisions.last.applied
    assert_equal 1, @notifier.messages.size
  end

  def test_dry_run_does_not_change_hosts
    api = FakeAPI.new([
                        host(id: 1, name: "node01", status: "CRIT"),
                        host(id: 2, name: "node02", status: "OK")
                      ])

    decisions = run_times(controller(api, mode: "act", dry_run: true), 3)

    assert_empty api.disabled
    assert_equal :disable, decisions.last.action
    refute decisions.last.applied
    assert(@logs.any? { |line| line.include?("(dry-run)") })
  end

  def test_refuses_to_disable_the_last_healthy_host
    api = FakeAPI.new([host(id: 1, name: "node01", status: "CRIT")])
    st  = state_store

    decisions = run_times(controller(api, mode: "act", store: st), 3)

    assert_empty api.disabled
    assert_equal :refuse_disable, decisions.last.action
    refute decisions.last.applied
    refute st.entry("node01")["disabled_by_nhc"]
    assert(@logs.any? { |line| line.include?("(refused)") })
  end

  def test_unknown_and_warn_do_not_disable
    api = FakeAPI.new([
                        host(id: 1, name: "node01", status: "UNKNOWN"),
                        host(id: 2, name: "node02", status: "OK")
                      ])

    run_times(controller(api, mode: "act", cfg: config("consecutive_crit" => 1)), 3)

    assert_empty api.disabled
  end

  def test_reenables_after_consecutive_ok
    api = FakeAPI.new([host(id: 1, name: "node01", status: "OK", state: DISABLED)])
    st  = state_store
    entry = st.entry("node01")
    entry["disabled_by_nhc"] = true
    entry["last_action"]     = 0

    decisions = run_times(controller(api, mode: "act", store: st), 2)

    assert_equal [1], api.enabled
    assert_equal :enable, decisions.last.action
    assert decisions.last.applied
    refute entry["disabled_by_nhc"]
  end

  def test_cooldown_blocks_enable
    api = FakeAPI.new([host(id: 1, name: "node01", status: "OK", state: DISABLED)])
    st  = state_store
    entry = st.entry("node01")
    entry["disabled_by_nhc"] = true
    entry["last_action"]     = @clock.now.to_i

    run_times(controller(api, mode: "act", store: st), 2)
    assert_empty api.enabled

    @clock.advance(301)
    run_times(controller(api, mode: "act", store: st), 1)
    assert_equal [1], api.enabled
  end

  def test_monitor_grace_blocks_redisable_after_enable
    api = FakeAPI.new([
                        host(id: 1, name: "node01", status: "CRIT"),
                        host(id: 2, name: "node02", status: "OK")
                      ])
    st  = state_store
    entry = st.entry("node01")
    entry["crit_count"] = 5
    entry["last_enable"] = @clock.now.to_i

    ctl = controller(api, mode: "act", store: st, cfg: config("cooldown" => 0))
    run_times(ctl, 1)
    assert_empty api.disabled

    @clock.advance(901)
    run_times(ctl, 1)
    assert_equal [1], api.disabled
  end

  def test_external_enable_clears_state
    api = FakeAPI.new([host(id: 1, name: "node01", status: "OK")])
    st  = state_store
    entry = st.entry("node01")
    entry["disabled_by_nhc"] = true
    entry["last_action"]     = 0

    run_times(controller(api, mode: "act", store: st), 1)

    assert_empty api.enabled
    refute entry["disabled_by_nhc"]
    assert_equal @clock.now.to_i, entry["last_enable"]
    assert(@logs.any? { |line| line.include?("enabled outside one-nhc") })
  end

  def test_trial_reenable_after_delay
    api = FakeAPI.new([host(id: 1, name: "node01", status: "CRIT", state: DISABLED)])
    st  = state_store
    entry = st.entry("node01")
    entry["disabled_by_nhc"] = true
    entry["last_action"]     = @clock.now.to_i - 100

    decisions = run_times(
      controller(api, mode: "act", store: st,
                 cfg: config("reenable_after" => 60)), 1
    )

    assert_equal [1], api.enabled
    assert_equal :reenable, decisions.last.action
    assert decisions.last.applied
    refute entry["disabled_by_nhc"]
    assert_equal @clock.now.to_i, entry["last_enable"]
  end

  def test_trial_reenable_waits_for_the_delay
    api = FakeAPI.new([host(id: 1, name: "node01", status: "CRIT", state: DISABLED)])
    st  = state_store
    entry = st.entry("node01")
    entry["disabled_by_nhc"] = true
    entry["last_action"]     = @clock.now.to_i - 10

    run_times(
      controller(api, mode: "act", store: st,
                 cfg: config("reenable_after" => 60)), 1
    )

    assert_empty api.enabled
  end

  def test_targeting_limits_managed_hosts
    api = FakeAPI.new([
                        host(id: 1, name: "node01", status: "CRIT"),
                        host(id: 2, name: "node02", status: "CRIT")
                      ])
    st  = state_store
    cfg = config(
      "include_hosts" => "node01",
      "never_disable_last" => false,
      "consecutive_crit" => 1
    )

    run_times(controller(api, mode: "act", store: st, cfg: cfg), 1)

    assert_equal [1], api.disabled
    assert_equal ["node01"], st.to_h["hosts"].keys
  end

  def test_state_persists_across_controller_instances
    api = FakeAPI.new([
                        host(id: 1, name: "node01", status: "CRIT"),
                        host(id: 2, name: "node02", status: "OK")
                      ])
    path = File.join(@dir, "state.json")
    cfg  = config

    run_times(controller(api, mode: "act", store: state_store(path), cfg: cfg), 2)
    assert_empty api.disabled

    run_times(controller(api, mode: "act", store: state_store(path), cfg: cfg), 1)
    assert_equal [1], api.disabled
  end

  def test_missing_status_is_not_a_failure
    api = FakeAPI.new([
                        host(id: 1, name: "node01", status: nil),
                        host(id: 2, name: "node02", status: "OK")
                      ])

    run_times(controller(api, mode: "act", cfg: config("consecutive_crit" => 1)), 3)

    assert_empty api.disabled
  end

  def test_hysteresis_counts_distinct_probe_samples
    api = FakeAPI.new([
                        host(id: 1, name: "node01", status: "CRIT", sample: 100),
                        host(id: 2, name: "node02", status: "OK", sample: 100)
                      ])
    cfg = config("consecutive_crit" => 3)
    st  = state_store
    ctl = controller(api, mode: "act", store: st, cfg: cfg)

    run_times(ctl, 5)
    assert_empty api.disabled
    assert_equal 1, st.entry("node01")["crit_count"]

    api.hosts.first.sample = 200
    run_times(ctl, 1)
    assert_equal 2, st.entry("node01")["crit_count"]

    api.hosts.first.sample = 300
    run_times(ctl, 1)
    assert_equal [1], api.disabled
  end
end

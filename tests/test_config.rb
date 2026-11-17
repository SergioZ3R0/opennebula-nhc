# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"

class TestConfig < Minitest::Test
  def controller(overrides = {})
    OneNHC::Config::DEFAULTS["controller"].merge(overrides)
  end

  def config(overrides = {}, groups = {})
    OneNHC::Config.new(
      "groups" => groups,
      "checks" => {},
      "controller" => controller(overrides)
    )
  end

  def test_defaults_are_valid
    assert config.validate!
  end

  def test_accepts_every_mode
    OneNHC::Controller::MODES.each do |mode|
      assert config("mode" => mode).validate!, "mode #{mode} should be valid"
    end
  end

  def test_rejects_unknown_mode
    error = assert_raises(ArgumentError) { config("mode" => "ysolo").validate! }
    assert_includes error.message, "controller.mode"
  end

  def test_rejects_non_integer_hysteresis
    error = assert_raises(ArgumentError) do
      config("consecutive_crit" => "three").validate!
    end
    assert_includes error.message, "controller.consecutive_crit"
  end

  def test_rejects_zero_hysteresis
    assert_raises(ArgumentError) { config("consecutive_ok" => 0).validate! }
  end

  def test_rejects_negative_cooldown
    assert_raises(ArgumentError) { config("cooldown" => -1).validate! }
  end

  def test_accepts_zero_reenable_after
    assert config("reenable_after" => 0).validate!
  end

  def test_rejects_unknown_group_in_include_hosts
    error = assert_raises(ArgumentError) do
      config("include_hosts" => "@nope").validate!
    end
    assert_includes error.message, "unknown group"
  end

  def test_accepts_group_in_include_hosts
    cfg = config({ "include_hosts" => "@compute" }, "compute" => "node[01-02]")
    assert cfg.validate!
  end

  def test_rejects_empty_state_file
    error = assert_raises(ArgumentError) { config("state_file" => " ").validate! }
    assert_includes error.message, "state_file"
  end

  def test_rejects_non_string_state_file
    assert_raises(ArgumentError) { config("state_file" => 123).validate! }
  end

  def test_rejects_scalar_controller
    cfg = OneNHC::Config.new(
      "groups" => {}, "checks" => {}, "controller" => "act"
    )
    assert_raises(ArgumentError) { cfg.validate! }
  end

  def test_rejects_string_boolean
    error = assert_raises(ArgumentError) { config("dry_run" => "yes").validate! }
    assert_includes error.message, "dry_run"
  end

  def test_rejects_non_mapping_notify
    error = assert_raises(ArgumentError) do
      config("notify" => "mailto:ops@example.com").validate!
    end
    assert_includes error.message, "controller.notify"
  end

  def test_accepts_command_and_webhook
    cfg = config("notify" => {
                   "command" => "/usr/local/bin/nhc-alert",
                   "webhook" => "https://hooks.example.com/services/XXX"
                 })
    assert cfg.validate!
  end

  def test_rejects_invalid_webhook
    error = assert_raises(ArgumentError) do
      config("notify" => { "webhook" => "not a url" }).validate!
    end
    assert_includes error.message, "webhook"
  end
end

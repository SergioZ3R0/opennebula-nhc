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

  def test_rejects_non_boolean_notify_on_warn
    assert_raises(ArgumentError) { config("notify_on_warn" => "yes").validate! }
  end

  def test_rejects_zero_min_healthy_hosts
    error = assert_raises(ArgumentError) do
      config("min_healthy_hosts" => 0).validate!
    end
    assert_includes error.message, "min_healthy_hosts"
  end

  def test_accepts_min_healthy_hosts
    assert config("min_healthy_hosts" => 3).validate!
  end

  def test_rejects_invalid_min_healthy_scope
    error = assert_raises(ArgumentError) do
      config("min_healthy_hosts_scope" => "region").validate!
    end
    assert_includes error.message, "min_healthy_hosts_scope"
  end

  def test_accepts_cluster_scope
    assert config("min_healthy_hosts_scope" => "cluster").validate!
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

  def test_accepts_webhook_retry_and_rate_limit_options
    cfg = config(
      "notify" => {
        "webhook" => "https://hooks.example.com/services/XXX",
        "webhook_retries" => 3,
        "webhook_retry_delay" => 0.5,
        "webhook_min_interval" => 0.1
      }
    )
    assert cfg.validate!
  end

  def test_rejects_negative_webhook_retries
    error = assert_raises(ArgumentError) do
      config("notify" => { "webhook_retries" => -1 }).validate!
    end
    assert_includes error.message, "webhook_retries"
  end

  def test_rejects_non_numeric_webhook_delay
    error = assert_raises(ArgumentError) do
      config("notify" => { "webhook_retry_delay" => "soon" }).validate!
    end
    assert_includes error.message, "webhook_retry_delay"
  end

  def test_rejects_negative_webhook_interval
    error = assert_raises(ArgumentError) do
      config("notify" => { "webhook_min_interval" => -1 }).validate!
    end
    assert_includes error.message, "webhook_min_interval"
  end

  def email(overrides = {})
    {
      "to" => "ops@example.com",
      "from" => "one-nhc@example.com",
      "host" => "smtp.example.com",
      "user" => "one-nhc@example.com",
      "password_env" => "NHC_SMTP_PASSWORD"
    }.merge(overrides)
  end

  def email_config(overrides = {})
    config("notify" => { "email" => email(overrides) })
  end

  def test_accepts_email_config
    assert email_config.validate!
  end

  def test_accepts_email_recipient_list
    assert email_config("to" => %w[ops@example.com oncall@example.com]).validate!
  end

  def test_accepts_email_password_file
    assert email_config(
      "password_env" => nil,
      "password_file" => "/etc/one-nhc/smtp.password"
    ).validate!
  end

  def test_rejects_email_not_a_mapping
    error = assert_raises(ArgumentError) do
      config("notify" => { "email" => "ops@example.com" }).validate!
    end
    assert_includes error.message, "must be a mapping"
  end

  def test_rejects_email_without_to
    error = assert_raises(ArgumentError) { email_config("to" => nil).validate! }
    assert_includes error.message, "email.to"
  end

  def test_rejects_invalid_email_recipient
    error = assert_raises(ArgumentError) { email_config("to" => "not-an-email").validate! }
    assert_includes error.message, "invalid address"
  end

  def test_rejects_email_without_from
    error = assert_raises(ArgumentError) { email_config("from" => "").validate! }
    assert_includes error.message, "email.from"
  end

  def test_rejects_email_without_host
    error = assert_raises(ArgumentError) { email_config("host" => "").validate! }
    assert_includes error.message, "email.host"
  end

  def test_rejects_invalid_email_port
    error = assert_raises(ArgumentError) { email_config("port" => 70_000).validate! }
    assert_includes error.message, "email.port"
  end

  def test_rejects_invalid_email_tls
    error = assert_raises(ArgumentError) { email_config("tls" => "smtp").validate! }
    assert_includes error.message, "email.tls"
  end

  def test_accepts_grouped_email
    assert email_config("group_by" => "tags", "failures_first" => true).validate!
  end

  def test_rejects_invalid_group_by
    error = assert_raises(ArgumentError) do
      email_config("group_by" => "other").validate!
    end
    assert_includes error.message, "group_by"
  end

  def test_rejects_invalid_failures_first
    error = assert_raises(ArgumentError) do
      email_config("failures_first" => "yes").validate!
    end
    assert_includes error.message, "failures_first"
  end

  def test_rejects_two_email_password_sources
    error = assert_raises(ArgumentError) do
      email_config("password_file" => "/etc/one-nhc/smtp.password").validate!
    end
    assert_includes error.message, "mutually exclusive"
  end

  def test_rejects_email_user_without_password_source
    error = assert_raises(ArgumentError) do
      email_config("password_env" => nil).validate!
    end
    assert_includes error.message, "password_env"
  end

  def test_rejects_email_password_without_user
    error = assert_raises(ArgumentError) { email_config("user" => nil).validate! }
    assert_includes error.message, "email.user"
  end

  def test_accepts_hooks_config
    assert config(
      "hooks" => {
        "timeout" => 5,
        "on_disable" => "/usr/local/bin/on-disable",
        "on_enable" => ["cmd-1", "cmd-2"],
        "on_reenable" => "cmd-3"
      }
    ).validate!
  end

  def test_rejects_unknown_hook_key
    error = assert_raises(ArgumentError) do
      config("hooks" => { "on_diable" => "cmd" }).validate!
    end
    assert_includes error.message, "unknown keys"
  end

  def test_rejects_invalid_hook_timeout
    error = assert_raises(ArgumentError) do
      config("hooks" => { "timeout" => 0 }).validate!
    end
    assert_includes error.message, "hooks.timeout"
  end

  def test_rejects_invalid_hook_command
    error = assert_raises(ArgumentError) do
      config("hooks" => { "on_disable" => [""] }).validate!
    end
    assert_includes error.message, "hooks.on_disable"
  end

  def sendmail_email(overrides = {})
    {
      "transport" => "sendmail",
      "to" => "ops@example.com",
      "from" => "one-nhc@example.com"
    }.merge(overrides)
  end

  def sendmail_config(overrides = {})
    config("notify" => { "email" => sendmail_email(overrides) })
  end

  def test_accepts_sendmail_without_smtp_credentials
    assert sendmail_config.validate!
  end

  def test_accepts_sendmail_path_and_args
    assert sendmail_config(
      "sendmail_path" => "/usr/sbin/sendmail",
      "sendmail_args" => ["-t", "-i"]
    ).validate!
  end

  def test_rejects_unknown_email_transport
    error = assert_raises(ArgumentError) do
      email_config("transport" => "smtp2").validate!
    end
    assert_includes error.message, "email.transport"
  end

  def test_rejects_sendmail_with_smtp_settings
    error = assert_raises(ArgumentError) do
      sendmail_config("host" => "smtp.example.com").validate!
    end
    assert_includes error.message, "only valid with transport: smtp"
  end

  def test_rejects_smtp_with_sendmail_settings
    error = assert_raises(ArgumentError) do
      email_config("sendmail_path" => "/usr/sbin/sendmail").validate!
    end
    assert_includes error.message, "only valid with transport: sendmail"
  end

  def test_rejects_invalid_sendmail_args
    error = assert_raises(ArgumentError) do
      sendmail_config("sendmail_args" => "-t").validate!
    end
    assert_includes error.message, "sendmail_args"
  end

  def test_rejects_empty_sendmail_path
    error = assert_raises(ArgumentError) do
      sendmail_config("sendmail_path" => " ").validate!
    end
    assert_includes error.message, "sendmail_path"
  end
end

# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"

class TestEmailNotifier < Minitest::Test
  class FakeSMTP
    attr_accessor :host, :port, :open_timeout, :read_timeout, :raise_on_start
    attr_reader :calls

    def initialize
      @calls = []
    end

    def enable_starttls_auto
      @calls << :starttls
    end

    def enable_tls
      @calls << :tls
    end

    def start(helo, user = nil, password = nil, auth = nil)
      raise "smtp boom" if @raise_on_start

      @calls << [:start, helo, user, password, auth]
      yield self
    end

    def send_message(message, from, to)
      @calls << [:send_message, message, from, to]
      true
    end
  end

  ENV_NAME = "NHC_TEST_SMTP_PASSWORD"

  def setup
    @dir  = Dir.mktmpdir
    @smtp = FakeSMTP.new
    @old  = ENV[ENV_NAME]
    ENV[ENV_NAME] = "secret"
  end

  def teardown
    if @old.nil?
      ENV.delete(ENV_NAME)
    else
      ENV[ENV_NAME] = @old
    end
    FileUtils.remove_entry(@dir)
  end

  def factory
    lambda do |host, port|
      @smtp.host = host
      @smtp.port = port
      @smtp
    end
  end

  def config(overrides = {})
    {
      "to" => "ops@example.com",
      "from" => "one-nhc@example.com",
      "host" => "smtp.example.com",
      "port" => 587,
      "user" => "one-nhc@example.com",
      "password_env" => ENV_NAME,
      "tls" => "starttls"
    }.merge(overrides)
  end

  def payload(overrides = {})
    {
      message: "host=node01 id=0 status=CRIT action=disable (notify): CRIT 1/1",
      host: "node01",
      host_id: 0,
      status: "CRIT",
      action: "disable",
      applied: false,
      time: Time.utc(2026, 11, 17, 20, 0, 0),
      sample: 1_794_942_477,
      details: {
        "NHC_STATUS" => "CRIT",
        "NHC_FS_RO" => "CRIT",
        "NHC_FS_RO_MSG" => "read-only: /data (ext4)"
      }
    }.merge(overrides)
  end

  def notifier(overrides = {})
    OneNHC::EmailNotifier.new(config(overrides), smtp_factory: factory)
  end

  def call(name)
    @smtp.calls.find { |entry| entry.is_a?(Array) && entry[0] == name }
  end

  def test_delivers_with_starttls_and_authentication
    assert notifier.deliver(payload)

    assert_includes @smtp.calls, :starttls
    assert_equal "smtp.example.com", @smtp.host
    assert_equal 587, @smtp.port

    start = call(:start)
    refute_nil start
    assert_equal "one-nhc@example.com", start[2]
    assert_equal "secret", start[3]
    assert_equal :plain, start[4]

    assert_equal ["ops@example.com"], call(:send_message)[3]
  end

  def test_message_is_multipart_with_html_and_text
    notifier.deliver(payload)
    message = call(:send_message)[1]

    assert_includes message, "Subject: [one-nhc] CRIT | node01 | disable"
    assert_includes message, "multipart/alternative"
    assert_includes message, "text/plain"
    assert_includes message, "text/html"
    assert_includes message, "Host health alert"
    assert_includes message, "read-only: /data (ext4)"
  end

  def test_ssl_mode
    notifier("tls" => "ssl").deliver(payload)

    assert_includes @smtp.calls, :tls
    refute_includes @smtp.calls, :starttls
  end

  def test_no_tls
    notifier("tls" => "none").deliver(payload)

    refute_includes @smtp.calls, :tls
    refute_includes @smtp.calls, :starttls
  end

  def test_no_authentication
    OneNHC::EmailNotifier.new(
      config("user" => nil, "password_env" => nil),
      smtp_factory: factory
    ).deliver(payload)

    start = call(:start)
    assert_nil start[2]
    assert_nil start[3]
  end

  def test_multiple_recipients
    recipients = ["ops@example.com", "oncall@example.com"]
    notifier("to" => recipients).deliver(payload)

    assert_equal recipients, call(:send_message)[3]
    assert_equal recipients, notifier("to" => recipients).to
  end

  def test_password_file
    path = File.join(@dir, "smtp.password")
    File.write(path, "file-secret\n")

    OneNHC::EmailNotifier.new(
      config("password_env" => nil, "password_file" => path),
      smtp_factory: factory
    ).deliver(payload)

    assert_equal "file-secret", call(:start)[3]
  end

  def test_missing_password_env_raises
    ENV.delete(ENV_NAME)

    error = assert_raises(OneNHC::EmailNotifier::Error) { notifier }
    assert_includes error.message, ENV_NAME
  end

  def test_missing_password_file_raises
    error = assert_raises(OneNHC::EmailNotifier::Error) do
      notifier("password_env" => nil, "password_file" => "/does/not/exist")
    end
    assert_includes error.message, "password file not found"
  end

  def test_smtp_errors_are_wrapped
    @smtp.raise_on_start = true

    error = assert_raises(OneNHC::EmailNotifier::Error) do
      notifier.deliver(payload)
    end
    assert_includes error.message, "smtp boom"
  end

  def test_from_name_and_subject_prefix
    notifier("from_name" => "One NHC", "subject_prefix" => "[LAB]").deliver(payload)
    message = call(:send_message)[1]

    assert_includes message, "From: One NHC <one-nhc@example.com>"
    assert_includes message, "Subject: [LAB] CRIT | node01 | disable"
  end

  def test_timeout_is_applied
    notifier("timeout" => 15).deliver(payload)

    assert_equal 15, @smtp.open_timeout
    assert_equal 15, @smtp.read_timeout
  end

  def test_to_reader
    assert_equal ["ops@example.com"], notifier.to
  end

  def test_invalid_tls_raises
    error = assert_raises(OneNHC::EmailNotifier::Error) { notifier("tls" => "smtp") }
    assert_includes error.message, "email.tls"
  end

  def test_user_without_password_source_raises
    error = assert_raises(OneNHC::EmailNotifier::Error) do
      notifier("password_env" => nil)
    end
    assert_includes error.message, "password_env"
  end

  def test_password_without_user_raises
    error = assert_raises(OneNHC::EmailNotifier::Error) do
      notifier("user" => nil)
    end
    assert_includes error.message, "email.user"
  end
end

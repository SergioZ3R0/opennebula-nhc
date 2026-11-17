# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class TestHooks < Minitest::Test
  FakeStatus = Struct.new(:code) do
    def success?
      code.zero?
    end
  end

  def payload(overrides = {})
    {
      message: "host=node01 id=0 status=CRIT action=disable (applied): CRIT 1/1",
      host: "node01",
      host_id: 0,
      status: "CRIT",
      action: "disable",
      applied: true,
      time: "2026-11-17T20:00:00Z",
      sample: 123,
      details: {}
    }.merge(overrides)
  end

  def hooks(config)
    OneNHC::Hooks.new(OneNHC::Config.new("controller" => { "hooks" => config }))
  end

  def capture_calls(responder)
    calls = []
    wrapper = lambda do |command, timeout:, env:|
      calls << { command: command, timeout: timeout, env: env }
      responder.call
    end

    [calls, wrapper]
  end

  def test_runs_the_matching_hook_with_the_payload_environment
    calls, wrapper = capture_calls(-> { ["", "", FakeStatus.new(0), :ok] })

    with_stub(OneNHC::Shell, :capture, wrapper) do
      hooks(
        "timeout" => 5,
        "on_disable" => "/usr/local/bin/on-disable"
      ).run(payload)
    end

    assert_equal 1, calls.size
    call = calls.first
    assert_equal ["sh", "-c", "/usr/local/bin/on-disable"], call[:command]
    assert_equal 5, call[:timeout]
    assert_equal "node01", call[:env]["NHC_HOST"]
    assert_equal "0", call[:env]["NHC_HOST_ID"]
    assert_equal "CRIT", call[:env]["NHC_STATUS"]
    assert_equal "disable", call[:env]["NHC_ACTION"]
    assert_equal "true", call[:env]["NHC_APPLIED"]
    assert_equal "123", call[:env]["NHC_SAMPLE"]
  end

  def test_runs_multiple_commands_in_order
    calls, wrapper = capture_calls(-> { ["", "", FakeStatus.new(0), :ok] })

    with_stub(OneNHC::Shell, :capture, wrapper) do
      hooks("on_disable" => ["cmd-1", "cmd-2"]).run(payload)
    end

    assert_equal 2, calls.size
    assert_equal "cmd-1", calls[0][:command].last
    assert_equal "cmd-2", calls[1][:command].last
  end

  def test_does_not_run_hooks_for_other_actions
    calls, wrapper = capture_calls(-> { ["", "", FakeStatus.new(0), :ok] })

    with_stub(OneNHC::Shell, :capture, wrapper) do
      hooks("on_enable" => "cmd").run(payload({ action: "disable" }))
      hooks("on_disable" => "cmd").run(payload({ action: "refuse_disable" }))
    end

    assert_empty calls
  end

  def test_failures_are_logged_and_do_not_raise
    _calls, wrapper = capture_calls(-> { ["", "hook boom", FakeStatus.new(1), :ok] })
    old_stderr = $stderr
    $stderr = StringIO.new

    begin
      with_stub(OneNHC::Shell, :capture, wrapper) do
        hooks("on_disable" => "cmd").run(payload)
      end
      output = $stderr.string
    ensure
      $stderr = old_stderr
    end

    assert_includes output, "hook disable failed"
    assert_includes output, "hook boom"
  end

  def test_timeouts_are_logged
    _calls, wrapper = capture_calls(-> { [nil, nil, nil, :timeout] })
    old_stderr = $stderr
    $stderr = StringIO.new

    begin
      with_stub(OneNHC::Shell, :capture, wrapper) do
        hooks("on_disable" => "cmd").run(payload)
      end
      output = $stderr.string
    ensure
      $stderr = old_stderr
    end

    assert_includes output, "hook disable failed (timeout)"
  end
end

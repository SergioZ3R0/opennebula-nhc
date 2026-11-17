# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"

class TestShell < Minitest::Test
  def test_capture_pipes_input
    out, err, status, state = OneNHC::Shell.capture(
      ["cat"], timeout: 5, input: "hello\n"
    )

    assert_equal :ok, state
    assert_equal "hello\n", out
    assert status.success?
    assert_empty err
  end

  def test_capture_reports_a_missing_command
    _out, _err, _status, state = OneNHC::Shell.capture(
      ["one-nhc-command-that-does-not-exist"], timeout: 5
    )

    assert_equal :notfound, state
  end
end

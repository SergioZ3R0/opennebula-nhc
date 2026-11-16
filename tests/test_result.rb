# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"

class TestResult < Minitest::Test
  def result(id, status)
    OneNHC::Result.new(check_id: id, status: status)
  end

  def test_rejects_invalid_status
    assert_raises(ArgumentError) do
      OneNHC::Result.new(check_id: "x", status: :boom)
    end
  end

  def test_worst_status
    ok   = result("a", :ok)
    warn = result("b", :warn)
    crit = result("c", :crit)
    skip = result("d", :skip)

    assert_equal :ok,   OneNHC::Runner.worst([ok, skip])
    assert_equal :warn, OneNHC::Runner.worst([ok, warn])
    assert_equal :crit, OneNHC::Runner.worst([warn, crit, ok])
    assert_equal :skip, OneNHC::Runner.worst([skip, skip])
  end

  def test_exit_codes
    assert_equal 2, OneNHC::Runner.exit_code([result("c", :crit)])
    assert_equal 1, OneNHC::Runner.exit_code([result("w", :warn)])
    assert_equal 3, OneNHC::Runner.exit_code([result("u", :unknown)])
    assert_equal 0, OneNHC::Runner.exit_code([result("o", :ok)])
  end
end

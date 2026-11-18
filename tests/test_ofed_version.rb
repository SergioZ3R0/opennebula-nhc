# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"

class TestOfedVersion < Minitest::Test
  FakeStatus = Struct.new(:code) do
    def success?
      code.zero?
    end
  end

  def check
    OneNHC.checks.find { |candidate| candidate.id == "ofed-version" }
  end

  def config(overrides = {})
    OneNHC::Config.new(
      "checks" => {
        "ofed-version" => {
          "enabled" => true,
          "version" => "26.01",
          "manager" => "rpm"
        }.merge(overrides)
      }
    )
  end

  def test_is_in_the_network_group
    assert_includes check.tags, "network"
  end

  def test_ok_when_the_version_matches
    responder = ->(_command, **) { ["26.01", "", FakeStatus.new(0), :ok] }

    with_stub(OneNHC::Shell, :which, "/usr/bin/rpm") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config)
        assert_equal :ok, result.status
        assert_equal "26.01", result.metrics["version"]
      end
    end
  end

  def test_crit_on_version_mismatch
    responder = ->(_command, **) { ["26.02", "", FakeStatus.new(0), :ok] }

    with_stub(OneNHC::Shell, :which, "/usr/bin/rpm") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config)
        assert_equal :crit, result.status
        assert_includes result.message, "26.02"
      end
    end
  end

  def test_crit_when_the_package_is_missing
    responder = ->(_command, **) { ["", "package not installed", FakeStatus.new(1), :ok] }

    with_stub(OneNHC::Shell, :which, "/usr/bin/rpm") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config)
        assert_equal :crit, result.status
        assert_includes result.message, "not installed"
      end
    end
  end

  def test_dpkg_prefix_match
    responder = ->(_command, **) { ["26.01.0.9", "", FakeStatus.new(0), :ok] }

    with_stub(OneNHC::Shell, :which, "/usr/bin/dpkg-query") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config("manager" => "dpkg", "match" => "prefix"))
        assert_equal :ok, result.status
      end
    end
  end

  def test_skip_without_a_version
    result = check.call(config("version" => ""))
    assert_equal :skip, result.status
    assert_includes result.message, "no expected OFED version"
  end

  def test_skip_without_a_package_manager
    with_stub(OneNHC::Shell, :which, nil) do
      result = check.call(config("manager" => "auto"))
      assert_equal :skip, result.status
      assert_includes result.message, "no package manager"
    end
  end
end

# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"

class TestPackageVersion < Minitest::Test
  FakeStatus = Struct.new(:code) do
    def success?
      code.zero?
    end
  end

  def check
    OneNHC.checks.find { |candidate| candidate.id == "package-version" }
  end

  def config(packages)
    OneNHC::Config.new(
      "checks" => {
        "package-version" => { "enabled" => true, "packages" => packages }
      }
    )
  end

  def rpm_responder(versions)
    lambda do |command, **|
      name = command[4]
      version = versions[name]
      if version
        [version, "", FakeStatus.new(0), :ok]
      else
        ["", "package #{name} is not installed", FakeStatus.new(1), :ok]
      end
    end
  end

  def test_ok_when_the_rpm_version_matches
    responder = rpm_responder("mlnx-ofa_kernel" => "26.01")

    with_stub(OneNHC::Shell, :which, "/usr/bin/rpm") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config(
                              [{ "name" => "mlnx-ofa_kernel", "version" => "26.01", "manager" => "rpm" }]
                            ))
        assert_equal :ok, result.status
        assert_equal 1, result.metrics["packages"]
      end
    end
  end

  def test_crit_on_version_mismatch
    responder = rpm_responder("mlnx-ofa_kernel" => "26.02")

    with_stub(OneNHC::Shell, :which, "/usr/bin/rpm") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config(
                              [{ "name" => "mlnx-ofa_kernel", "version" => "26.01", "manager" => "rpm" }]
                            ))
        assert_equal :crit, result.status
        assert_includes result.message, "26.02"
      end
    end
  end

  def test_crit_when_the_package_is_not_installed
    responder = rpm_responder({})

    with_stub(OneNHC::Shell, :which, "/usr/bin/rpm") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config(
                              [{ "name" => "mlnx-ofa_kernel", "version" => "26.01", "manager" => "rpm" }]
                            ))
        assert_equal :crit, result.status
        assert_includes result.message, "not installed"
      end
    end
  end

  def test_dpkg_prefix_match
    responder = ->(_command, **) { ["1.2.3-1", "", FakeStatus.new(0), :ok] }

    with_stub(OneNHC::Shell, :which, "/usr/bin/dpkg-query") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config(
                              [{
                                "name" => "opennebula",
                                "version" => "1.2.3",
                                "manager" => "dpkg",
                                "match" => "prefix"
                              }]
                            ))
        assert_equal :ok, result.status
      end
    end
  end

  def test_skip_without_packages
    assert_equal :skip, check.call(config([])).status
  end

  def test_skip_without_a_package_manager
    with_stub(OneNHC::Shell, :which, nil) do
      result = check.call(config(
                            [{ "name" => "opennebula", "version" => "7.4", "manager" => "auto" }]
                          ))
      assert_equal :skip, result.status
      assert_includes result.message, "no package manager"
    end
  end

  def test_unknown_when_one_package_cannot_be_checked
    responder = lambda do |command, **|
      if command[0] == "dpkg-query"
        [nil, nil, nil, :notfound]
      else
        ["26.01", "", FakeStatus.new(0), :ok]
      end
    end
    which = ->(command) { command == "rpm" ? "/usr/bin/rpm" : nil }

    with_stub(OneNHC::Shell, :which, which) do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config(
                              [
                                { "name" => "mlnx-ofa_kernel", "version" => "26.01", "manager" => "auto" },
                                { "name" => "other", "version" => "1", "manager" => "dpkg" }
                              ]
                            ))
        assert_equal :unknown, result.status
        assert_equal 1, result.metrics["skipped"]
      end
    end
  end
end

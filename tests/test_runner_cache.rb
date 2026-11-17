# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"

class TestRunnerCache < Minitest::Test
  def setup
    @dir     = Dir.mktmpdir
    @path    = File.join(@dir, "cache.json")
    @cache   = OneNHC::Cache.new(@path)
    @runs    = 0
    @heavy   = OneNHC::Check.new(
      id: "heavy", description: "heavy", heavy: true, ttl: 60
    ) do |ctx|
      @runs += 1
      ctx.ok!("ran")
    end
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def config
    OneNHC::Config.new(
      "report_not_targeted" => false,
      "checks" => { "heavy" => { "enabled" => true } }
    )
  end

  def runner(cache: @cache)
    OneNHC::Runner.new(config, node: "node01", cache: cache)
  end

  def test_probe_uses_a_fresh_cache_entry
    @cache.write(
      [OneNHC::Result.new(check_id: "heavy", status: :crit, message: "cached crit")],
      host: "node01",
      now: Time.now.to_i
    )

    with_stub(OneNHC, :checks, [@heavy]) do
      result = runner.probe_results.first
      assert_equal :crit, result.status
      assert_includes result.message, "cached crit"
      assert_equal 0, @runs
    end
  end

  def test_probe_reports_unknown_without_a_cache
    with_stub(OneNHC, :checks, [@heavy]) do
      result = runner.probe_results.first
      assert_equal :unknown, result.status
      assert_includes result.message, "cache missing or stale"
    end
  end

  def test_check_mode_runs_the_heavy_check
    with_stub(OneNHC, :checks, [@heavy]) do
      result = runner.results.first
      assert_equal :ok, result.status
      assert_equal "ran", result.message
      assert_equal 1, @runs
    end
  end

  def test_heavy_results_runs_only_heavy_checks
    light = OneNHC::Check.new(id: "light") { |ctx| ctx.ok!("light") }

    with_stub(OneNHC, :checks, [@heavy, light]) do
      results = runner.heavy_results
      assert_equal ["heavy"], results.map(&:check_id)
      assert_equal 1, @runs
    end
  end
end

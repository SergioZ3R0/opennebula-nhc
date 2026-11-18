# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "json"

class TestCache < Minitest::Test
  def setup
    @dir   = Dir.mktmpdir
    @path  = File.join(@dir, "cache.json")
    @cache = OneNHC::Cache.new(@path)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def result(status: :ok, message: "healthy", metrics: { "disks" => 1 })
    OneNHC::Result.new(
      check_id: "smart", status: status, message: message, metrics: metrics
    )
  end

  def test_write_and_read_a_fresh_result
    @cache.write([result], host: "node01", now: 100)

    cached = @cache.result("smart", ttl: 10, now: 105)

    refute_nil cached
    assert_equal :ok, cached.status
    assert_includes cached.message, "healthy"
    assert_includes cached.message, "cached 5s ago"
    assert_equal 5, cached.metrics["cached_age"]
    assert cached.metrics["cached"]
  end

  def test_stale_result_returns_nil
    @cache.write([result], host: "node01", now: 100)

    assert_nil @cache.result("smart", ttl: 10, now: 120)
  end

  def test_missing_cache_returns_nil
    assert_nil @cache.result("smart", ttl: 10)
  end

  def test_corrupt_cache_returns_nil
    File.write(@path, "{not json")
    assert_nil @cache.result("smart", ttl: 10)
  end

  def test_write_creates_the_directory
    path = File.join(@dir, "nested", "cache.json")
    OneNHC::Cache.new(path).write([result], host: "node01", now: 100)

    assert File.file?(path)
  end

  def test_write_does_not_leave_temporary_files
    @cache.write([result], host: "node01", now: 100)

    assert_empty Dir.glob("#{@path}.tmp.*")
  end

  def test_invalid_status_returns_nil
    File.write(
      @path,
      JSON.generate("checks" => { "smart" => { "status" => "BROKEN", "at" => 100 } })
    )

    assert_nil @cache.result("smart", ttl: 10, now: 105)
  end

  def test_write_records_the_schema_version
    @cache.write([result], host: "node01", now: 100)

    data = JSON.parse(File.read(@path))
    assert_equal OneNHC::Cache::SCHEMA_VERSION, data["schema_version"]
  end

  def test_legacy_cache_without_schema_version_is_accepted
    File.write(
      @path,
      JSON.generate(
        "checks" => {
          "smart" => { "status" => "ok", "message" => "legacy", "at" => 100 }
        }
      )
    )

    cached = @cache.result("smart", ttl: 10, now: 105)
    refute_nil cached
    assert_equal :ok, cached.status
  end

  def test_mismatched_schema_version_is_ignored
    File.write(
      @path,
      JSON.generate(
        "schema_version" => OneNHC::Cache::SCHEMA_VERSION + 1,
        "checks" => {
          "smart" => { "status" => "ok", "message" => "future", "at" => 100 }
        }
      )
    )

    assert_nil @cache.result("smart", ttl: 10, now: 105)
  end
end

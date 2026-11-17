# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"

class TestState < Minitest::Test
  def setup
    @dir  = Dir.mktmpdir
    @path = File.join(@dir, "state.json")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_entry_creates_defaults
    entry = OneNHC::State.new(@path).entry("node01")

    assert_equal 0, entry["crit_count"]
    assert_equal 0, entry["ok_count"]
    refute entry["disabled_by_nhc"]
    assert_equal 0, entry["last_action"]
    assert_equal 0, entry["last_enable"]
    assert_equal 0, entry["last_sample"]
    assert_nil entry["notified_action"]
    assert_nil entry["last_status"]
  end

  def test_entry_merges_legacy_entries
    File.write(@path, JSON.generate(
                         "hosts" => {
                           "node01" => {
                             "crit_count" => 7,
                             "disabled_by_nhc" => true
                           }
                         }
                       ))

    entry = OneNHC::State.new(@path).entry("node01")

    assert_equal 7, entry["crit_count"]
    assert entry["disabled_by_nhc"]
    assert_equal 0, entry["ok_count"]
    assert_equal 0, entry["last_enable"]
  end

  def test_save_and_reload
    state = OneNHC::State.new(@path)
    state.entry("node01")["crit_count"] = 2
    state.save

    reloaded = OneNHC::State.new(@path).entry("node01")
    assert_equal 2, reloaded["crit_count"]
  end

  def test_save_creates_missing_directory
    path  = File.join(@dir, "nested", "state.json")
    state = OneNHC::State.new(path)
    state.entry("node01")["last_status"] = "OK"
    state.save

    assert File.file?(path)
    assert_equal "OK", OneNHC::State.new(path).entry("node01")["last_status"]
  end

  def test_corrupt_file_is_ignored
    File.write(@path, "{not json")

    state = OneNHC::State.new(@path)
    assert_empty state.to_h["hosts"]
  end

  def test_invalid_hosts_shape_is_reset
    File.write(@path, JSON.generate("hosts" => []))

    entry = OneNHC::State.new(@path).entry("node01")
    assert_equal 0, entry["crit_count"]
  end

  def test_invalid_entry_shape_is_reset
    File.write(@path, JSON.generate("hosts" => { "node01" => 5 }))

    entry = OneNHC::State.new(@path).entry("node01")
    assert_equal 0, entry["crit_count"]
  end

  def test_save_does_not_leave_temporary_files
    state = OneNHC::State.new(@path)
    state.entry("node01")
    state.save

    assert_empty Dir.glob("#{@path}.tmp.*")
  end
end

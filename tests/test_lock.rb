# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"

class TestLock < Minitest::Test
  def setup
    @dir  = Dir.mktmpdir
    @path = File.join(@dir, "state.json.lock")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_acquire_creates_the_file_and_directory
    path = File.join(@dir, "nested", "state.json.lock")
    lock = OneNHC::Lock.new(path)

    assert lock.acquire
    assert File.file?(path)
  ensure
    lock&.release
  end

  def test_second_lock_is_rejected_until_release
    first  = OneNHC::Lock.new(@path)
    second = OneNHC::Lock.new(@path)

    assert first.acquire
    refute second.acquire

    first.release
    assert second.acquire
  ensure
    first&.release
    second&.release
  end

  def test_release_is_idempotent
    lock = OneNHC::Lock.new(@path)
    lock.acquire

    lock.release
    lock.release

    assert true
  end

  def test_acquire_is_idempotent
    lock = OneNHC::Lock.new(@path)

    assert lock.acquire
    assert lock.acquire
  ensure
    lock&.release
  end
end

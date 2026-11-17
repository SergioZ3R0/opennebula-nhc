# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require "fileutils"

module OneNHC
  # Advisory lock to keep a single controller per state file.
  #
  # The lock is held for the lifetime of the process: systemd's timer and a
  # manual `--watch` cannot both mutate the same state file.
  class Lock
    def initialize(path)
      @path = path
      @file = nil
    end

    def acquire
      return true if @file

      dir = File.dirname(@path)
      FileUtils.mkdir_p(dir) unless dir == "."

      file = File.open(@path, File::RDWR | File::CREAT, 0o600)
      begin
        if file.flock(File::LOCK_EX | File::LOCK_NB)
          @file = file
          true
        else
          file.close
          false
        end
      rescue StandardError
        file.close
        raise
      end
    end

    def release
      return unless @file

      @file.flock(File::LOCK_UN)
      @file.close
      @file = nil
    end
  end
end

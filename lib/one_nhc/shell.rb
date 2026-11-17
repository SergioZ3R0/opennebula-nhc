# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require "open3"
require "timeout"

module OneNHC
  # Small helpers to run external commands with a hard timeout.
  module Shell
    module_function

    def which(command)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        candidate = File.join(dir, command)
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end

    # Returns [stdout, stderr, status, state].
    # state is one of :ok, :timeout or :notfound.
    def capture(command, timeout:, env: {}, input: nil)
      Open3.popen3(env, *command, pgroup: true) do |stdin, stdout, stderr, wait_thr|
        begin
          stdin.write(input.to_s) unless input.nil?
        rescue Errno::EPIPE, IOError
          # The command closed stdin early; let it finish.
        ensure
          stdin.close
        end

        out_thread = Thread.new { stdout.read }
        err_thread = Thread.new { stderr.read }

        begin
          Timeout.timeout(timeout) { wait_thr.value }
        rescue Timeout::Error
          begin
            Process.kill("KILL", -wait_thr.pid)
          rescue Errno::ESRCH
            # process already gone
          end
          return [safe_value(out_thread), safe_value(err_thread), nil, :timeout]
        end

        [out_thread.value, err_thread.value, wait_thr.value, :ok]
      end
    rescue Errno::ENOENT
      [nil, nil, nil, :notfound]
    end

    def safe_value(thread)
      thread.value
    rescue StandardError
      ""
    end
  end
end

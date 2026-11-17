# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "one_nhc/version"
require_relative "one_nhc/result"
require_relative "one_nhc/check"
require_relative "one_nhc/config"
require_relative "one_nhc/runner"
require_relative "one_nhc/shell"
require_relative "one_nhc/hostlist"
require_relative "one_nhc/state"
require_relative "one_nhc/controller"
require_relative "one_nhc/notifier"
require_relative "one_nhc/adapters/human"
require_relative "one_nhc/adapters/on_monitor"
require_relative "one_nhc/adapters/json"

require "socket"

# NHC-style health checks for OpenNebula.
module OneNHC
  class << self
    def checks
      @checks ||= []
    end

    def check(**metadata, &block)
      checks << Check.new(**metadata, &block)
    end

    # Local node name used to evaluate check targeting.
    def node_name
      ENV["ONE_NHC_NODE"] || Socket.gethostname.split(".").first
    end

    # Loads every check definition from a directory.
    def load_checks(dir = default_checks_dir)
      Dir.glob(File.join(dir, "*.rb")).sort.each { |file| require file }
    end

    def default_checks_dir
      candidates = [
        ENV["ONE_NHC_CHECKS"],
        File.expand_path("../checks.d", __dir__),
        "/usr/local/share/one-nhc/checks.d",
        "/usr/share/one-nhc/checks.d"
      ].compact

      candidates.find { |dir| Dir.exist?(dir) } || candidates.last
    end
  end
end

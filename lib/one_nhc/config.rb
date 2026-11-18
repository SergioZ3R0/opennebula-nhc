# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require "yaml"
require "uri"

module OneNHC
  # YAML configuration with defaults. Keys are strings (as parsed from YAML).
  class Config
    DEFAULTS = {
      "proc_mounts" => "/proc/mounts",
      "node_name" => nil,
      "groups" => {},
      "report_not_targeted" => false,
      "cache_file" => "/var/lib/one-nhc/cache.json",
      "controller" => {
        "mode" => "monitor",
        "dry_run" => false,
        "consecutive_crit" => 3,
        "consecutive_ok" => 2,
        "cooldown" => 300,
        "reenable_after" => 0,
        "monitor_grace" => 900,
        "never_disable_last" => true,
        "min_healthy_hosts" => 1,
        "include_hosts" => "all",
        "exclude_hosts" => nil,
        "interval" => 60,
        "state_file" => "/var/lib/one-nhc/state.json",
        "hooks" => {
          "timeout" => 10,
          "on_disable" => nil,
          "on_enable" => nil,
          "on_reenable" => nil
        },
        "notify" => {
          "command" => nil,
          "webhook" => nil,
          "email" => nil
        }
      },
      "checks" => {
        "fs-ro" => {
          "enabled" => true,
          "allowlist" => []
        },
        "datastore-mounts" => {
          "enabled" => true,
          "mounts" => [
            { "path" => "/var/lib/one/datastores", "must_be_mount" => false }
          ]
        },
        "libvirt" => {
          "enabled" => true,
          "uri" => "qemu:///system",
          "timeout" => 6
        },
        "fs-usage" => {
          "enabled" => false,
          "warn" => 90,
          "crit" => 95,
          "check_inodes" => false,
          "timeout" => 5,
          "mounts" => []
        },
        "network-interface" => {
          "enabled" => false,
          "sysfs" => "/sys/class/net",
          "interfaces" => []
        },
        "infiniband" => {
          "enabled" => false,
          "sysfs" => "/sys/class/infiniband",
          "require_openibd" => false,
          "devices" => []
        },
        "service" => {
          "enabled" => false,
          "services" => []
        },
        "raid" => {
          "enabled" => false,
          "sysfs" => "/sys/block",
          "mdstat" => "/proc/mdstat"
        },
        "smart" => {
          "enabled" => false,
          "required" => false,
          "timeout" => 15,
          "sudo" => false,
          "devices" => []
        },
        "gpu" => {
          "enabled" => false,
          "required" => false,
          "timeout" => 10
        },
        "gpu-fabric" => {
          "enabled" => false,
          "required" => false,
          "timeout" => 10
        },
        "package-version" => {
          "enabled" => false,
          "packages" => []
        }
      }
    }.freeze

    def self.load(path = nil)
      merged = deep_dup(DEFAULTS)

      if path && !path.to_s.empty? && File.file?(path)
        user = YAML.safe_load(File.read(path, encoding: "UTF-8"), aliases: false) || {}
        raise ArgumentError, "config root must be a mapping" unless user.is_a?(Hash)

        merged = deep_merge(merged, user)
      end

      new(merged)
    end

    def self.deep_merge(base, override)
      base.merge(override) do |_key, old_value, new_value|
        if old_value.is_a?(Hash) && new_value.is_a?(Hash)
          deep_merge(old_value, new_value)
        else
          new_value
        end
      end
    end

    def self.deep_dup(hash)
      hash.each_with_object({}) do |(key, value), acc|
        acc[key] = value.is_a?(Hash) ? deep_dup(value) : value
      end
    end

    def initialize(hash)
      @hash = hash
    end

    def [](key)
      @hash[key]
    end

    def dig(*keys)
      @hash.dig(*keys)
    end

    def check(id)
      (@hash["checks"] || {})[id.to_s] || {}
    end

    # Validates every hosts/exclude expression, every group definition and the
    # controller settings. Raises ArgumentError with a clear message on unknown
    # groups, cycles, unbalanced brackets, invalid ranges or bad controller
    # values.
    def validate!
      groups     = @hash["groups"] || {}
      checks     = @hash["checks"] || {}
      controller = @hash["controller"] || {}

      checks.each do |_id, options|
        %w[hosts exclude].each do |key|
          expression = options[key]
          next if expression.nil? || expression.to_s.strip.empty?

          Hostlist.expand(expression, groups: groups)
        end
      end

      groups.each_key do |name|
        Hostlist.expand(groups[name], groups: groups, seen: [name])
      end

      validate_controller!(controller, groups)

      true
    end

    def to_h
      @hash
    end

    private

    MODES = %w[monitor notify act].freeze
    NON_NEGATIVE = %w[cooldown reenable_after monitor_grace].freeze
    POSITIVE     = %w[consecutive_crit consecutive_ok interval min_healthy_hosts].freeze

    def validate_controller!(controller, groups)
      unless controller.is_a?(Hash)
        raise ArgumentError, "controller must be a mapping"
      end

      # Config.new may be built without a controller section; Config.load
      # always merges the defaults. Only validate what is present.
      return if controller.empty?

      %w[dry_run never_disable_last].each do |key|
        value = controller[key]
        next if value.nil? || value == true || value == false

        raise ArgumentError, "controller.#{key} must be true or false"
      end

      mode = controller["mode"].to_s
      unless MODES.include?(mode)
        raise ArgumentError,
              "controller.mode must be one of #{MODES.join(', ')} (got '#{mode}')"
      end

      POSITIVE.each do |key|
        next if controller[key].nil?

        value = positive_integer(key, controller[key])
        raise ArgumentError, "controller.#{key} must be >= 1" if value < 1
      end

      NON_NEGATIVE.each do |key|
        next if controller[key].nil?

        value = positive_integer(key, controller[key])
        raise ArgumentError, "controller.#{key} must be >= 0" if value.negative?
      end

      %w[include_hosts exclude_hosts].each do |key|
        expression = controller[key]
        next if expression.nil? || expression.to_s.strip.empty?

        Hostlist.expand(expression, groups: groups)
      end

      state_file = controller["state_file"]
      unless state_file.is_a?(String) && !state_file.strip.empty?
        raise ArgumentError, "controller.state_file must be a non-empty path"
      end

      hooks = controller["hooks"] || {}
      raise ArgumentError, "controller.hooks must be a mapping" unless hooks.is_a?(Hash)

      unknown = hooks.keys.map(&:to_s) -
                %w[timeout on_disable on_enable on_reenable]
      unless unknown.empty?
        raise ArgumentError,
              "controller.hooks has unknown keys: #{unknown.join(', ')}"
      end

      unless hooks["timeout"].nil?
        value = positive_integer("hooks.timeout", hooks["timeout"])
        raise ArgumentError, "controller.hooks.timeout must be >= 1" if value < 1
      end

      %w[on_disable on_enable on_reenable].each do |key|
        value = hooks[key]
        next if value.nil?

        commands = value.is_a?(Array) ? value : [value]
        unless commands.all? { |command| command.is_a?(String) && !command.strip.empty? }
          raise ArgumentError,
                "controller.hooks.#{key} must be a command or a list of commands"
        end
      end

      notify = controller["notify"] || {}
      raise ArgumentError, "controller.notify must be a mapping" unless notify.is_a?(Hash)

      %w[command webhook].each do |key|
        value = notify[key]
        next if value.nil? || value.to_s.strip.empty?

        if key == "webhook"
          begin
            URI.parse(value.to_s)
          rescue URI::InvalidURIError
            raise ArgumentError, "controller.notify.webhook is not a valid URL"
          end
        end
      end

      validate_email!(notify["email"]) unless notify["email"].nil?
    end

    def validate_email!(email)
      raise ArgumentError, "controller.notify.email must be a mapping" unless email.is_a?(Hash)

      transport = (email["transport"] || "smtp").to_s
      unless %w[smtp sendmail].include?(transport)
        raise ArgumentError,
              "controller.notify.email.transport must be smtp or sendmail"
      end

      recipients = email["to"]
      recipients = [recipients] unless recipients.is_a?(Array)
      recipients = recipients.compact.map(&:to_s).reject(&:empty?)
      raise ArgumentError, "controller.notify.email.to is required" if recipients.empty?

      recipients.each do |address|
        unless address.include?("@")
          raise ArgumentError,
                "controller.notify.email.to has an invalid address: '#{address}'"
        end
      end

      from = email["from"].to_s.strip
      raise ArgumentError, "controller.notify.email.from is required" if from.empty?

      unless from.include?("@")
        raise ArgumentError, "controller.notify.email.from has an invalid address"
      end

      timeout = email["timeout"]
      unless timeout.nil?
        value = positive_integer("notify.email.timeout", timeout)
        raise ArgumentError, "controller.notify.email.timeout must be >= 1" if value < 1
      end

      group_by = (email["group_by"] || "none").to_s
      unless %w[none tags].include?(group_by)
        raise ArgumentError,
              "controller.notify.email.group_by must be none or tags"
      end

      unless [true, false, nil].include?(email["failures_first"])
        raise ArgumentError,
              "controller.notify.email.failures_first must be true or false"
      end

      if transport == "sendmail"
        validate_sendmail!(email)
      else
        validate_smtp!(email)
      end
    end

    def validate_smtp!(email)
      host = email["host"].to_s.strip
      raise ArgumentError, "controller.notify.email.host is required" if host.empty?

      %w[sendmail_path sendmail_args].each do |key|
        value = email[key]
        next if value.nil? || (value.respond_to?(:empty?) && value.empty?)

        raise ArgumentError,
              "controller.notify.email.#{key} is only valid with transport: sendmail"
      end

      port = email["port"]
      unless port.nil?
        value = positive_integer("notify.email.port", port)
        unless (1..65_535).cover?(value)
          raise ArgumentError, "controller.notify.email.port must be between 1 and 65535"
        end
      end

      tls = (email["tls"] || "starttls").to_s
      unless %w[starttls ssl none].include?(tls)
        raise ArgumentError, "controller.notify.email.tls must be one of starttls, ssl, none"
      end

      user = email["user"].to_s.strip
      env  = email["password_env"].to_s.strip
      file = email["password_file"].to_s.strip

      if !env.empty? && !file.empty?
        raise ArgumentError,
              "controller.notify.email.password_env and password_file are mutually exclusive"
      end

      if !user.empty? && env.empty? && file.empty?
        raise ArgumentError,
              "controller.notify.email.user requires password_env or password_file"
      end

      if user.empty? && (!env.empty? || !file.empty?)
        raise ArgumentError,
              "controller.notify.email password source requires email.user"
      end
    end

    def validate_sendmail!(email)
      %w[host port tls user password_env password_file helo].each do |key|
        value = email[key]
        next if value.nil? || value.to_s.strip.empty?

        raise ArgumentError,
              "controller.notify.email.#{key} is only valid with transport: smtp"
      end

      path = email["sendmail_path"]
      if !path.nil? && path.to_s.strip.empty?
        raise ArgumentError, "controller.notify.email.sendmail_path cannot be empty"
      end

      args = email["sendmail_args"]
      return if args.nil?

      unless args.is_a?(Array) && !args.empty? &&
             args.all? { |arg| !arg.to_s.strip.empty? }
        raise ArgumentError,
              "controller.notify.email.sendmail_args must be a non-empty list of strings"
      end
    end

    def positive_integer(key, value)
      Integer(value)
    rescue ArgumentError, TypeError
      raise ArgumentError, "controller.#{key} must be an integer (got '#{value}')"
    end
  end
end

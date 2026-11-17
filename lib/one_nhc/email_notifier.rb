# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require "net/smtp"
require "socket"
require "time"

module OneNHC
  # Sends controller notifications by email.
  #
  # Credentials are never read from the YAML: use `password_env` (an
  # environment variable, for example with a systemd EnvironmentFile) or
  # `password_file` (a file readable only by oneadmin).
  class EmailNotifier
    class Error < StandardError; end

    TLS_MODES = %w[starttls ssl none].freeze

    attr_reader :to

    def initialize(config, smtp_factory: nil)
      @config       = config || {}
      @smtp_factory = smtp_factory || ->(host, port) { Net::SMTP.new(host, port) }

      @to           = Array(@config["to"]).map(&:to_s).reject(&:empty?)
      @from         = @config["from"].to_s
      @from_name    = @config["from_name"].to_s
      @host         = @config["host"].to_s
      @port         = Integer(@config.fetch("port", 587))
      @user         = @config["user"].to_s
      @user         = nil if @user.empty?
      @password     = resolve_password
      @tls          = (@config["tls"] || "starttls").to_s
      @timeout      = Integer(@config.fetch("timeout", 10))
      @helo         = @config["helo"].to_s
      @helo         = Socket.gethostname if @helo.empty?
      @subject_prefix = (@config["subject_prefix"] || "[one-nhc]").to_s

      validate!
    end

    def deliver(payload)
      send_message(build_message(payload))
      true
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "#{e.class}: #{e.message}"
    end

    private

    def resolve_password
      env_name = @config["password_env"].to_s
      file     = @config["password_file"].to_s

      if !env_name.empty?
        value = ENV[env_name]
        raise Error, "environment variable #{env_name} is not set" if value.nil? || value.empty?

        value
      elsif !file.empty?
        raise Error, "password file not found: #{file}" unless File.file?(file)

        value = File.read(file).strip
        raise Error, "password file is empty: #{file}" if value.empty?

        value
      end
    end

    def validate!
      raise Error, "email.to is required" if @to.empty?
      raise Error, "email.from is required" if @from.empty?
      raise Error, "email.host is required" if @host.empty?
      raise Error, "email.port must be between 1 and 65535" unless (1..65_535).cover?(@port)
      raise Error, "email.tls must be one of #{TLS_MODES.join(', ')}" unless TLS_MODES.include?(@tls)
      raise Error, "email.timeout must be >= 1" if @timeout < 1
      raise Error, "email.user requires password_env or password_file" if @user && @password.nil?
      raise Error, "email password requires email.user" if @password && @user.nil?
    end

    def build_message(payload)
      boundary   = "one-nhc-#{Time.now.to_i}-#{rand(1_000_000)}"
      text_body  = EmailTemplate.text(payload)
      html_body  = EmailTemplate.html(payload)
      from_header = @from_name.empty? ? @from : "#{@from_name} <#{@from}>"
      subject    = "#{@subject_prefix} #{payload[:status]} | #{payload[:host]} | #{payload[:action]}"
      subject    = subject.gsub(/\s+/, " ").strip

      <<~MAIL
        From: #{from_header}
        To: #{@to.join(', ')}
        Subject: #{subject}
        Date: #{Time.now.rfc2822}
        Message-ID: <#{Time.now.to_i}.#{rand(1_000_000)}@one-nhc.local>
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="#{boundary}"

        --#{boundary}
        Content-Type: text/plain; charset=UTF-8
        Content-Transfer-Encoding: 8bit

        #{text_body}
        --#{boundary}
        Content-Type: text/html; charset=UTF-8
        Content-Transfer-Encoding: 8bit

        #{html_body}
        --#{boundary}--
      MAIL
    end

    def send_message(message)
      smtp = @smtp_factory.call(@host, @port)
      smtp.open_timeout = @timeout
      smtp.read_timeout = @timeout

      case @tls
      when "starttls" then smtp.enable_starttls_auto
      when "ssl" then smtp.enable_tls
      end

      if @user
        smtp.start(@helo, @user, @password, :plain) do |session|
          session.send_message(message, @from, @to)
        end
      else
        smtp.start(@helo) do |session|
          session.send_message(message, @from, @to)
        end
      end
    end
  end
end

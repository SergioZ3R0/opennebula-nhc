# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

OneNHC.check(
  id: "gpu",
  description: "NVIDIA GPU count matches the expected value",
  severity: :crit,
  timeout: 15,
  tags: %w[hardware gpu]
) do |ctx|
  options  = ctx.config.check("gpu")
  required = options.fetch("required", false)
  expected = options["count"]
  timeout  = Integer(options.fetch("timeout", 10))

  unless OneNHC::Shell.which("nvidia-smi")
    if required
      ctx.crit!("nvidia-smi not installed")
    else
      ctx.skip!("nvidia-smi not installed")
    end
  end

  stdout, stderr, status, state = OneNHC::Shell.capture(
    ["nvidia-smi", "-L"], timeout: timeout
  )

  case state
  when :notfound
    ctx.skip!("nvidia-smi not found")
  when :timeout
    ctx.crit!("nvidia-smi -L timed out after #{timeout}s")
  end

  unless status&.success?
    message = stderr.to_s.strip.empty? ? stdout.to_s.strip : stderr.to_s.strip
    ctx.crit!("nvidia-smi -L failed: #{message.lines.first.to_s.strip}")
  end

  gpus = stdout.to_s.lines.count { |line| line.start_with?("GPU ") }

  if gpus.zero? && expected.nil?
    if required
      ctx.crit!("no NVIDIA GPUs detected")
    else
      ctx.skip!("no NVIDIA GPUs detected")
    end
  end

  if !expected.nil? && gpus != expected.to_i
    ctx.crit!(
      "expected #{expected} GPU(s), found #{gpus}",
      metrics: { "gpus" => gpus }
    )
  else
    ctx.ok!("#{gpus} GPU(s) present", metrics: { "gpus" => gpus })
  end
end

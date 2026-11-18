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
  options   = ctx.config.check("gpu")
  required  = options.fetch("required", false)
  expected  = options["count"]
  count_mig = options.fetch("count_mig", true)
  timeout   = Integer(options.fetch("timeout", 10))

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

  lines    = stdout.to_s.lines.map(&:strip)
  physical = lines.count { |line| line.start_with?("GPU ") }
  mig      = lines.count { |line| line.start_with?("MIG") }
  gpus     = physical + (count_mig ? mig : 0)

  if physical.zero? && expected.nil?
    if required
      ctx.crit!("no NVIDIA GPUs detected")
    else
      ctx.skip!("no NVIDIA GPUs detected")
    end
  end

  metrics = { "gpus" => gpus, "physical_gpus" => physical, "mig" => mig }
  detail  = mig.zero? ? "" : " (#{physical} physical, #{mig} MIG)"

  if !expected.nil? && gpus != expected.to_i
    ctx.crit!(
      "expected #{expected} GPU(s), found #{gpus}#{detail}",
      metrics: metrics
    )
  else
    ctx.ok!("#{gpus} GPU(s) present#{detail}", metrics: metrics)
  end
end

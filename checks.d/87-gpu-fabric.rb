# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

OneNHC.check(
  id: "gpu-fabric",
  description: "NVIDIA GPU Fabric State and Status are healthy",
  severity: :crit,
  timeout: 60,
  heavy: true,
  ttl: 1800,
  tags: %w[hardware gpu]
) do |ctx|
  options  = ctx.config.check("gpu-fabric")
  required = options.fetch("required", false)
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
    ctx.unknown!("nvidia-smi -L timed out after #{timeout}s")
  end

  unless status&.success?
    message = stderr.to_s.strip.empty? ? stdout.to_s.strip : stderr.to_s.strip
    ctx.unknown!("nvidia-smi -L failed: #{message.lines.first.to_s.strip}")
  end

  gpus = stdout.to_s.lines.count { |line| line.start_with?("GPU ") }

  if gpus.zero?
    if required
      ctx.crit!("no NVIDIA GPUs detected")
    else
      ctx.skip!("no NVIDIA GPUs detected")
    end
  end

  problems = []
  unknowns = []

  gpus.times do |index|
    out, err, st, stt = OneNHC::Shell.capture(
      ["nvidia-smi", "-q", "-i", index.to_s], timeout: timeout
    )

    case stt
    when :notfound
      unknowns << "nvidia-smi not found"
      break
    when :timeout
      unknowns << "GPU#{index} Fabric query timed out after #{timeout}s"
      next
    end

    unless st&.success?
      message = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
      unknowns << "GPU#{index} query failed: #{message.lines.first.to_s.strip}"
      next
    end

    lines = out.to_s.lines
    start = lines.index { |line| line.strip == "Fabric" }
    unless start
      unknowns << "GPU#{index} Fabric information missing"
      next
    end

    block    = lines[start, 8].join
    state_v  = block[/State\s*:\s*(\S+)/, 1]
    status_v = block[/Status\s*:\s*(\S+)/, 1]

    if state_v.nil? || status_v.nil?
      unknowns << "GPU#{index} Fabric State/Status unparseable"
    elsif state_v != "Completed" || status_v != "Success"
      problems << "GPU#{index} Fabric State=#{state_v} Status=#{status_v}"
    end
  end

  if problems.any?
    ctx.crit!(problems.join("; "), metrics: { "problems" => problems.size })
  elsif unknowns.any?
    ctx.unknown!(unknowns.join("; "), metrics: { "unknowns" => unknowns.size })
  else
    ctx.ok!("#{gpus} GPU(s) Fabric healthy", metrics: { "gpus" => gpus })
  end
end

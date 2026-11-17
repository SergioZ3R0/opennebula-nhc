# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

OneNHC.check(
  id: "gpu",
  description: "NVIDIA GPUs present and GPU Fabric healthy",
  severity: :crit,
  timeout: 30,
  tags: %w[hardware gpu]
) do |ctx|
  options  = ctx.config.check("gpu")
  required = options.fetch("required", false)
  fabric   = options.fetch("fabric", false)
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

  gpus     = stdout.to_s.lines.count { |line| line.start_with?("GPU ") }
  problems = []

  if gpus.zero? && expected.nil?
    if required
      ctx.crit!("no NVIDIA GPUs detected")
    else
      ctx.skip!("no NVIDIA GPUs detected")
    end
  end

  if !expected.nil? && gpus != expected.to_i
    problems << "expected #{expected} GPU(s), found #{gpus}"
  end

  if fabric
    gpus.times do |index|
      out, err, st, stt = OneNHC::Shell.capture(
        ["nvidia-smi", "-q", "-i", index.to_s], timeout: timeout
      )

      case stt
      when :notfound
        problems << "nvidia-smi not found"
        break
      when :timeout
        problems << "GPU#{index} Fabric query timed out after #{timeout}s"
        next
      end

      unless st&.success?
        message = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
        problems << "GPU#{index} query failed: #{message.lines.first.to_s.strip}"
        next
      end

      lines   = out.to_s.lines
      start   = lines.index { |line| line.strip == "Fabric" }
      block   = start ? lines[start, 8].join : ""
      state_v = block[/State\s*:\s*(\S+)/, 1]
      status_v = block[/Status\s*:\s*(\S+)/, 1]

      if state_v != "Completed" || status_v != "Success"
        problems << "GPU#{index} Fabric State=#{state_v || '?'} Status=#{status_v || '?'}"
      end
    end
  end

  if problems.empty?
    ctx.ok!("#{gpus} GPU(s) healthy", metrics: { "gpus" => gpus })
  else
    ctx.crit!(problems.join("; "), metrics: { "gpus" => gpus, "problems" => problems.size })
  end
end

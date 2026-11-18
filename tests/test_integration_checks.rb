# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"

# End-to-end simulation of every check with fake commands and fake sysfs.
# No SMART disks, GPUs, InfiniBand hardware, RPM or systemd are required.
class TestIntegrationChecks < Minitest::Test
  CLI = File.expand_path("../bin/one-nhc", __dir__)

  def setup
    @dir    = Dir.mktmpdir
    @bin    = File.join(@dir, "bin")
    @sys    = File.join(@dir, "sys")
    @net    = File.join(@sys, "class", "net")
    @ib     = File.join(@sys, "class", "infiniband")
    @block  = File.join(@sys, "block")
    @data   = File.join(@dir, "data")
    @proc   = File.join(@dir, "proc_mounts")
    @mdstat = File.join(@dir, "mdstat")
    @cache  = File.join(@dir, "cache.json")
    @config = File.join(@dir, "one-nhc.conf")

    FileUtils.mkdir_p([@bin, @net, @ib, @block, @data])
    write_fixtures
    write_fake_commands
    write_config
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  def write_fixtures(fs_ro: false, iface_down: false, ib_down: false, raid_degraded: 0)
    File.write(@proc, <<~MOUNTS)
      proc /proc proc rw 0 0
      sysfs /sys sysfs rw 0 0
      /dev/sda1 / ext4 rw,relatime 0 0
      /dev/sdb1 /data ext4 #{fs_ro ? "ro" : "rw"},relatime 0 0
    MOUNTS

    FileUtils.mkdir_p(File.join(@net, "onebr0"))
    File.write(File.join(@net, "onebr0", "operstate"), iface_down ? "down\n" : "up\n")
    File.write(File.join(@net, "onebr0", "speed"), "25000\n")

    port = File.join(@ib, "mlx5_0", "ports", "1")
    FileUtils.mkdir_p(port)
    File.write(File.join(port, "state"), ib_down ? "1: DOWN\n" : "4: ACTIVE\n")
    File.write(File.join(port, "phys_state"), ib_down ? "2: Polling\n" : "5: LinkUp\n")
    File.write(File.join(port, "rate"), "400 Gb/sec (4X EDR)\n")
    File.write(File.join(@ib, "mlx5_0", "fw_ver"), "28.45.1200\n")

    md = File.join(@block, "md0", "md")
    FileUtils.mkdir_p(md)
    File.write(File.join(md, "degraded"), "#{raid_degraded}\n")

    File.write(@mdstat, "Personalities : [raid1]\nmd0 : active raid1 sda1[0] sdb1[1]\n")
  end

  def write_fake_commands
    {
      "df" => <<~'SH',
        #!/bin/sh
        usage=50
        if [ "${SIM_FS_USAGE_FAIL:-0}" = "1" ]; then usage=96; fi
        case "$1" in
          -Pi) echo "Filesystem Inodes IUsed IFree IUse% Mounted on"; echo "/dev/sda1 1000 500 500 ${usage}% /data" ;;
          *)   echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; echo "/dev/sda1 1000 500 500 ${usage}% /data" ;;
        esac
      SH
      "smartctl" => <<~'SH',
        #!/bin/sh
        if [ "${SIM_SMART_FAIL:-0}" = "1" ]; then
          echo "SMART overall-health self-assessment test result: FAILED!"
        else
          echo "SMART overall-health self-assessment test result: PASSED"
        fi
        exit 0
      SH
      "nvidia-smi" => <<~'SH',
        #!/bin/sh
        if [ "$1" = "-L" ]; then
          echo "GPU 0: NVIDIA A100 (UUID: GPU-0)"
          if [ "${SIM_GPU_FAIL:-0}" != "1" ]; then
            echo "GPU 1: NVIDIA A100 (UUID: GPU-1)"
          fi
          exit 0
        fi
        echo "GPU 00000000:01:00.0"
        echo "    Fabric"
        if [ "${SIM_GPU_FABRIC_FAIL:-0}" = "1" ]; then
          echo "        State : Failed"
          echo "        Status : Error"
        else
          echo "        State : Completed"
          echo "        Status : Success"
        fi
        exit 0
      SH
      "systemctl" => <<~'SH',
        #!/bin/sh
        if [ "${SIM_SERVICE_FAIL:-0}" = "1" ]; then exit 3; fi
        exit 0
      SH
      "pgrep" => <<~'SH',
        #!/bin/sh
        if [ "${SIM_SERVICE_FAIL:-0}" = "1" ]; then exit 1; fi
        exit 0
      SH
      "virsh" => <<~'SH',
        #!/bin/sh
        if [ "${SIM_LIBVIRT_FAIL:-0}" = "1" ]; then
          echo "error: failed to connect to the hypervisor" >&2
          exit 1
        fi
        echo " Id   Name"
        echo " 1    vm-a"
        echo " 2    vm-b"
      SH
      "rpm" => <<~'SH'
        #!/bin/sh
        if [ "${SIM_PACKAGE_FAIL:-0}" = "1" ]; then
          echo "26.02"
        else
          echo "26.01"
        fi
        exit 0
      SH
    }.each do |name, body|
      path = File.join(@bin, name)
      File.write(path, body)
      File.chmod(0o755, path)
    end
  end

  def write_config
    File.write(@config, <<~YAML)
      proc_mounts: #{@proc}
      cache_file: #{@cache}
      node_name: simnode

      groups:
        all: "simnode"

      checks:
        fs-ro:
          enabled: true
          hosts: all
        datastore-mounts:
          enabled: true
          hosts: all
          mounts:
            - {path: #{@data}, must_be_mount: false}
        libvirt:
          enabled: true
          hosts: all
        fs-usage:
          enabled: true
          hosts: all
          mounts:
            - {path: #{@data}}
        network-interface:
          enabled: true
          hosts: all
          sysfs: #{@net}
          interfaces:
            - {name: onebr0, state: up, speed: 25000}
        infiniband:
          enabled: true
          hosts: all
          sysfs: #{@ib}
          devices:
            - {device: mlx5_0, port: 1, state: ACTIVE, rate: 400, firmware: "28.45.1200"}
        service:
          enabled: true
          hosts: all
          services:
            - {name: openibd, type: systemd}
            - {name: slurmd, type: process}
        raid:
          enabled: true
          hosts: all
          sysfs: #{@block}
          mdstat: #{@mdstat}
        gpu:
          enabled: true
          hosts: all
          count: 2
          required: true
        gpu-fabric:
          enabled: true
          hosts: all
          required: true
        smart:
          enabled: true
          hosts: all
          required: true
          devices: ["/dev/sda"]
        ofed-version:
          enabled: true
          hosts: all
          package: mlnx-ofa_kernel
          version: "26.01"
          manager: rpm
    YAML
  end

  def run_cli(*args, env: {})
    base = {
      "PATH" => "#{@bin}:#{ENV.fetch('PATH', '')}",
      "ONE_NHC_NODE" => "simnode"
    }

    Open3.capture3(base.merge(env), RbConfig.ruby, CLI, *args)
  end

  def check_json(*args, env: {})
    stdout, stderr, status = run_cli("check", "-c", @config, "--json", *args, env: env)
    assert status.success?, "check failed: #{stderr}"
    JSON.parse(stdout)
  end

  def assert_check_status(id, expected, env: {})
    stdout, stderr, _status = run_cli(
      "check", "-c", @config, "--json", "--only", id, env: env
    )
    data = JSON.parse(stdout)
    result = data["checks"].find { |check| check["id"] == id }

    refute_nil result, "missing #{id} result: #{stderr}"
    assert_equal expected, result["status"], "#{id}: #{result['message']}"
  end

  def parse_probe(output)
    output.lines.each_with_object({}) do |line, result|
      line = line.chomp
      next unless line =~ /\A([A-Z0-9_]+)="(.*)"\z/

      result[Regexp.last_match(1)] = Regexp.last_match(2)
    end
  end

  def test_all_checks_are_ok
    data = check_json

    assert_equal "OK", data["status"]
    assert_equal 12, data["checks"].size

    data["checks"].each do |check|
      assert_equal "OK", check["status"], "#{check['id']}: #{check['message']}"
    end
  end

  def test_fs_ro_crit
    write_fixtures(fs_ro: true)
    assert_check_status("fs-ro", "CRIT")
  end

  def test_datastore_mounts_crit
    FileUtils.rm_rf(@data)
    assert_check_status("datastore-mounts", "CRIT")
  end

  def test_libvirt_crit
    assert_check_status("libvirt", "CRIT", env: { "SIM_LIBVIRT_FAIL" => "1" })
  end

  def test_fs_usage_crit
    assert_check_status("fs-usage", "CRIT", env: { "SIM_FS_USAGE_FAIL" => "1" })
  end

  def test_network_interface_crit
    write_fixtures(iface_down: true)
    assert_check_status("network-interface", "CRIT")
  end

  def test_infiniband_crit
    write_fixtures(ib_down: true)
    assert_check_status("infiniband", "CRIT")
  end

  def test_service_crit
    assert_check_status("service", "CRIT", env: { "SIM_SERVICE_FAIL" => "1" })
  end

  def test_raid_crit
    write_fixtures(raid_degraded: 1)
    assert_check_status("raid", "CRIT")
  end

  def test_gpu_crit
    assert_check_status("gpu", "CRIT", env: { "SIM_GPU_FAIL" => "1" })
  end

  def test_gpu_fabric_crit
    assert_check_status("gpu-fabric", "CRIT", env: { "SIM_GPU_FABRIC_FAIL" => "1" })
  end

  def test_smart_crit
    assert_check_status("smart", "CRIT", env: { "SIM_SMART_FAIL" => "1" })
  end

  def test_ofed_version_crit
    assert_check_status("ofed-version", "CRIT", env: { "SIM_PACKAGE_FAIL" => "1" })
  end

  def test_heavy_checks_use_the_cache
    _out, err, status = run_cli(
      "cache", "-c", @config, "--only", "smart,gpu-fabric"
    )
    assert status.success?, "cache failed: #{err}"

    cache = JSON.parse(File.read(@cache))
    assert_equal %w[gpu-fabric smart], cache["checks"].keys.sort

    out, _err, _status = run_cli(
      "probe", "-c", @config, "--only", "smart,gpu-fabric"
    )
    values = parse_probe(out)

    assert_equal "OK", values["NHC_SMART"], out
    assert_equal "OK", values["NHC_GPU_FABRIC"], out
  end

  def test_missing_cache_reports_unknown_for_heavy_checks
    FileUtils.rm_f(@cache)

    out, _err, _status = run_cli(
      "probe", "-c", @config, "--only", "smart,gpu-fabric"
    )
    values = parse_probe(out)

    assert_equal "UNKNOWN", values["NHC_SMART"], out
    assert_equal "UNKNOWN", values["NHC_GPU_FABRIC"], out
  end

  def test_fast_gpu_count_does_not_use_the_cache
    FileUtils.rm_f(@cache)

    out, _err, _status = run_cli("probe", "-c", @config, "--only", "gpu")
    values = parse_probe(out)

    assert_equal "OK", values["NHC_GPU"], out
  end
end

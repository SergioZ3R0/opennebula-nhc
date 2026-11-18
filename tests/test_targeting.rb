# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"

class TestTargeting < Minitest::Test
  def check(id)
    OneNHC::Check.new(id: id) { |ctx| ctx.ok! }
  end

  def config(checks, groups = {})
    disabled = OneNHC.checks.each_with_object({}) do |candidate, result|
      result[candidate.id] = { "enabled" => false }
    end

    OneNHC::Config.new(
      "groups" => groups,
      "checks" => disabled.merge(checks)
    )
  end

  def test_default_targets_every_host
    cfg = config("fs-ro" => { "enabled" => true })

    assert check("fs-ro").targets_host?(cfg, "node01")
    assert check("fs-ro").targets_host?(cfg, "anywhere")
  end

  def test_hosts_expression_with_group
    cfg = config(
      { "infiniband" => { "enabled" => true, "hosts" => "@gpu" } },
      "gpu" => "gpu[01-02]"
    )

    assert check("infiniband").targets_host?(cfg, "gpu01")
    assert check("infiniband").targets_host?(cfg, "gpu02")
    refute check("infiniband").targets_host?(cfg, "node01")
  end

  def test_exclude_wins_over_hosts
    cfg = config(
      "fs-ro" => { "enabled" => true, "hosts" => "all", "exclude" => "node05" }
    )

    refute check("fs-ro").targets_host?(cfg, "node05")
    assert check("fs-ro").targets_host?(cfg, "node06")
  end

  def test_runner_filters_not_targeted
    cfg = config(
      "fs-ro" => { "enabled" => true, "hosts" => "node01" },
      "datastore-mounts" => { "enabled" => true, "hosts" => "all" },
      "libvirt" => { "enabled" => true, "hosts" => "all" }
    )
    runner = OneNHC::Runner.new(cfg, node: "node02")

    ids = runner.selected.map(&:id)
    refute_includes ids, "fs-ro"
    assert_includes ids, "datastore-mounts"
    assert_includes ids, "libvirt"

    assert_equal ["fs-ro"], runner.not_targeted.map(&:id)
  end

  def test_validate_rejects_unknown_group
    cfg = config("fs-ro" => { "enabled" => true, "hosts" => "@nope" })
    assert_raises(ArgumentError) { cfg.validate! }
  end

  def test_validate_accepts_known_group
    cfg = config(
      { "fs-ro" => { "enabled" => true, "hosts" => "@compute" } },
      "compute" => "node[01-10]"
    )
    assert cfg.validate!
  end

  def test_nested_groups_are_flattened
    cfg = OneNHC::Config.new(
      "groups" => {
        "default" => {
          "cpu" => "node[01-02]",
          "gpu" => "gpu[01-02]"
        },
        "LLM" => {
          "fat" => "fat[01-10]"
        }
      },
      "checks" => {
        "fs-ro" => { "enabled" => true, "hosts" => "@default/gpu" }
      }
    )

    assert cfg.validate!
    assert_equal "gpu[01-02]", cfg["groups"]["default/gpu"]
    assert_equal "fat[01-10]", cfg["groups"]["LLM/fat"]
    assert OneNHC::Hostlist.match?(
      "@default/gpu", "gpu01", groups: cfg["groups"]
    )
    refute OneNHC::Hostlist.match?(
      "@default/gpu", "fat01", groups: cfg["groups"]
    )
  end

  def test_probe_results_omit_not_targeted_by_default
    cfg = config(
      "fs-ro" => { "enabled" => true, "hosts" => "node01" },
      "datastore-mounts" => { "enabled" => true, "hosts" => "node01" },
      "libvirt" => { "enabled" => true, "hosts" => "node01" }
    )
    runner = OneNHC::Runner.new(cfg, node: "node02")

    assert_empty runner.probe_results
  end

  def test_probe_results_report_not_targeted_when_enabled
    base = config(
      "fs-ro" => { "enabled" => true, "hosts" => "node01" },
      "datastore-mounts" => { "enabled" => true, "hosts" => "node01" },
      "libvirt" => { "enabled" => true, "hosts" => "node01" }
    )
    cfg = OneNHC::Config.new(
      "report_not_targeted" => true,
      "groups" => {},
      "checks" => base.to_h["checks"]
    )
    runner = OneNHC::Runner.new(cfg, node: "node02")
    results = runner.probe_results

    assert_equal 3, results.size
    assert results.all? { |result| result.status == :skip }
    assert_includes results.first.message, "not targeted on node02"
  end
end

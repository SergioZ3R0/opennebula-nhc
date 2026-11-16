# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"

class TestTargeting < Minitest::Test
  def check(id)
    OneNHC::Check.new(id: id) { |ctx| ctx.ok! }
  end

  def config(checks, groups = {})
    OneNHC::Config.new("groups" => groups, "checks" => checks)
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
end

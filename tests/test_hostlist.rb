# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"

class TestHostlist < Minitest::Test
  def expand(expr, groups = {})
    OneNHC::Hostlist.expand(expr, groups: groups)
  end

  def test_single_host
    assert_equal ["node01"], expand("node01")
  end

  def test_zero_padded_range
    assert_equal %w[node01 node02 node03], expand("node[01-03]")
  end

  def test_unpadded_range
    assert_equal %w[node1 node2 node3], expand("node[1-3]")
  end

  def test_comma_list
    assert_equal %w[node01 node08], expand("node[01,08]")
  end

  def test_mixed_ranges_and_values
    expected = %w[node01 node02 node03 node08 node10 node11 node12]
    assert_equal expected, expand("node[01-03,08,10-12]")
  end

  def test_multiple_brackets
    expected = %w[node01-rack1 node01-rack2 node02-rack1 node02-rack2]
    assert_equal expected, expand("node[01-02]-rack[1-2]")
  end

  def test_group_reference
    groups = { "compute" => "node[01-02]" }
    assert_equal %w[node01 node02], expand("@compute", groups)
  end

  def test_nested_groups
    groups = { "allcompute" => "@compute", "compute" => "node[01-02]" }
    assert_equal %w[node01 node02], expand("@allcompute", groups)
  end

  def test_top_level_comma_with_groups
    groups = { "compute" => "node[01-02]" }
    assert_equal %w[node01 node02 stor01], expand("@compute,stor01", groups)
  end

  def test_all
    assert_equal ["*"], expand("all")
    assert_equal ["*"], expand("*")
  end

  def test_match
    assert OneNHC::Hostlist.match?("node[01-10]", "node05")
    refute OneNHC::Hostlist.match?("node[01-10]", "node11")
    assert OneNHC::Hostlist.match?("node*", "node42")
    assert OneNHC::Hostlist.match?("all", "anything")
  end

  def test_unknown_group
    assert_raises(ArgumentError) { expand("@nope") }
  end

  def test_cyclic_group
    groups = { "a" => "@b", "b" => "@a" }
    assert_raises(ArgumentError) { expand("@a", groups) }
  end

  def test_unbalanced_brackets
    assert_raises(ArgumentError) { expand("node[01-03") }
  end

  def test_range_too_large
    assert_raises(ArgumentError) { expand("node[1-999999999]") }
  end
end

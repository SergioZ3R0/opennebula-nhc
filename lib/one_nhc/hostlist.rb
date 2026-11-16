# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

module OneNHC
  # clush/dsh-style hostlist expansion and matching.
  #
  #   node01
  #   node[01-10]
  #   node[01,08]
  #   node[01-03,08,10-12]
  #   node[01-02]-rack[1-2]     (cartesian product)
  #   node*                     (glob, via File.fnmatch)
  #   @group                    (reference to groups.<group>)
  #   all | *                   (every host)
  module Hostlist
    MAX_RANGE = 100_000

    module_function

    # Expands an expression into a list of literal patterns.
    def expand(expr, groups: {}, seen: [])
      split_top_level(expr.to_s).flat_map do |token|
        token = token.strip
        next [] if token.empty?
        next ["*"] if token == "all" || token == "*"

        if token.start_with?("@")
          name = token[1..]
          raise ArgumentError, "cyclic group reference @#{name}" if seen.include?(name)

          definition = groups[name] || groups[name.to_sym]
          raise ArgumentError, "unknown group @#{name}" if definition.nil?

          expand(definition, groups: groups, seen: seen + [name])
        else
          expand_token(token)
        end
      end.uniq
    end

    # Returns true when the node matches the expression.
    def match?(expr, node, groups: {})
      return true if expr.nil?

      expand(expr, groups: groups).any? { |pattern| File.fnmatch?(pattern, node) }
    end

    def split_top_level(expr)
      result  = []
      depth   = 0
      current = +""

      expr.each_char do |char|
        case char
        when "["
          depth += 1
          current << char
        when "]"
          depth -= 1
          current << char
        when ","
          if depth.zero?
            result << current
            current = +""
          else
            current << char
          end
        else
          current << char
        end
      end

      result << current
      result
    end

    def expand_token(token)
      open_index = token.index("[")
      return [token] if open_index.nil?

      close_index = matching_bracket(token, open_index)
      prefix      = token[0...open_index]
      inner       = token[(open_index + 1)...close_index]
      suffix      = token[(close_index + 1)..] || ""

      expand_inner(inner).flat_map do |value|
        expand_token("#{prefix}#{value}#{suffix}")
      end
    end

    def matching_bracket(token, open_index)
      depth = 0

      token.each_char.with_index do |char, index|
        next if index < open_index

        depth += 1 if char == "["
        depth -= 1 if char == "]"
        return index if depth.zero?
      end

      raise ArgumentError, "unbalanced brackets in '#{token}'"
    end

    def expand_inner(inner)
      inner.split(",", -1).flat_map do |part|
        raise ArgumentError, "empty element in '[#{inner}]'" if part.empty?

        if part.include?("-")
          from_str, to_str = part.split("-", 2)
          from = Integer(from_str)
          to   = Integer(to_str)

          raise ArgumentError, "invalid range '#{part}'" if to < from
          raise ArgumentError, "range too large '#{part}'" if (to - from) > MAX_RANGE

          width = from_str.start_with?("0") ? from_str.length : 0
          (from..to).map do |number|
            width.positive? ? number.to_s.rjust(width, "0") : number.to_s
          end
        else
          [part]
        end
      end
    end
  end
end

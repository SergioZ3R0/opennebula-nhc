# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "one_nhc"
require "minitest/autorun"
require "tmpdir"

# Minimal singleton-method stub, avoids depending on minitest/mock.
module StubHelper
  def with_stub(object, method_name, value)
    singleton = object.singleton_class
    defined   = singleton.method_defined?(method_name) ||
                singleton.private_method_defined?(method_name)
    original  = singleton.instance_method(method_name) if defined

    singleton.send(:define_method, method_name) do |*args, **kwargs|
      value.respond_to?(:call) ? value.call(*args, **kwargs) : value
    end

    yield
  ensure
    if defined
      singleton.send(:define_method, method_name, original)
    else
      singleton.send(:remove_method, method_name)
    end
  end
end

Minitest::Test.include(StubHelper)

OneNHC.load_checks

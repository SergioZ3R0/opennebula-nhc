# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

Dir[File.join(__dir__, "test_*.rb")].sort.each { |file| require file }

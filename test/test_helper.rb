# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "autoproj/cli/ci"
require "autoproj/test"

require "minitest/autorun"
require "minitest/spec"

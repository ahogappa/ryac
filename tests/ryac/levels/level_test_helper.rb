# frozen_string_literal: true

require_relative '../../test_helper'

module LevelTestHelper
  LEVEL_TEST_CODE = File.read(File.expand_path('../../fixtures/level_test_code.rb', __dir__))
end

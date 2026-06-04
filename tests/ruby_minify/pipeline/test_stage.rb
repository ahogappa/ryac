# frozen_string_literal: true

require_relative '../../test_helper'

# The Pipeline::Stage base only defines the call(input) contract; concrete
# stages override it. Subclasses that forget to do so must fail loudly.
class TestStage < Minitest::Test
  def test_base_call_raises_not_implemented
    error = assert_raises(NotImplementedError) do
      RubyMinify::Pipeline::Stage.new.call('input')
    end
    assert_includes error.message, 'call must be implemented'
  end

  def test_not_implemented_message_names_the_subclass
    subclass = Class.new(RubyMinify::Pipeline::Stage)
    error = assert_raises(NotImplementedError) { subclass.new.call(nil) }
    assert_includes error.message, '#call must be implemented'
  end
end

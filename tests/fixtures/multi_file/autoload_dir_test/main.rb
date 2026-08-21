# frozen_string_literal: true

module DirTest
  autoload :Helper, "#{__dir__}/mixin/helper"

  class Runner
    def run
      Helper.greet
    end
  end
end

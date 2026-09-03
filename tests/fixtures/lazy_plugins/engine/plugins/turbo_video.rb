# frozen_string_literal: true

require "no_such_gem_for_the_ryac_fixture"

module Engine
  class TurboVideo < Video
    def init
      super
      @palette = @palette_rgb.map { |c| c * 2 }
    end
  end
end

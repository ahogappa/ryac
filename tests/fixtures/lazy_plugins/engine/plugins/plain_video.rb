# frozen_string_literal: true

require_relative "shared"

module Engine
  class PlainVideo < Video
    include SharedHelpers

    def init
      super
      @palette = brighten(@palette_rgb)
      @ticks << :plain
    end
  end
end

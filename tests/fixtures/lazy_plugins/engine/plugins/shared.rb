# frozen_string_literal: true

module Engine
  module SharedHelpers
    BRIGHTNESS = 5

    def brighten(colors)
      colors.map { |c| c + BRIGHTNESS }
    end
  end
end

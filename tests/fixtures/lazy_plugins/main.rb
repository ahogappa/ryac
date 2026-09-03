# frozen_string_literal: true

require_relative "engine/loader"

module Engine
  class Video
    def initialize(conf)
      @conf = conf
      @palette_rgb = [10, 20, 30]
      @ticks = []
      init
    end

    attr_reader :palette

    def init
      @ticks << :base
    end

    def tick
      @ticks.size
    end
  end
end

if $PROGRAM_NAME == __FILE__
  video = Engine::Loader.load_video(:turbo) || Engine::Loader.load_video(:plain)
  puts video.is_a?(Engine::PlainVideo)
  puts video.palette.inspect
  puts video.tick
  puts Engine.const_defined?(:TurboVideo)
  puts Engine::Loader.load_video(:plain).tick
end

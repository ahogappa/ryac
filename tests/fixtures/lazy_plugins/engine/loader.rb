# frozen_string_literal: true

module Engine
  module Loader
    DB = { turbo: :TurboVideo, plain: :PlainVideo }

    # An entry point for a launcher outside the bundle: nothing in here
    # calls it, so it keeps its name.
    def self.boot(name)
      load_video(name)&.palette
    end

    def self.load_video(name)
      require_relative "plugins/#{name}_video"
      Engine.const_get(DB.fetch(name)).new(:config)
    rescue LoadError
      nil
    end
  end
end

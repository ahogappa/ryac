# frozen_string_literal: true

require_relative "lib/ryac/version"

Gem::Specification.new do |spec|
  spec.name = "ryac"
  spec.version = Ryac::VERSION
  spec.authors = ["ahogappa"]
  spec.email = ["ahogappa@gmail.com"]

  spec.summary = "A Ruby source code minifier with type-aware renaming (ryac, read as ryaku)"
  spec.description = "Ryac minifies Ruby source code using Prism AST transformations and TypeProf type inference. " \
                     "It supports multi-file bundling via require_relative, 6 compression levels (whitespace removal, " \
                     "constant folding, constant/variable/method renaming), and preserves functional equivalence " \
                     "through scope-aware analysis."
  spec.homepage = "https://github.com/ahogappa/ryac"
  spec.license = "MIT"
  # Set by the hard floor of typeprof, which requires Ruby >= 3.3. Nothing in
  # lib/ needs anything newer; the suite passes on 3.3 and on 4.0.
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/ahogappa/ryac"
  spec.metadata["changelog_uri"] = "https://github.com/ahogappa/ryac/releases"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = "bin"
  spec.executables = ["ryac"]
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.4.0"
  # 0.32.0 is the first release containing the constant-resolution fixes this
  # gem relies on; 0.31.x aborts while analyzing some real-world sources.
  spec.add_dependency "typeprof", ">= 0.32.0"
  # rbs is a transitive dependency via typeprof, but the bound belongs here:
  # from 4.1.0 on, TypeProf::Core::Service.new never finishes loading the core
  # RBS files, which hangs every run that reaches the analysis stages (L2+).
  spec.add_dependency "rbs", ">= 3.6.0", "< 4.1.0"
  spec.add_dependency "rubocop"
end

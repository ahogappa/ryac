# frozen_string_literal: true

require_relative "lib/ryac/version"

Gem::Specification.new do |spec|
  spec.name = "ryac"
  spec.version = Ryac::VERSION
  spec.authors = ["ahogappa"]
  spec.email = ["ahogappa@gmail.com"]

  spec.summary = "A Ruby source code minifier with type-aware renaming (ryac, read as ryaku)"
  spec.description = "Ryac minifies Ruby source code using Prism AST transformations and TypeProf type inference. " \
                     "It supports multi-file bundling via require_relative, two compression levels (stable: whitespace " \
                     "removal, constant folding, constant/variable renaming; unstable: adds method renaming), and " \
                     "preserves functional equivalence through scope-aware analysis."
  spec.homepage = "https://github.com/ahogappa/ryac"
  spec.license = "MIT"
  # 3.3 was dropped deliberately: it ships a pre-Core typeprof as a bundled
  # gem, which shadows the one this project needs in any unbundled context.
  # The suite passes on 3.4 and on 4.0.
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/ahogappa/ryac"
  spec.metadata["changelog_uri"] = "https://github.com/ahogappa/ryac/releases"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[tests/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = "bin"
  spec.executables = ["ryac"]
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.4.0"
  # The floor is the first release with the constant-resolution fixes this
  # gem relies on; older releases abort while analyzing some real-world
  # sources.
  spec.add_dependency "typeprof", ">= 0.32.0"
  # rbs is a transitive dependency via typeprof, but the bound belongs here:
  # past the upper bound, TypeProf::Core::Service.new never finishes loading
  # the core RBS files, which hangs every run that reaches the rename stages.
  spec.add_dependency "rbs", ">= 3.6.0", "< 4.1.0"
end

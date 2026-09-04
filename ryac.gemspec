# frozen_string_literal: true

require_relative "lib/ryac/version"

Gem::Specification.new do |spec|
  spec.name = "ryac"
  spec.version = Ryac::VERSION
  spec.authors = ["ahogappa"]
  spec.email = ["ahogappa@gmail.com"]

  spec.summary = "A Ruby source code minifier with type-aware renaming (ryac, read as ryaku)"
  spec.description = "Ryac minifies Ruby source code using Prism AST transformations and TypeProf type inference. " \
                     "It bundles a program's require_relative and autoload graph into one file (dynamic requires " \
                     "become lazy regions), compacts and folds the AST, renames constants, variables and methods " \
                     "with compatibility aliases for the names a caller outside the bundle may still use, and can " \
                     "emit the result as a self-extracting file. Two levels: stable renames a method only when type " \
                     "inference resolved every caller; unstable also renames methods with unresolved callers. " \
                     "Ryac is under active development: its architecture, interfaces and output format may change " \
                     "between releases."
  spec.homepage = "https://github.com/ahogappa/ryac"
  spec.license = "MIT"
  # 3.3 was dropped deliberately: it ships a pre-Core typeprof as a bundled
  # gem, which shadows the one this project needs in any unbundled context.
  # The suite passes on 3.4 and on 4.0.
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata["source_code_uri"] = "https://github.com/ahogappa/ryac"
  spec.metadata["changelog_uri"] = "https://github.com/ahogappa/ryac/releases"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[tests/ test/ spec/ features/ .git appveyor Gemfile]) ||
        %w[bin/console bin/setup].include?(f)
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

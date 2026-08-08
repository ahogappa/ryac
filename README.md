# RubyMinify

A Ruby code minifier that uses [TypeProf](https://github.com/ruby/typeprof) for type-aware analysis and AST-based transformations to achieve high compression rates while preserving functional equivalence.

## Philosophy

This project takes an **aggressive optimization** approach. In Ruby, even comment removal requires context awareness — for example, `foo\n# comment\n.to_s` works because the comment connects the method chain, but removing it causes a syntax error. Whether a given comment is safe to remove depends entirely on context, making the boundary between safe and unsafe transformations inherently blurry. Since conservative minification is already difficult in Ruby, we choose to optimize as aggressively as possible. TypeProf's type analysis helps make these transformations more informed, but the goal is always maximum compression.

## Features

- **Multi-file support**: Follows `require_relative` and `autoload` to collect and concatenate dependencies into a single output
- **Whitespace & comment removal**: Strips all unnecessary whitespace and comments
- **AST transformations**: Boolean/char shortening, constant folding, control flow simplification, endless methods, parenthesis optimization
- **Constant aliasing**: Renames user-defined constants and shortens repeated external constant paths
- **Variable renaming**: Shortens local variables, keyword arguments, instance/class/global variables
- **Method renaming**: Shortens method names with `send(:sym)` coordination and attr-backed ivar optimization
- **Method alias shortening**: Replaces long stdlib method names with shorter aliases (e.g., `collect` → `map`)
- **Dead code elimination**: Removes unreachable code after `return`, `break`, `next`, `raise`
- **RuboCop preprocessing**: Applies safe autocorrections before minification
- **Dynamic code detection**: Disables renaming in scopes containing `eval`, `binding`, `send`, etc.

## Installation

```ruby
gem 'ruby-minify'
```

## Usage

### Command Line

```bash
# Minify a file (follows require_relative automatically)
bin/minify path/to/entry.rb

# Specify compression level (0-5 or alias: min, stable, unstable, max)
bin/minify path/to/entry.rb -c 5
bin/minify path/to/entry.rb -c max

# Write to output file
bin/minify path/to/entry.rb -o minified.rb

# Write constant aliases to a separate file (only generated at L2+)
bin/minify path/to/entry.rb -o minified.rb -a aliases.rb

# Multiple entry points
bin/minify file1.rb file2.rb

# Minify installed gem(s) by name (resolved via Gem::Specification)
bin/minify -g rack
bin/minify -g rack,rack-session -o bundle.rb

# Show version / help
bin/minify -v
bin/minify -h
```

### Ruby API

```ruby
require 'ruby_minify'

minifier = RubyMinify::Minifier.new
result = minifier.call('path/to/entry.rb')

puts result.content           # minified code
puts result.preamble          # external prefix declarations (e.g., "A=TypeProf::Core::AST")
puts result.aliases           # backward-compat alias declarations (e.g., "MyClass=A")
puts result.stats.file_count  # number of files processed
puts result.stats.compression_ratio  # e.g., 0.44 (56% reduction)

# Specify optimization level (0-5, default: 3)
result = minifier.call('path/to/entry.rb', level: 5)
```

## Optimization Levels

The default level is **3** (`stable`). Levels 0-3 are safe transformations that preserve all public interfaces. Levels 4-5 are aggressive and may break code that relies on reflection or name inspection.

| Level | Alias | Transformations | Safety |
|-------|-------|----------------|--------|
| 0 | `min` | Whitespace/comment removal (AST rebuild) | Safe |
| 1 | | + AST transformations (boolean/char/constant folding, control flow, endless methods, paren removal) | Safe |
| 2 | | + Constant aliasing, external prefix aliasing | Safe |
| 3 | `stable` | + Local variable & keyword argument renaming | Safe |
| 4 | `unstable` | + Class/module renaming, instance/class/global variable renaming | Aggressive |
| 5 | `max` | + Method renaming, attr-backed ivar coordination | Aggressive |

See [`tests/ruby_minify/pipeline/`](tests/ruby_minify/pipeline/) for per-stage transformation examples, and [`tests/ruby_minify/levels/`](tests/ruby_minify/levels/) for end-to-end compression examples at each level.

### What the aggressive levels are verified against

The supported boundary is defined by two programs, both verified in CI:

- **This minifier itself at L5** — the minified minifier re-minifies the original source to identical output ([`tests/test_integration.rb`](tests/test_integration.rb))
- **[Optcarrot](https://github.com/mame/optcarrot) at L4** — the minified emulator renders 180 frames from a real ROM with a checksum identical to the original ([`tests/test_optcarrot.rb`](tests/test_optcarrot.rb))

How far a given program gets past L3 depends on the program. Optcarrot stops at L4 because it defeats method renaming by construction: it builds its CPU/PPU cores as source strings and `eval`s them, scans that text for `@ivar` names with a regexp, and dispatches through `send(computed_symbol)` — method names survive inside strings, out of reach of static analysis. The sinatra and rubocop suites run in CI as regression canaries at L3, but they sit outside this boundary and do not define it.

## Development

```bash
bundle install

# Run tests (fast, excludes self-hosting)
rake test

# Run all tests including self-hosting
rake test:all

# Run self-hosting test only
rake test:integration

# Run gem integration tests (minifies real gems and runs their test suites)
rake test:gems

# Minify optcarrot at L4 and compare rendered frames against the original
# (requires gem_tests/optcarrot: git clone https://github.com/mame/optcarrot gem_tests/optcarrot)
rake test:optcarrot

# Show compression ratio on self-hosting
rake benchmark
```

## Architecture

The minification pipeline:

```
FileCollector → Concatenator → Preprocessor → Compactor → STAGES[level] → Output
```

1. **FileCollector** — Resolves `require_relative` / `autoload` and collects all source files into a dependency graph
2. **Concatenator** — Topologically sorts files and concatenates them into a single source
3. **Preprocessor** — Applies RuboCop safe autocorrections (redundant return/self, symbol proc, etc.)
4. **Compactor** — Rebuilds the AST into minimal whitespace form (L0 baseline)
5. **STAGES** — Table-driven stage pipeline, configured per level:
   - **Optimize stages** (Hash `{Class => weight}`): `ControlFlowSimplify`, `EndlessMethod`, `ConstantFold`, `BooleanShorten`, `CharShorten`, `ParenOptimizer` — executed by weight (high-weight before renames, zero-weight after), each transforms `String → String`
   - **Rename stages** (Array `[Class, kwargs]`): `ConstantAliaser`, `VariableRenamer`, `MethodRenamer` — run via `UnifiedRenamer` with a single TypeProf analysis pass

## Dependencies

- [TypeProf](https://github.com/ruby/typeprof) - Type-aware AST analysis
- [Prism](https://github.com/ruby/prism) - Syntax validation
- [RuboCop](https://github.com/rubocop/rubocop) - Preprocessing autocorrections

## License

The gem is available as open source under the terms of the MIT License.

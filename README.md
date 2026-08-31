# ryac

**ryac** — minify the word *ruby* and you are left with *ry*; this tool then analyzes and compacts, so: **R**ub**y**, **A**nalyzed & **C**ompacted. Pronounced *ryaku*, like 略 — the Japanese word for "abbreviation".

A Ruby code minifier that uses [TypeProf](https://github.com/ruby/typeprof) for type-aware analysis and AST-based transformations to achieve high compression rates while preserving functional equivalence.

## Philosophy

This project takes an **aggressive optimization** approach. In Ruby, even comment removal requires context awareness — for example, `foo\n# comment\n.to_s` works because the comment connects the method chain, but removing it causes a syntax error. Whether a given comment is safe to remove depends entirely on context, making the boundary between safe and unsafe transformations inherently blurry. Since conservative minification is already difficult in Ruby, we choose to optimize as aggressively as possible. TypeProf's type analysis helps make these transformations more informed, but the goal is always maximum compression.

## Features

- **Multi-file support**: Follows `require_relative` and `autoload` to collect and concatenate dependencies into a single output
- **Whitespace & comment removal**: Strips all unnecessary whitespace and comments
- **AST transformations**: Boolean/char shortening, constant folding, control flow simplification, endless methods, parenthesis optimization
- **Constant aliasing**: Renames user-defined constants and shortens repeated external constant paths, emitting backward-compat aliases; a program that loads files dynamically at runtime (e.g. optcarrot's drivers) has enumerated its external readers, so its value-constant aliases prune to the names those files mention (the class/module skeleton always stays restorable)
- **Variable renaming**: Shortens local variables, keyword arguments, instance/class/global variables
- **Method renaming**: Shortens method names with `send(:sym)` coordination and attr-backed ivar optimization
- **Method alias shortening**: Replaces long stdlib method names with shorter aliases (e.g., `collect` → `map`)
- **Dead code elimination**: Removes unreachable code after `return`, `break`, `next`, `raise`
- **Dynamic code detection**: Disables renaming in scopes containing `eval`, `binding`, `send`, etc.

## Installation

```ruby
gem 'ryac'
```

## Usage

### Command Line

```bash
# Minify a file (follows require_relative automatically)
bin/ryac path/to/entry.rb

# Specify compression level (stable or unstable)
bin/ryac path/to/entry.rb -c stable
bin/ryac path/to/entry.rb -c unstable

# Write to output file
bin/ryac path/to/entry.rb -o minified.rb

# Write constant aliases to a separate file
bin/ryac path/to/entry.rb -o minified.rb -a aliases.rb

# Multiple entry points
bin/ryac file1.rb file2.rb

# Minify installed gem(s) by name (resolved via Gem::Specification)
bin/ryac -g rack
bin/ryac -g rack,rack-session -o bundle.rb

# Show version / help
bin/ryac -v
bin/ryac -h
```

### Ruby API

```ruby
require 'ryac'

minifier = Ryac::Minifier.new
result = minifier.call('path/to/entry.rb')

puts result.content           # minified code
puts result.preamble          # external prefix declarations (e.g., "A=TypeProf::Core::AST")
puts result.aliases           # backward-compat alias declarations (e.g., "MyClass=A")
puts result.stats.file_count  # number of files processed
puts result.stats.compression_ratio  # e.g., 0.44 (56% reduction)

# Specify optimization level (:stable or :unstable, default: :stable)
result = minifier.call('path/to/entry.rb', level: :unstable)
```

## Optimization Levels

There are exactly two levels, named for their promise. The default is **`stable`**.

| Level | Transformations | Promise |
|-------|----------------|---------|
| `stable` | AST compaction and folding, constant/class/module renaming with compatibility aliases, external prefix aliasing, local/keyword/instance/class/global variable renaming | Verified frame-for-frame on a real program (Optcarrot). Sound under closed-world analysis; reflection over *names the program renames* is the caveat. |
| `unstable` | + Method renaming, attr-backed ivar coordination | A program can defeat method renaming by construction (names inside strings, `eval`'d source, `send(computed)`), so this works only when the program plays along. Verified by self-hosting. |

Finer configurations are not levels: the pipeline is built from steps, and callers can pass an explicit stage list in place of a level name (`Minifier#call(path, level: [...stage defs...])`). The unit tests pin each step's behavior through exactly that mechanism.

See [`tests/ryac/pipeline/`](tests/ryac/pipeline/) for per-stage transformation examples, and [`tests/ryac/levels/`](tests/ryac/levels/) for end-to-end compression examples.

### What the levels are verified against

The supported boundary is defined by two programs, both verified in CI:

- **[Optcarrot](https://github.com/mame/optcarrot) at `stable`** — the minified emulator matches the original frame-for-frame across the 180-frame demo and three scripted play scenarios (1,820 frames of title menus, piece rotation, pausing and button mashing) ([`tests/test_optcarrot.rb`](tests/test_optcarrot.rb))
- **This minifier itself at `unstable`** — the minified minifier re-minifies the original source to identical output, and minifying its own output is a byte-identical fixed point ([`tests/test_integration.rb`](tests/test_integration.rb))

Whether `unstable` holds for a given program depends on the program. Optcarrot stops at `stable` because it defeats method renaming by construction: it builds its CPU/PPU cores as source strings and `eval`s them, scans that text for `@ivar` names with a regexp, and dispatches through `send(computed_symbol)` — method names survive inside strings, out of reach of static analysis. The sinatra and rubocop suites run in CI as regression canaries on a keyword-only step composition, but they sit outside this boundary and do not define it.

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

# Minify optcarrot at :stable and compare rendered frames against the original
# (requires gem_tests/optcarrot: git clone https://github.com/mame/optcarrot gem_tests/optcarrot)
rake test:optcarrot

# Show compression ratio on self-hosting
rake benchmark
```

## Architecture

The minification pipeline:

```
FileCollector → Concatenator → StageRunner (Compactor → stage list) → Output
```

1. **FileCollector** — Resolves `require_relative` / `autoload` and collects all source files into a dependency graph
2. **Concatenator** — Topologically sorts files and concatenates them into a single source
3. **StageRunner** — Compacts the source (AST rebuilt into minimal whitespace form), then walks the level's ordered stage list. Every stage implements one contract — `needs_analysis?` / `fixpoint?` / `collect(ctx, patches)` / `finish(ctx)` — and phase is list position:
   - **Syntactic stages** (no analysis): `ControlFlowSimplify`, `EndlessMethod`, `ConstantFold`, `BooleanShorten`, `CharShorten` before the rename batch; `ParenOptimizer` after it
   - **Analysis stages**: `ConstantAliaser`, `AttrDeclShorten`, `VariableRenamer` (plus `MethodRenamer` at `unstable`) — consecutive analysis stages form one batch sharing a single TypeProf pass, and the runner rejects a list that would need two

## Dependencies

- [TypeProf](https://github.com/ruby/typeprof) - Type-aware AST analysis
- [Prism](https://github.com/ruby/prism) - Syntax validation

## License

The gem is available as open source under the terms of the MIT License.

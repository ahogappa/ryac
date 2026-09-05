# ryac

**ryac** — minify the word *ruby* and you are left with *ry*; this tool then analyzes and compacts, so: **R**ub**y**, **A**nalyzed & **C**ompacted. Pronounced *ryaku*, like 略 — the Japanese word for "abbreviation".

A Ruby code minifier that uses [TypeProf](https://github.com/ruby/typeprof) for type-aware analysis and AST-based transformations to achieve high compression rates while preserving functional equivalence.

## Status

ryac is under active development and no interface is settled yet. The architecture — the pipeline stages, the rename policies, the alias and lazy-region mechanisms — and with it the CLI options, the `Ryac::Minifier` API and the shape of the output may all change between releases. Pin an exact version if you depend on any of them.

## Philosophy

This project takes an **aggressive optimization** approach. In Ruby, even comment removal requires context awareness — for example, `foo\n# comment\n.to_s` works because the comment connects the method chain, but removing it causes a syntax error. Whether a given comment is safe to remove depends entirely on context, making the boundary between safe and unsafe transformations inherently blurry. Since conservative minification is already difficult in Ruby, we choose to optimize as aggressively as possible. TypeProf's type analysis helps make these transformations more informed, but the goal is always maximum compression.

## Features

- **Multi-file support**: Follows `require_relative` and `autoload` to collect and concatenate dependencies into a single output — or, with `--split`, writes every file back minified at its own path (see [Split output](#split-output))
- **Dynamic requires**: A `require_relative "driver/#{name}"` inside a method bundles every file under that directory as a lazy region — registered at load, run the moment the require would have run — so a driver's own `require "ffi"` keeps its optional-dependency timing while the whole program shares one rename table (see [Dynamic requires](#dynamic-requires))
- **Whitespace & comment removal**: Strips all unnecessary whitespace and comments
- **AST transformations**: Boolean/char shortening, constant folding, control flow simplification, endless methods, parenthesis optimization
- **Constant aliasing**: Renames user-defined constants and shortens repeated external constant paths, emitting backward-compat aliases; once a program's dynamically loaded files are bundled, the only reader left outside is a launcher, which spells the class/module skeleton (`Optcarrot::NES.new.run`) and never a value constant — so value-constant aliases are dropped and the skeleton's kept
- **Variable renaming**: Shortens local variables, keyword arguments, instance/class/global variables
- **Method renaming**: Shortens method names with `send(:sym)` coordination and attr-backed ivar optimization
- **Method alias shortening**: Replaces long stdlib method names with shorter aliases (e.g., `collect` → `map`)
- **Dead code elimination**: Removes unreachable code after `return`, `break`, `next`, `raise`
- **Dynamic code detection**: Disables renaming in scopes containing `eval`, `binding`, `send`, etc.

## Installation

```bash
gem install ryac
```

Or in a Gemfile:

```ruby
gem 'ryac'
```

## Usage

### Command Line

```bash
# Minify a file (follows require_relative automatically)
ryac path/to/entry.rb

# Specify compression level (stable or unstable)
ryac path/to/entry.rb -c stable
ryac path/to/entry.rb -c unstable

# Write to output file
ryac path/to/entry.rb -o minified.rb

# Write constant aliases to a separate file
ryac path/to/entry.rb -o minified.rb -a aliases.rb

# Emit a self-extracting packed file (self = zero dependencies, zlib = smaller)
ryac path/to/entry.rb -o packed.rb --pack self

# Keep the program a library and write the driver that loads and runs it
ryac path/to/entry.rb -o minify.rb --driver driver.rb

# Write the program back as files under a directory, minified together
ryac path/to/entry.rb --split min/

# Multiple entry points
ryac file1.rb file2.rb

# Minify installed gem(s) by name (resolved via Gem::Specification)
ryac -g rack
ryac -g rack,rack-session -o bundle.rb

# Show version / help
ryac -v
ryac -h
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

# The two-file layout: the program as a library, run by ryac's fixed driver
core = minifier.call('path/to/entry.rb', driver: true).full_content
File.write('driver.rb', Ryac::DriverFile::SOURCE)

# The split layout: every file written back, one rename table across them
minifier.split('path/to/entry.rb').files  # { "entry.rb" => "...", "lib/dep.rb" => "..." }
```

## Optimization Levels

There are exactly two levels, named for their promise. The default is **`stable`**.

| Level | Transformations | Promise |
|-------|----------------|---------|
| `stable` | AST compaction and folding, constant/class/module renaming with compatibility aliases, external prefix aliasing, local/keyword/instance/class/global variable renaming, and method renaming under the `:safe` policy — a name is renamed only when type inference resolved every caller and no dynamic escape hatch (a string mention, a dynamic-ivar class, an uncalled def) touches it; attr declarations, their backing ivars and their call sites move together | Verified frame-for-frame on a real program (Optcarrot). Sound under closed-world analysis; reflection over *names the program renames* is the caveat. |
| `unstable` | The same stages; method renaming switches to `:aggressive`, which also renames names whose callers type inference could not resolve, betting that a same-named call is the same method | A program can defeat that bet by construction (names inside strings, `eval`'d source, `send(computed)`), so this works only when the program plays along. Verified by self-hosting. |

Finer configurations are not levels: the pipeline is built from steps, and callers can pass an explicit stage list in place of a level name (`Minifier#call(path, level: [...stage defs...])`). The unit tests pin each step's behavior through exactly that mechanism.

### Dynamic requires

A file the program loads by a computed path — optcarrot's `require_relative "driver/#{name}_#{type}"` inside `Driver.load_each` — is outside any static dependency graph, yet it runs against the program: subclassing its classes, reading its instance variables, overriding its methods. Renaming one side and not the other breaks exactly there. When the computed path starts with a static directory, ryac bundles every `.rb` file under it (and whatever those files require that nothing static did) into the same closed world, so the rename table covers both sides, and writes each as a *lazy region*:

```ruby
RYAC_LAZY["optcarrot/driver/sdl2_video"] = -> { ...the file, minified... }
```

The region's body runs when the original require would have run — a short loader keeps Ruby's contract (once and `true`, `false` on a repeat, a failed run stays retryable, an unregistered path falls through to a real `require_relative` relative to the bundle), and the require sites are rewritten to call it. So `require "ffi"` and `ffi_lib "SDL2"` at a driver's top level still execute only when that driver is selected, and the auto-selection's `rescue LoadError` still walks on to the next one.

The output is still one file. For optcarrot, it stands in for `lib/optcarrot.rb` under upstream's unmodified `bin/optcarrot`:

```bash
ryac gem_tests/optcarrot/lib/optcarrot.rb -o /path/to/optcarrot/lib/optcarrot.rb
cd /path/to/optcarrot && bin/optcarrot examples/Lan_Master.nes
```

A constant only a region defines (`SDL2Video`, the `SDL2` module) keeps its name — it does not exist until the region runs, so no alias at the end of the file could restore it — and an external constant a region references is never hoisted into the preamble. Neither costs much: a region's own names are few, and its references to the core rename like everything else.

Or keep the program a library and let a driver run it:

```bash
ryac gem_tests/optcarrot/lib/optcarrot.rb -o minify.rb --driver driver.rb
ruby driver.rb minify.rb --exec "Optcarrot::NES.new.run" examples/Lan_Master.nes
```

`minify.rb` is the whole program as a library: the registry with every region, the core and its aliases — nothing that runs, and no loader. `driver.rb` is the loader, the same file for every program (`--driver` writes a copy): it defines `ryac_require`, which looks the path up in `RYAC_LAZY` and runs the region — Ruby's contract kept, an unregistered path falling through to a real require relative to the core — then loads the core and evals the `--exec` expression at top level, its own two arguments already gone from `ARGV` so the program's option parsing sees only what follows (anything after `--` is never read). Those two names are the contract between the files: the core keeps them, a program that spells either itself is refused, and everything else renames as usual. The expression is code outside the bundle, so it can spell only what survives outside: the class/module skeleton, which the aliases restore, and methods the program itself never calls — under `stable`'s safe policy an uncalled def keeps its name, and a launcher's entry point (`NES#run`) is exactly that. `--driver` needs `-o`, and cannot be combined with `-a` or with `--pack` (a packed core cannot be loaded).

### Split output

`--split DIR` keeps the files. The whole program is still analyzed and renamed as one closed world — the same rename table across every file, dynamically loaded ones included — but each file is written back under `DIR` at its path relative to the files' common root, with its `require_relative`, `require` and `autoload` lines in place. So it loads from the tree exactly as the original did: nothing is bundled, registered or hoisted, a dynamic require stays a real require, and `__FILE__` means the file. The entry file additionally carries the preamble at its top and the aliases at its end. Two things keep their spelling because the text itself is the lookup: a constant named by `autoload :Name, "file"`, and — since no require is hoisted above the preamble — an external prefix is aliased only when its root exists at boot. For optcarrot it stands in for `lib/` wholesale under upstream's unmodified `bin/optcarrot`:

```bash
ryac gem_tests/optcarrot/lib/optcarrot.rb --split min
cp -r min/. /path/to/optcarrot/lib/ && cd /path/to/optcarrot && bin/optcarrot examples/Lan_Master.nes
```

`--split` takes one entry file and cannot be combined with `-o`, `-a`, `--pack` or `--driver`.

### Packed output

`--pack` is an output format, orthogonal to the levels: it wraps the minified program in a self-extracting stub — a short plain-Ruby decoder followed by the compressed bytes after `__END__`. On optcarrot it takes the artifact from 37% of the original source to 19.4% (`self`) or 15.1% (`zlib`).

- `--pack self` inlines a pure-Ruby LZSS decoder (282 bytes) — no `require` at all, runs anywhere Ruby runs
- `--pack zlib` deflates via the zlib default gem — smaller, but dead on a Ruby built without it

A packed file is a main-program format: the stub reads its own `__END__` data and `eval`s the program with `$0` as the file name, so `ruby packed.rb` runs it and a `$PROGRAM_NAME == __FILE__` launcher still fires. It cannot be `require`d — only the main script has `DATA` — and a program that itself uses `__END__` or reads `DATA` is refused with an error.

See [`tests/ryac/pipeline/`](tests/ryac/pipeline/) for per-stage transformation examples, and [`tests/ryac/levels/`](tests/ryac/levels/) for end-to-end compression examples.

### What the levels are verified against

The supported boundary is defined by two programs, both verified in CI:

- **[Optcarrot](https://github.com/mame/optcarrot) at `stable`** — the minified emulator matches the original frame-for-frame across the 180-frame demo and three scripted play scenarios (1,820 frames of title menus, piece rotation, pausing and button mashing), and, standing in for `lib/optcarrot.rb` under upstream's own `bin/optcarrot`, its bundled png and wav drivers write the same frame and samples as the original's ([`tests/test_optcarrot.rb`](tests/test_optcarrot.rb))
- **This minifier itself at `unstable`** — the minified minifier re-minifies the original source to identical output, and minifying its own output is a byte-identical fixed point ([`tests/test_integration.rb`](tests/test_integration.rb))

Whether `unstable` holds for a given program depends on the program. Optcarrot stops at `stable` because it defeats aggressive method renaming by construction: it builds its CPU/PPU cores as source strings and `eval`s them, scans that text for `@ivar` names with a regexp, and dispatches through `send(computed_symbol)` — method names survive inside strings, out of reach of static analysis. The sinatra and rubocop suites run in CI as regression canaries on a keyword-only step composition, but they sit outside this boundary and do not define it.

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
   - **Analysis stages**: `ConstantAliaser`, `AttrDeclShorten`, `VariableRenamer`, `MethodRenamer` (`:safe` at `stable`, `:aggressive` at `unstable`) — consecutive analysis stages form one batch sharing a single TypeProf pass, and the runner rejects a list that would need two

## Dependencies

- [TypeProf](https://github.com/ruby/typeprof) - Type-aware AST analysis
- [Prism](https://github.com/ruby/prism) - Syntax validation

## License

The gem is available as open source under the terms of the MIT License.

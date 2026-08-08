# godot-csharp-lint

A drop-in linting and formatting bundle for Godot 4 C# projects. One command, one gate.

## What it installs

| File                        | Role                                                                                  |
| --------------------------- | ------------------------------------------------------------------------------------- |
| `Directory.Build.props`     | Central analyzer config. Picked up automatically by every project at or below it.     |
| `.editorconfig`             | Formatting conventions, analyzer severities, and protection for Godot-authored files. |
| `.csharpierignore`          | Keeps CSharpier out of `addons/`, where third-party plugin sources live.              |
| `Makefile`                  | `restore` / `lint` / `fix` / `format` / `lint-sarif` / `clean`.                       |
| `.config/dotnet-tools.json` | Pinned CSharpier version.                                                             |

All five are project-agnostic. The `Makefile` discovers the solution with `$(firstword $(wildcard *.sln))`, so nothing needs renaming per project.

## Install

### Option A: `dotnet new` template

```sh
dotnet new install /path/to/godot-csharp-lint     # once per machine
cd /path/to/your/godot/project
dotnet new godot-lint
```

### Option B: script

```sh
/path/to/godot-csharp-lint/install.sh /path/to/your/godot/project
```

Existing files are skipped; pass `--force` to overwrite.

### Then

```sh
make restore
make lint
```

## Targets

| Target       | Does                                                                |
| ------------ | ------------------------------------------------------------------- |
| `restore`    | `dotnet tool restore` + `dotnet restore`. Run once after cloning.   |
| `lint`       | The gate. CSharpier check, then a full rebuild with `-warnaserror`. |
| `fix`        | `dotnet format style` → `analyzers` → `csharpier format`.           |
| `format`     | CSharpier only.                                                     |
| `lint-sarif` | Same build as `lint`, emitting `lint.sarif` instead of failing.     |
| `clean`      | `dotnet clean`.                                                     |

`fix` takes a `SEVERITY` variable (`info` by default; `info`, `warn` or `error`) to set how deep the auto-fix pass goes:

```sh
make fix                 # everything fixable, including note-level Roslynator rules
make fix SEVERITY=warn   # only what `make lint` would actually reject
```

## Design decisions

These are the non-obvious ones, and the reasoning is repeated inline in each file so it survives being copied around.

- **`<Nullable>enable</Nullable>`, with `CS8618` suppressed - not `annotations`.**
  Godot assigns node references in `_Ready()`, not in the constructor,
  so full nullable analysis reports `CS8618` on essentially every such field.
  The tempting fix is `<Nullable>annotations</Nullable>`, but that disables the whole warning context:
  `CS8602` ("dereference of a possibly null reference") goes quiet along with the noise,
  which throws away the only nullable rule that catches an actual crash.
  Suppressing `CS8618` on its own in `.editorconfig` removes the Godot false positives and keeps the rest.

- **`TreatWarningsAsErrors` is not set in the props.**
  Local builds stay non-fatal; the `lint` target enforces via `dotnet build -warnaserror`.
  This mirrors `golangci-lint` being a separate gate rather than part of every `go build`.

- **`fix` runs CSharpier last.**
  `dotnet format` on its own includes a whitespace pass that fights CSharpier over the same files,
  so the two formatting-capable passes are scoped explicitly (`style`, `analyzers`) and CSharpier gets the final say on layout.

- **`fix` defaults to `--severity info`; `lint` still gates at warning.**
  Every Roslynator rule ships at `note` severity and `dotnet format` fixes `warn` and above by default,
  so at the stock severity the RCS rules are never applied and `Roslynator.Analyzers` has no observable effect at all.
  The asymmetry is deliberate: `fix` cleans up more than the gate demands,
  so `lint` stays a stable contract while `fix` keeps the codebase ahead of it.
  Raise the floor with `make fix SEVERITY=warn` if you'd rather the two match.

- **The SARIF report comes from the compiler, not a second tool.**
  `Roslynator.Analyzers` already runs inside the build as an analyzer package,
  so shelling out to the Roslynator CLI would be a second, slower analysis of the same code -
  and that CLI cannot write SARIF anyway (`--output-format` accepts only `xml` and `gitlab`).
  `-p:ErrorLog=lint.sarif,version=2.1` makes the normal build emit SARIF 2.1 covering every analyzer
  the gate runs, which keeps the report and the gate structurally incapable of disagreeing.

- **`.editorconfig` ships suppressions commented out.**
  At `AnalysisMode=Recommended` a Godot project produces no idiom noise, so nothing needs silencing.
  The suppressions for `CA1707` (underscored engine callbacks), `CA1051` (`[Export]` fields) and `CA1801` (parameters only the engine passes)
  are pre-written for when you raise `AnalysisMode` to `All`.

- **`addons/` is excluded from formatting.**
  CSharpier skips `.godot/`, `obj/` and `bin/` on its own, but walks into `addons/`,
  where Godot installs third-party plugins whose C# sources compile as part of your project.
  Without `.csharpierignore` the gate fails on other people's code,
  and "fixing" it means carrying a permanent diff that every plugin update conflicts with.

- **Godot-authored files are excluded from whitespace rules.**
  `*.tscn`, `*.tres`, `*.godot` and `*.import` get `trim_trailing_whitespace = false` and `insert_final_newline = false`,
  because Godot owns their exact bytes and editing them produces spurious diffs.

## Tip: prefer `internal` over `public`

Not enforced by this bundle, but it multiplies its value.
Analyzers only report an unused member when they can prove no call sites exist, which is possible for `private` and `internal` but not `public`.
A game assembly is closed, so `public` buys nothing and actively suppresses the diagnostic.
Switching a small project to `internal` throughout surfaced both dead code and `CA1852` (seal internal types), neither of which had been reportable before.

Everything can be `internal` in Godot except `public override` engine callbacks (`_Ready`, `_PhysicsProcess`, …) - C# forbids an override from narrowing visibility.
`[Export]` members, `[Signal]` delegates and node classes are all fine as `internal`.

## Requirements

- .NET SDK 8.0+ (developed against 10.0)
- Godot 4.x with the Mono/.NET build
- `make`

On macOS, if `make` fails with an `xcodebuild ... -find make` error, point `xcode-select` at the Command Line Tools:

```sh
sudo xcode-select --switch /Library/Developer/CommandLineTools
```

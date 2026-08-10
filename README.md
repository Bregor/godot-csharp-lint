# godot-csharp-lint

A drop-in linting and formatting bundle for Godot 4 C# projects. One command, one gate.

## Why

A Godot C# project fails in ways the compiler cannot see, and the obvious analyzer setup makes two of them worse.

- **A renamed signal handler still compiles.** The connection lives in the `.tscn` as text,
  so nothing catches it until the signal fires - possibly in a scene nobody opens before release.
  `lint` reads the scene files.

- **Subscribing in `_Ready` and unsubscribing in `_ExitTree` looks symmetric.**
  `_Ready` runs once per node, `_ExitTree` on every removal,
  so after a remove and re-add the handler is gone for good and the signal fires into nothing.
  `lint` reports the mismatched pair - pointing at the redundant `-=` when the target is a child node,
  and at the misplaced `+=` when it is an autoload - and reports a subscription to an autoload that is never undone.

- **Only one of three configurations gets analyzed.**
  Godot generates `Debug`, `ExportDebug` and `ExportRelease`, and a default `dotnet build` compiles the first.
  Anything behind `#if !DEBUG` ships unanalyzed. `lint` builds `ExportRelease` too.

- **`<Nullable>annotations</Nullable>` turns off the half that catches crashes.**
  It is the natural answer to `CS8618` firing on every `_Ready`-assigned node reference,
  and it takes `CS8602` with it. This bundle keeps `enable` and silences `CS8618` alone.

- **Third-party addons fail your gate.**
  `Godot.NET.Sdk` compiles every `.cs` under the project root, so plugin sources become your findings.
  `addons/` is excluded from the formatter and the analyzers both.

- **`Roslynator.Analyzers` does nothing at stock settings.**
  Every RCS rule ships at `note` - below the threshold the gate enforces, and below what `dotnet format` repairs.
  Both are raised here.

- **Nothing tells you a script is still `public`.**
  `CA1515` exists for exactly that and is disabled for libraries, which is how Godot builds a game;
  `CA1051` only covers fields, so a public class with public properties passes clean.
  `CA1050` is pressed into service here - read it as "still public", not as "add a namespace".

- **Two analyzer rules fire on code Godot demands.**
  `CA1711` rejects the `EventHandler` suffix that `[Signal]` delegates cannot compile without,
  and `CA2007` asks for `ConfigureAwait(false)`, which moves scene-tree access off the main thread.
  Both are off; a stock analyzer setup has them on.

- **Formatters corrupt Godot-authored files.**
  `.tscn`, `.tres`, `.import` and the `.uid` sidecars Godot 4.4+ writes are byte-owned by the engine.

What it deliberately does not do is find dead code inside node scripts.
Godot's source generators emit a dispatch table naming every method and serialization code touching every field,
so no member of a `Node` subclass is ever reportable as unused - by any analyzer, at any visibility.
`make dead-code` says so plainly; it earns its keep on plain classes.

Every claim above was checked against Godot 4.7.1 and a real project rather than reasoned about.
The measurements are in [Design decisions](#design-decisions).

## What it installs

| File                        | Role                                                                                                                               |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `Directory.Build.props`     | Central analyzer config. Picked up automatically by every project at or below it.                                                  |
| `.editorconfig`             | Formatting conventions, analyzer severities, and protection for Godot-authored files.                                              |
| `.csharpierignore`          | Keeps CSharpier out of `addons/`, where third-party plugin sources live.                                                           |
| `check-signals.sh`          | Verifies scene signal connections resolve to real methods. Run by `lint`.                                                          |
| `check-subscriptions.sh`    | Verifies `+=` signal subscriptions are undone in a matching lifecycle method. Run by `lint`.                                       |
| `Makefile`                  | `restore` / `lint` / `fix` / `format` / `lint-sarif` / `check-signals` / `check-subscriptions` / `dead-code` / `ignore` / `clean`. |
| `.config/dotnet-tools.json` | Pinned CSharpier and Roslynator CLI versions.                                                                                      |

All seven are project-agnostic. The `Makefile` discovers the solution itself - `*.sln`, then `*.slnx`, then `*.csproj` - so nothing needs renaming per project.

## Install

Get the repository first - `dotnet new install` takes a NuGet package id, a folder, or a `.nupkg`, but not a git URL:

```sh
git clone https://github.com/Bregor/godot-csharp-lint.git
```

### Option A: `dotnet new` template

```sh
dotnet new install ./godot-csharp-lint            # once per machine
cd /path/to/your/godot/project
dotnet new godot-lint
```

#### Packing

```sh
dotnet pack -c Release
dotnet new install bin/Release/Bregor.Godot.CSharpLint.0.0.1.nupkg
```

Now `dotnet new uninstall` reports a version, `dotnet new update` works,
and `dotnet new install Bregor.Godot.CSharpLint::0.0.1` pins one.
Bump `PackageVersion` in `godot-csharp-lint.csproj` and tag the commit to match -
the tag is for humans, since `dotnet new` has no idea git exists.

### Option B: script

```sh
./godot-csharp-lint/install.sh /path/to/your/godot/project
```

Existing files are skipped; pass `--force` to overwrite.

`.gitignore` is the one exception: it is merged, never overwritten, even under `--force`.
The script runs `make ignore` for you; on the `dotnet new` route, run it yourself.

### Then

```sh
make ignore     # once, keeps lint.sarif out of git
make restore
make lint
```

## Targets

| Target                | Does                                                                                                                                          |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `restore`             | `dotnet tool restore` + `dotnet restore`. Run once after cloning.                                                                             |
| `lint`                | The gate. Signal + subscription checks, CSharpier check, a rebuild per configuration with `-warnaserror`. Every stage runs; fails at the end. |
| `fix`                 | `dotnet format style` → `analyzers` → `csharpier format`.                                                                                     |
| `format`              | CSharpier only.                                                                                                                               |
| `lint-sarif`          | Same build as `lint`, emitting `lint.sarif` instead of failing.                                                                               |
| `check-signals`       | Scene signal connections that point at methods which do not exist.                                                                            |
| `check-subscriptions` | `+=` subscriptions that are never undone, or undone in the wrong lifecycle method.                                                            |
| `dead-code`           | Reports unreferenced public/internal symbols. Advisory - read the caveats.                                                                    |
| `ignore`              | One-time. Merges `lint.sarif` into `.gitignore`. Idempotent.                                                                                  |
| `clean`               | `dotnet clean`.                                                                                                                               |

### Variables

| Variable         | Default               | Effect                                                            |
| ---------------- | --------------------- | ----------------------------------------------------------------- |
| `SEVERITY`       | `info`                | How deep `fix` goes. `info`, `warn` or `error`.                   |
| `LINT_CONFIGS`   | `Debug ExportRelease` | Configurations `lint` builds.                                     |
| `ANALYSIS_LEVEL` | _(unset)_             | Overrides `AnalysisLevel` for one run. Unset means use the props. |

```sh
make fix SEVERITY=warn        # only what `make lint` would actually reject
make lint LINT_CONFIGS=Debug  # single configuration, roughly half the time
make lint ANALYSIS_LEVEL=9.0  # try a pinned rule set before committing to it
```

`ANALYSIS_LEVEL` is deliberately empty by default.
`AnalysisLevel` belongs in `Directory.Build.props`, because the Godot editor builds the project too and never reads the `Makefile` -
a pin that lived only here would make the editor and the gate disagree.
The variable is for trying a level, not for holding it.

## CI

There is no workflow in this bundle: the gate is `make lint`, and how you invoke it is your call.
Whatever runner you use, it needs the .NET SDK, then:

```sh
make restore
make lint
```

`make lint-sarif` writes `lint.sarif` (SARIF 2.1) if your CI ingests static-analysis reports -
GitHub code scanning, GitLab, and SonarQube all read that format.
It does not fail on findings, so run it alongside `make lint` rather than instead of it.

## Design decisions

These are the non-obvious ones, and the reasoning is repeated inline in each file so it survives being copied around.

- **`lint` runs every stage before it fails.**
  The scene and subscription checks are cheap and run first,
  so making them prerequisites would mean one stale signal connection hides every analyzer finding in the project
  until it is fixed - and you would fix things one round-trip at a time.
  Each stage runs, each reports, and the exit code is decided at the end.
  `golangci-lint` does not stop at its first linter either.

- **`lint` checks scene signal connections, and it is the only check here that catches a crash.**
  A connection is plain text in the `.tscn`:
  `[connection signal="pressed" from="Button" to="." method="OnPressed"]`.
  Rename `OnPressed` and the project still compiles, every analyzer stays quiet,
  and the game breaks the next time that signal fires -
  possibly in a scene nobody opens until release.
  Roslyn cannot read scene files, so nothing else in this bundle can see it.
  `check-signals.sh` is a grep, not a parser: it verifies the method exists _somewhere_ in the project,
  not that it exists on the class attached to the target node.
  Resolving `to="../Foo/Bar"` would mean walking the node tree and the `ext_resource` table;
  the loose check already catches the case that actually happens - a handler renamed while the connection stayed behind.
  It needs no build, so it runs first in `lint`, where it costs nothing.
  A connection targeting a built-in engine method (`queue_free`) has no C# declaration to find;
  list those in `.signalignore`.
  That list stays project-local on purpose -
  a dictionary of Godot's own methods would need re-syncing with every engine release
  to handle something that comes up once or twice per project.

- **`lint` checks signal subscriptions against the node lifecycle, not for `+=`/`-=` symmetry.**
  Plain symmetry would be noise: subscribing to a child node needs no unsubscribe,
  because the child is freed with its parent and the connection goes with it.
  Flagging those buries the findings that matter. Three things are reported instead.

  Subscribing in `_Ready` while unsubscribing in `_ExitTree` is the sharp one, and it looks correct.
  `_Ready` runs once per node; `_ExitTree` runs on every removal. Verified on Godot 4.7.1:

  ```
  add     -> _enter_tree, _ready
  remove  -> _exit_tree
  re-add  -> _enter_tree            (no _ready)
  ```

  What to do about it depends on the target, and the two cases are opposite,
  so the check reports them differently instead of prescribing one fix.

  **Target is an autoload.** The unsubscribe is required - the singleton outlives the node
  and would keep holding the handler - so the subscription is the half in the wrong place.
  `_EnterTree` runs on every entry and pairs with `_ExitTree`.

  **Target is anything else, typically a child node.** The unsubscribe is the redundant half,
  and it is what breaks things. A connection lives on the objects rather than on the tree, so it survives removal -
  measured: a parent removed and re-added still received its child timer's signal, with the connection reported alive.
  The child is freed with the parent anyway. So that `-=` runs on every removal,
  destroys a subscription that would have survived, and `_Ready` never runs again to restore it.
  Deleting the line is usually the fix, and that is the line the check points at.

  `RequestReady()` is deliberately not part of this. It re-arms `_Ready` for the next entry and would silence the finding,
  but it re-runs the whole method - a re-initialisation decision that belongs to the author, not to a linter.

  The other two are a subscription to an autoload with no unsubscribe anywhere -
  the autoload outlives the node and keeps holding the handler, with autoload names read from `project.godot` -
  and a lambda or `Callable.From` handler, which has no reference to hand back to `-=` at all.

- **Meziantou is added alongside Roslynator, not instead of it.**
  Measured on a real project, the two reported 12 and 20 findings with _zero_ overlapping locations,
  and they differ in kind: Roslynator does micro-refactoring that `make fix` mostly applies by itself,
  Meziantou does correctness.
  Two of its rules are switched off, or it would undo decisions made elsewhere:
  `MA0047` is a third copy of the namespace demand after `CA1050` and `RCS1110`,
  and `MA0038` is deprecated in favour of `CA1822` - on the same project they flagged the same five members.
  What is left is `MA0076` and `MA0048`, seven findings, and both are worth having.

- **`CA1711` is off, because Godot requires what it forbids.**
  It objects to type names ending in `EventHandler`; Godot refuses to compile a `[Signal]` delegate without that suffix
  (`error GD0201`). The rule fires on the only spelling the engine accepts.

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

- **Roslynator's category is promoted to `warning`.**
  Every RCS rule ships at `note`, below the threshold `lint` enforces,
  so without the promotion `Roslynator.Analyzers` never fails the gate and only ever acts through `fix`.
  Measured on a small real Godot project before switching it on: 8 findings at `note`, 7 at `warning`,
  4 surviving `make fix` either way - the counts barely move,
  because `fix` already applies RCS fixes at `--severity info`.
  Promotion changes what _blocks_, not what gets cleaned up.
  All 4 survivors were `RCS1163` (unused parameter), which has no Fix All, and all 4 were a real bug.

- **`fix` defaults to `--severity info`; `lint` still gates at warning.**
  Every Roslynator rule ships at `note` severity and `dotnet format` fixes `warn` and above by default,
  so at the stock severity the RCS rules are never applied and `Roslynator.Analyzers` has no observable effect at all.
  The asymmetry is deliberate: `fix` cleans up more than the gate demands,
  so `lint` stays a stable contract while `fix` keeps the codebase ahead of it.
  Raise the floor with `make fix SEVERITY=warn` if you'd rather the two match.

- **The SARIF report comes from the compiler, not a second tool.**
  `Roslynator.Analyzers` already runs inside the build as an analyzer package,
  so `roslynator analyze` would be a second, slower pass over the same code -
  and it cannot write SARIF anyway (`--output-format` accepts only `xml` and `gitlab`).
  `-p:ErrorLog=lint.sarif,version=2.1` makes the normal build emit SARIF 2.1 covering every analyzer
  the gate runs, which keeps the report and the gate structurally incapable of disagreeing.
  The Roslynator CLI is still installed, but only for `dead-code`,
  which does something the analyzer package genuinely cannot.

- **`.editorconfig` ships most suppressions commented out.**
  `CA1707` (underscored engine callbacks) and `RCS1163`/`IDE0060` (parameters a signal signature forces you to accept)
  are pre-written for when you raise `AnalysisMode` to `All`.
  `CA1051` (`[Export]` fields) fires at `Recommended` but only on public fields,
  so making your scripts `internal` clears it without a suppression, and is the fix worth taking -
  on a real project that single change removed 14 findings.

- **`CA1050` is on to catch public types; `RCS1110` and `MA0047` are off.**
  Despite the shared title, they are not the same rule.
  `CA1050` fires on externally visible types only, and Godot code has no namespaces at all,
  so its firing set is exactly the set of public types - the thing actually worth knowing about.
  Its message is the wrong instruction here: **the fix is `internal`, not a namespace.**
  `RCS1110` and `MA0047` fire at any visibility, so `internal` does not clear them
  and the only escape is a real namespace; both are off.
  `CA1515`, the rule that says the right words ("types can be made internal"), is unavailable -
  it applies only to assemblies that are applications, and Godot builds the game as a library
  so the engine can load it dynamically.
  Do not expect `CA1051` to cover this: it is about visible _fields_,
  so a public class exposing public _properties_ passes it cleanly.

- **The bundle ships no `.gitignore`, and merges instead of copying.**
  Godot writes `.gitignore` itself when a project is created with Git version-control metadata:

  ```gitignore
  # Godot 4+ specific ignores
  .godot/
  /android/
  ```

  Copying over that file would un-ignore `.godot/`, so the next commit sweeps in the whole import cache.
  `dotnet new` can only skip or overwrite - it refuses outright when the file exists,
  and `--force` destroys it - so the bundle ships no `.gitignore` at all
  and appends through the `ignore` target instead.
  A target rather than a file also means both install routes get identical behaviour,
  and `install.sh` just delegates to it, so the merge logic exists in exactly one place.
  Only one entry is needed: `lint.sarif`.
  There is no `bin/` or `obj/` at the project root to ignore,
  because `Godot.NET.Sdk` redirects both under `.godot/mono/temp/`.

- **`addons/` is excluded from both formatting and analysis.**
  CSharpier skips `.godot/`, `obj/` and `bin/` on its own, but walks into `addons/`,
  where Godot installs third-party plugins whose C# sources compile as part of your project.
  Without `.csharpierignore` the gate fails on other people's code,
  and "fixing" it means carrying a permanent diff that every plugin update conflicts with.
  The analyzers need the same treatment, via `generated_code = true` in `.editorconfig` -
  `dotnet_analyzer_diagnostic.severity` does not work for this,
  because the per-rule entries the SDK emits for `AnalysisMode` outrank bulk configuration.

- **`lint` builds every configuration, not just `Debug`.**
  Godot generates `Debug`, `ExportDebug` and `ExportRelease`, and they do not compile the same source.
  A null dereference behind `#if !DEBUG` is invisible to a default `dotnet build`
  and reaches players in the only configuration that ships.
  `ExportDebug` is skipped because it defines the same symbols as `Debug`.

- **Godot-authored files are excluded from whitespace rules.**
  `*.tscn`, `*.tres`, `*.godot` and `*.import` get `trim_trailing_whitespace = false` and `insert_final_newline = false`,
  because Godot owns their exact bytes and editing them produces spurious diffs.

## Scripts from the Godot editor start red

This one is deliberate, so it is worth knowing before it happens rather than after.
Godot's "new C# script" template emits a public class with no namespace,
so a brand-new script trips `CA1050` before it contains a line of your code:

```csharp
public partial class Player : Node { }     // CA1050
```

**Ignore what the message says.** It reads _"Declare types in namespaces"_, and that is the wrong
instruction in a Godot project - the fix is `internal`:

```csharp
internal sealed partial class Player : Node { }
```

The rule is kept because it is the only one left that notices a public type,
and on a project that already follows the convention it is near-silent:
seven internal types and one public produced exactly one finding, on the class that had just been widened by hand.
`CA1515` would say the right words, but it only applies to applications,
and Godot builds the game as a library.
`RCS1110` and `MA0047` are off, because they demand namespaces at any visibility.

If a type genuinely has to stay public, suppress it in place with the reason recorded -
the same three mechanisms as below work, with `CA1050` in place of `CA1051`.

Adding an exported field brings in a second rule:

```csharp
public partial class Player : Node
{
    [Export]
    public float Speed = 1f;      // CA1051
}
```

`CA1051` fires on that combination. It needs both halves to be externally visible, which makes it precise:

| class      | field      | fires    |
| ---------- | ---------- | -------- |
| `public`   | `public`   | `CA1051` |
| `public`   | `internal` | silent   |
| `internal` | `public`   | silent   |

So a freshly created empty script stays quiet, and the rule speaks up the moment you add an exported field -
which is the point at which the visibility question is worth asking.

**The fix is `internal`, on either half.** `[Export]` works identically on internal members:

```csharp
internal sealed partial class Player : Node
{
    [Export]
    internal float Speed = 1f;
}
```

That also makes `CA1852` reportable and, at `AnalysisMode=All`, `CA1812` - see
[the `internal` tip](#tip-internal-classes-private-members).

For a field that really is public API - tuned from another assembly, exposed to mods -
suppress it in place with the reason recorded:

```csharp
using System.Diagnostics.CodeAnalysis;

[SuppressMessage(
    "Design",
    "CA1051:Do not declare visible instance fields",
    Justification = "Tuned from another assembly at runtime."
)]
public float Speed = 1f;
```

`#pragma warning disable CA1051` around a region works too, and
`GlobalSuppressions.cs` with `[assembly: SuppressMessage(..., Scope = "member", Target = "~F:Player.Speed")]`
keeps the list in one place if you accumulate several -
Rider and Visual Studio generate that form through _Suppress → in Suppression File_.
All three were checked; there is no `// nolint`-style comment in C#, since Roslyn does not read comments.

Both rules key off _external visibility_, which is why `internal` clears them at the source.

## Tip: `internal` classes, `private` members

Not enforced by this bundle, but it multiplies its value.
The two halves do different jobs, and it is worth knowing which is which before churning code:

| Change                       | What it actually buys                                                                                |
| ---------------------------- | ---------------------------------------------------------------------------------------------------- |
| class `public` → `internal`  | silences `CA1050` and `CA1051`; makes `CA1852` (seal) reportable, and `CA1812` at `AnalysisMode=All` |
| member `public` → `private`  | makes unused-member analysis possible (`RCS1213`, `CS0414`, `RCS1169`)                               |
| member `public` → `internal` | **nothing** - measured, not assumed                                                                  |

The tempting theory is that `internal` lets the compiler see every call site, so uncalled _members_ become reportable.
It is true in principle and false in practice: no analyzer reports an uncalled `internal` member, at any `AnalysisMode`.
The visibility-sensitive rules that do exist are all type-level - `CA1852`, and `CA1812` at `All`.

Nor does it help `make dead-code`, the one thing that _can_ find unused public code:
its `--visibility` option filters which symbols get reported, it is not a capability gate,
so `public`, `internal` and `private` members are all found equally.
Marking members `internal` is fine as intent-documentation - it just is not worth a refactor,
because nothing rewards it.

Only the _type's_ visibility matters for `CA1050`/`CA1051`/`CA1852`,
and only the _member's_ `private`-ness matters for dead-code analysis.
An `internal` member is treated exactly like a `public` one there:
in an `internal sealed class`, an uncalled `public` method, an uncalled `internal` method and an uncalled `private` method
produce nothing, nothing, and three findings respectively.
So marking every member `internal` is churn without a payoff - mark the _class_ `internal` and leave members alone unless they can be `private`.

`CA1050` and `CA1051` both fire at `AnalysisMode=Recommended`, and both apply only to externally visible members.
Godot's own "new C# script" templates emit `public partial class X : Y` with no namespace,
so every freshly created script trips both until the class visibility changes.
Marking the class `internal` clears them at the source instead of suppressing them -
on a real project it removed 14 findings, and `[Export]` members keep working exactly as before.

`CA1051` is left on for exactly that reason: it is the gate's way of noticing a script that stayed public,
and it is meant to be silenced case by case rather than project-wide -
see [`[Export]` on a public script starts red](#export-on-a-public-script-starts-red).
`CA1050` is off, because what it asks for is a namespace, and that is not the Godot answer.

Everything can be `internal` in Godot except `public override` engine callbacks (`_Ready`, `_PhysicsProcess`, …) - C# forbids an override from narrowing visibility.
`[Export]` members, `[Signal]` delegates and node classes are all fine as `internal`.

One Godot-specific limit, which blunts the `private` half specifically:
private members of a `Node` subclass are _never_ reported as unused, even when nothing references them.
Godot's source generators emit a dispatch table naming every method,
and serialization code that both reads and writes every field.
That is what makes scene-wired signal handlers safe from `make fix` -
but it also means dead code inside node scripts stays invisible,
and even `readonly` suggestions never fire on their fields.
The tip pays off on plain classes; on node scripts, only the non-generated findings come through.

## Requirements

- .NET SDK 8.0+ (developed against 10.0)
- Godot 4.x with the Mono/.NET build
- `make`
- A generated C# project. Godot writes the `.csproj` and `.sln` only after the project
  contains at least one C# script _and_ you press Build (or Run) in the editor -
  opening the project does not do it. `fix` falls back to the `.csproj` if the solution
  is missing, but neither exists before that first build.

On macOS, if `make` fails with an `xcodebuild ... -find make` error, point `xcode-select` at the Command Line Tools:

```sh
sudo xcode-select --switch /Library/Developer/CommandLineTools
```

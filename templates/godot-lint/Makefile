.PHONY: restore lint format fix lint-sarif dead-code ignore clean

# Godot generates both <Name>.csproj and <Name>.sln at the project root, which
# makes `dotnet format` ambiguous, so it has to be told which one to use.
# Discovered rather than hardcoded so this file is drop-in for any project.
#
# .slnx is checked too - the newer solution format, which `dotnet new sln` now
# emits by default - and .csproj last, so a project whose solution has not been
# generated yet still works. Without those fallbacks this expands to nothing and
# `dotnet format` silently runs unqualified, which is the exact ambiguity the
# variable exists to remove. No emptiness guard is needed: reaching that state
# means no project file exists at all, and `restore` has already failed.
PROJECT := $(firstword $(wildcard *.sln) $(wildcard *.slnx) $(wildcard *.csproj))

# Analyzer rule set version, forwarded to MSBuild only when set.
#
# Empty by default on purpose: the permanent value belongs in
# Directory.Build.props, because the Godot editor builds the project too and
# never reads this Makefile - a pin that lives only here would make the editor
# and the gate disagree. Use this to try a level before committing to it, since
# -p: global properties override the props file:
#
#   make lint ANALYSIS_LEVEL=9.0
ANALYSIS_LEVEL ?=
ANALYSIS_ARG := $(if $(ANALYSIS_LEVEL),-p:AnalysisLevel=$(ANALYSIS_LEVEL))

# Severity floor for the `fix` pass. Allowed values: info, warn, error.
#
# `info` is the default because every Roslynator rule ships at `note` severity,
# and dotnet format's own default of `warn` would skip all of them - making
# Roslynator.Analyzers a no-op. Override for a narrower pass, e.g. to apply only
# what the gate would actually reject:
#
#   make fix SEVERITY=warn
SEVERITY ?= info

# Configurations the gate builds. Godot generates three - Debug, ExportDebug
# and ExportRelease - and they do not compile the same source: anything behind
# `#if !DEBUG` or `#if TOOLS` is invisible to the others.
#
# Debug alone would leave the code that actually ships to players unanalyzed,
# so ExportRelease is included. ExportDebug is omitted because it defines the
# same symbols as Debug and would only cost time. Narrow it if lint gets slow:
#
#   make lint LINT_CONFIGS=Debug
#
# These names come from the solution Godot generates, which declares Debug,
# ExportDebug and ExportRelease. A solution made some other way - `dotnet new
# sln` declares only Debug and Release - fails with a cryptic MSB4126 "solution
# configuration is invalid". Set this to whatever your solution actually has.
LINT_CONFIGS ?= Debug ExportRelease

# Restore pinned tools + NuGet packages. Run once after cloning.
restore:
	dotnet tool restore
	dotnet restore

# The golangci-lint equivalent: one command, fails on any finding.
lint: restore
	dotnet csharpier check .
	@for cfg in $(LINT_CONFIGS); do \
		echo "==> dotnet build -c $$cfg -warnaserror"; \
		dotnet build --no-incremental -warnaserror -c "$$cfg" $(ANALYSIS_ARG) || exit 1; \
	done

# Auto-fix everything that can be fixed automatically.
#
# Order matters: dotnet format applies code-style and analyzer fixes, then
# csharpier has the final say on layout. Running bare `dotnet format` here
# would include its whitespace pass, which fights csharpier over the same
# files, so the two formatting-capable passes are scoped explicitly.
#
# --severity is required, not cosmetic: see the SEVERITY definition above for
# why the default has to be `info`. Note that `lint` still only fails on
# warnings and above, so `fix` cleans up more than the gate demands - which is
# the right way round.
fix: restore
	dotnet format style $(PROJECT) --severity $(SEVERITY)
	dotnet format analyzers $(PROJECT) --severity $(SEVERITY)
	dotnet csharpier format .

# Formatting only.
format: restore
	dotnet csharpier format .

# Optional: emit a machine-readable report (closer to golangci-lint's report
# output) for CI annotations or code-scanning upload.
#
# This is the same build as `lint`, with the compiler's SARIF writer switched
# on, so it reports exactly what the gate reports - no second analysis pass and
# no extra tool. The %2C is an escaped comma: MSBuild splits property values on
# bare commas, and ErrorLog needs "path,version=2.1" to emit SARIF 2.1 rather
# than the legacy 1.0 format.
#
# No -warnaserror here: the point is to produce the report, not to fail.
lint-sarif: restore
	dotnet build --no-incremental -p:ErrorLog=lint.sarif%2Cversion=2.1 $(ANALYSIS_ARG)

# Report code nothing references, including public and internal members.
#
# This is the one job the analyzer package cannot do: Roslyn only reports unused
# *private* members, so anything public or internal is invisible to `lint` no
# matter how dead it is. Roslynator's CLI counts references instead, at any
# visibility.
#
# Deliberately not wired into `lint`, and never run with --remove, because in a
# Godot project it is wrong in both directions:
#
#   False positives - Roslyn cannot read scene files, so enum values picked in
#   the inspector, signal handlers wired in a .tscn, and exported resources all
#   look unreferenced. Deleting them breaks the game with no compile error.
#
#   False negatives - the source generators emit a dispatch table naming every
#   method and serialization code touching every field, and those count as
#   references, so genuinely dead members of a Node script are never reported.
#
# What is left is real signal on plain, non-Node classes: state machines, data
# types, helpers. Read the output, decide per item.
#
# --ignore-generated-code is not optional: without it the report is mostly
# Godot's own generated members (GetGodotMethodList, SignalName, and friends).
dead-code: restore
	dotnet roslynator find-symbol $(PROJECT) \
		--unused \
		--visibility public internal \
		--symbol-kind type member \
		--ignore-generated-code

# One-time: keep `lint.sarif` out of version control.
#
# Run once after installing the bundle. `install.sh` calls this for you; the
# `dotnet new` route cannot ship a .gitignore at all, because the template
# engine can only skip or overwrite a file - and overwriting the one Godot
# generates would un-ignore .godot/, sweeping the entire import cache into your
# next commit. Hence a target rather than a file.
#
# Appends, never replaces, and is idempotent, so it is safe to re-run and safe
# on a project that already has Godot's version-control metadata.
ignore:
	@if [ ! -e .gitignore ]; then \
		printf '# Godot 4+ specific ignores\n.godot/\n/android/\n\n# godot-csharp-lint\nlint.sarif\n' >.gitignore; \
		echo "  created  .gitignore"; \
	elif grep -qxF 'lint.sarif' .gitignore; then \
		echo "  ok       .gitignore (already ignores lint.sarif)"; \
	else \
		printf '\n# godot-csharp-lint\nlint.sarif\n' >>.gitignore; \
		echo "  merged   .gitignore (+lint.sarif)"; \
	fi

clean:
	dotnet clean

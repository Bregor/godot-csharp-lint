.PHONY: restore lint format fix lint-sarif clean

# Godot generates both <Name>.csproj and <Name>.sln at the project root, which
# makes `dotnet format` ambiguous, so it has to be told which one to use.
# Discovered rather than hardcoded so this file is drop-in for any project.
SLN := $(firstword $(wildcard *.sln))

# Severity floor for the `fix` pass. Allowed values: info, warn, error.
#
# `info` is the default because every Roslynator rule ships at `note` severity,
# and dotnet format's own default of `warn` would skip all of them - making
# Roslynator.Analyzers a no-op. Override for a narrower pass, e.g. to apply only
# what the gate would actually reject:
#
#   make fix SEVERITY=warn
SEVERITY ?= info

# Restore pinned tools + NuGet packages. Run once after cloning.
restore:
	dotnet tool restore
	dotnet restore

# The golangci-lint equivalent: one command, fails on any finding.
lint: restore
	dotnet csharpier check .
	dotnet build --no-incremental -warnaserror

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
	dotnet format style $(SLN) --severity $(SEVERITY)
	dotnet format analyzers $(SLN) --severity $(SEVERITY)
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
	dotnet build --no-incremental -p:ErrorLog=lint.sarif%2Cversion=2.1

clean:
	dotnet clean

#!/usr/bin/env sh
#
# Copy the Godot C# lint bundle into an existing Godot project.
# Zero-dependency fallback for the `dotnet new godot-lint` template.
#
#   ./install.sh /path/to/godot/project
#   ./install.sh /path/to/godot/project --force
#
# Existing files are skipped unless --force is given, so re-running is safe.

set -eu

TARGET="${1:-}"
FORCE="${2:-}"

if [ -z "$TARGET" ]; then
	echo "usage: $0 <path-to-godot-project> [--force]" >&2
	exit 2
fi

if [ ! -d "$TARGET" ]; then
	echo "error: '$TARGET' is not a directory" >&2
	exit 2
fi

SRC="$(cd "$(dirname "$0")/templates/godot-lint" && pwd)"

copy_one() {
	src="$SRC/$1"
	dst="$TARGET/$1"

	if [ -e "$dst" ] && [ "$FORCE" != "--force" ]; then
		echo "  skip     $1 (exists; pass --force to overwrite)"
		return
	fi

	mkdir -p "$(dirname "$dst")"
	cp "$src" "$dst"
	echo "  copied   $1"
}

echo "Installing Godot C# lint bundle into $TARGET"
copy_one "Makefile"
copy_one "Directory.Build.props"
copy_one ".editorconfig"
copy_one ".csharpierignore"
copy_one ".config/dotnet-tools.json"

# `[ -f "$TARGET"/*.sln ]` would abort with "too many arguments" when a
# project has more than one solution, so count matches instead of testing them.
if [ "$(find "$TARGET" -maxdepth 1 -name '*.sln' | wc -l)" -eq 0 ]; then
	echo
	echo "note: no .sln found in $TARGET. Open the project in Godot once to"
	echo "      generate it, or the 'fix' target will fail."
fi

echo
echo "Next:"
echo "  cd $TARGET"
echo "  make restore"
echo "  make lint"

#!/usr/bin/env sh
#
# Copy the Godot C# lint bundle into an existing Godot project.
# Zero-dependency fallback for the `dotnet new godot-lint` template.
#
#   ./install.sh /path/to/godot/project
#   ./install.sh /path/to/godot/project --force
#   ./install.sh --force /path/to/godot/project
#
# Existing files are skipped unless --force is given, so re-running is safe.

set -eu

usage() {
	cat >&2 <<'EOF'
usage: install.sh [-f|--force] <path-to-godot-project>

  -f, --force   Overwrite bundle files that already exist.
                .gitignore is always merged, never overwritten.
  -h, --help    Show this message.
EOF
}

# Hand-rolled rather than getopt(1): POSIX getopts handles short flags only, and
# the getopt(1) that ships with macOS is the BSD one, which has no --long-option
# support at all. A while/case loop is the portable way to accept both spellings
# in any order.
TARGET=""
FORCE=""

while [ $# -gt 0 ]; do
	case "$1" in
	-f | --force)
		FORCE="--force"
		;;
	-h | --help)
		usage
		exit 0
		;;
	--)
		# Everything after this is positional, so a path that begins with a
		# dash stays usable.
		shift
		break
		;;
	-*)
		echo "error: unknown option '$1'" >&2
		usage
		exit 2
		;;
	*)
		if [ -n "$TARGET" ]; then
			echo "error: unexpected argument '$1' (target already set to '$TARGET')" >&2
			exit 2
		fi
		TARGET="$1"
		;;
	esac
	shift
done

# Pick up a target that followed `--`.
if [ -z "$TARGET" ] && [ $# -gt 0 ]; then
	TARGET="$1"
fi

if [ -z "$TARGET" ]; then
	usage
	exit 2
fi

if [ ! -d "$TARGET" ]; then
	echo "error: '$TARGET' is not a directory" >&2
	exit 2
fi

# A Godot project is defined by project.godot; without it this is almost
# certainly the wrong directory, and the bundle would sit somewhere harmless but
# useless until someone noticed.
if [ ! -f "$TARGET/project.godot" ]; then
	echo "error: no project.godot in '$TARGET' - not a Godot project directory" >&2
	exit 2
fi

SRC="$(cd "$(dirname "$0")/templates/godot-lint" && pwd)"

# Set when .editorconfig was left in place, so the run can end with a warning
# instead of a single line lost among the copies. See the note where it is
# reported: a skipped .editorconfig leaves the bundle actively half-configured,
# which is worse than not installing it at all.
SKIPPED_EDITORCONFIG=""

copy_one() {
	src="$SRC/$1"
	dst="$TARGET/$1"

	if [ -e "$dst" ] && [ "$FORCE" != "--force" ]; then
		echo "  skip     $1 (exists; pass --force to overwrite)"
		if [ "$1" = ".editorconfig" ]; then
			SKIPPED_EDITORCONFIG="yes"
		fi
		return
	fi

	mkdir -p "$(dirname "$dst")"
	cp "$src" "$dst"
	echo "  copied   $1"
}

# `lint.sarif` is the only artifact this bundle adds that needs ignoring:
# Godot.NET.Sdk redirects bin/ and obj/ under .godot/mono/temp/, and Godot's own
# .gitignore already covers .godot/.
#
# Delegated to the Makefile just copied in, so the merge lives in exactly one
# place and template users get the same behaviour via `make ignore`. It appends
# rather than replacing - even under --force - because overwriting the
# .gitignore Godot generates would un-ignore the import cache.
merge_gitignore() {
	if command -v make >/dev/null 2>&1; then
		# --no-print-directory: without it make wraps the output in
		# "Entering directory"/"Leaving directory" lines that have nothing to do
		# with what was installed.
		make --no-print-directory -C "$TARGET" ignore
	else
		echo "  skip     .gitignore (no 'make' found; run 'make ignore' later)"
	fi
}

echo "Installing Godot C# lint bundle into $TARGET"
copy_one "Makefile"
copy_one "Directory.Build.props"
copy_one ".editorconfig"
copy_one ".csharpierignore"
copy_one ".config/dotnet-tools.json"
merge_gitignore

# `[ -f "$TARGET"/*.sln ]` would abort with "too many arguments" when a
# project has more than one solution, so count matches instead of testing them.
if [ "$(find "$TARGET" -maxdepth 1 \( -name '*.sln' -o -name '*.slnx' \) | wc -l)" -eq 0 ]; then
	echo
	echo "note: no solution found in $TARGET. Godot writes the .csproj and .sln"
	echo "      only once the project has a C# script and you press Build (or"
	echo "      Run) in the editor - opening the project is not enough."
	echo "      Until then 'fix' falls back to the .csproj if one exists."
fi

# A skipped .editorconfig is not a partial install, it is a broken one:
# Directory.Build.props still lands and still sets <Nullable>enable</Nullable>,
# but the CS8618 suppression that makes that usable lives in .editorconfig - as
# do the Roslynator promotion, the addons/ exclusions and the protection for
# Godot-authored files. So the gate ends up stricter in the one place Godot
# needs it looser. Worth more than one line among the copies.
if [ -n "$SKIPPED_EDITORCONFIG" ]; then
	echo
	echo "WARNING: .editorconfig already existed and was left alone, but the bundle"
	echo "         does not work without it. Directory.Build.props still sets"
	echo "         <Nullable>enable</Nullable>, while the CS8618 suppression that makes"
	echo "         it workable in Godot lives in .editorconfig - along with the"
	echo "         Roslynator severities, the addons/ exclusions, and the rules that"
	echo "         stop formatters touching .tscn/.tres/.uid files."
	echo
	echo "         Merge $SRC/.editorconfig into $TARGET/.editorconfig by hand, or"
	echo "         overwrite it:"
	echo "           $0 --force $TARGET"
fi

echo
echo "Next:"
echo "  cd $TARGET"
echo "  make restore"
echo "  make lint"

#!/usr/bin/env sh
#
# Check that C# signal subscriptions are unsubscribed in a matching lifecycle
# method.
#
#   ./check-subscriptions.sh [path]     # defaults to the current directory
#
# Three things are reported, all verified against Godot 4.7.1:
#
# 1. Subscribed in _Ready, unsubscribed in _ExitTree.
#
#    _Ready runs once per node, _ExitTree runs on every removal from the tree.
#    So remove a node and add it back and the pair does not balance: _ExitTree
#    unsubscribed, _Ready never runs again, the handler is gone for good. The
#    signal keeps firing into nothing, with no error. Confirmed on the engine:
#
#      add    -> _enter_tree, _ready
#      remove -> _exit_tree
#      re-add -> _enter_tree            (no _ready)
#
#    Subscribe in _EnterTree when you unsubscribe in _ExitTree.
#
# 2. Subscribed to an autoload with no unsubscribe anywhere in the file.
#
#    An autoload outlives every scene, so it keeps holding the handler after the
#    node is gone. Subscriptions to a child node are NOT reported: the child is
#    freed with its parent and the connection goes with it, so the unsubscribe
#    is optional there. Autoload names come from project.godot, so no dictionary
#    of engine internals has to be kept in sync.
#
# 3. Subscribed with a lambda or Callable.From.
#
#    There is no reference to hand back to -=, so the subscription cannot be
#    undone at all. Fine for something that lives as long as the emitter,
#    a leak otherwise.
#
# Not covered: the string-based Connect("signal", Callable) / Disconnect API,
# and subscriptions in ordinary methods such as a Start()/Stop() pair, where
# balancing is the caller's business rather than the lifecycle's.

set -eu

ROOT="${1:-.}"

if [ ! -d "$ROOT" ]; then
	echo "error: '$ROOT' is not a directory" >&2
	exit 2
fi

EXCLUDES="--exclude-dir=.godot --exclude-dir=.git --exclude-dir=bin --exclude-dir=obj --exclude-dir=addons"

sources=$(find "$ROOT" -name '*.cs' -not -path '*/.godot/*' -not -path '*/.git/*' -not -path '*/addons/*' 2>/dev/null || true)

if [ -z "$sources" ]; then
	echo "no .cs files under $ROOT - nothing to check"
	exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# Autoload names, e.g. SignalBus="*uid://abc" -> SignalBus. These are the
# singletons that outlive the nodes subscribing to them.
sed -n '/^\[autoload\]/,/^\[/p' "$ROOT/project.godot" 2>/dev/null |
	sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=.*/\1/p' |
	sort -u >"$WORK/autoloads" || true

# Every += / -= on an event, tagged with the method it sits in.
#
# The enclosing method is the nearest preceding declaration line rather than
# something brace-aware. In a Godot script that is exact, and it degrades to a
# wrong label rather than a wrong verdict: the rules below only compare labels
# for pairs found in the same file.
for f in $sources; do
	awk -v file="$f" '
		/^[[:space:]]*(public|private|internal|protected)[^;]*\(/ {
			if (match($0, /[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/)) {
				m = substr($0, RSTART, RLENGTH)
				sub(/[[:space:]]*\($/, "", m)
				sub(/[[:space:]]*\(/, "", m)
				method = m
			}
			# No next: a one-line body puts the subscription on this same line.
		}
		/[-+]=/ {
			line = $0
			if (match(line, /[A-Za-z_][A-Za-z0-9_.]*[[:space:]]*\+=/)) {
				op = "+"
			} else if (match(line, /[A-Za-z_][A-Za-z0-9_.]*[[:space:]]*-=/)) {
				op = "-"
			} else {
				next
			}
			left = substr(line, RSTART, RLENGTH)
			sub(/[[:space:]]*[-+]=$/, "", left)

			rhs = substr(line, RSTART + RLENGTH)
			sub(/^[[:space:]]*/, "", rhs)
			# Stop at the statement end, so a one-line method body does not drag
			# its closing brace into the handler name.
			sub(/[;{}].*$/, "", rhs)
			sub(/[[:space:]]*$/, "", rhs)

			# Only member accesses are subscriptions; `i += 1` is not.
			if (left !~ /\./) next

			printf "%s|%d|%s|%s|%s|%s\n", file, NR, method, op, left, rhs
		}
	' "$f"
done >"$WORK/events"

problems=0

report() {
	if [ "$problems" -eq 0 ]; then
		echo "Signal subscription problems:"
		echo
	fi
	problems=$((problems + 1))
	printf '%s\n' "$1"
}

# --- 1. _Ready subscribes, _ExitTree unsubscribes -------------------------
while IFS='|' read -r file line method op left rhs; do
	[ "$op" = "+" ] || continue
	[ "$method" = "_Ready" ] || continue

	if grep -q "^${file}|[0-9]*|_ExitTree|-|${left}|${rhs}$" "$WORK/events"; then
		unsub=$(grep "^${file}|[0-9]*|_ExitTree|-|${left}|${rhs}$" "$WORK/events" | cut -d'|' -f2 | head -1)
		report "  ${file#"$ROOT"/}:${line}: '${left} += ${rhs}' in _Ready, but '-=' is in _ExitTree (line ${unsub}).
    _Ready runs once, _ExitTree runs on every removal - after a remove and
    re-add the subscription is gone for good. Subscribe in _EnterTree instead."
		echo
	fi
done <"$WORK/events"

# --- 2. autoload subscription never undone --------------------------------
if [ -s "$WORK/autoloads" ]; then
	while IFS='|' read -r file line method op left rhs; do
		[ "$op" = "+" ] || continue

		root=${left%%.*}
		grep -qx "$root" "$WORK/autoloads" || continue

		if ! grep -q "^${file}|[0-9]*|[A-Za-z_]*|-|${left}|${rhs}$" "$WORK/events"; then
			report "  ${file#"$ROOT"/}:${line}: '${left} += ${rhs}' subscribes to autoload '${root}', never unsubscribed.
    The autoload outlives this node, so it keeps holding the handler."
			echo
		fi
	done <"$WORK/events"
fi

# --- 3. handlers that cannot be unsubscribed ------------------------------
while IFS='|' read -r file line method op left rhs; do
	[ "$op" = "+" ] || continue
	case "$rhs" in
	*"=>"* | *"Callable.From"* | *"delegate"*) ;;
	*) continue ;;
	esac

	report "  ${file#"$ROOT"/}:${line}: '${left} +=' takes a lambda, so nothing can be passed to '-='.
    Store it in a field if this has to be undone."
	echo
done <"$WORK/events"

total=$(grep -c '|+|' "$WORK/events" 2>/dev/null || echo 0)

if [ "$problems" -gt 0 ]; then
	echo "$total subscription(s) checked - $problems problem(s)."
	exit 1
fi

echo "$total subscription(s) checked - all balanced."

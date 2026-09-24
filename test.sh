#!/bin/sh
# Run the suite with every home, store, and temp path in a throwaway
# directory, so a test that forgets its own scratch env still cannot reach
# real logins.
set -eu

cd "$(dirname "$0")"

scratch=$(mktemp -d /private/tmp/kiba-test-XXXXXX)
clean() { rm -rf "$scratch"; }
trap clean EXIT
for sig in HUP INT TERM; do
    trap "clean; trap - EXIT $sig; kill -s $sig \$\$" "$sig"
done

export HOME="$scratch/home"
export CLAUDE_CONFIG_DIR="$scratch/claude"
export CODEX_HOME="$scratch/codex"
# The inherited TMPDIR may not exist, and swiftc fails without one.
export TMPDIR="$scratch/tmp"
mkdir "$HOME" "$TMPDIR"

swift test "$@"

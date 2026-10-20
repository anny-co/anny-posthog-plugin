#!/usr/bin/env bash
#
# Installs the plugin into a throwaway Codex home, the way a user would, and
# checks that Codex actually loads it: installed and enabled, its MCP server on
# our endpoint, every skill on disk.
#
# Codex is stricter about the manifests than the Claude app -- it refuses a
# plugin whose plugin.json name differs from its marketplace entry -- so a tree
# that passes apply-patches.sh can still be one Codex will not install. The
# mirror workflow runs this on every sync, the check workflow on every push.
#
#   .anny/check-codex.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=config.env
source .anny/config.env

fail() { echo "check-codex: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"
command -v npx >/dev/null || fail "npx required"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/home" "$TMP/tree"
codex() { CODEX_HOME="$TMP/home" npx --yes "@openai/codex@${CODEX_VERSION}" "$@"; }

# The marketplace's plugin source is this repo on GitHub, which would install
# what is already published rather than this tree. Point it at a git snapshot
# of the working tree instead -- uncommitted, as a sync leaves it -- so Codex
# clones exactly what would ship.
find . -mindepth 1 -maxdepth 1 ! -name .git -exec cp -a {} "$TMP/tree/" \;
jq --arg u "file://$TMP/tree" '.plugins |= map(.source.url = $u)' \
    "$TMP/tree/.agents/plugins/marketplace.json" > "$TMP/marketplace.json"
mv "$TMP/marketplace.json" "$TMP/tree/.agents/plugins/marketplace.json"
git -C "$TMP/tree" init -q
git -C "$TMP/tree" add -A
git -C "$TMP/tree" -c user.name=check-codex -c user.email=check-codex@localhost commit -qm snapshot

ID="${PLUGIN_NAME}@${MARKETPLACE_NAME}"
codex plugin marketplace add "$TMP/tree" >/dev/null || fail "Codex rejected the marketplace"
codex plugin add "$ID" >/dev/null || fail "Codex refused to install $ID (its reason is above)"

codex plugin list --json | jq -e --arg id "$ID" 'any(.installed[]; .pluginId == $id and .enabled)' >/dev/null \
    || fail "$ID is not installed and enabled"

MCP=$(codex mcp list --json)
jq -e --arg u "$MCP_URL" 'any(.[]; .enabled and .transport.url == $u)' <<<"$MCP" >/dev/null \
    || fail "Codex sees no enabled MCP server on ${MCP_URL}: $MCP"

WANT=$(find skills -name SKILL.md | wc -l | tr -d ' ')
GOT=$(find "$TMP/home/plugins/cache/$MARKETPLACE_NAME/$PLUGIN_NAME" -path '*/skills/*' -name SKILL.md | wc -l | tr -d ' ')
[ "$WANT" -gt 0 ] && [ "$GOT" = "$WANT" ] || fail "installed plugin has $GOT skills, the tree has $WANT"

echo "check-codex: ok -- $ID installs in Codex ${CODEX_VERSION}, MCP ${MCP_URL}, ${GOT} skills"

#!/usr/bin/env bash
#
# Turns a pristine upstream checkout into the anny mirror.
#
# Every patch is anchored: the anchors are asserted before anything is
# rewritten, so an upstream restructure fails the sync loudly instead of
# quietly shipping a plugin that still points at PostHog Cloud. Idempotent --
# running it twice changes nothing.
#
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=config.env
source .anny/config.env

fail() { echo "apply-patches: $*" >&2; exit 1; }

# jq that keeps the anchor honest: the filter must match something that
# already exists, otherwise we are inventing structure rather than patching it.
assert() {
    jq -e "$2" "$1" >/dev/null 2>&1 || fail "anchor gone in $1 -- upstream restructured: $2"
}
jqi() {
    local f=$1; shift
    jq "$@" "$f" > "$f.tmp" || fail "jq failed on $f"
    mv "$f.tmp" "$f"
}
# Portable in-place sed over a file list on stdin (BSD and GNU both take -i.bak).
sed_files() {
    local expr=$1
    while IFS= read -r f; do
        sed -i.bak -E "$expr" "$f" && rm -f "$f.bak"
    done
}

# --- anchors -----------------------------------------------------------------
for f in .mcp.json mcp.json .claude-plugin/plugin.json \
         .claude-plugin/marketplace.json .agents/plugins/marketplace.json \
         commands/llma-cc-setup.md commands/llma-cc-setup.toml; do
    [ -f "$f" ] || fail "missing $f"
done
# The rewrites below grep these directories with stderr silenced; a directory
# upstream moved would make grep exit 2 and kill the script without a word.
for d in skills commands agents hooks telemetry/posthog_llma telemetry/hooks; do
    [ -d "$d" ] || fail "missing $d/ -- upstream restructured"
done
assert .mcp.json                     '.mcpServers.posthog.url'
assert mcp.json                      '.mcpServers.posthog.url'
assert .claude-plugin/plugin.json    '.name == "posthog"'
assert .claude-plugin/marketplace.json '.plugins[0].source == "./"'
assert .agents/plugins/marketplace.json '.plugins[0].source.url'

# --- 1. the MCP endpoint -----------------------------------------------------
# The entire reason this mirror exists. A blanket rewrite (not just the two
# JSONs) so a new file upstream that hardcodes the hosted endpoint gets caught
# too; the assertion at the bottom proves none was missed.
grep -rlF 'https://mcp.posthog.com/mcp' . \
    --exclude-dir=.git --exclude-dir=.anny --exclude-dir=node_modules 2>/dev/null \
    | sed_files "s#https://mcp\.posthog\.com/mcp#${MCP_URL}#g"

# --- 2. identity -------------------------------------------------------------
# Renamed so it can live side by side with the official plugin: someone who
# also has `posthog@claude-plugins-official` installed gets both, pointed at
# two different instances, instead of a name collision.
jqi .claude-plugin/plugin.json \
    --arg n "$PLUGIN_NAME" --arg r "$REPO_URL" --arg p "$POSTHOG_URL" '
    .name = $n
    | .description = "PostHog on \($p) (anny self-hosted) -- analytics, feature flags, experiments, error tracking. Mirror of PostHog/ai-plugin."
    | .repository = $r
    | .homepage = $r'

jqi .claude-plugin/marketplace.json \
    --arg m "$MARKETPLACE_NAME" --arg n "$PLUGIN_NAME" --arg r "$REPO_URL" --arg p "$POSTHOG_URL" '
    .name = $m
    | .owner = { name: "anny", url: "https://anny.co" }
    | .description = "anny plugins for Claude. PostHog wired to \($p)."
    | .plugins |= map(
        .name = $n
        | .displayName = "PostHog (anny)"
        | .description = "PostHog on \($p) (anny self-hosted) -- analytics, feature flags, experiments, error tracking."
        | .repository = $r
        | .homepage = $r
        | .author = { name: "anny", url: "https://anny.co" })'

# The manifest the Claude app reads when a marketplace is added from a repo.
# Upstream points it back at PostHog/ai-plugin -- left alone, the app would
# install the OFFICIAL plugin (pointed at PostHog Cloud) from our marketplace.
jqi .agents/plugins/marketplace.json \
    --arg m "$MARKETPLACE_NAME" --arg n "$PLUGIN_NAME" --arg r "${REPO_URL}.git" '
    .name = $m
    | .interface.displayName = "PostHog (anny)"
    | .plugins |= map(.name = $n | .source.url = $r)'

# --- 3. deep links in the skills --------------------------------------------
# ~250 "open this in PostHog" links across the skills point at the hosted app.
# Left alone every one of them sends a reader to an instance they have no
# account on.
grep -rlE 'https://(us|eu|app)\.posthog\.com' skills commands agents 2>/dev/null \
    | sed_files "s#https://(us|eu|app)\.posthog\.com#${POSTHOG_URL}#g"

# --- 4. ingestion host -------------------------------------------------------
# Every place that sends events -- the LLMA session hook, its setup command,
# and the ~700 SDK snippets the instrument-* skills paste into an app -- names
# PostHog Cloud. We have exactly one ingest host, so all of them go there.
#
# The LLMA setup command first: it offers a US/EU choice and calls US the
# default. With one host there is no choice to offer, so drop that wording
# before the blanket rewrite below turns it into "use p.anny.cloud for EU".
printf '%s\n' commands/llma-cc-setup.md commands/llma-cc-setup.toml | sed_files "
    s#\\(default: \`https://us\\.i\\.posthog\\.com\`, use \`https://eu\\.i\\.posthog\\.com\` for EU\\)#(default: \`${POSTHOG_INGEST_URL}\`)#
    s#[[:space:]]*\\# for EU, omit for US##
    s#defaults to US#defaults to ${POSTHOG_INGEST_URL}#
    s#Help them choose US or EU hosting#Set \`POSTHOG_HOST\` to \`${POSTHOG_INGEST_URL}\`#"

# us-assets.i.posthog.com is the static-asset half of the reverse-proxy
# recipes; self-hosted serves both halves from the ingest host.
grep -rlE 'https://(us|eu)(-assets)?\.i\.posthog\.com' telemetry hooks skills commands agents 2>/dev/null \
    | sed_files "s#https://(us|eu)(-assets)?\.i\.posthog\.com#${POSTHOG_INGEST_URL}#g"

# The rewrite leaves the region prose behind: "usually X or X", "use X for EU
# region", an instruction to ask the user whether they are on US or EU Cloud.
# With one host that is noise at best, and an agent following it asks a
# question that has no answer. Collapse it to the one host. The SDK-default
# claims are the dangerous part -- "host is optional" was true for PostHog
# Cloud, but the SDKs' own default still IS PostHog Cloud, so leaving the host
# out ships the app's events there.
H_RE=$(printf '%s' "$POSTHOG_INGEST_URL" | sed 's/[.]/\\./g')
REGION_PROSE=$(sed -e "s#@H@#${H_RE}#g" -e "s#@URL@#${POSTHOG_INGEST_URL}#g" <<'SED'
s#`US` maps to `@H@`, `EU` maps to `@H@`\. If the region is not available from the MCP response or from existing project configuration, ask the user: "Are you on PostHog US Cloud or EU Cloud\?" Do not assume US Cloud\.#use `@URL@`.#g
s#(['`])@H@(['`]) (by default )?or (['`])@H@(['`])#\1@URL@\2#g
s#`@H@([^`]*)` \(US\) or `@H@[^`]*` \(EU\), matching the region determined above#`@URL@\1`#g
s# for US-based projects and `@H@` for EU-based projects##g
s#\. Set to `@H@` for EU Cloud##g
s#[[:space:]]*// Optional: defaults to @H@\. Use @H@ for EU region##g
s#If the host is not specified, the default host `@H@` is used\.#Always set the host to `@URL@` -- the SDK's own default is PostHog Cloud.#g
s#Host is optional if you use `@H@`\.#Always set it -- the SDK's own default is PostHog Cloud.#g
s#\*\*Default:\*\* `@H@`#**Default:** PostHog Cloud -- always set it#g
s#For EU Cloud, set the host explicitly:#Set the host explicitly -- the chart defaults to PostHog Cloud:#g
SED
)
grep -rlF "$POSTHOG_INGEST_URL" skills commands agents 2>/dev/null | sed_files "$REGION_PROSE"

# --- assertions --------------------------------------------------------------
[ "$(jq -r '.mcpServers.posthog.url' .mcp.json)" = "$MCP_URL" ] || fail ".mcp.json url not rewritten"
[ "$(jq -r '.mcpServers.posthog.url' mcp.json)" = "$MCP_URL" ] || fail "mcp.json url not rewritten"
[ "$(jq -r '.name' .claude-plugin/plugin.json)" = "$PLUGIN_NAME" ] || fail "plugin not renamed"
[ "$(jq -r '.plugins[0].source.url' .agents/plugins/marketplace.json)" = "${REPO_URL}.git" ] \
    || fail "app marketplace still points upstream"
CLOUD_HOSTS='https://((us|eu)(-assets)?\.i|us|eu|app)\.posthog\.com'
if grep -rqE "$CLOUD_HOSTS" . --exclude-dir=.git --exclude-dir=.anny --exclude=README.md 2>/dev/null; then
    echo "apply-patches: leftover PostHog Cloud hosts:" >&2
    grep -rnE "$CLOUD_HOSTS" . --exclude-dir=.git --exclude-dir=.anny --exclude=README.md >&2
    exit 1
fi
if grep -qE 'for EU|defaults to US|US or EU' commands/llma-cc-setup.md commands/llma-cc-setup.toml; then
    echo "apply-patches: LLMA setup docs still offer a US/EU choice:" >&2
    grep -nE 'for EU|defaults to US|US or EU' commands/llma-cc-setup.md commands/llma-cc-setup.toml >&2
    exit 1
fi
if grep -rqF 'mcp.posthog.com' . --exclude-dir=.git --exclude-dir=.anny --exclude='*.md' 2>/dev/null; then
    echo "apply-patches: leftover references to the hosted MCP endpoint:" >&2
    grep -rlF 'mcp.posthog.com' . --exclude-dir=.git --exclude-dir=.anny --exclude='*.md' >&2
    exit 1
fi

# --- 5. our own files --------------------------------------------------------
# Upstream's CI has no business running in a mirror (it releases to PostHog's
# marketplace and syncs skills from their monorepo). Drop it, then lay our
# workflow back down -- .anny/ is the canonical copy, this is just the copy
# GitHub actually reads.
rm -rf .github
mkdir -p .github/workflows
cp .anny/workflows/mirror.yml .github/workflows/mirror.yml

# Upstream's README tells the reader to install `posthog@posthog` from
# PostHog. Keep it for reference, lead with ours.
[ -f README.md ] && mv README.md UPSTREAM_README.md
cp .anny/README.md README.md

echo "apply-patches: ok -- MCP ${MCP_URL}, auth server ${POSTHOG_URL}"

#!/usr/bin/env bash
#
# End-to-end check of the two Octopus Buildkite plugins on a real agent.
# Simulates what the Buildkite agent does: sets the plugin's configuration
# env vars, sources the environment hook, then runs the command hook.
#
set -euo pipefail

OCTOPUS_CLI_VERSION="2.21.4"

echo "--- :package: Install the octopus CLI ${OCTOPUS_CLI_VERSION}"
curl -sSfL -o /tmp/octopus.tar.gz \
  "https://github.com/OctopusDeploy/cli/releases/download/v${OCTOPUS_CLI_VERSION}/octopus_${OCTOPUS_CLI_VERSION}_linux_amd64.tar.gz"
mkdir -p /tmp/octopus-cli
tar -xzf /tmp/octopus.tar.gz -C /tmp/octopus-cli
export PATH="/tmp/octopus-cli:$PATH"
octopus version

echo "--- :mag: What JSON tooling does this agent actually have?"
for c in jq python3 curl; do
  printf '%-8s %s\n' "$c" "$(command -v "$c" || echo MISSING)"
done

echo "--- :key: octopus-login plugin: environment hook"
export BUILDKITE_PLUGIN_OCTOPUS_LOGIN_SERVER="https://md.octopus.app"
export BUILDKITE_PLUGIN_OCTOPUS_LOGIN_SERVICE_ACCOUNT_ID="d5de4670-4678-4c08-9479-09555cd6ccbb"
export BUILDKITE_PLUGIN_OCTOPUS_LOGIN_SPACE="OIDC With Claude"

# The agent sources the environment hook into the job shell.
source .buildkite/plugins/octopus-login/hooks/environment

echo "Exported for later steps:"
echo "  OCTOPUS_URL=${OCTOPUS_URL:-<unset>}"
echo "  OCTOPUS_SPACE=${OCTOPUS_SPACE:-<unset>}"
echo "  OCTOPUS_ACCESS_TOKEN length=${#OCTOPUS_ACCESS_TOKEN}"
echo "  OCTOPUS_API_KEY=${OCTOPUS_API_KEY:-<unset, as it should be>}"

echo "--- :rocket: create-release plugin: command hook (no credentials passed in)"
export BUILDKITE_PLUGIN_CREATE_RELEASE_PROJECT="OIDC Demo"
export BUILDKITE_PLUGIN_CREATE_RELEASE_RELEASE_NUMBER="3.0.${BUILDKITE_BUILD_NUMBER}"
export BUILDKITE_PLUGIN_CREATE_RELEASE_OUTPUT_FORMAT="basic"

# invoked via bash: the gh contents API uploaded these without the exec bit.
# In the real repos hooks/command is committed 100755.
bash .buildkite/plugins/create-release/hooks/command

echo "--- :test_tube: Negative check: a removed option must be rejected, not ignored"
export BUILDKITE_PLUGIN_CREATE_RELEASE_WHAT_IF="true"
if bash .buildkite/plugins/create-release/hooks/command; then
  echo "FAIL: what_if was accepted; it should have been rejected"
  exit 1
fi
echo "Correctly rejected."
unset BUILDKITE_PLUGIN_CREATE_RELEASE_WHAT_IF

echo "--- :white_check_mark: Both plugins work on a real agent with no Octopus API key"

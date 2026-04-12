#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox
# This script:
# 1. Runs openclaw onboard --non-interactive to configure from env vars
# 2. Patches config for features onboard doesn't cover (channels, gateway auth)
# 3. Starts the gateway
#
# NOTE: Persistence (backup/restore) is handled by the Sandbox SDK at the
# Worker level, not inside the container. The Worker calls createBackup()
# and restoreBackup() which use squashfs snapshots stored in R2.
# No rclone or R2 credentials are needed inside the container.

set -e

if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
WORKSPACE_DIR="/root/clawd"
SKILLS_DIR="/root/clawd/skills"

echo "Config directory: $CONFIG_DIR"

mkdir -p "$CONFIG_DIR"

# ============================================================
# ONBOARD (only if no config exists yet)
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, running openclaw onboard..."

    # Determine auth choice — openclaw onboard reads the actual key values
    # from environment variables (ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.)
    # so we only pass --auth-choice, never the key itself, to avoid
    # exposing secrets in process arguments visible via ps/proc.
    AUTH_ARGS=""
    if [ -n "$CLOUDFLARE_AI_GATEWAY_API_KEY" ] && [ -n "$CF_AI_GATEWAY_ACCOUNT_ID" ] && [ -n "$CF_AI_GATEWAY_GATEWAY_ID" ]; then
        AUTH_ARGS="--auth-choice cloudflare-ai-gateway-api-key --cloudflare-ai-gateway-account-id $CF_AI_GATEWAY_ACCOUNT_ID --cloudflare-ai-gateway-gateway-id $CF_AI_GATEWAY_GATEWAY_ID"
    elif [ -n "$ANTHROPIC_API_KEY" ]; then
        AUTH_ARGS="--auth-choice apiKey"
    elif [ -n "$OPENAI_API_KEY" ]; then
        AUTH_ARGS="--auth-choice openai-api-key"
    fi

    openclaw onboard --non-interactive --accept-risk \
        --mode local \
        $AUTH_ARGS \
        --gateway-port 18789 \
        --gateway-bind lan \
        --skip-channels \
        --skip-skills \
        --skip-health

    echo "Onboard completed"
else
    echo "Using existing config"
fi

# ============================================================
# PATCH CONFIG (channels, gateway auth, trusted proxies)
# ============================================================
# openclaw onboard handles provider/model config, but we need to patch in:
# - Channel config (Telegram, Discord, Slack)
# - Gateway token auth
# - Trusted proxies for sandbox networking
# - Base URL override for legacy AI Gateway path
node << 'EOFPATCH'
const fs = require('fs');

const configPath = '/root/.openclaw/openclaw.json';
console.log('Patching config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

config.gateway.controlUi = config.gateway.controlUi || {};
config.gateway.controlUi.allowedOrigins = ['*'];

if (process.env.OPENCLAW_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN;
}

// Allow any origin to connect to the gateway control UI.
// The gateway runs inside a Cloudflare Container behind the Worker, which
// proxies requests from the public workers.dev domain. Without this,
// openclaw >= 2026.2.26 rejects WebSocket connections because the browser's
// origin (https://....workers.dev) doesn't match the gateway's localhost.
// Security is handled by CF Access + gateway token auth, not origin checks.
config.gateway.controlUi = config.gateway.controlUi || {};
config.gateway.controlUi.allowedOrigins = ['*'];

if (process.env.OPENCLAW_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Legacy AI Gateway base URL override:
// ANTHROPIC_BASE_URL is picked up natively by the Anthropic SDK,
// so we don't need to patch the provider config. Writing a provider
// entry without a models array breaks OpenClaw's config validation.

// General model override (e.g. OPENCLAW_MODEL_OVERRIDE=anthropic/claude-3-7-sonnet-20250219)
if (process.env.OPENCLAW_MODEL_OVERRIDE) {
    config.agents = config.agents || {};
    config.agents.defaults = config.agents.defaults || {};
    config.agents.defaults.model = { primary: process.env.OPENCLAW_MODEL_OVERRIDE };
    console.log('Model overridden to: ' + process.env.OPENCLAW_MODEL_OVERRIDE);
}

// AI Gateway model override (CF_AI_GATEWAY_MODEL=provider/model-id)
// Adds a provider entry for any AI Gateway provider and sets it as default model.
// Examples:
//   workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast
//   openai/gpt-4o
//   anthropic/claude-sonnet-4-5
if (process.env.CF_AI_GATEWAY_MODEL) {
    const raw = process.env.CF_AI_GATEWAY_MODEL;
    const slashIdx = raw.indexOf('/');
    const gwProvider = raw.substring(0, slashIdx);
    const modelId = raw.substring(slashIdx + 1);

    const accountId = process.env.CF_AI_GATEWAY_ACCOUNT_ID;
    const gatewayId = process.env.CF_AI_GATEWAY_GATEWAY_ID;
    const apiKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY;

    let baseUrl;
    if (accountId && gatewayId) {
        baseUrl = 'https://gateway.ai.cloudflare.com/v1/' + accountId + '/' + gatewayId + '/' + gwProvider;
        if (gwProvider === 'workers-ai') baseUrl += '/v1';
    } else if (gwProvider === 'workers-ai' && process.env.CF_ACCOUNT_ID) {
        baseUrl = 'https://api.cloudflare.com/client/v4/accounts/' + process.env.CF_ACCOUNT_ID + '/ai/v1';
    }

    if (baseUrl && apiKey) {
        const api = gwProvider === 'anthropic' ? 'anthropic-messages' : 'openai-completions';
        const providerName = 'cf-ai-gw-' + gwProvider;

        config.models = config.models || {};
        config.models.providers = config.models.providers || {};
        config.models.providers[providerName] = {
            baseUrl: baseUrl,
            apiKey: apiKey,
            api: api,
            models: [{ id: modelId, name: modelId, contextWindow: 131072, maxTokens: 8192 }],
        };
        config.agents = config.agents || {};
        config.agents.defaults = config.agents.defaults || {};
        config.agents.defaults.model = { primary: providerName + '/' + modelId };
        console.log('AI Gateway model override: provider=' + providerName + ' model=' + modelId + ' via ' + baseUrl);
    } else {
        console.warn('CF_AI_GATEWAY_MODEL set but missing required config (account ID, gateway ID, or API key)');
    }
}

// Telegram configuration
// Overwrite entire channel object to drop stale keys from old R2 backups
// that would fail OpenClaw's strict config validation (see #47)
if (process.env.TELEGRAM_BOT_TOKEN) {
    const dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram = {
        botToken: process.env.TELEGRAM_BOT_TOKEN,
        enabled: true,
        dmPolicy: dmPolicy,
    };
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
    } else if (dmPolicy === 'open') {
        config.channels.telegram.allowFrom = ['*'];
    }
}

// Discord configuration
// Discord uses a nested dm object: dm.policy, dm.allowFrom (per DiscordDmConfig)
if (process.env.DISCORD_BOT_TOKEN) {
    const dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    const dm = { policy: dmPolicy };
    if (dmPolicy === 'open') {
        dm.allowFrom = ['*'];
    }
    config.channels.discord = {
        token: process.env.DISCORD_BOT_TOKEN,
        enabled: true,
        dm: dm,
    };
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = {
        botToken: process.env.SLACK_BOT_TOKEN,
        appToken: process.env.SLACK_APP_TOKEN,
        enabled: true,
    };
}

// OpenAI configuration
if (process.env.OPENAI_API_KEY) {
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    config.models.providers.openai = {
        baseUrl: 'https://api.openai.com/v1',
        apiKey: process.env.OPENAI_API_KEY,
        api: 'openai-completions',
        models: [{ id: 'gpt-5-mini', name: 'GPT-5 mini', contextWindow: 128000, maxTokens: 4096 }]
    };
    console.log('OpenAI provider configured from environment variable');
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration patched successfully');
EOFPATCH

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting OpenClaw Gateway..."
echo "Gateway will be available on port 18789"

rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

echo "Dev mode: ${OPENCLAW_DEV_MODE:-false}"

# Gateway token (if set) is already written to openclaw.json by the config
# patch above (gateway.auth.token). We deliberately avoid passing --token on
# the command line because CLI arguments are visible to all processes in the
# container via ps/proc.
if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
else
    echo "Starting gateway with device pairing (no token)..."
fi

# Inject OpenAI Codex OAuth token directly into the agent directory
echo "Injecting OpenAI Codex OAuth token..."
mkdir -p /home/openclaw/.openclaw/agents/main/agent
echo "ewogICJ2ZXJzaW9uIjogMSwKICAicHJvZmlsZXMiOiB7CiAgICAib3BlbmFpLWNvZGV4OmRlZmF1bHQiOiB7CiAgICAgICJ0eXBlIjogIm9hdXRoIiwKICAgICAgInByb3ZpZGVyIjogIm9wZW5haS1jb2RleCIsCiAgICAgICJhY2Nlc3MiOiAiZXlKaGJHY2lPaUpTVXpJMU5pSXNJbXRwWkNJNklqRTVNelEwWlRZMUxXSmlZemt0TkRSa01TMWhPV1F3TFdZNU5UZGlNRGM1WW1Rd1pTSXNJblI1Y0NJNklrcFhWQ0o5LmV5SmhkV1FpT2xzaWFIUjBjSE02THk5aGNHa3ViM0JsYm1GcExtTnZiUzkyTVNKZExDSmpiR2xsYm5SZmFXUWlPaUpoY0hCZlJVMXZZVzFGUlZvM00yWXdRMnRZWVZod04yaHlZVzV1SWl3aVpYaHdJam94TnpjMk9EWTJNamsxTENKb2RIUndjem92TDJGd2FTNXZjR1Z1WVdrdVkyOXRMMkYxZEdnaU9uc2lZVzF5SWpwYkluQjNaQ0lzSW05MGNDSXNJbTFtWVNJc0luVnlianB2Y0dWdVlXazZZVzF5T205MGNGOWxiV0ZwYkNKZExDSmphR0YwWjNCMFgyRmpZMjkxYm5SZmFXUWlPaUk0T0RabFl6WTVOUzFtWWpkakxUUmhZemd0WWpNNU1TMWlNRGsxT0RNek1EaGtPRFFpTENKamFHRjBaM0IwWDJGalkyOTFiblJmZFhObGNsOXBaQ0k2SW5WelpYSXRlVUpuUzFWdmNtOVJPVWwwVVVaaWJuZDJNRkpWT0VkRVgxODRPRFpsWXpZNU5TMW1ZamRqTFRSaFl6Z3RZak01TVMxaU1EazFPRE16TURoa09EUWlMQ0pqYUdGMFozQjBYMk52YlhCMWRHVmZjbVZ6YVdSbGJtTjVJam9pYm05ZlkyOXVjM1J5WVdsdWRDSXNJbU5vWVhSbmNIUmZjR3hoYmw5MGVYQmxJam9pY0d4MWN5SXNJbU5vWVhSbmNIUmZkWE5sY2w5cFpDSTZJblZ6WlhJdGVVSm5TMVZ2Y205Uk9VbDBVVVppYm5kMk1GSlZPRWRFSWl3aWJHOWpZV3hvYjNOMElqcDBjblZsTENKMWMyVnlYMmxrSWpvaWRYTmxjaTE1UW1kTFZXOXliMUU1U1hSUlJtSnVkM1l3VWxVNFIwUWlmU3dpYUhSMGNITTZMeTloY0drdWIzQmxibUZwTG1OdmJTOXdjbTltYVd4bElqcDdJbVZ0WVdsc0lqb2ljR1ZqWW1GemMwQm5iV0ZwYkM1amIyMGlMQ0psYldGcGJGOTJaWEpwWm1sbFpDSTZkSEoxWlgwc0ltbGhkQ0k2TVRjM05UazVPRFU1TkN3aWFYTnpJam9pYUhSMGNITTZMeTloZFhSb0xtOXdaVzVoYVM1amIyMGlMQ0pxZEdraU9pSmxOV1ZoWVRreVlpMDJaRFZoTFRRMk4yUXRZbVJoTkMwMVpURTBZamxpWldWaE16VWlMQ0p1WW1ZaU9qRTNOelU1T1RnMU9UUXNJbkIzWkY5aGRYUm9YM1JwYldVaU9qRTNOelU1T1RnMU9UTXhPVGtzSW5OamNDSTZXeUp2Y0dWdWFXUWlMQ0p3Y205bWFXeGxJaXdpWlcxaGFXd2lMQ0p2Wm1ac2FXNWxYMkZqWTJWemN5SmRMQ0p6WlhOemFXOXVYMmxrSWpvaVlYVjBhSE5sYzNOZmFubzJSWFkyYVZwa1NUVjRRMmMwTlVwMGN6QjVXWE5aSWl3aWMyd2lPblJ5ZFdVc0luTjFZaUk2SW1GMWRHZ3dmRFl6WkRsaU0yTTFaR0U1TW1Oa1pqZzJaalZrTldGa1lTSjkudUFkUDdqRFl4djhERDhITnU1N3FzZHhrUGpJTHVQYjZ6Nno2YXpKdU01TlF3bkVNdVdpcjI4Q2tWR3YxRl9HdEQ4cHczbUNmWThQZVN0YnFYVGZVdFdXYVl5blloNzlDd3R6TVJVdlVQVWFpWjEwY1V3elplX1dKY3lhSFhSemlqZ3N0R3dFSXVVT3pmYmJURjg3dHhxcHBBSmstN3RqQnNCZ0NJY3d4NUZ2YzVPZVNjcHg1eDhfZjJQcU9aWWpzUzBUYW1nb3hnanZDbVZwU0d5ZEp6NTJpcVVELUZCQXZqVE5lbFVmaV9UUW4ta0R6MUFUZDdMMWQ4YVJyeUVlYUEyWGhuSE1zeFRQbDNnWVRLWHFKeV96SlE1TGk5YWVCOFdybnhRQURPaEtOT2FtWUxjUE1TMW1tMjNlWDRCY1ZGRlJWVjYtUTV6UjFxbmg3cE8xNmRvSGlJeUhURW5CNGFNeVp1TUEyRkpXMy12Slp5NlhQSW1RZ09SeEUxbVIxRFgwcC11a1QwS0FTUlEzelNoVUJDYTgwemljTTNnTUtYdnZBcUV2cEN5amtjdldZUjc3aUoxYlVHOUxfXzBsSzdjcXpEd3pwWm9zRHZKM3pYNnRTQ2oxYlJaaWZTUFBpbHpWRkVrcDkxMlJUT21OSllDNU04RHN3MmFzNUNnYlEwYk5wU3FCSU96X1FzZ1BnUXE2OFU2ZDBuYnRTUGxjYzYyaXB4Y0tOa3FTOVNLTGJVcUF3d0FHbHhLUjRVRTFudXNzdlRMdUN3Y2MwSUxKcTFZUjUwNFJTRnZJOWpiQTQzZ0dzV1hmd0xTSHphQ3MwWmR1aXdjSmY1bVcwQUFOV0toTENCUTNjZEl2aEoybXc1aVNWbnZZOGwxVlBhaTdPX1lLcGllclc4eGsiLAogICAgICAicmVmcmVzaCI6ICJydF83NFV1N1ctdFZ4SVNnN08yeU1NWW5vdG53Rk9EaVhiM0xHN1ZDZE9QcVBjLjFRU3lKWVdETnh1cFZ5T09pVGFaY1pVOGJrV0h2Tlc3cjlNMmtiX3VyU1EiLAogICAgICAiZXhwaXJlcyI6IDE3NzY4NjI1OTQ1NDgsCiAgICAgICJlbWFpbCI6ICJwZWNiYXNzQGdtYWlsLmNvbSIKICAgIH0KICB9Cn0K" | base64 -d > /home/openclaw/.openclaw/agents/main/agent/auth-profiles.json
echo "Token injection complete."

exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan

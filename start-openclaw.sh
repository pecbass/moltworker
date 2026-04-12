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
echo "ewogICJ2ZXJzaW9uIjogMSwKICAicHJvZmlsZXMiOiB7CiAgICAib3BlbmFpLWNvZGV4OmRlZmF1bHQiOiB7CiAgICAgICJ0eXBlIjogIm9hdXRoIiwKICAgICAgInByb3ZpZGVyIjogIm9wZW5haS1jb2RleCIsCiAgICAgICJhY2Nlc3MiOiAiZXlKaGJHY2lPaUpTVXpJMU5pSXNJbXRwWkNJNklqRTVNelEwWlRZMUxXSmlZemt0TkRSa01TMWhPV1F3TFdZNU5UZGlNRGM1WW1Rd1pTSXNJblI1Y0NJNklrcFhWQ0o5LmV5SmhkV1FpT2xzaWFIUjBjSE02THk5aGNHa3ViM0JsYm1GcExtTnZiUzkyTVNKZExDSmpiR2xsYm5SZmFXUWlPaUpoY0hCZlJVMXZZVzFGUlZvM00yWXdRMnRZWVZod04yaHlZVzV1SWl3aVpYaHdJam94TnpjeU9EQTFNamd5TENKb2RIUndjem92TDJGd2FTNXZjR1Z1WVdrdVkyOXRMMkYxZEdnaU9uc2lZMmhoZEdkd2RGOWhZMk52ZFc1MFgybGtJam9pT0RnMlpXTTJPVFV0Wm1JM1l5MDBZV000TFdJek9URXRZakE1TlRnek16QTRaRGcwSWl3aVkyaGhkR2R3ZEY5aFkyTnZkVzUwWDNWelpYSmZhV1FpT2lKMWMyVnlMWGxDWjB0VmIzSnZVVGxKZEZGR1ltNTNkakJTVlRoSFJGOWZPRGcyWldNMk9UVXRabUkzWXkwMFlXTTRMV0l6T1RFdFlqQTVOVGd6TXpBNFpEZzBJaXdpWTJoaGRHZHdkRjlqYjIxd2RYUmxYM0psYzJsa1pXNWplU0k2SW01dlgyTnZibk4wY21GcGJuUWlMQ0pqYUdGMFozQjBYM0JzWVc1ZmRIbHdaU0k2SW5Cc2RYTWlMQ0pqYUdGMFozQjBYM1Z6WlhKZmFXUWlPaUoxYzJWeUxYbENaMHRWYjNKdlVUbEpkRkZHWW01M2RqQlNWVGhIUkNJc0luVnpaWEpmYVdRaU9pSjFjMlZ5TFhsQ1owdFZiM0p2VVRsSmRGRkdZbTUzZGpCU1ZUaEhSQ0o5TENKb2RIUndjem92TDJGd2FTNXZjR1Z1WVdrdVkyOXRMM0J5YjJacGJHVWlPbnNpWlcxaGFXd2lPaUp3WldOaVlYTnpRR2R0WVdsc0xtTnZiU0lzSW1WdFlXbHNYM1psY21sbWFXVmtJanAwY25WbGZTd2lhV0YwSWpveE56Y3hPVFF4TWpneExDSnBjM01pT2lKb2RIUndjem92TDJGMWRHZ3ViM0JsYm1GcExtTnZiU0lzSW1wMGFTSTZJalZpWXpobVpEZGtMV0kzTWpRdE5EUXlZUzA1WkdWaExUUXpZMll6TmpsbE0ySmpOaUlzSW01aVppSTZNVGMzTVRrME1USTRNU3dpY0hka1gyRjFkR2hmZEdsdFpTSTZNVGMzTVRJME9URTNNemd3TVN3aWMyTndJanBiSW05d1pXNXBaQ0lzSW5CeWIyWnBiR1VpTENKbGJXRnBiQ0lzSW05bVpteHBibVZmWVdOalpYTnpJbDBzSW5ObGMzTnBiMjVmYVdRaU9pSmhkWFJvYzJWemMxODBjRFZsTURVeVpXeHFTWFpRYjJsM2RVSlFTM2h3TTJRaUxDSnpkV0lpT2lKaGRYUm9NSHcyTTJRNVlqTmpOV1JoT1RKalpHWTRObVkxWkRWaFpHRWlmUS5aN0VaaFpKek5aNlViVjF6cktLLTVfYTdMMXNvQzBSMWFGaXBPRjlrWGprRWV6alpvMkVQMUYyb0xfWFVaOVN5RHBYUWxBbVBadW9rZjdOa21SY0dlWFZwdUNLa2hIdVQxV2FwcU5xWnNicmNFX2ZuanlNLXdFTEVEZmpxUVpGcE5Sand5dlcxb1kyQnR5VmNSV05wMkVmRm5qcVc2bXVoWFI4VjRrMHpaSGRzSmlVc0FkWkdUcnNkbnVqZFZCVWtOZWxxa3NmREZ0SVZodlFFUzlOY2pyNE5oZXFRTmwzT09pS04zY3JnQ3JqeVRpbXlObU10U1cxNlIxQ1ZoR29HSW9La2JoSmE2djdLUzljejFEb2xZem1IMEcwZkdUcUlER21lN19DRHFmRUpnVkNxaE1PckN5SWg2d3h4Tld3MHhyTjFGbEFKakc3U2MzNndxbHptczJWT2drUVlQX0tvd3hQZS1HTkpHVXFPeFZrWkh0b2NwTHVRMV9NaWhLaUx1N0hjRmR5YUNZckhwMjFWdHFnNldzYm1rOXNsYmRieEp2enFIRGkzdE95d0ViQ2hhbWpWY0xwbHJoSjU5aHBzbGdneVFBVDV5NlZlaVlkM0JZbWhMREttemEyNm0xd2xwQm94Q3JISWNUVlg0aFdkTkRKamZuRGE3VzRSYlpNc0E5ZU9zOElpRXhsamkzaVpQZ3pSZTlkNzEwaEw2Zldpd24zdnQxMFJNaHZpaUo3OE5QXzk0OHhXZU56OVpibV93VWZnbW5JcWpieGIyeXQ3X19TRUlkaC16NUpfRTJuWXl3MDhKSTNtRWdSdXl6MXZVTUR6dzFGbmZKREtIRjNfR0ZuWE00NEt1NTBGSUpGR0twSmREN29vcDlhTlhpZWYwQWdJM29USnUtUSIsCiAgICAgICJyZWZyZXNoIjogInJ0XzFTOGVxT3U3eWduMjlmWllOUEFuN0xzRHlRQXYxQWwxcUp0WEpUNlFuYUUuSUF6M0M3QjZEenY1Q19tVU9FSUw1OEhubnJCZmptV1k1Rk1NcDBWMHR5ZyIsCiAgICAgICJleHBpcmVzIjogMTc3MjgwNTI4MjAwMCwKICAgICAgImFjY291bnRJZCI6ICI4ODZlYzY5NS1mYjdjLTRhYzgtYjM5MS1iMDk1ODMzMDhkODQiLAogICAgICAibWFuYWdlZEJ5IjogImNvZGV4LWNsaSIKICAgIH0sCiAgICAib3BlbmFpLWNvZGV4OnBlY2Jhc3NAZ21haWwuY29tIjogewogICAgICAidHlwZSI6ICJvYXV0aCIsCiAgICAgICJwcm92aWRlciI6ICJvcGVuYWktY29kZXgiLAogICAgICAiYWNjZXNzIjogImV5SmhiR2NpT2lKU1V6STFOaUlzSW10cFpDSTZJakU1TXpRMFpUWTFMV0ppWXprdE5EUmtNUzFoT1dRd0xXWTVOVGRpTURjNVltUXdaU0lzSW5SNWNDSTZJa3BYVkNKOS5leUpoZFdRaU9sc2lhSFIwY0hNNkx5OWhjR2t1YjNCbGJtRnBMbU52YlM5Mk1TSmRMQ0pqYkdsbGJuUmZhV1FpT2lKaGNIQmZSVTF2WVcxRlJWbzNNMll3UTJ0WVlWaHdOMmh5WVc1dUlpd2laWGh3SWpveE56YzJPRFkyTWprMUxDSm9kSFJ3Y3pvdkwyRndhUzV2Y0dWdVlXa3VZMjl0TDJGMWRHZ2lPbnNpWVcxeUlqcGJJbkIzWkNJc0ltOTBjQ0lzSW0xbVlTSXNJblZ5YmpwdmNHVnVZV2s2WVcxeU9tOTBjRjlsYldGcGJDSmRMQ0pqYUdGMFozQjBYMkZqWTI5MWJuUmZhV1FpT2lJNE9EWmxZelk1TlMxbVlqZGpMVFJoWXpndFlqTTVNUzFpTURrMU9ETXpNRGhrT0RRaUxDSmphR0YwWjNCMFgyRmpZMjkxYm5SZmRYTmxjbDlwWkNJNkluVnpaWEl0ZVVKblMxVnZjbTlST1VsMFVVWmlibmQyTUZKVk9FZEVYMTg0T0RabFl6WTVOUzFtWWpkakxUUmhZemd0WWpNNU1TMWlNRGsxT0RNek1EaGtPRFFpTENKamFHRjBaM0IwWDJOdmJYQjFkR1ZmY21WemFXUmxibU41SWpvaWJtOWZZMjl1YzNSeVlXbHVkQ0lzSW1Ob1lYUm5jSFJmY0d4aGJsOTBlWEJsSWpvaWNHeDFjeUlzSW1Ob1lYUm5jSFJmZFhObGNsOXBaQ0k2SW5WelpYSXRlVUpuUzFWdmNtOVJPVWwwVVVaaWJuZDJNRkpWT0VkRUlpd2liRzlqWVd4b2IzTjBJanAwY25WbExDSjFjMlZ5WDJsa0lqb2lkWE5sY2kxNVFtZExWVzl5YjFFNVNYUlJSbUp1ZDNZd1VsVTRSMFFpZlN3aWFIUjBjSE02THk5aGNHa3ViM0JsYm1GcExtTnZiUzl3Y205bWFXeGxJanA3SW1WdFlXbHNJam9pY0dWalltRnpjMEJuYldGcGJDNWpiMjBpTENKbGJXRnBiRjkyWlhKcFptbGxaQ0k2ZEhKMVpYMHNJbWxoZENJNk1UYzNOVGs1T0RVNU5Dd2lhWE56SWpvaWFIUjBjSE02THk5aGRYUm9MbTl3Wlc1aGFTNWpiMjBpTENKcWRHa2lPaUpsTldWaFlUa3lZaTAyWkRWaExUUTJOMlF0WW1SaE5DMDFaVEUwWWpsaVpXVmhNelVpTENKdVltWWlPakUzTnpVNU9UZzFPVFFzSW5CM1pGOWhkWFJvWDNScGJXVWlPakUzTnpVNU9UZzFPVE14T1Rrc0luTmpjQ0k2V3lKdmNHVnVhV1FpTENKd2NtOW1hV3hsSWl3aVpXMWhhV3dpTENKdlptWnNhVzVsWDJGalkyVnpjeUpkTENKelpYTnphVzl1WDJsa0lqb2lZWFYwYUhObGMzTmZhbm8yUlhZMmFWcGtTVFY0UTJjME5VcDBjekI1V1hOWklpd2ljMndpT25SeWRXVXNJbk4xWWlJNkltRjFkR2d3ZkRZelpEbGlNMk0xWkdFNU1tTmtaamcyWmpWa05XRmtZU0o5LnVBZFA3akRZeHY4REQ4SE51NTdxc2R4a1BqSUx1UGI2ejZ6NmF6SnVNNU5Rd25FTXVXaXIyOENrVkd2MUZfR3REOHB3M21DZlk4UGVTdGJxWFRmVXRXV2FZeW5ZaDc5Q3d0ek1SVXZVUFVhaVoxMGNVd3paZV9XSmN5YUhYUnppamdzdEd3RUl1VU96ZmJiVEY4N3R4cXBwQUprLTd0akJzQmdDSWN3eDVGdmM1T2VTY3B4NXg4X2YyUHFPWllqc1MwVGFtZ294Z2p2Q21WcFNHeWRKejUyaXFVRC1GQkF2alROZWxVZmlfVFFuLWtEejFBVGQ3TDFkOGFScnlFZWFBMlhobkhNc3hUUGwzZ1lUS1hxSnlfekpRNUxpOWFlQjhXcm54UUFET2hLTk9hbVlMY1BNUzFtbTIzZVg0QmNWRkZSVlY2LVE1elIxcW5oN3BPMTZkb0hpSXlIVEVuQjRhTXladU1BMkZKVzMtdkpaeTZYUEltUWdPUnhFMW1SMURYMHAtdWtUMEtBU1JRM3pTaFVCQ2E4MHppY00zZ01LWHZ2QXFFdnBDeWprY3ZXWVI3N2lKMWJVRzlMX18wbEs3Y3F6RHd6cFpvc0R2SjN6WDZ0U0NqMWJSWmlmU1BQaWx6VkZFa3A5MTJSVE9tTkpZQzVNOERzdzJhczVDZ2JRMGJOcFNxQklPel9Rc2dQZ1FxNjhVNmQwbmJ0U1BsY2M2MmlweGNLTmtxUzlTS0xiVXFBd3dBR2x4S1I0VUUxbnVzc3ZUTHVDd2NjMElMSnExWVI1MDRSU0Z2STlqYkE0M2dHc1dYZndMU0h6YUNzMFpkdWl3Y0pmNW1XMEFBTldLaExDQlEzY2RJdmhKMm13NWlTVm52WThsMVZQYWk3T19ZS3BpZXJXOHhrIiwKICAgICAgInJlZnJlc2giOiAicnRfNzRVdTdXLXRWeElTZzdPMnlNTVlub3Rud0ZPRGlYYjNMRzdWQ2RPUHFQYy4xUVN5SllXRE54dXBWeU9PaVRhWmNaVThia1dIdk5XN3I5TTJrYl91clNRIiwKICAgICAgImV4cGlyZXMiOiAxNzc2ODYyNTk0NTQ4LAogICAgICAiZW1haWwiOiAicGVjYmFzc0BnbWFpbC5jb20iCiAgICB9CiAgfQp9Cg==" | base64 -d > /home/openclaw/.openclaw/agents/main/agent/auth-profiles.json
echo "Token injection complete."

exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan

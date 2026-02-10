#!/bin/bash
# Startup script for Moltbot in Cloudflare Sandbox
# This script:
# 1. Restores config from R2 backup if available
# 2. Configures moltbot from environment variables
# 3. Starts a background sync to backup config to R2
# 4. Starts the gateway

set -e
set -x

# Redirect all output to log file (and keep on stdout for wrangler tail)
LOG_FILE="/tmp/moltbot.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Force kill any existing clawdbot processes to free the port
echo "Cleaning up existing clawdbot processes..."
pkill -f "clawdbot gateway" || true

# Force kill any old nc listener loops (from previous keep_alive_on_crash)
pkill -f "nc -l -p 18789" || true

# Force kill any OTHER instances of this script to stop them from restarting nc
MY_PID=$$
echo "My PID: $MY_PID"
for pid in $(pgrep -f "start-moltbot.sh"); do
    if [ "$pid" != "$MY_PID" ] && [ "$pid" != "$PPID" ]; then
        echo "Killing old script instance $pid"
        kill -9 "$pid" 2>/dev/null || true
    fi
done

# Wait for port to be free
sleep 2

# Check if port 18789 is actually free, retry kill if not
if nc -z localhost 18789; then
    echo "Port 18789 is still in use! Forcing kill..."
    pkill -9 -f "clawdbot" || true
    pkill -9 -f "nc" || true
    sleep 2
fi

# Paths (clawdbot paths are used internally - upstream hasn't renamed yet)
CONFIG_DIR="/root/.clawdbot"
CONFIG_FILE="$CONFIG_DIR/clawdbot.json"
TEMPLATE_DIR="/root/.clawdbot-templates"
TEMPLATE_FILE="$TEMPLATE_DIR/moltbot.json.template"
BACKUP_DIR="/data/moltbot"

echo "Config directory: $CONFIG_DIR"
echo "Backup directory: $BACKUP_DIR"

# Create config directory
mkdir -p "$CONFIG_DIR"

# ============================================================
# RESTORE FROM R2 BACKUP
# ============================================================
# Check if R2 backup exists by looking for clawdbot.json
# The BACKUP_DIR may exist but be empty if R2 was just mounted
# Note: backup structure is $BACKUP_DIR/clawdbot/ and $BACKUP_DIR/skills/

# Helper function to check if R2 backup is newer than local
should_restore_from_r2() {
    local R2_SYNC_FILE="$BACKUP_DIR/.last-sync"
    local LOCAL_SYNC_FILE="$CONFIG_DIR/.last-sync"
    
    # If no R2 sync timestamp, don't restore
    if [ ! -f "$R2_SYNC_FILE" ]; then
        echo "No R2 sync timestamp found, skipping restore"
        return 1
    fi
    
    # If no local sync timestamp, restore from R2
    if [ ! -f "$LOCAL_SYNC_FILE" ]; then
        echo "No local sync timestamp, will restore from R2"
        return 0
    fi
    
    # Compare timestamps
    R2_TIME=$(cat "$R2_SYNC_FILE" 2>/dev/null)
    LOCAL_TIME=$(cat "$LOCAL_SYNC_FILE" 2>/dev/null)
    
    echo "R2 last sync: $R2_TIME"
    echo "Local last sync: $LOCAL_TIME"
    
    # Convert to epoch seconds for comparison
    R2_EPOCH=$(date -d "$R2_TIME" +%s 2>/dev/null || echo "0")
    LOCAL_EPOCH=$(date -d "$LOCAL_TIME" +%s 2>/dev/null || echo "0")
    
    if [ "$R2_EPOCH" -gt "$LOCAL_EPOCH" ]; then
        echo "R2 backup is newer, will restore"
        return 0
    else
        echo "Local data is newer or same, skipping restore"
        return 1
    fi
}

if [ -f "$BACKUP_DIR/clawdbot/clawdbot.json" ]; then
    if should_restore_from_r2; then
        echo "Restoring from R2 backup at $BACKUP_DIR/clawdbot..."
        cp -a "$BACKUP_DIR/clawdbot/." "$CONFIG_DIR/"
        # Copy the sync timestamp to local so we know what version we have
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from R2 backup"
    fi
elif [ -f "$BACKUP_DIR/clawdbot.json" ]; then
    # Legacy backup format (flat structure)
    if should_restore_from_r2; then
        echo "Restoring from legacy R2 backup at $BACKUP_DIR..."
        cp -a "$BACKUP_DIR/." "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from legacy R2 backup"
    fi
elif [ -d "$BACKUP_DIR" ]; then
    echo "R2 mounted at $BACKUP_DIR but no backup data found yet"
else
    echo "R2 not mounted, starting fresh"
fi

# Restore skills from R2 backup if available (only if R2 is newer)
SKILLS_DIR="/root/clawd/skills"
if [ -d "$BACKUP_DIR/skills" ] && [ "$(ls -A $BACKUP_DIR/skills 2>/dev/null)" ]; then
    if should_restore_from_r2; then
        echo "Restoring skills from $BACKUP_DIR/skills..."
        mkdir -p "$SKILLS_DIR"
        cp -a "$BACKUP_DIR/skills/." "$SKILLS_DIR/"
        echo "Restored skills from R2 backup"
    fi
fi

# If config file still doesn't exist, create from template
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, initializing from template..."
    if [ -f "$TEMPLATE_FILE" ]; then
        cp "$TEMPLATE_FILE" "$CONFIG_FILE"
    else
        # Create minimal config if template doesn't exist
        cat > "$CONFIG_FILE" << 'EOFCONFIG'
{
  "agents": {
    "defaults": {
      "workspace": "/root/clawd"
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local"
  }
}
EOFCONFIG
    fi
else
    echo "Using existing config"
fi

# ============================================================
# UPDATE CONFIG FROM ENVIRONMENT VARIABLES
# ============================================================
node << 'EOFNODE'
const fs = require('fs');

const configPath = '/root/.clawdbot/clawdbot.json';
console.log('Updating config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

// Ensure nested objects exist
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Clean up any broken anthropic provider config from previous runs
// (older versions didn't include required 'name' field)
if (config.models?.providers?.anthropic?.models) {
    const hasInvalidModels = config.models.providers.anthropic.models.some(m => !m.name);
    if (hasInvalidModels) {
        console.log('Removing broken anthropic provider config (missing model names)');
        delete config.models.providers.anthropic;
    }
}



// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

// Set gateway token if provided
if (process.env.CLAWDBOT_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.CLAWDBOT_GATEWAY_TOKEN;
}

// Allow insecure auth for dev mode
if (process.env.CLAWDBOT_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Telegram configuration
if (process.env.TELEGRAM_BOT_TOKEN) {
    config.channels.telegram = config.channels.telegram || {};
    config.channels.telegram.botToken = process.env.TELEGRAM_BOT_TOKEN;
    config.channels.telegram.enabled = true;
    const telegramDmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram.dmPolicy = telegramDmPolicy;
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        // Explicit allowlist: "123,456,789" → ['123', '456', '789']
        config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
    } else if (telegramDmPolicy === 'open') {
        // "open" policy requires allowFrom: ["*"]
        config.channels.telegram.allowFrom = ['*'];
    }
}

// Discord configuration
// Note: Discord uses nested dm.policy, not flat dmPolicy like Telegram
// See: https://github.com/moltbot/moltbot/blob/v2026.1.24-1/src/config/zod-schema.providers-core.ts#L147-L155
if (process.env.DISCORD_BOT_TOKEN) {
    config.channels.discord = config.channels.discord || {};
    config.channels.discord.token = process.env.DISCORD_BOT_TOKEN;
    config.channels.discord.enabled = true;
    const discordDmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    config.channels.discord.dm = config.channels.discord.dm || {};
    config.channels.discord.dm.policy = discordDmPolicy;
    // "open" policy requires allowFrom: ["*"]
    if (discordDmPolicy === 'open') {
        config.channels.discord.dm.allowFrom = ['*'];
    }
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = config.channels.slack || {};
    config.channels.slack.botToken = process.env.SLACK_BOT_TOKEN;
    config.channels.slack.appToken = process.env.SLACK_APP_TOKEN;
    config.channels.slack.enabled = true;
}

// Base URL override (e.g., for Cloudflare AI Gateway)
// Usage: Set AI_GATEWAY_BASE_URL or ANTHROPIC_BASE_URL to your endpoint like:
//   https://gateway.ai.cloudflare.com/v1/{account_id}/{gateway_id}/anthropic
//   https://gateway.ai.cloudflare.com/v1/{account_id}/{gateway_id}/openai
//   https://gateway.ai.cloudflare.com/v1/{account_id}/{gateway_id}/openai
const baseUrl = (process.env.AI_GATEWAY_BASE_URL || process.env.ANTHROPIC_BASE_URL || '').replace(/\/+$/, '');
const isGoogle = baseUrl.endsWith('/google') || baseUrl.includes('gemini') || (process.env.CF_AI_GATEWAY_MODEL && process.env.CF_AI_GATEWAY_MODEL.startsWith('google/'));
const isOpenAI = baseUrl.endsWith('/openai') || (process.env.CF_AI_GATEWAY_MODEL && process.env.CF_AI_GATEWAY_MODEL.startsWith('openai/'));

// Default models - removed invalid claude-opus-4-5-20251101
const anthropicModels = [
    { id: 'claude-sonnet-4-5-20250929', name: 'Claude Sonnet 4.5', contextWindow: 200000 },
    { id: 'claude-haiku-4-5-20251001', name: 'Claude Haiku 4.5', contextWindow: 200000 },
    { id: 'claude-3-5-sonnet-latest', name: 'Claude 3.5 Sonnet', contextWindow: 200000 },
    { id: 'claude-3-opus-latest', name: 'Claude 3 Opus', contextWindow: 200000 },
];

const openaiModels = [
    { id: 'gpt-5.2', name: 'GPT-5.2', contextWindow: 200000 },
    { id: 'gpt-5', name: 'GPT-5', contextWindow: 200000 },
    { id: 'gpt-4.5-preview', name: 'GPT-4.5 Preview', contextWindow: 128000 },
];

const googleModels = [
    { id: 'gemini-3-flash', name: 'Gemini 3 Flash', contextWindow: 1000000 },
    { id: 'gemini-3-pro-preview', name: 'Gemini 3 Pro', contextWindow: 2000000 },
    { id: 'gemini-2.0-flash', name: 'Gemini 2.0 Flash', contextWindow: 1000000 },
];

let envModel;

if (isGoogle) {
    // Configure Google provider (Gemini)
    console.log('Configuring Google provider with base URL:', baseUrl);
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};

    // For Cloudflare AI Gateway, we often use the openai-compatible endpoint for Google models
    // But if we are using direct google-ai-studio, we need specific config.
    // Assuming AI Gateway usage with OpenAI compatibility layer for simplicity if baseUrl is set
    
    // Check if we should use 'google' provider or 'openai' provider with google models
    // If baseUrl ends with /openai, use openai provider even for google models
    if (baseUrl.endsWith('/openai')) {
         config.models.providers.openai = {
            baseUrl: baseUrl,
            api: 'openai-responses',
            models: googleModels
        };
        // Add models to allowlist
        config.agents.defaults.models = config.agents.defaults.models || {};
        googleModels.forEach(m => {
            // Map google/xxxx to the ID
            config.agents.defaults.models[`google/${m.id}`] = { alias: m.name };
            // Also map openai/google/xxxx just in case
            config.agents.defaults.models[`openai/google/${m.id}`] = { alias: m.name };
        });
    } else {
        // Native Google provider config (if supported by this Moltbot version) or generic
        config.models.providers.google = {
            baseUrl: baseUrl || 'https://generativelanguage.googleapis.com',
            api: 'google-generative-ai',
            models: googleModels
        };
        if (process.env.OPENAI_API_KEY) { // Mapped from AI_GATEWAY_API_KEY in env.ts for google logic
             config.models.providers.google.apiKey = process.env.OPENAI_API_KEY;
        }
         // Add models to allowlist
        config.agents.defaults.models = config.agents.defaults.models || {};
        googleModels.forEach(m => {
            config.agents.defaults.models[`google/${m.id}`] = { alias: m.name };
        });
    }

    // Set primary model from env or default
    envModel = process.env.CF_AI_GATEWAY_MODEL;
    if (envModel) {
        config.agents.defaults.model.primary = envModel;
    } else {
        config.agents.defaults.model.primary = 'google/gemini-3-flash';
    }

} else if (isOpenAI) {
    // Create custom openai provider config with baseUrl override
    // Omit apiKey so moltbot falls back to OPENAI_API_KEY env var
    console.log('Configuring OpenAI provider with base URL:', baseUrl);
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    config.models.providers.openai = {
        baseUrl: baseUrl,
        api: 'openai-responses',
        models: openaiModels
    };
    // Add models to the allowlist so they appear in /models
    config.agents.defaults.models = config.agents.defaults.models || {};
    openaiModels.forEach(m => {
        config.agents.defaults.models[`openai/${m.id}`] = { alias: m.name };
    });
    
     // Set primary model from env or default
    envModel = process.env.CF_AI_GATEWAY_MODEL;
    if (envModel) {
        config.agents.defaults.model.primary = envModel;
    } else {
        config.agents.defaults.model.primary = 'openai/gpt-5.2';
    }
} else {
    // Configure Anthropic provider (with or without custom baseUrl)
    console.log('Configuring Anthropic provider...');
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    
    const providerConfig = {
        baseUrl: baseUrl || 'https://api.anthropic.com',
        api: 'anthropic-messages',
        models: anthropicModels
    };
    
    if (baseUrl) {
        console.log('Using custom base URL:', baseUrl);
    }
    
    // Include API key in provider config if set
    if (process.env.ANTHROPIC_API_KEY) {
        providerConfig.apiKey = process.env.ANTHROPIC_API_KEY;
    }
    
    config.models.providers.anthropic = providerConfig;
    
    // Add models to the allowlist
    config.agents.defaults.models = config.agents.defaults.models || {};
    anthropicModels.forEach(m => {
        config.agents.defaults.models[`anthropic/${m.id}`] = { alias: m.name };
    });
    
    // Set primary model
    envModel = process.env.CF_AI_GATEWAY_MODEL;
    if (envModel) {
        config.agents.defaults.model.primary = envModel;
    } else {
        config.agents.defaults.model.primary = 'anthropic/claude-sonnet-4-5-20250929';
    }
}

// Write updated config
fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration updated successfully');
console.log('Config:', JSON.stringify(config, null, 2));
EOFNODE

# ============================================================
# START GATEWAY
# ============================================================
# Note: R2 backup sync is handled by the Worker's cron trigger
echo "Starting Moltbot Gateway..."
echo "Gateway will be available on port 18789"

# Clean up stale lock files
rm -f /tmp/clawdbot-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

BIND_MODE="lan"
echo "Dev mode: ${CLAWDBOT_DEV_MODE:-false}, Bind mode: $BIND_MODE"

# Function to keep container alive on crash
keep_alive_on_crash() {
    local exit_code=$1
    echo "==============================================="
    echo "CRASH DETECTED: clawdbot exited with code $exit_code"
    echo "Starting fake listener on 18789 to keep container alive for logs..."
    echo "==============================================="
    
    # Start netcat in loop to answer health checks with log content
    while true; do
        # Prepare log content (escape for HTML/safe output if needed, but plain text is fine for curl/browser view source)
        echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nCRASH DETECTED (Exit code: $exit_code)\n\n--- LAST 50 LINES OF LOG ---\n" > /tmp/response.txt
        tail -n 50 "$LOG_FILE" >> /tmp/response.txt
        
        cat /tmp/response.txt | nc -l -p 18789 -q 1
    done
}

# Check available memory
echo "System memory:"
free -m || true

# Set memory limit for Node.js to prevent OOM (Exit code 137) in sandbox
# Lowered to 512MB to stay well within container limits (likely 1GB or less)
export NODE_OPTIONS="--max-old-space-size=512"

if [ -n "$CLAWDBOT_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    clawdbot gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE" --token "$CLAWDBOT_GATEWAY_TOKEN" || keep_alive_on_crash $?
else
    echo "Starting gateway with device pairing (no token)..."
    clawdbot gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE" || keep_alive_on_crash $?
fi

import type { MoltbotEnv } from '../types';

/**
 * Build environment variables to pass to the Moltbot container process
 * 
 * @param env - Worker environment bindings
 * @returns Environment variables record
 */
export function buildEnvVars(env: MoltbotEnv): Record<string, string> {
  const envVars: Record<string, string> = {};

  // Normalize the base URL by removing trailing slashes
  // Normalize the base URL by removing trailing slashes
  let baseUrl = env.AI_GATEWAY_BASE_URL;

  // Guide compliance: Construct AI Gateway URL from ID and Account ID if not explicitly set
  if (!baseUrl && env.CLOUDFLARE_AI_GATEWAY_ID && env.CF_ACCOUNT_ID) {
    // Default to anthropic provider for the gateway URL construction
    // The actual provider (openai/anthropic) is determined by the URL suffix in Moltbot
    // But since the guide uses this for both, we need to pick one.
    // However, start-moltbot.sh controls the actual provider config based on the URL.
    // Let's assume Anthropic as default if not specified, but check model name.

    let provider = 'anthropic';
    if (env.CF_AI_GATEWAY_MODEL?.startsWith('google/') || env.CF_AI_GATEWAY_MODEL?.includes('gemini')) {
      // For Gemini, we might need a different path or just standard OpenAI compatible endpoint
      // Cloudflare AI Gateway supports OpenAI-compatible endpoints for many providers
      provider = 'openai';
    }

    baseUrl = `https://gateway.ai.cloudflare.com/v1/${env.CF_ACCOUNT_ID}/${env.CLOUDFLARE_AI_GATEWAY_ID}/${provider}`;
  }

  const normalizedBaseUrl = baseUrl?.replace(/\/+$/, '');
  const isOpenAIGateway = normalizedBaseUrl?.endsWith('/openai');

  // AI Gateway vars take precedence
  // Map to the appropriate provider env var based on the gateway endpoint
  // AI Gateway vars take precedence
  // Map to the appropriate provider env var based on the gateway endpoint
  const apiKey = env.AI_GATEWAY_API_KEY || env.CLOUDFLARE_AI_GATEWAY_API_KEY;

  if (apiKey) {
    if (isOpenAIGateway) {
      envVars.OPENAI_API_KEY = apiKey;
    } else {
      envVars.ANTHROPIC_API_KEY = apiKey;
    }
  }

  // Fall back to direct provider keys
  if (!envVars.ANTHROPIC_API_KEY && env.ANTHROPIC_API_KEY) {
    envVars.ANTHROPIC_API_KEY = env.ANTHROPIC_API_KEY;
  }
  if (!envVars.OPENAI_API_KEY && env.OPENAI_API_KEY) {
    envVars.OPENAI_API_KEY = env.OPENAI_API_KEY;
  }

  // Pass base URL (used by start-moltbot.sh to determine provider)
  if (normalizedBaseUrl) {
    envVars.AI_GATEWAY_BASE_URL = normalizedBaseUrl;
    // Also set the provider-specific base URL env var
    if (isOpenAIGateway) {
      envVars.OPENAI_BASE_URL = normalizedBaseUrl;
    } else {
      envVars.ANTHROPIC_BASE_URL = normalizedBaseUrl;
    }
  } else if (env.ANTHROPIC_BASE_URL) {
    envVars.ANTHROPIC_BASE_URL = env.ANTHROPIC_BASE_URL;
  }
  // Map MOLTBOT_GATEWAY_TOKEN to CLAWDBOT_GATEWAY_TOKEN (container expects this name)
  if (env.MOLTBOT_GATEWAY_TOKEN) envVars.CLAWDBOT_GATEWAY_TOKEN = env.MOLTBOT_GATEWAY_TOKEN;
  if (env.DEV_MODE) envVars.CLAWDBOT_DEV_MODE = env.DEV_MODE; // Pass DEV_MODE as CLAWDBOT_DEV_MODE to container
  if (env.CLAWDBOT_BIND_MODE) envVars.CLAWDBOT_BIND_MODE = env.CLAWDBOT_BIND_MODE;
  if (env.TELEGRAM_BOT_TOKEN) envVars.TELEGRAM_BOT_TOKEN = env.TELEGRAM_BOT_TOKEN;
  if (env.TELEGRAM_DM_POLICY) envVars.TELEGRAM_DM_POLICY = env.TELEGRAM_DM_POLICY;
  if (env.DISCORD_BOT_TOKEN) envVars.DISCORD_BOT_TOKEN = env.DISCORD_BOT_TOKEN;
  if (env.DISCORD_DM_POLICY) envVars.DISCORD_DM_POLICY = env.DISCORD_DM_POLICY;
  if (env.SLACK_BOT_TOKEN) envVars.SLACK_BOT_TOKEN = env.SLACK_BOT_TOKEN;
  if (env.SLACK_APP_TOKEN) envVars.SLACK_APP_TOKEN = env.SLACK_APP_TOKEN;
  if (env.CDP_SECRET) envVars.CDP_SECRET = env.CDP_SECRET;
  if (env.WORKER_URL) envVars.WORKER_URL = env.WORKER_URL;
  if (env.WORKER_URL) envVars.WORKER_URL = env.WORKER_URL;
  if (env.CF_ACCOUNT_ID) envVars.CF_ACCOUNT_ID = env.CF_ACCOUNT_ID;
  if (env.CF_AI_GATEWAY_MODEL) envVars.CF_AI_GATEWAY_MODEL = env.CF_AI_GATEWAY_MODEL;

  return envVars;
}

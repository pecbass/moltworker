import type { Sandbox, Process } from '@cloudflare/sandbox';
import type { MoltbotEnv } from '../types';
import { MOLTBOT_PORT, STARTUP_TIMEOUT_MS } from '../config';
import { buildEnvVars } from './env';
import { mountR2Storage } from './r2';

/**
 * Find all existing Moltbot gateway processes
 * 
 * @param sandbox - The sandbox instance
 * @returns Array of found processes
 */
export async function findExistingMoltbotProcesses(sandbox: Sandbox): Promise<Process[]> {
  const found: Process[] = [];
  try {
    const processes = await sandbox.listProcesses();
    for (const proc of processes) {
      // Only match the gateway process
      const isGatewayProcess =
        proc.command.includes('start-moltbot.sh') ||
        proc.command.includes('clawdbot gateway');
      const isCliCommand =
        proc.command.includes('clawdbot devices') ||
        proc.command.includes('clawdbot --version');

      if (isGatewayProcess && !isCliCommand) {
        found.push(proc);
      }
    }
  } catch (e) {
    console.log('Could not list processes:', e);
  }
  return found;
}

/**
 * Legacy wrapper for compatibility
 */
export async function findExistingMoltbotProcess(sandbox: Sandbox): Promise<Process | null> {
  const processes = await findExistingMoltbotProcesses(sandbox);
  return processes.find(p => p.status === 'running' || p.status === 'starting') || null;
}

/**
 * Ensure the Moltbot gateway is running
 * 
 * This will:
 * 1. Mount R2 storage if configured
 * 2. Check for an existing gateway process
 * 3. Wait for it to be ready, or start a new one
 * 
 * @param sandbox - The sandbox instance
 * @param env - Worker environment bindings
 * @returns The running gateway process
 */
export async function ensureMoltbotGateway(sandbox: Sandbox, env: MoltbotEnv): Promise<Process> {
  // Mount R2 storage for persistent data (non-blocking if not configured)
  await mountR2Storage(sandbox, env);

  // Find ALL potentially conflicting processes
  const existingProcesses = await findExistingMoltbotProcesses(sandbox);

  // If there are multiple, or one that is not responsive, kill them all
  // to ensure a clean slate and avoid port conflicts.
  if (existingProcesses.length > 0) {
    console.log(`Found ${existingProcesses.length} existing Moltbot processes. Cleaning up...`);
    for (const proc of existingProcesses) {
      console.log(`Killing process ${proc.id} (status: ${proc.status})...`);
      try {
        await proc.kill();
      } catch (e) {
        console.log(`Failed to kill process ${proc.id}:`, e);
      }
    }
    // Give it a moment to release ports
    await new Promise(resolve => setTimeout(resolve, 2000));
  }

  // Start a new Moltbot gateway
  console.log('Starting new Moltbot gateway...');
  const envVars = buildEnvVars(env);
  const command = '/usr/local/bin/start-moltbot.sh';

  console.log('Starting process with command:', command);
  console.log('Environment vars being passed:', Object.keys(envVars));

  let process: Process;
  try {
    process = await sandbox.startProcess(command, {
      env: Object.keys(envVars).length > 0 ? envVars : undefined,
    });
    console.log('Process started with id:', process.id, 'status:', process.status);
  } catch (startErr) {
    console.error('Failed to start process:', startErr);
    throw startErr;
  }

  // Wait for the gateway to be ready
  try {
    console.log('[Gateway] Waiting for Moltbot gateway to be ready on port', MOLTBOT_PORT);
    await process.waitForPort(MOLTBOT_PORT, { mode: 'tcp', timeout: STARTUP_TIMEOUT_MS });
    console.log('[Gateway] Moltbot gateway is ready!');

    const logs = await process.getLogs();
    if (logs.stdout) console.log('[Gateway] stdout:', logs.stdout);
    if (logs.stderr) console.log('[Gateway] stderr:', logs.stderr);
  } catch (e) {
    console.error('[Gateway] waitForPort failed:', e);
    try {
      const logs = await process.getLogs();
      console.error('[Gateway] startup failed. Stderr:', logs.stderr);
      console.error('[Gateway] startup failed. Stdout:', logs.stdout);
      throw new Error(`Moltbot gateway failed to start. Stderr: ${logs.stderr || '(empty)'}`);
    } catch (logErr) {
      console.error('[Gateway] Failed to get logs:', logErr);
      throw e;
    }
  }

  // Verify gateway is actually responding
  console.log('[Gateway] Verifying gateway health...');

  return process;
}

import express, { Request, Response, NextFunction } from 'express';
import rateLimit from 'express-rate-limit';
import { readdir } from 'fs/promises';
import { open } from 'fs/promises';
import { exec } from 'child_process';
import { promisify } from 'util';
import { constants } from 'fs';
import { Server } from 'http';
import { createHash, createPublicKey, verify } from 'crypto';

const execAsync = promisify(exec);

const app = express();
const PORT = process.env.PORT || 3456;
const LISTEN_ADDRESS = process.env.LISTEN_ADDRESS || '127.0.0.1';
const PIPES_DIR = '/var/lib/secure-unlocker/pipes';
const SUDO = '/run/wrappers/bin/sudo';
const SYSTEMCTL = '/run/current-system/sw/bin/systemctl';
const PUBLIC_DIR = process.env.PUBLIC_DIR || '/var/lib/secure-unlocker/public';
const ALLOWED_PUBLIC_KEYS = process.env.ALLOWED_PUBLIC_KEYS?.split(',').filter(s => s) || [];

// Rate limiting configuration
// Strict rate limiter for authentication failures - prevents brute force signature attacks
const authFailureLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 20, // Limit each IP to 20 failed authentication attempts per 15 minutes
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many failed authentication attempts, please try again later' },
  skipSuccessfulRequests: true, // Only count failed authentication attempts
});

// Strict rate limiter for mount/unmount operations - prevents brute force password attacks
const mountLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 10, // Limit each IP to 10 failed mount attempts per 15 minutes
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many failed mount attempts, please try again later' },
  skipSuccessfulRequests: true, // Only count failed attempts
});

// Ed25519 signature verification middleware
function verifySignature(req: Request, res: Response, next: NextFunction): void {
  // Skip authentication for static files and health endpoint
  if (req.path === '/health' || req.path.startsWith('/icon') ||
      req.path === '/manifest.json' || req.path === '/sw.js' || req.path === '/') {
    next();
    return;
  }

  // If no allowed public keys configured, deny all API requests
  if (ALLOWED_PUBLIC_KEYS.length === 0) {
    res.status(503).json({ error: 'Authentication not configured' });
    return;
  }

  const signature = req.headers['x-signature'] as string;
  const timestamp = req.headers['x-timestamp'] as string;
  const publicKey = req.headers['x-public-key'] as string;

  if (!signature || !timestamp || !publicKey) {
    res.status(401).json({ error: 'Missing authentication headers' });
    return;
  }

  try {
    // Check if the public key is in the allowed list
    if (!ALLOWED_PUBLIC_KEYS.includes(publicKey.toLowerCase())) {
      res.status(401).json({ error: 'Authentication failed' });
      return;
    }

    // Check timestamp is within 5 minutes
    const now = Math.floor(Date.now() / 1000);
    const requestTimestamp = parseInt(timestamp, 10);
    if (isNaN(requestTimestamp) || Math.abs(now - requestTimestamp) > 300) {
      res.status(401).json({ error: 'Authentication failed' });
      return;
    }

    // Build the message to verify
    const method = req.method;
    // Use originalUrl to include query parameters in signature
    const url = req.originalUrl;

    // Always compute body hash for consistency (empty string if no body)
    // Check if body exists and is not empty object
    const bodyStr = (req.body && Object.keys(req.body).length > 0) ? JSON.stringify(req.body) : '';
    const bodyHash = createHash('sha256').update(bodyStr).digest('hex');

    const message = `${method}:${url}:${timestamp}:${bodyHash}`;

    // Debug logging
    console.log('Server verification:', {
      method,
      url,
      timestamp,
      bodyStr,
      bodyHash,
      message,
      signature
    });

    // Verify Ed25519 signature
    const signatureBuffer = Buffer.from(signature, 'hex');
    const messageBuffer = Buffer.from(message, 'utf8');

    // Ed25519 public keys in Node.js crypto need to be in PEM or DER format
    // The client will send the raw 32-byte public key in hex
    // We need to wrap it in the SPKI DER structure for Ed25519
    const rawPublicKey = Buffer.from(publicKey, 'hex');

    // SPKI DER prefix for Ed25519 public keys
    // This is the standard ASN.1 DER encoding for Ed25519 public keys
    const spkiPrefix = Buffer.from([
      0x30, 0x2a, // SEQUENCE, length 42
      0x30, 0x05, // SEQUENCE, length 5
      0x06, 0x03, 0x2b, 0x65, 0x70, // OID 1.3.101.112 (Ed25519)
      0x03, 0x21, 0x00, // BIT STRING, length 33, no unused bits
    ]);
    const derPublicKey = Buffer.concat([spkiPrefix, rawPublicKey]);

    const keyObject = createPublicKey({
      key: derPublicKey,
      format: 'der',
      type: 'spki',
    });

    const verified = verify(
      null, // Ed25519 doesn't use a digest algorithm
      messageBuffer,
      keyObject,
      signatureBuffer
    );

    if (!verified) {
      console.log('Signature verification failed - signature did not match message');
      res.status(401).json({ error: 'Authentication failed' });
      return;
    }

    console.log('Signature verification successful');

    next();
  } catch (error) {
    console.error('Signature verification error:', error);
    res.status(401).json({ error: 'Signature verification failed' });
  }
}

async function tryListen(maxWaitMs = 60000, intervalMs = 1000): Promise<Server> {
  const startTime = Date.now();

  while (true) {
    try {
      return await new Promise<Server>((resolve, reject) => {
        const server = app.listen(Number(PORT), LISTEN_ADDRESS, () => {
          console.log(`Secure Unlocker server listening on ${LISTEN_ADDRESS}:${PORT}`);
          resolve(server);
        });

        server.on('error', (err: NodeJS.ErrnoException) => {
          server.close();
          reject(err);
        });
      });
    } catch (error) {
      const err = error as NodeJS.ErrnoException;

      // If address not available yet (EADDRNOTAVAIL), keep retrying
      if (err.code === 'EADDRNOTAVAIL' || err.code === 'EADDRINUSE') {
        if (Date.now() - startTime > maxWaitMs) {
          throw new Error(`Timed out waiting for address ${LISTEN_ADDRESS} to become available`);
        }
        console.log(`Address ${LISTEN_ADDRESS} not available yet, retrying in ${intervalMs}ms... (${err.code})`);
        await new Promise(resolve => setTimeout(resolve, intervalMs));
        continue;
      }

      // For other errors, throw immediately
      throw error;
    }
  }
}

app.use(express.json());
app.use(express.static(PUBLIC_DIR));

// Apply auth failure rate limiting to API routes (before signature verification)
app.use(authFailureLimiter);

// Apply signature verification to all routes
app.use(verifySignature);

app.get('/health', (req: Request, res: Response) => {
  res.json({ status: 'ok' });
});

app.get('/list', async (req: Request, res: Response) => {
  try {
    const files = await readdir(PIPES_DIR);

    const statusPromises = files.map(async (name) => {
      try {
        // Check if the systemd service is active (which means it's mounted)
        const { stdout } = await execAsync(`${SUDO} ${SYSTEMCTL} is-active secure-unlocker-${name}.service`);
        const isActive = stdout.trim() === 'active';
        return { name, status: isActive ? 'mounted' : 'unmounted' };
      } catch (error) {
        // Service not active or doesn't exist
        return { name, status: 'unmounted' };
      }
    });

    const statusResults = await Promise.all(statusPromises);

    // Convert array to object with mount names as keys
    const statusObject = statusResults.reduce((acc, { name, status }) => {
      acc[name] = status;
      return acc;
    }, {} as Record<string, string>);

    res.json(statusObject);
  } catch (error) {
    res.status(500).json({
      error: 'Failed to read pipes directory',
      message: error instanceof Error ? error.message : 'Unknown error'
    });
  }
});

app.post('/mount/:name', mountLimiter, async (req: Request, res: Response) => {
  try {
    const { name } = req.params;
    const { password } = req.body;

    // Validate name to prevent path traversal and injection attacks
    const nameRegex = /^[a-zA-Z0-9._-]+$/;
    if (!nameRegex.test(name)) {
      res.status(400).json({ error: 'Invalid name format. Only alphanumeric characters, dots, hyphens, and underscores are allowed.' });
      return;
    }

    if (!password) {
      res.status(400).json({ error: 'Password is required in request body' });
      return;
    }

    // Check if already mounted
    try {
      const { stdout: statusOut } = await execAsync(`${SUDO} ${SYSTEMCTL} is-active secure-unlocker-${name}.service`);
      if (statusOut.trim() === 'active') {
        // Service is active, meaning it's already mounted
        res.status(400).json({ error: 'Already mounted' });
        return;
      }
    } catch {
      // Service not active, continue with mount
    }

    // Ensure the service is running and waiting for the password
    try {
      // Reset any failed state first
      await execAsync(`${SUDO} ${SYSTEMCTL} reset-failed secure-unlocker-${name}.service 2>/dev/null || true`);
      // Start the service
      await execAsync(`${SUDO} ${SYSTEMCTL} start secure-unlocker-${name}.service`);
      // Give it a moment to start and open the pipe
      await new Promise(resolve => setTimeout(resolve, 500));
    } catch (error) {
      res.status(500).json({
        error: 'Failed to start mount service',
        message: error instanceof Error ? error.message : 'Unknown error'
      });
      return;
    }

    const pipePath = `${PIPES_DIR}/${name}`;

    // Open the pipe in non-blocking write mode
    const fd = await open(pipePath, constants.O_WRONLY | constants.O_NONBLOCK);
    try {
      await fd.writeFile(password + '\n');
    } finally {
      await fd.close();
    }

    res.json({ success: true });
  } catch (error) {
    res.status(500).json({
      error: 'Failed to write to pipe',
      message: error instanceof Error ? error.message : 'Unknown error'
    });
  }
});

app.post('/unmount/:name', mountLimiter, async (req: Request, res: Response) => {
  try {
    const { name } = req.params;

    // Validate name to prevent path traversal and injection attacks
    const nameRegex = /^[a-zA-Z0-9._-]+$/;
    if (!nameRegex.test(name)) {
      res.status(400).json({ error: 'Invalid name format. Only alphanumeric characters, dots, hyphens, and underscores are allowed.' });
      return;
    }

    // First, check if the service is active
    try {
      const { stdout } = await execAsync(`${SUDO} ${SYSTEMCTL} is-active secure-unlocker-${name}.service`);
      if (stdout.trim() !== 'active') {
        res.status(400).json({ error: 'Mount is not active' });
        return;
      }
    } catch (error) {
      res.status(400).json({ error: 'Mount is not active' });
      return;
    }

    // Stop the service - this will trigger ExecStop which handles unmount and cleanup
    await execAsync(`${SUDO} ${SYSTEMCTL} stop secure-unlocker-${name}.service`);

    res.json({ success: true });
  } catch (error) {
    res.status(500).json({
      error: 'Failed to unmount',
      message: error instanceof Error ? error.message : 'Unknown error'
    });
  }
});

async function main() {
  await tryListen();
}

main().catch((error) => {
  console.error('Failed to start server:', error);
  process.exit(1);
});

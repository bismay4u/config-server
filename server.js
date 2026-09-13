require('dotenv').config({ quiet: true });

const express = require('express');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const createAdminRouter = require('./admin');

const PORT = process.env.PORT || 4000;
const DATA_FILE = path.join(__dirname, 'config-store.enc');

// Master secret used to derive the encryption key. MUST be set in production
// and kept out of source control (env var, secrets manager, etc).
const MASTER_SECRET = process.env.CONFIG_MASTER_KEY;
if (!MASTER_SECRET) {
  console.error('FATAL: CONFIG_MASTER_KEY env var is not set. Refusing to start.');
  process.exit(1);
}

// API key clients must present. No insecure default — refuse to start
// rather than silently accepting a well-known key.
const API_KEY = process.env.CONFIG_API_KEY;
if (!API_KEY) {
  console.error('FATAL: CONFIG_API_KEY env var is not set. Refusing to start.');
  process.exit(1);
}

const app = express();
app.use(express.json());
app.use((req, res, next) => {
  res.on('finish', () => {
    console.log(`${req.method} ${req.originalUrl} ${res.statusCode}`);
  });
  next();
});

const ALGO = 'aes-256-gcm';
const SALT_LEN = 16;
const IV_LEN = 12; // recommended for GCM
const KEY_LEN = 32; // 256 bits

function deriveKey(salt) {
  // scrypt is deliberately slow/memory-hard to resist brute force on the secret
  return crypto.scryptSync(MASTER_SECRET, salt, KEY_LEN);
}

function encrypt(plaintext) {
  const salt = crypto.randomBytes(SALT_LEN);
  const iv = crypto.randomBytes(IV_LEN);
  const key = deriveKey(salt);
  const cipher = crypto.createCipheriv(ALGO, key, iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  const authTag = cipher.getAuthTag();
  // Store salt|iv|authTag|ciphertext together, base64 encoded
  return Buffer.concat([salt, iv, authTag, ciphertext]).toString('base64');
}

function decrypt(payloadB64) {
  const payload = Buffer.from(payloadB64, 'base64');
  const salt = payload.subarray(0, SALT_LEN);
  const iv = payload.subarray(SALT_LEN, SALT_LEN + IV_LEN);
  const authTag = payload.subarray(SALT_LEN + IV_LEN, SALT_LEN + IV_LEN + 16);
  const ciphertext = payload.subarray(SALT_LEN + IV_LEN + 16);
  const key = deriveKey(salt);
  const decipher = crypto.createDecipheriv(ALGO, key, iv);
  decipher.setAuthTag(authTag);
  const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  return plaintext.toString('utf8');
}

// ---- storage helpers ----
function loadStore() {
  if (!fs.existsSync(DATA_FILE)) return {};
  try {
    const encoded = fs.readFileSync(DATA_FILE, 'utf8');
    return JSON.parse(decrypt(encoded));
  } catch (err) {
    // Fail loudly rather than silently starting with an empty store, which
    // would look like (or cause) accidental data loss. Most likely causes:
    // wrong CONFIG_MASTER_KEY or a corrupted data file.
    console.error('FATAL: failed to read/decrypt existing store:', err.message);
    process.exit(1);
  }
}

function saveStore(store) {
  const encoded = encrypt(JSON.stringify(store));
  fs.writeFileSync(DATA_FILE, encoded);
}

let store = loadStore();

// Property names that could pollute the store's prototype if used as a key
// (e.g. via PUT /config/__proto__ or admin bulk import).
const UNSAFE_KEYS = new Set(['__proto__', 'constructor', 'prototype']);
function isUnsafeKey(key) {
  return UNSAFE_KEYS.has(key);
}

// ---- auth middleware ----
const API_KEY_BUF = Buffer.from(API_KEY, 'utf8');

function requireApiKey(req, res, next) {
  const key = req.header('x-api-key');
  const keyBuf = Buffer.from(key || '', 'utf8');
  // Constant-time comparison to avoid leaking key length/content via timing.
  const valid = keyBuf.length === API_KEY_BUF.length &&
    crypto.timingSafeEqual(keyBuf, API_KEY_BUF);
  if (!valid) {
    return res.status(401).json({ error: 'Invalid or missing API key' });
  }
  next();
}

// ---- routes ----

// Health check — no auth required, for load balancers/orchestrators.
app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

app.use(requireApiKey);

// Admin/management routes (stats, export/import, clear, reload) — see admin.js.
app.use('/admin', createAdminRouter({
  getStore: () => store,
  replaceStore: (newStore) => { store = newStore; },
  persist: () => saveStore(store),
  reload: () => { store = loadStore(); },
  dataFile: DATA_FILE,
  isUnsafeKey,
}));

// Get all keys
app.get('/config', (req, res) => {
  res.json(store);
});

// Get one key
app.get('/config/:key', (req, res) => {
  const { key } = req.params;
  if (!(key in store)) {
    return res.status(404).json({ error: `Key '${key}' not found` });
  }
  res.json({ key, value: store[key] });
});

// Set/update a key
app.put('/config/:key', (req, res) => {
  const { key } = req.params;
  const { value } = req.body;
  if (isUnsafeKey(key)) {
    return res.status(400).json({ error: `Key '${key}' is not allowed` });
  }
  if (value === undefined) {
    return res.status(400).json({ error: 'Request body must include "value"' });
  }
  store[key] = value;
  saveStore(store);
  res.json({ key, value });
});

// Delete a key
app.delete('/config/:key', (req, res) => {
  const { key } = req.params;
  if (!(key in store)) {
    return res.status(404).json({ error: `Key '${key}' not found` });
  }
  delete store[key];
  saveStore(store);
  res.json({ deleted: key });
});

const server = app.listen(PORT, () => {
  console.log(`Config server running on port ${PORT}`);
});

function shutdown(signal) {
  console.log(`${signal} received, shutting down gracefully`);
  server.close(() => {
    console.log('Server closed');
    process.exit(0);
  });
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
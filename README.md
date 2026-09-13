# Config Server

A minimal HTTP key-value configuration store, protected by a static API key and
persisted to disk with AES-256-GCM encryption at rest.

## Features

- Simple REST API to get, set, and delete config keys
- Single API-key auth (`x-api-key` header) required on every route except `/health`, using a constant-time comparison
- Encrypted persistence — the store is never written to disk in plaintext
  - Key derivation via `scrypt` from a master secret (`CONFIG_MASTER_KEY`)
  - Per-write random salt + IV, with an AES-GCM auth tag for integrity
- `.env` file support via `dotenv`
- Fails loudly (non-zero exit) instead of silently degrading if a required secret is missing or the data file can't be decrypted
- `/health` endpoint for load balancers/orchestrators
- Graceful shutdown on `SIGINT`/`SIGTERM`
- Basic request logging (method, path, status)
- Admin/management routes ([admin.js](admin.js)) for stats, bulk export/import, clearing, and reloading the store
- Guards against prototype-pollution keys (`__proto__`, `constructor`, `prototype`) in both the regular and admin write paths

## Requirements

- Node.js 18+
- npm

## Setup

```bash
npm install
```

Create a `.env` file in the project root:

```bash
CONFIG_MASTER_KEY=<a long, random secret — required, server refuses to start without it>
CONFIG_API_KEY=<the API key clients must send — required, server refuses to start without it>
PORT=4000  # optional, defaults to 4000
```

`.env` is gitignored — never commit it.

Run the server:

```bash
npm start
```

## Environment Variables

| Variable            | Required | Default | Purpose                                                                 |
|---------------------|----------|---------|--------------------------------------------------------------------------|
| `CONFIG_MASTER_KEY`  | Yes      | —       | Secret used to derive the AES-256 encryption key. Server exits if unset. |
| `CONFIG_API_KEY`     | Yes      | —       | API key clients must send in the `x-api-key` header. Server exits if unset. |
| `PORT`               | No       | `4000`  | Port the HTTP server listens on.                                         |

## API

A full [OpenAPI 3.0 spec](openapi.yaml) documents every route, request/response
shape, and error case — load it into Swagger UI, Redoc, Postman, etc.

All routes except `/health` require the header:

```
x-api-key: <CONFIG_API_KEY>
```

Requests without a valid key receive `401 { "error": "Invalid or missing API key" }`.

### Health check

```
GET /health
```

Response: `200 { "status": "ok" }` — no API key required.

### Get all config keys

```
GET /config
```

Response: `200 { "<key>": "<value>", ... }`

### Get a single key

```
GET /config/:key
```

- `200 { "key": "...", "value": "..." }`
- `404 { "error": "Key '...' not found" }`

### Set (create or update) a key

```
PUT /config/:key
Content-Type: application/json

{ "value": <any JSON value> }
```

- `200 { "key": "...", "value": "..." }`
- `400 { "error": "Request body must include \"value\"" }`

### Delete a key

```
DELETE /config/:key
```

- `200 { "deleted": "..." }`
- `404 { "error": "Key '...' not found" }`

## Admin / Management API

Defined in [admin.js](admin.js) and mounted at `/admin`, behind the same
`x-api-key` requirement as `/config`. There is currently no separate admin
privilege tier — anyone with the API key can use these routes.

### Stats

```
GET /admin/stats
```

`200 { "keyCount": <n>, "uptimeSeconds": <n>, "dataFile": "<path>", "dataFileBytes": <n|null> }`

### Export (full dump, for backups/migration)

```
GET /admin/export
```

`200 { "<key>": "<value>", ... }` — same shape as `GET /config`.

### Import (bulk load)

```
POST /admin/import
Content-Type: application/json

{ "data": { "<key>": <value>, ... }, "mode": "merge" | "replace" }
```

`mode` defaults to `"merge"` (existing keys not present in `data` are kept);
`"replace"` wipes the store and replaces it with exactly `data`.

- `200 { "imported": <n>, "mode": "merge" | "replace" }`
- `400` if `data` is missing/not an object, or contains an unsafe key (see below)

### Clear (wipe everything)

```
DELETE /admin/clear
```

`200 { "cleared": <n> }` — `n` is the number of keys removed.

### Reload (discard in-memory state, re-read the encrypted file from disk)

```
POST /admin/reload
```

`200 { "reloaded": true, "keyCount": <n> }` — useful if `config-store.enc` was
modified out-of-band (e.g. restored from a backup) while the server was running.

## Data Storage & Security

- Config is kept in memory and persisted to `config-store.enc` in the project
  root after every write (gitignored).
- Encryption: AES-256-GCM, key derived per-write via `scrypt(MASTER_SECRET, salt)`.
  The file format is `salt (16B) | iv (12B) | authTag (16B) | ciphertext`, base64-encoded.
- If the data file exists but fails to decrypt (wrong `CONFIG_MASTER_KEY` or
  corruption), the server logs a fatal error and exits rather than silently
  starting with an empty store.

## Testing

Curl-driven functional test suites live in [tests/curl-tests.sh](tests/curl-tests.sh)
(auth enforcement, the full CRUD flow, non-string values, health check) and
[tests/curl-tests-admin.sh](tests/curl-tests-admin.sh) (stats, export, import
in both merge/replace modes, clear, reload, and the prototype-pollution guard).
Both run against a **running** server instance.

```bash
npm start &            # start the server
npm test                # runs both suites (reads CONFIG_API_KEY from .env)
```

Override the target with `BASE_URL` and/or `CONFIG_API_KEY` env vars if needed.

## Known Limitations / Not Yet Implemented

The server is functional for a single trusted client but is missing a few
things you'd likely want before production use:

- **No concurrency/multi-instance support** — the store is a single in-memory
  object with no file locking; running multiple instances against the same
  data file, or handling concurrent writes, can cause lost updates.
- **No input validation** — no size/type limits on keys or values.
- **No HTTPS/TLS** — expects to sit behind a reverse proxy (e.g. nginx, Caddy)
  for encryption in transit.
- **No automated CI** — the curl test suite is manual/local only; there's no
  workflow wiring it into a pipeline.
- **No structured audit trail** — request logging is basic (method/path/status
  to stdout), with no record of *who* (beyond "held a valid API key") changed
  a given key.
- **No separate admin privilege tier** — `/admin/*` (including destructive
  `DELETE /admin/clear`) is gated by the same `CONFIG_API_KEY` as regular
  config reads/writes, not a distinct admin credential or role.

## License

MIT

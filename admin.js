const express = require('express');
const fs = require('fs');

// Admin/management routes for the config store: stats, bulk export/import,
// clearing everything, and forcing a reload from disk. Mounted by server.js
// under /admin, behind the same requireApiKey middleware as everything else.
//
// `deps` is supplied by server.js and must provide:
// - getStore(): returns the current in-memory store object
// - replaceStore(obj): swaps the in-memory store for `obj`
// - persist(): encrypts and writes the current in-memory store to disk
// - reload(): discards in-memory state and reloads the store from disk
// - dataFile: absolute path to the encrypted store file (for stats)
// - isUnsafeKey(key): true if `key` could pollute the store's prototype
function createAdminRouter(deps) {
  const { getStore, replaceStore, persist, reload, dataFile, isUnsafeKey } = deps;
  const router = express.Router();
  const startedAt = Date.now();

  // GET /admin/stats - operational info about the running server/store
  router.get('/stats', (req, res) => {
    let dataFileBytes = null;
    try {
      dataFileBytes = fs.statSync(dataFile).size;
    } catch {
      dataFileBytes = null;
    }
    res.json({
      keyCount: Object.keys(getStore()).length,
      uptimeSeconds: Math.floor((Date.now() - startedAt) / 1000),
      dataFile,
      dataFileBytes,
    });
  });

  // GET /admin/export - full dump of the store, for backups/migration
  router.get('/export', (req, res) => {
    res.json(getStore());
  });

  // POST /admin/import - bulk load keys
  // Body: { "data": { "<key>": <value>, ... }, "mode": "merge" | "replace" }
  // mode defaults to "merge" (existing keys not in `data` are kept).
  router.post('/import', (req, res) => {
    const { data, mode } = req.body || {};
    if (typeof data !== 'object' || data === null || Array.isArray(data)) {
      return res.status(400).json({ error: 'Request body must include a "data" object' });
    }
    const unsafeKey = Object.keys(data).find(isUnsafeKey);
    if (unsafeKey) {
      return res.status(400).json({ error: `Key '${unsafeKey}' is not allowed` });
    }

    if (mode === 'replace') {
      replaceStore({ ...data });
    } else {
      Object.assign(getStore(), data);
    }
    persist();
    res.json({ imported: Object.keys(data).length, mode: mode === 'replace' ? 'replace' : 'merge' });
  });

  // DELETE /admin/clear - wipe every config key
  router.delete('/clear', (req, res) => {
    const store = getStore();
    const cleared = Object.keys(store).length;
    for (const key of Object.keys(store)) delete store[key];
    persist();
    res.json({ cleared });
  });

  // POST /admin/reload - discard in-memory state, reload from the encrypted file
  router.post('/reload', (req, res) => {
    reload();
    res.json({ reloaded: true, keyCount: Object.keys(getStore()).length });
  });

  return router;
}

module.exports = createAdminRouter;

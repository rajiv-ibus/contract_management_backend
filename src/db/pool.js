const fs = require("fs");
const { Pool } = require("pg");

const config = require("../config");
const logger = require("../utils/logger");

function sslOptions() {
  if (config.DB_SSL_MODE === "require") return { rejectUnauthorized: false };
  if (config.DB_SSL_MODE === "verify-full") return { ca: fs.readFileSync(config.DB_SSL_CA_PATH, "utf8") };
  return false;
}

// Every connection works inside the application's own schema; public stays on the path for extensions.
const pool = new Pool({
  connectionString: config.DATABASE_URL,
  ssl: sslOptions(),
  options: `-c search_path=${config.DB_SCHEMA},public -c timezone=UTC`,
  max: 10,
});

pool.on("error", (err) => logger.error("Idle database client error", { err }));

async function query(text, params) {
  return pool.query(text, params);
}

// Runs fn(client) inside BEGIN/COMMIT; any thrown error rolls the whole unit back.
async function withTransaction(fn) {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }
}

module.exports = { pool, query, withTransaction };

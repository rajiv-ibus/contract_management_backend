/*
 * Applies db/migrations/NNNN_name.sql files in order, each in its own transaction.
 *
 *   npm run migrate          apply pending migrations
 *   npm run migrate:status   list applied and pending migrations
 *
 * - All objects are created in DB_SCHEMA (default ibus_cms), which is created if missing.
 * - An applied file is recorded in schema_migrations (name, checksum, applied_at) and never re-run.
 *   Editing an applied file is refused: add a new numbered file instead.
 */
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const config = require("../src/config");
const { pool } = require("../src/db/pool");

const DIR = path.join(__dirname, "..", "db", "migrations");
const statusOnly = process.argv.includes("--status");

function checksum(sql) {
  return crypto.createHash("sha256").update(sql).digest("hex");
}

async function main() {
  const files = fs.readdirSync(DIR).filter((f) => /^\d{4}_.+\.sql$/.test(f)).sort();
  const client = await pool.connect();
  try {
    await client.query(`CREATE SCHEMA IF NOT EXISTS ${config.DB_SCHEMA}`);
    await client.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
      name text PRIMARY KEY,
      checksum char(64) NOT NULL,
      applied_at timestamptz(3) NOT NULL DEFAULT now()
    )`);

    const { rows } = await client.query("SELECT name, checksum FROM schema_migrations ORDER BY name");
    const applied = new Map(rows.map((r) => [r.name, r.checksum]));

    for (const f of files) {
      const sql = fs.readFileSync(path.join(DIR, f), "utf8");
      const sum = checksum(sql);

      if (applied.has(f)) {
        if (applied.get(f) !== sum) {
          throw new Error(`${f} was changed after it was applied. Add a new migration instead of editing it.`);
        }
        if (statusOnly) console.log(`applied  ${f}`);
        continue;
      }

      if (statusOnly) {
        console.log(`pending  ${f}`);
        continue;
      }

      console.log(`applying ${f}`);
      await client.query("BEGIN");
      try {
        await client.query(sql);
        await client.query("INSERT INTO schema_migrations (name, checksum) VALUES ($1, $2)", [f, sum]);
        await client.query("COMMIT");
      } catch (err) {
        await client.query("ROLLBACK");
        throw new Error(`${f} failed: ${err.message}`);
      }
    }

    if (!statusOnly) console.log(`schema ${config.DB_SCHEMA} is up to date`);
  } finally {
    client.release();
    await pool.end();
  }
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});

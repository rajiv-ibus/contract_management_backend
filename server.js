const config = require("./src/config");
const logger = require("./src/utils/logger");
const { pool } = require("./src/db/pool");
const { createApp } = require("./src/app");

const server = createApp().listen(config.PORT, () => {
  logger.info(`Contract management API listening on port ${config.PORT} (${config.NODE_ENV})`);
});

function shutdown(signal) {
  logger.info(`${signal} received, shutting down`);
  server.close(async () => {
    await pool.end();
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 10000).unref();
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));

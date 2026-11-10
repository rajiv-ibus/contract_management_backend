const { test, before, after } = require("node:test");
const assert = require("node:assert/strict");

process.env.NODE_ENV = "test";
process.env.JWT_SECRET = "test-secret-that-is-at-least-32-characters-long";
// Nothing listens on port 1, so the health check sees the database as down without hanging.
process.env.DATABASE_URL = "postgresql://nobody:nothing@127.0.0.1:1/none";

const { createApp } = require("../src/app");
const { pool } = require("../src/db/pool");

let server;
let base;

before(async () => {
  server = createApp().listen(0);
  await new Promise((resolve) => server.once("listening", resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  await new Promise((resolve) => server.close(resolve));
  await pool.end();
});

test("unknown routes return a JSON 404", async () => {
  const res = await fetch(`${base}/api/does-not-exist`);
  assert.equal(res.status, 404);
  const body = await res.json();
  assert.equal(body.error.code, "NOT_FOUND");
});

test("malformed JSON returns a 400, not a 500", async () => {
  const res = await fetch(`${base}/api/health`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: "{not json",
  });
  assert.equal(res.status, 400);
  assert.equal((await res.json()).error.code, "BAD_REQUEST");
});

test("health reports the database as down when it cannot connect", async () => {
  const res = await fetch(`${base}/api/health`);
  assert.equal(res.status, 503);
  assert.deepEqual(await res.json(), { status: "degraded", database: "down" });
});

test("security headers are set and the framework is not advertised", async () => {
  const res = await fetch(`${base}/api/health`);
  assert.equal(res.headers.get("x-powered-by"), null);
  assert.equal(res.headers.get("x-content-type-options"), "nosniff");
});

const { Router } = require("express");

const db = require("../../db/pool");

const router = Router();

router.get("/", async (req, res) => {
  let database = "up";
  try {
    await db.query("SELECT 1");
  } catch {
    database = "down";
  }
  res.status(database === "up" ? 200 : 503).json({ status: database === "up" ? "ok" : "degraded", database });
});

module.exports = router;

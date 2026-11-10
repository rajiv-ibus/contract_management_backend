const AppError = require("../utils/AppError");
const logger = require("../utils/logger");

function notFound(req, res, next) {
  next(AppError.notFound(`Route ${req.method} ${req.path} not found`));
}

// eslint-disable-next-line no-unused-vars
function errorHandler(err, req, res, next) {
  if (err instanceof AppError) {
    return res.status(err.status).json({ error: { code: err.code, message: err.message, details: err.details } });
  }

  if (err.type === "entity.parse.failed") {
    return res.status(400).json({ error: { code: "BAD_REQUEST", message: "Malformed JSON body" } });
  }

  logger.error("Unhandled error", { err, method: req.method, path: req.path });
  return res.status(500).json({ error: { code: "INTERNAL_ERROR", message: "Something went wrong" } });
}

module.exports = { notFound, errorHandler };

const winston = require("winston");
require("winston-daily-rotate-file");

const config = require("../config");

const transports = [
  new winston.transports.Console({
    format:
      config.NODE_ENV === "production"
        ? winston.format.json()
        : winston.format.combine(winston.format.colorize(), winston.format.simple()),
  }),
];

if (config.NODE_ENV !== "test") {
  transports.push(
    new winston.transports.DailyRotateFile({
      dirname: "logs",
      filename: "app-%DATE%.log",
      datePattern: "YYYY-MM-DD",
      maxFiles: "30d",
      format: winston.format.json(),
    }),
  );
}

const logger = winston.createLogger({
  level: config.NODE_ENV === "production" ? "info" : "debug",
  format: winston.format.combine(winston.format.timestamp(), winston.format.errors({ stack: true })),
  transports,
  silent: config.NODE_ENV === "test",
});

module.exports = logger;

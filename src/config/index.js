require("dotenv").config({ quiet: true });

const { z } = require("zod");

// Defaults are applied to the raw env string, before it is transformed.
const bool = (fallback) =>
  z
    .enum(["true", "false"])
    .default(fallback)
    .transform((v) => v === "true");

const csv = (fallback = "") =>
  z
    .string()
    .default(fallback)
    .transform((v) =>
      v
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean),
    );

const int = (fallback) => z.coerce.number().int().positive().default(fallback);

const schema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
  PORT: int(4000),
  APP_BASE_URL: z.string().min(1).default("http://localhost:5173"),
  CORS_ORIGINS: csv(),

  DATABASE_URL: z.string().min(1, "DATABASE_URL is required"),
  DB_SCHEMA: z
    .string()
    .regex(/^[a-z_][a-z0-9_]*$/, "DB_SCHEMA must be a lowercase SQL identifier")
    .default("ibus_cms"),
  DB_SSL_MODE: z.enum(["disable", "require", "verify-full"]).default("disable"),
  DB_SSL_CA_PATH: z.string().default(""),

  JWT_SECRET: z.string().min(32, "JWT_SECRET must be at least 32 characters"),

  SPACES_ENDPOINT: z.string().default(""),
  SPACES_REGION: z.string().default(""),
  SPACES_BUCKET: z.string().default(""),
  SPACES_KEY: z.string().default(""),
  SPACES_SECRET: z.string().default(""),

  EMAIL_PROVIDER: z.enum(["SIMULATED", "EMAIL_API"]).default("SIMULATED"),
  EMAIL_API_URL: z.string().default(""),
  EMAIL_API_KEY: z.string().default(""),
  EMAIL_FROM: z.string().default("iBUS Contracts <no-reply@example.com>"),

  INVITE_TTL_HOURS: int(48),
  RESET_TTL_MINUTES: int(30),
  PASSWORD_MIN_LENGTH: int(8),
  PASSWORD_REQUIRE_LETTER_AND_NUMBER: bool("true"),
  LOGIN_MAX_FAILED_ATTEMPTS: int(5),
  LOGIN_LOCK_MINUTES: int(15),
  SESSION_TTL_HOURS: int(8),
  UPLOAD_ALLOWED_TYPES: csv("application/pdf"),
  UPLOAD_MAX_SIZE_MB: int(25),
  DOWNLOAD_URL_TTL_MINUTES: int(5),
  EMAIL_MAX_ATTEMPTS: int(5),
  EMAIL_EVENTS_ENABLED: csv("SUBMITTED,APPROVED,REJECTED,INVALIDATED"),
});

const parsed = schema.safeParse(process.env);

if (!parsed.success) {
  const problems = parsed.error.issues.map((i) => `  - ${i.path.join(".")}: ${i.message}`).join("\n");
  throw new Error(`Invalid configuration:\n${problems}`);
}

const env = parsed.data;

if (env.DB_SSL_MODE === "verify-full" && !env.DB_SSL_CA_PATH) {
  throw new Error("Invalid configuration:\n  - DB_SSL_CA_PATH: required when DB_SSL_MODE is verify-full");
}

module.exports = Object.freeze(env);

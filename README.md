# contract_management_backend

Backend for the iBUS Contract Management System: maker–checker approval for contract documents, with project-level access, immutable versions and a permanent audit trail.

Design reference: *iBUS Contract Management System — Architecture and Design Baseline v2.1*.

## Requirements

| Tool | Version |
| --- | --- |
| Node.js | 26.12.1 (see `.nvmrc`) |
| npm | 11.20.0 |
| PostgreSQL | 15 or later |

## Setup

```bash
npm install
cp .env.example .env    # then fill in DATABASE_URL and JWT_SECRET
npm run migrate         # creates schema ibus_cms and all tables
npm run dev             # http://localhost:4000/api/health
```

## Scripts

| Script | What it does |
| --- | --- |
| `npm start` | Start the API |
| `npm run dev` | Start the API and restart on file changes |
| `npm run migrate` | Apply pending SQL migrations in `db/migrations` |
| `npm run migrate:status` | List applied and pending migrations |
| `npm test` | Run the tests |

## Database

- Every table lives in the schema named by `DB_SCHEMA` (default `ibus_cms`). The app connects with `search_path = ibus_cms, public`.
- Migrations are numbered files, `db/migrations/NNNN_name.sql`. Each runs once, in a transaction, and is recorded in `schema_migrations` with its checksum. Never edit an applied file; add a new one.
- The `citext` extension is created in `public` by the first migration. On a managed database where the app user cannot create extensions, ask the database owner to run `CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;` first.
- Rules such as immutable versions, the approval lock and "no delete" are enforced by constraints and triggers in the database, not only in code.

### Creating a Super Admin

Super Admins are created only by a direct database change. Insert the user, then use **Forgot password** in the app to set the password:

```sql
SET search_path = ibus_cms, public;

INSERT INTO users (full_name, email, user_role, status, created_by, updated_by)
VALUES ('Full Name', 'name@example.com', 'SUPER_ADMIN', 'INVITED',
        '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001');
```

`00000000-0000-0000-0000-000000000001` is the built-in SYSTEM user, which records automated and seeded changes.

## Tests

```bash
npm test
```

`tests/schema.test.js` checks the database rules against a real PostgreSQL. It is skipped unless `TEST_DATABASE_URL` is set; it creates and drops its own schema `cms_schema_test`.

```bash
TEST_DATABASE_URL=postgresql://user:password@localhost:5432/contract_management_system_dev npm test
```

## Project structure

```text
server.js              entry point
src/
  app.js               Express app: security middleware, routes, error handling
  config/              environment loading and validation
  db/                  connection pool and transactions
  middleware/          shared middleware
  modules/             one folder per feature (routes, controller, service, repository)
  utils/               logger, errors
db/migrations/         numbered SQL migrations
scripts/migrate.cjs    migration runner
tests/                 node:test suites
```

/*
 * Checks the database rules in db/migrations against a real PostgreSQL.
 * Runs only when TEST_DATABASE_URL is set; it creates and drops its own schema (cms_schema_test).
 */
const { test, before, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");
const { Client } = require("pg");

const url = process.env.TEST_DATABASE_URL;
const SCHEMA = "cms_schema_test";
const SYSTEM = "00000000-0000-0000-0000-000000000001";
const HASH = "a".repeat(64);

const opts = { skip: url ? false : "TEST_DATABASE_URL not set" };

let db;

async function expectRejected(promise, pattern) {
  await assert.rejects(promise, (err) => {
    assert.match(err.message, pattern);
    return true;
  });
}

// Builds one project with a category, a type, an active template and a draft document with its PDF.
async function seedDraft() {
  const one = async (sql, params) => (await db.query(sql, params)).rows[0];

  const project = await one(
    `INSERT INTO projects (project_code, project_name, created_by, updated_by)
     VALUES ('P' || substr(md5(random()::text), 1, 8), 'Project ' || md5(random()::text), $1, $1) RETURNING project_id`,
    [SYSTEM],
  );
  const category = await one(
    `INSERT INTO document_categories (project_id, category_code, category_name, created_by, updated_by)
     VALUES ($1, 'LEASE', 'Leases', $2, $2) RETURNING category_id`,
    [project.project_id, SYSTEM],
  );
  const type = await one(
    `INSERT INTO document_types (project_id, category_id, type_code, type_name, created_by, updated_by)
     VALUES ($1, $2, 'HOTEL_LEASE', 'Hotel Lease', $3, $3) RETURNING document_type_id`,
    [project.project_id, category.category_id, SYSTEM],
  );
  const schemaVersion = await one(
    `INSERT INTO metadata_schema_versions (document_type_id, schema_version_no, schema_json, content_hash, created_by, updated_by)
     VALUES ($1, 1, '{"fields":[]}', $2, $3, $3) RETURNING schema_version_id`,
    [type.document_type_id, HASH, SYSTEM],
  );

  await db.query("BEGIN");
  const doc = await one(
    `INSERT INTO documents (project_id, document_type_id, title, note_id, working_schema_version_id, created_by, updated_by)
     VALUES ($1, $2, 'Lease', gen_random_uuid(), $3, $4, $4) RETURNING document_id, note_id`,
    [project.project_id, type.document_type_id, schemaVersion.schema_version_id, SYSTEM],
  );
  await db.query(`INSERT INTO notes (note_id, document_id, created_by, updated_by) VALUES ($1, $2, $3, $3)`, [
    doc.note_id,
    doc.document_id,
    SYSTEM,
  ]);
  const file = await one(
    `INSERT INTO storage_references (document_id, reference_type, region, bucket_name, object_key,
       original_file_name, content_type, size_bytes, file_hash, created_by, updated_by)
     VALUES ($1::uuid, 'SOURCE_UPLOAD', 'blr1', 'bucket', 'documents/' || $1::text || '/sources/a.pdf',
       'a.pdf', 'application/pdf', 100, $2, $3, $3) RETURNING storage_reference_id`,
    [doc.document_id, HASH, SYSTEM],
  );
  await db.query(`UPDATE documents SET draft_storage_reference_id = $1 WHERE document_id = $2`, [
    file.storage_reference_id,
    doc.document_id,
  ]);
  await db.query("COMMIT");

  return { ...project, ...type, ...schemaVersion, ...doc, fileId: file.storage_reference_id };
}

async function submit(d) {
  const one = async (sql, params) => (await db.query(sql, params)).rows[0];
  await db.query("BEGIN");
  const combined = await one(
    `INSERT INTO storage_references (document_id, reference_type, region, bucket_name, object_key,
       original_file_name, content_type, size_bytes, file_hash, created_by, updated_by)
     VALUES ($1::uuid, 'COMBINED_VERSION', 'blr1', 'bucket', 'documents/' || $1::text || '/versions/' || gen_random_uuid() || '.pdf',
       'combined.pdf', 'application/pdf', 200, $2, $3, $3) RETURNING storage_reference_id`,
    [d.document_id, HASH, SYSTEM],
  );
  const version = await one(
    `INSERT INTO document_versions (document_id, version_no, document_type_id, schema_version_id, metadata_json,
       source_storage_reference_id, storage_reference_id, created_by, updated_by)
     VALUES ($1, coalesce((SELECT max(version_no) FROM document_versions WHERE document_id = $1), 0) + 1,
       $2, $3, '{}', $4, $5, $6, $6) RETURNING version_id`,
    [d.document_id, d.document_type_id, d.schema_version_id, d.fileId, combined.storage_reference_id, SYSTEM],
  );
  await db.query(`UPDATE documents SET current_version_id = $1, workflow_status = 'APPROVAL_PENDING' WHERE document_id = $2`, [
    version.version_id,
    d.document_id,
  ]);
  await db.query("COMMIT");
  return { ...version, combinedId: combined.storage_reference_id };
}

before(async () => {
  if (!url) return;
  db = new Client({ connectionString: url });
  await db.connect();
  await db.query(`DROP SCHEMA IF EXISTS ${SCHEMA} CASCADE`);
  await db.query(`CREATE SCHEMA ${SCHEMA}`);
  await db.query(`SET search_path = ${SCHEMA}, public`);
  const dir = path.join(__dirname, "..", "db", "migrations");
  for (const f of fs.readdirSync(dir).filter((n) => n.endsWith(".sql")).sort()) {
    await db.query(fs.readFileSync(path.join(dir, f), "utf8"));
  }
});

after(async () => {
  if (!db) return;
  await db.query("ROLLBACK").catch(() => {});
  await db.query(`DROP SCHEMA IF EXISTS ${SCHEMA} CASCADE`);
  await db.end();
});

test("the SYSTEM actor is seeded and cannot hold a password", opts, async () => {
  const { rows } = await db.query(`SELECT user_role FROM users WHERE user_id = $1`, [SYSTEM]);
  assert.equal(rows[0].user_role, "SYSTEM");
  await expectRejected(db.query(`UPDATE users SET password_hash = 'x' WHERE user_id = $1`, [SYSTEM]), /users_system_has_no_password/);
});

test("a project Admin must be a Checker and every member needs a role", opts, async () => {
  const { project_id } = await seedDraft();
  const insert = (admin, make, check) =>
    db.query(
      `INSERT INTO project_memberships (project_id, user_id, is_admin, can_make, can_check, created_by, updated_by)
       VALUES ($1, $2, $3, $4, $5, $2, $2)`,
      [project_id, SYSTEM, admin, make, check],
    );
  await expectRejected(insert(true, true, false), /project_memberships_admin_is_checker/);
  await expectRejected(insert(false, false, false), /project_memberships_has_role/);
  await insert(true, false, true);
});

test("a draft that was never submitted can be soft-deleted, but not hard-deleted", opts, async () => {
  const d = await seedDraft();
  await expectRejected(db.query(`DELETE FROM documents WHERE document_id = $1`, [d.document_id]), /cannot be deleted/);
  await db.query(`UPDATE documents SET deleted_at = now(), deleted_by = $1 WHERE document_id = $2`, [SYSTEM, d.document_id]);
  await expectRejected(
    db.query(`UPDATE documents SET title = 'changed' WHERE document_id = $1`, [d.document_id]),
    /was deleted/,
  );
});

test("a submitted document cannot be deleted, even after going back to draft", opts, async () => {
  const d = await seedDraft();
  await submit(d);
  await db.query(`UPDATE documents SET workflow_status = 'DRAFT' WHERE document_id = $1`, [d.document_id]);
  await expectRejected(
    db.query(`UPDATE documents SET deleted_at = now(), deleted_by = $1 WHERE document_id = $2`, [SYSTEM, d.document_id]),
    /documents_delete_only_unsubmitted_draft/,
  );
});

test("versions are immutable", opts, async () => {
  const d = await seedDraft();
  const v = await submit(d);
  await expectRejected(
    db.query(`UPDATE document_versions SET metadata_json = '{"x":1}' WHERE version_id = $1`, [v.version_id]),
    /immutable/,
  );
  await expectRejected(db.query(`DELETE FROM document_versions WHERE version_id = $1`, [v.version_id]), /immutable/);
});

test("approval locks the document; only APPROVED -> INVALID with a reason is allowed", opts, async () => {
  const d = await seedDraft();
  const v = await submit(d);
  await db.query(`UPDATE documents SET workflow_status = 'APPROVED', approved_version_id = $1 WHERE document_id = $2`, [
    v.version_id,
    d.document_id,
  ]);

  await expectRejected(
    db.query(`UPDATE documents SET metadata_json = '{"x":1}' WHERE document_id = $1`, [d.document_id]),
    /approved and locked/,
  );
  await expectRejected(
    db.query(`UPDATE documents SET workflow_status = 'INVALID' WHERE document_id = $1`, [d.document_id]),
    /documents_invalid_fields/,
  );

  await db.query(
    `UPDATE documents SET workflow_status = 'INVALID', invalidated_at = now(), invalidated_by = $1,
       invalidation_reason = 'Replaced by a new agreement' WHERE document_id = $2`,
    [SYSTEM, d.document_id],
  );
  await expectRejected(
    db.query(`UPDATE documents SET title = 'again' WHERE document_id = $1`, [d.document_id]),
    /is invalid/,
  );
});

test("only one decision comment per version, and comments are immutable", opts, async () => {
  const d = await seedDraft();
  const v = await submit(d);
  const add = (type) =>
    db.query(
      `INSERT INTO comments (note_id, document_id, version_id, storage_reference_id, comment_type, comment_text, created_by, updated_by)
       VALUES ($1, $2, $3, $4, $5, 'Looks fine', $6, $6) RETURNING comment_id`,
      [d.note_id, d.document_id, v.version_id, v.combinedId, type, SYSTEM],
    );
  const { rows } = await add("REJECTION");
  await expectRejected(add("APPROVAL"), /comments_one_decision_per_version/);
  await expectRejected(
    db.query(`UPDATE comments SET comment_text = 'edited' WHERE comment_id = $1`, [rows[0].comment_id]),
    /immutable/,
  );
});

test("a comment must point at a version of its own document", opts, async () => {
  const a = await seedDraft();
  const b = await seedDraft();
  const vb = await submit(b);
  await expectRejected(
    db.query(
      `INSERT INTO comments (note_id, document_id, version_id, storage_reference_id, comment_text, created_by, updated_by)
       VALUES ($1, $2, $3, $4, 'wrong document', $5, $5)`,
      [a.note_id, a.document_id, vb.version_id, vb.combinedId, SYSTEM],
    ),
    /comments_version_fk/,
  );
});

test("a stored file may change location but never its hash", opts, async () => {
  const d = await seedDraft();
  await db.query(`UPDATE storage_references SET bucket_name = 'new-bucket' WHERE storage_reference_id = $1`, [d.fileId]);
  await expectRejected(
    db.query(`UPDATE storage_references SET file_hash = $1 WHERE storage_reference_id = $2`, ["b".repeat(64), d.fileId]),
    /may only change its location/,
  );
});

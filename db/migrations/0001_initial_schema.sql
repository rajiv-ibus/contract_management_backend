-- iBUS Contract Management System: initial schema (16 tables).
-- Runs inside schema ibus_cms (search_path is set by the migration runner).
-- Design reference: Architecture and Design Baseline v2.1, section 9.

-- Extensions live in public, which is always on the app's search_path, so their types resolve from any schema.
CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;

-- ---------------------------------------------------------------------------
-- Enum types
-- ---------------------------------------------------------------------------

CREATE TYPE user_role AS ENUM ('SUPER_ADMIN', 'USER', 'SYSTEM');
CREATE TYPE user_status AS ENUM ('INVITED', 'ACTIVE', 'DEACTIVATED');
CREATE TYPE workflow_status AS ENUM ('DRAFT', 'APPROVAL_PENDING', 'REJECTED', 'APPROVED', 'INVALID');
CREATE TYPE comment_type AS ENUM ('COMMENT', 'APPROVAL', 'REJECTION');
CREATE TYPE storage_provider AS ENUM ('DO_SPACES');
CREATE TYPE storage_reference_type AS ENUM ('SOURCE_UPLOAD', 'COMBINED_VERSION');
CREATE TYPE email_type AS ENUM (
  'INVITE', 'PASSWORD_RESET',
  'DOCUMENT_SUBMITTED', 'DOCUMENT_APPROVED', 'DOCUMENT_REJECTED', 'DOCUMENT_INVALIDATED'
);
CREATE TYPE email_provider AS ENUM ('SIMULATED', 'EMAIL_API');
CREATE TYPE email_status AS ENUM ('PENDING', 'SENT', 'FAILED');

-- ---------------------------------------------------------------------------
-- Shared trigger functions
-- ---------------------------------------------------------------------------

-- Mutable tables: keep updated_at current on every change.
CREATE FUNCTION set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- Immutable tables: no UPDATE or DELETE, ever.
CREATE FUNCTION prevent_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% rows are immutable (% refused)', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'restrict_violation';
END;
$$;

-- Record tables that keep history: no DELETE.
CREATE FUNCTION prevent_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% rows cannot be deleted', TG_TABLE_NAME
    USING ERRCODE = 'restrict_violation';
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. users
-- ---------------------------------------------------------------------------

CREATE TABLE users (
  user_id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name            varchar(150) NOT NULL,
  email                citext NOT NULL UNIQUE,
  password_hash        varchar(255),
  user_role            user_role NOT NULL DEFAULT 'USER',
  status               user_status NOT NULL DEFAULT 'INVITED',
  token_version        integer NOT NULL DEFAULT 0,
  failed_login_count   integer NOT NULL DEFAULT 0,
  locked_until         timestamptz(3),
  last_login_at        timestamptz(3),
  password_changed_at  timestamptz(3),
  created_at           timestamptz(3) NOT NULL DEFAULT now(),
  created_by           uuid NOT NULL,
  updated_at           timestamptz(3) NOT NULL DEFAULT now(),
  updated_by           uuid NOT NULL,
  CONSTRAINT users_active_needs_password
    CHECK (status <> 'ACTIVE' OR password_hash IS NOT NULL OR user_role = 'SYSTEM'),
  CONSTRAINT users_system_has_no_password
    CHECK (user_role <> 'SYSTEM' OR password_hash IS NULL),
  CONSTRAINT users_created_by_fk FOREIGN KEY (created_by) REFERENCES users (user_id) DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT users_updated_by_fk FOREIGN KEY (updated_by) REFERENCES users (user_id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TRIGGER users_set_updated_at BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- The SYSTEM actor: author of seed data and automated work. It has no password and never logs in.
INSERT INTO users (user_id, full_name, email, user_role, status, created_by, updated_by)
VALUES (
  '00000000-0000-0000-0000-000000000001', 'System', 'system@contract-management.local', 'SYSTEM', 'ACTIVE',
  '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001'
);

-- ---------------------------------------------------------------------------
-- 2. projects
-- ---------------------------------------------------------------------------

CREATE TABLE projects (
  project_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_code  varchar(30) NOT NULL UNIQUE,
  project_name  varchar(150) NOT NULL UNIQUE,
  description   text,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz(3) NOT NULL DEFAULT now(),
  created_by    uuid NOT NULL REFERENCES users (user_id),
  updated_at    timestamptz(3) NOT NULL DEFAULT now(),
  updated_by    uuid NOT NULL REFERENCES users (user_id)
);

CREATE TRIGGER projects_set_updated_at BEFORE UPDATE ON projects
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. project_memberships
-- ---------------------------------------------------------------------------

CREATE TABLE project_memberships (
  project_membership_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id             uuid NOT NULL REFERENCES projects (project_id),
  user_id                uuid NOT NULL REFERENCES users (user_id),
  is_admin               boolean NOT NULL DEFAULT false,
  can_make               boolean NOT NULL DEFAULT false,
  can_check              boolean NOT NULL DEFAULT false,
  created_at             timestamptz(3) NOT NULL DEFAULT now(),
  created_by             uuid NOT NULL REFERENCES users (user_id),
  updated_at             timestamptz(3) NOT NULL DEFAULT now(),
  updated_by             uuid NOT NULL REFERENCES users (user_id),
  CONSTRAINT project_memberships_one_per_user UNIQUE (project_id, user_id),
  CONSTRAINT project_memberships_admin_is_checker CHECK (NOT is_admin OR can_check),
  CONSTRAINT project_memberships_has_role CHECK (can_make OR can_check)
);

CREATE INDEX project_memberships_user_idx ON project_memberships (user_id);

CREATE TRIGGER project_memberships_set_updated_at BEFORE UPDATE ON project_memberships
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 4. project_notification_recipients
-- ---------------------------------------------------------------------------

CREATE TABLE project_notification_recipients (
  recipient_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id    uuid NOT NULL REFERENCES projects (project_id),
  email         citext NOT NULL,
  display_name  varchar(150),
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz(3) NOT NULL DEFAULT now(),
  created_by    uuid NOT NULL REFERENCES users (user_id),
  updated_at    timestamptz(3) NOT NULL DEFAULT now(),
  updated_by    uuid NOT NULL REFERENCES users (user_id),
  CONSTRAINT project_notification_recipients_unique_email UNIQUE (project_id, email)
);

CREATE TRIGGER project_notification_recipients_set_updated_at BEFORE UPDATE ON project_notification_recipients
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 5. user_invitations
-- ---------------------------------------------------------------------------

CREATE TABLE user_invitations (
  invitation_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES users (user_id),
  token_hash     char(64) NOT NULL UNIQUE,
  expires_at     timestamptz(3) NOT NULL,
  accepted_at    timestamptz(3),
  revoked_at     timestamptz(3),
  created_at     timestamptz(3) NOT NULL DEFAULT now(),
  created_by     uuid NOT NULL REFERENCES users (user_id),
  updated_at     timestamptz(3) NOT NULL DEFAULT now(),
  updated_by     uuid NOT NULL REFERENCES users (user_id),
  CONSTRAINT user_invitations_hash_format CHECK (token_hash ~ '^[0-9a-f]{64}$')
);

CREATE UNIQUE INDEX user_invitations_one_open_per_user
  ON user_invitations (user_id) WHERE accepted_at IS NULL AND revoked_at IS NULL;

CREATE TRIGGER user_invitations_set_updated_at BEFORE UPDATE ON user_invitations
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 6. password_reset_tokens
-- ---------------------------------------------------------------------------

CREATE TABLE password_reset_tokens (
  reset_token_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES users (user_id),
  token_hash      char(64) NOT NULL UNIQUE,
  expires_at      timestamptz(3) NOT NULL,
  used_at         timestamptz(3),
  revoked_at      timestamptz(3),
  requested_ip    inet,
  created_at      timestamptz(3) NOT NULL DEFAULT now(),
  created_by      uuid NOT NULL REFERENCES users (user_id),
  updated_at      timestamptz(3) NOT NULL DEFAULT now(),
  updated_by      uuid NOT NULL REFERENCES users (user_id),
  CONSTRAINT password_reset_tokens_hash_format CHECK (token_hash ~ '^[0-9a-f]{64}$')
);

CREATE INDEX password_reset_tokens_user_idx ON password_reset_tokens (user_id);

CREATE TRIGGER password_reset_tokens_set_updated_at BEFORE UPDATE ON password_reset_tokens
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 7. document_categories
-- ---------------------------------------------------------------------------

CREATE TABLE document_categories (
  category_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id     uuid NOT NULL REFERENCES projects (project_id),
  category_code  varchar(50) NOT NULL,
  category_name  varchar(150) NOT NULL,
  description    text,
  is_active      boolean NOT NULL DEFAULT true,
  created_at     timestamptz(3) NOT NULL DEFAULT now(),
  created_by     uuid NOT NULL REFERENCES users (user_id),
  updated_at     timestamptz(3) NOT NULL DEFAULT now(),
  updated_by     uuid NOT NULL REFERENCES users (user_id),
  CONSTRAINT document_categories_unique_code UNIQUE (project_id, category_code),
  CONSTRAINT document_categories_project_key UNIQUE (project_id, category_id)
);

CREATE TRIGGER document_categories_set_updated_at BEFORE UPDATE ON document_categories
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 8. document_types (active template FK is added after table 9)
-- ---------------------------------------------------------------------------

CREATE TABLE document_types (
  document_type_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id                uuid NOT NULL,
  category_id               uuid NOT NULL,
  type_code                 varchar(50) NOT NULL,
  type_name                 varchar(150) NOT NULL,
  description               text,
  active_schema_version_id  uuid,
  is_active                 boolean NOT NULL DEFAULT true,
  created_at                timestamptz(3) NOT NULL DEFAULT now(),
  created_by                uuid NOT NULL REFERENCES users (user_id),
  updated_at                timestamptz(3) NOT NULL DEFAULT now(),
  updated_by                uuid NOT NULL REFERENCES users (user_id),
  CONSTRAINT document_types_category_fk FOREIGN KEY (project_id, category_id)
    REFERENCES document_categories (project_id, category_id),
  CONSTRAINT document_types_unique_code UNIQUE (project_id, type_code),
  CONSTRAINT document_types_project_key UNIQUE (project_id, document_type_id)
);

CREATE TRIGGER document_types_set_updated_at BEFORE UPDATE ON document_types
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 9. metadata_schema_versions (immutable)
-- ---------------------------------------------------------------------------

CREATE TABLE metadata_schema_versions (
  schema_version_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_type_id   uuid NOT NULL REFERENCES document_types (document_type_id),
  schema_version_no  integer NOT NULL CHECK (schema_version_no > 0),
  schema_json        jsonb NOT NULL,
  content_hash       char(64) NOT NULL CHECK (content_hash ~ '^[0-9a-f]{64}$'),
  created_at         timestamptz(3) NOT NULL DEFAULT now(),
  created_by         uuid NOT NULL REFERENCES users (user_id),
  updated_at         timestamptz(3) NOT NULL DEFAULT now(),
  updated_by         uuid NOT NULL REFERENCES users (user_id),
  CONSTRAINT metadata_schema_versions_unique_no UNIQUE (document_type_id, schema_version_no),
  CONSTRAINT metadata_schema_versions_type_key UNIQUE (document_type_id, schema_version_id),
  CONSTRAINT metadata_schema_versions_frozen CHECK (updated_at = created_at AND updated_by = created_by)
);

CREATE TRIGGER metadata_schema_versions_immutable BEFORE UPDATE OR DELETE ON metadata_schema_versions
  FOR EACH ROW EXECUTE FUNCTION prevent_change();

ALTER TABLE document_types
  ADD CONSTRAINT document_types_active_schema_fk FOREIGN KEY (document_type_id, active_schema_version_id)
  REFERENCES metadata_schema_versions (document_type_id, schema_version_id) DEFERRABLE INITIALLY DEFERRED;

-- ---------------------------------------------------------------------------
-- 10. documents (FKs to notes, versions and files are added after those tables)
-- ---------------------------------------------------------------------------

CREATE TABLE documents (
  document_id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id                  uuid NOT NULL REFERENCES projects (project_id),
  document_type_id            uuid NOT NULL,
  title                       varchar(255) NOT NULL,
  note_id                     uuid NOT NULL UNIQUE,
  working_schema_version_id   uuid NOT NULL,
  metadata_json               jsonb NOT NULL DEFAULT '{}',
  draft_storage_reference_id  uuid,
  workflow_status             workflow_status NOT NULL DEFAULT 'DRAFT',
  current_version_id          uuid,
  approved_version_id         uuid,
  restored_from_version_id    uuid,
  created_from_document_id    uuid,
  invalidated_at              timestamptz(3),
  invalidated_by              uuid REFERENCES users (user_id),
  invalidation_reason         text,
  deleted_at                  timestamptz(3),
  deleted_by                  uuid REFERENCES users (user_id),
  row_version                 integer NOT NULL DEFAULT 0,
  created_at                  timestamptz(3) NOT NULL DEFAULT now(),
  created_by                  uuid NOT NULL REFERENCES users (user_id),
  updated_at                  timestamptz(3) NOT NULL DEFAULT now(),
  updated_by                  uuid NOT NULL REFERENCES users (user_id),
  CONSTRAINT documents_project_key UNIQUE (project_id, document_id),
  CONSTRAINT documents_type_fk FOREIGN KEY (project_id, document_type_id)
    REFERENCES document_types (project_id, document_type_id),
  CONSTRAINT documents_working_schema_fk FOREIGN KEY (document_type_id, working_schema_version_id)
    REFERENCES metadata_schema_versions (document_type_id, schema_version_id),
  CONSTRAINT documents_created_from_fk FOREIGN KEY (project_id, created_from_document_id)
    REFERENCES documents (project_id, document_id),
  CONSTRAINT documents_submitted_has_version
    CHECK (workflow_status = 'DRAFT' OR current_version_id IS NOT NULL),
  CONSTRAINT documents_approved_has_pointer
    CHECK (workflow_status NOT IN ('APPROVED', 'INVALID') OR approved_version_id IS NOT NULL),
  CONSTRAINT documents_invalid_fields CHECK (
    (workflow_status = 'INVALID'
      AND invalidated_at IS NOT NULL AND invalidated_by IS NOT NULL AND length(btrim(invalidation_reason)) > 0)
    OR (workflow_status <> 'INVALID'
      AND invalidated_at IS NULL AND invalidated_by IS NULL AND invalidation_reason IS NULL)
  ),
  CONSTRAINT documents_delete_only_unsubmitted_draft CHECK (
    (deleted_at IS NULL AND deleted_by IS NULL)
    OR (deleted_at IS NOT NULL AND deleted_by IS NOT NULL
      AND workflow_status = 'DRAFT' AND current_version_id IS NULL)
  )
);

CREATE INDEX documents_project_status_idx ON documents (project_id, workflow_status) WHERE deleted_at IS NULL;
CREATE INDEX documents_metadata_gin_idx ON documents USING gin (metadata_json);

CREATE TRIGGER documents_set_updated_at BEFORE UPDATE ON documents
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER documents_no_delete BEFORE DELETE ON documents
  FOR EACH ROW EXECUTE FUNCTION prevent_delete();

-- An approved document is locked: the only change allowed afterwards is APPROVED -> INVALID.
-- An invalid document never changes again; a deleted draft never comes back.
CREATE FUNCTION documents_lock() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.workflow_status = 'INVALID' THEN
    RAISE EXCEPTION 'document % is invalid and cannot change', OLD.document_id USING ERRCODE = 'restrict_violation';
  END IF;

  IF OLD.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'document % was deleted and cannot change', OLD.document_id USING ERRCODE = 'restrict_violation';
  END IF;

  IF OLD.workflow_status = 'APPROVED' THEN
    IF NEW.workflow_status NOT IN ('APPROVED', 'INVALID')
      OR NEW.project_id IS DISTINCT FROM OLD.project_id
      OR NEW.document_type_id IS DISTINCT FROM OLD.document_type_id
      OR NEW.title IS DISTINCT FROM OLD.title
      OR NEW.note_id IS DISTINCT FROM OLD.note_id
      OR NEW.working_schema_version_id IS DISTINCT FROM OLD.working_schema_version_id
      OR NEW.metadata_json IS DISTINCT FROM OLD.metadata_json
      OR NEW.draft_storage_reference_id IS DISTINCT FROM OLD.draft_storage_reference_id
      OR NEW.current_version_id IS DISTINCT FROM OLD.current_version_id
      OR NEW.approved_version_id IS DISTINCT FROM OLD.approved_version_id
      OR NEW.restored_from_version_id IS DISTINCT FROM OLD.restored_from_version_id
      OR NEW.created_from_document_id IS DISTINCT FROM OLD.created_from_document_id
      OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at
    THEN
      RAISE EXCEPTION 'document % is approved and locked; it can only be marked INVALID', OLD.document_id
        USING ERRCODE = 'restrict_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER documents_lock_after_approval BEFORE UPDATE ON documents
  FOR EACH ROW EXECUTE FUNCTION documents_lock();

-- ---------------------------------------------------------------------------
-- 13. notes (one comment thread per document)
-- ---------------------------------------------------------------------------

CREATE TABLE notes (
  note_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id  uuid NOT NULL UNIQUE REFERENCES documents (document_id) DEFERRABLE INITIALLY DEFERRED,
  created_at   timestamptz(3) NOT NULL DEFAULT now(),
  created_by   uuid NOT NULL REFERENCES users (user_id),
  updated_at   timestamptz(3) NOT NULL DEFAULT now(),
  updated_by   uuid NOT NULL REFERENCES users (user_id),
  CONSTRAINT notes_document_key UNIQUE (note_id, document_id)
);

CREATE TRIGGER notes_set_updated_at BEFORE UPDATE ON notes
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER notes_no_delete BEFORE DELETE ON notes
  FOR EACH ROW EXECUTE FUNCTION prevent_delete();

ALTER TABLE documents
  ADD CONSTRAINT documents_note_fk FOREIGN KEY (note_id, document_id)
  REFERENCES notes (note_id, document_id) DEFERRABLE INITIALLY DEFERRED;

-- ---------------------------------------------------------------------------
-- 12. storage_references
-- ---------------------------------------------------------------------------

CREATE TABLE storage_references (
  storage_reference_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id           uuid NOT NULL REFERENCES documents (document_id) DEFERRABLE INITIALLY DEFERRED,
  reference_type        storage_reference_type NOT NULL,
  provider              storage_provider NOT NULL DEFAULT 'DO_SPACES',
  region                varchar(30) NOT NULL,
  bucket_name           varchar(63) NOT NULL,
  object_key            varchar(1024) NOT NULL,
  original_file_name    varchar(255) NOT NULL,
  content_type          varchar(100) NOT NULL,
  size_bytes            bigint NOT NULL CHECK (size_bytes > 0),
  file_hash             char(64) NOT NULL CHECK (file_hash ~ '^[0-9a-f]{64}$'),
  created_at            timestamptz(3) NOT NULL DEFAULT now(),
  created_by            uuid NOT NULL REFERENCES users (user_id),
  updated_at            timestamptz(3) NOT NULL DEFAULT now(),
  updated_by            uuid NOT NULL REFERENCES users (user_id),
  CONSTRAINT storage_references_unique_object UNIQUE (provider, bucket_name, object_key),
  CONSTRAINT storage_references_document_key UNIQUE (document_id, storage_reference_id)
);

CREATE TRIGGER storage_references_set_updated_at BEFORE UPDATE ON storage_references
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER storage_references_no_delete BEFORE DELETE ON storage_references
  FOR EACH ROW EXECUTE FUNCTION prevent_delete();

-- Only the physical location may change (storage moves); what the file is never changes.
CREATE FUNCTION storage_references_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.document_id IS DISTINCT FROM OLD.document_id
    OR NEW.reference_type IS DISTINCT FROM OLD.reference_type
    OR NEW.original_file_name IS DISTINCT FROM OLD.original_file_name
    OR NEW.content_type IS DISTINCT FROM OLD.content_type
    OR NEW.size_bytes IS DISTINCT FROM OLD.size_bytes
    OR NEW.file_hash IS DISTINCT FROM OLD.file_hash
  THEN
    RAISE EXCEPTION 'storage reference % may only change its location', OLD.storage_reference_id
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER storage_references_location_only BEFORE UPDATE ON storage_references
  FOR EACH ROW EXECUTE FUNCTION storage_references_guard();

ALTER TABLE documents
  ADD CONSTRAINT documents_draft_file_fk FOREIGN KEY (document_id, draft_storage_reference_id)
  REFERENCES storage_references (document_id, storage_reference_id) DEFERRABLE INITIALLY DEFERRED;

-- ---------------------------------------------------------------------------
-- 11. document_versions (immutable)
-- ---------------------------------------------------------------------------

CREATE TABLE document_versions (
  version_id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id                  uuid NOT NULL REFERENCES documents (document_id) DEFERRABLE INITIALLY DEFERRED,
  version_no                   integer NOT NULL CHECK (version_no > 0),
  document_type_id             uuid NOT NULL,
  schema_version_id            uuid NOT NULL,
  metadata_json                jsonb NOT NULL,
  source_storage_reference_id  uuid NOT NULL,
  storage_reference_id         uuid NOT NULL UNIQUE,
  restored_from_version_id     uuid,
  created_at                   timestamptz(3) NOT NULL DEFAULT now(),
  created_by                   uuid NOT NULL REFERENCES users (user_id),
  updated_at                   timestamptz(3) NOT NULL DEFAULT now(),
  updated_by                   uuid NOT NULL REFERENCES users (user_id),
  CONSTRAINT document_versions_unique_no UNIQUE (document_id, version_no),
  CONSTRAINT document_versions_document_key UNIQUE (document_id, version_id),
  CONSTRAINT document_versions_file_key UNIQUE (version_id, storage_reference_id),
  CONSTRAINT document_versions_schema_fk FOREIGN KEY (document_type_id, schema_version_id)
    REFERENCES metadata_schema_versions (document_type_id, schema_version_id),
  CONSTRAINT document_versions_source_file_fk FOREIGN KEY (document_id, source_storage_reference_id)
    REFERENCES storage_references (document_id, storage_reference_id),
  CONSTRAINT document_versions_combined_file_fk FOREIGN KEY (document_id, storage_reference_id)
    REFERENCES storage_references (document_id, storage_reference_id),
  CONSTRAINT document_versions_restored_from_fk FOREIGN KEY (document_id, restored_from_version_id)
    REFERENCES document_versions (document_id, version_id),
  CONSTRAINT document_versions_frozen CHECK (updated_at = created_at AND updated_by = created_by)
);

CREATE TRIGGER document_versions_immutable BEFORE UPDATE OR DELETE ON document_versions
  FOR EACH ROW EXECUTE FUNCTION prevent_change();

ALTER TABLE documents
  ADD CONSTRAINT documents_current_version_fk FOREIGN KEY (document_id, current_version_id)
    REFERENCES document_versions (document_id, version_id) DEFERRABLE INITIALLY DEFERRED,
  ADD CONSTRAINT documents_approved_version_fk FOREIGN KEY (document_id, approved_version_id)
    REFERENCES document_versions (document_id, version_id) DEFERRABLE INITIALLY DEFERRED,
  ADD CONSTRAINT documents_restored_from_fk FOREIGN KEY (document_id, restored_from_version_id)
    REFERENCES document_versions (document_id, version_id) DEFERRABLE INITIALLY DEFERRED;

-- ---------------------------------------------------------------------------
-- 14. comments (immutable)
-- ---------------------------------------------------------------------------

CREATE TABLE comments (
  comment_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  note_id               uuid NOT NULL,
  document_id           uuid NOT NULL,
  version_id            uuid NOT NULL,
  storage_reference_id  uuid NOT NULL,
  comment_type          comment_type NOT NULL DEFAULT 'COMMENT',
  comment_text          text NOT NULL,
  reply_to_comment_id   uuid,
  created_at            timestamptz(3) NOT NULL DEFAULT now(),
  created_by            uuid NOT NULL REFERENCES users (user_id),
  updated_at            timestamptz(3) NOT NULL DEFAULT now(),
  updated_by            uuid NOT NULL REFERENCES users (user_id),
  CONSTRAINT comments_note_key UNIQUE (note_id, comment_id),
  CONSTRAINT comments_note_fk FOREIGN KEY (note_id, document_id) REFERENCES notes (note_id, document_id),
  CONSTRAINT comments_version_fk FOREIGN KEY (document_id, version_id)
    REFERENCES document_versions (document_id, version_id),
  CONSTRAINT comments_file_fk FOREIGN KEY (version_id, storage_reference_id)
    REFERENCES document_versions (version_id, storage_reference_id),
  CONSTRAINT comments_reply_fk FOREIGN KEY (note_id, reply_to_comment_id) REFERENCES comments (note_id, comment_id),
  CONSTRAINT comments_text_length CHECK (length(btrim(comment_text)) > 0 AND char_length(comment_text) <= 5000),
  CONSTRAINT comments_decision_not_reply CHECK (comment_type = 'COMMENT' OR reply_to_comment_id IS NULL),
  CONSTRAINT comments_frozen CHECK (updated_at = created_at AND updated_by = created_by)
);

CREATE UNIQUE INDEX comments_one_decision_per_version
  ON comments (version_id) WHERE comment_type IN ('APPROVAL', 'REJECTION');
CREATE INDEX comments_document_version_idx ON comments (document_id, version_id, created_at);

CREATE TRIGGER comments_immutable BEFORE UPDATE OR DELETE ON comments
  FOR EACH ROW EXECUTE FUNCTION prevent_change();

-- ---------------------------------------------------------------------------
-- 15. audit_events (immutable)
-- ---------------------------------------------------------------------------

CREATE TABLE audit_events (
  audit_event_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type          varchar(50) NOT NULL,
  document_id         uuid REFERENCES documents (document_id),
  version_id          uuid,
  target_type         varchar(50),
  target_id           varchar(100),
  occurred_at         timestamptz(3) NOT NULL DEFAULT now(),
  event_details_json  jsonb NOT NULL DEFAULT '{}',
  correlation_id      varchar(100),
  ip_address          inet,
  created_at          timestamptz(3) NOT NULL DEFAULT now(),
  created_by          uuid NOT NULL REFERENCES users (user_id),
  updated_at          timestamptz(3) NOT NULL DEFAULT now(),
  updated_by          uuid NOT NULL REFERENCES users (user_id),
  CONSTRAINT audit_events_version_fk FOREIGN KEY (document_id, version_id)
    REFERENCES document_versions (document_id, version_id),
  CONSTRAINT audit_events_version_needs_document CHECK (version_id IS NULL OR document_id IS NOT NULL),
  CONSTRAINT audit_events_frozen CHECK (updated_at = created_at AND updated_by = created_by)
);

CREATE UNIQUE INDEX audit_events_one_decision_per_version
  ON audit_events (version_id) WHERE event_type IN ('DOCUMENT_APPROVED', 'DOCUMENT_REJECTED');
CREATE INDEX audit_events_document_idx ON audit_events (document_id, occurred_at);
CREATE INDEX audit_events_target_idx ON audit_events (target_type, target_id);
CREATE INDEX audit_events_type_idx ON audit_events (event_type, occurred_at);

CREATE TRIGGER audit_events_immutable BEFORE UPDATE OR DELETE ON audit_events
  FOR EACH ROW EXECUTE FUNCTION prevent_change();

-- ---------------------------------------------------------------------------
-- 16. email_notifications
-- ---------------------------------------------------------------------------

CREATE TABLE email_notifications (
  email_notification_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email_type             email_type NOT NULL,
  recipient_user_id      uuid REFERENCES users (user_id),
  to_emails              citext[] NOT NULL CHECK (cardinality(to_emails) > 0),
  cc_emails              citext[] NOT NULL DEFAULT '{}',
  subject                varchar(255) NOT NULL,
  body_text              text,
  template_data_json     jsonb NOT NULL DEFAULT '{}',
  document_id            uuid REFERENCES documents (document_id),
  version_id             uuid,
  provider               email_provider NOT NULL,
  status                 email_status NOT NULL DEFAULT 'PENDING',
  attempt_count          integer NOT NULL DEFAULT 0,
  next_attempt_at        timestamptz(3),
  sent_at                timestamptz(3),
  last_error             text,
  provider_message_id    varchar(255),
  created_at             timestamptz(3) NOT NULL DEFAULT now(),
  created_by             uuid NOT NULL REFERENCES users (user_id),
  updated_at             timestamptz(3) NOT NULL DEFAULT now(),
  updated_by             uuid NOT NULL REFERENCES users (user_id),
  CONSTRAINT email_notifications_version_fk FOREIGN KEY (document_id, version_id)
    REFERENCES document_versions (document_id, version_id)
);

CREATE INDEX email_notifications_pending_idx ON email_notifications (next_attempt_at) WHERE status = 'PENDING';

CREATE TRIGGER email_notifications_set_updated_at BEFORE UPDATE ON email_notifications
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

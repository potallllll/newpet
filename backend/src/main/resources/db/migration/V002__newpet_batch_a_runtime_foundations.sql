-- Stage 11 review migration. Apply once after the pinned Stage 09 V001.
-- All authoritative times are UTC DATETIME(3). This migration registers no AppIDs or credentials.

ALTER TABLE wechat_binding
  ADD UNIQUE KEY uq_wechat_binding_user (appid, openid, platform_user_id);

ALTER TABLE staff
  ADD COLUMN staff_session_generation BIGINT UNSIGNED NOT NULL DEFAULT 1,
  ADD UNIQUE KEY uq_staff_session_identity (store_id, staff_id, platform_user_id),
  ADD CONSTRAINT ck_staff_session_generation CHECK (staff_session_generation > 0);

ALTER TABLE store
  ADD COLUMN store_staff_session_generation BIGINT UNSIGNED NOT NULL DEFAULT 1,
  ADD CONSTRAINT ck_store_staff_generation CHECK (store_staff_session_generation > 0);

ALTER TABLE staff_invitation
  ADD UNIQUE KEY uq_staff_invitation_store (store_id, staff_invitation_id);

CREATE TABLE auth_wechat_app (
  appid VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  app_audience VARCHAR(12) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  open_platform_namespace VARBINARY(64) NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (appid),
  UNIQUE KEY uq_wechat_app_namespace (appid, open_platform_namespace),
  UNIQUE KEY uq_wechat_app_audience (appid, app_audience),
  CHECK (app_audience IN ('customer','staff')),
  CHECK (OCTET_LENGTH(open_platform_namespace) > 0),
  CHECK (enabled IN (0,1))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE auth_wechat_group (
  wechat_group_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  open_platform_namespace VARBINARY(64) NOT NULL,
  unionid_digest BINARY(32) NOT NULL,
  platform_user_id BIGINT UNSIGNED NOT NULL,
  group_state VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  evidence_observed_at DATETIME(3) NOT NULL,
  revoked_at DATETIME(3) NULL,
  active_user_guard BIGINT UNSIGNED GENERATED ALWAYS AS
    (CASE WHEN group_state = 'active' THEN platform_user_id END) STORED,
  PRIMARY KEY (wechat_group_id),
  UNIQUE KEY uq_wechat_issuer_subject (open_platform_namespace, unionid_digest),
  UNIQUE KEY uq_wechat_group_active_user (open_platform_namespace, active_user_guard),
  UNIQUE KEY uq_wechat_group_owner (wechat_group_id, open_platform_namespace, platform_user_id, group_state),
  CONSTRAINT fk_wechat_group_user FOREIGN KEY (platform_user_id) REFERENCES platform_user (platform_user_id),
  CHECK (OCTET_LENGTH(open_platform_namespace) > 0),
  CHECK ((group_state = 'active' AND revoked_at IS NULL)
      OR (group_state = 'revoked' AND revoked_at IS NOT NULL AND revoked_at >= evidence_observed_at))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE auth_wechat_binding_group (
  appid VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  openid VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  platform_user_id BIGINT UNSIGNED NOT NULL,
  open_platform_namespace VARBINARY(64) NOT NULL,
  wechat_group_id BIGINT UNSIGNED NOT NULL,
  group_state VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
  linked_at DATETIME(3) NOT NULL,
  PRIMARY KEY (appid, openid),
  CONSTRAINT fk_group_original_binding FOREIGN KEY (appid, openid, platform_user_id)
    REFERENCES wechat_binding (appid, openid, platform_user_id),
  CONSTRAINT fk_group_binding_issuer FOREIGN KEY (appid, open_platform_namespace)
    REFERENCES auth_wechat_app (appid, open_platform_namespace),
  CONSTRAINT fk_group_binding_owner FOREIGN KEY
    (wechat_group_id, open_platform_namespace, platform_user_id, group_state)
    REFERENCES auth_wechat_group (wechat_group_id, open_platform_namespace, platform_user_id, group_state),
  CHECK (group_state = 'active')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE auth_wechat_challenge (
  wechat_challenge_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  challenge_token_digest BINARY(32) NOT NULL,
  appid VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  session_epoch BINARY(16) NOT NULL,
  challenge_kind VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  parent_challenge_id BIGINT UNSIGNED NULL,
  target_platform_user_id BIGINT UNSIGNED NULL,
  expected_auth_version BIGINT UNSIGNED NULL,
  seal_key_ref VARBINARY(192) NULL,
  sealed_context VARBINARY(4096) NULL,
  issued_at DATETIME(3) NOT NULL,
  expires_at DATETIME(3) NOT NULL,
  consumed_at DATETIME(3) NULL,
  PRIMARY KEY (wechat_challenge_id),
  UNIQUE KEY uq_wechat_challenge_token (challenge_token_digest),
  UNIQUE KEY uq_wechat_challenge_app (wechat_challenge_id, appid),
  UNIQUE KEY uq_wechat_challenge_one_child (parent_challenge_id),
  KEY ix_wechat_challenge_expiry (expires_at, wechat_challenge_id),
  CONSTRAINT fk_wechat_challenge_app FOREIGN KEY (appid) REFERENCES auth_wechat_app (appid),
  CONSTRAINT fk_wechat_challenge_parent FOREIGN KEY (parent_challenge_id, appid)
    REFERENCES auth_wechat_challenge (wechat_challenge_id, appid),
  CONSTRAINT fk_wechat_challenge_target FOREIGN KEY (target_platform_user_id)
    REFERENCES platform_user (platform_user_id),
  CHECK ((challenge_kind = 'phone' AND parent_challenge_id IS NULL
       AND target_platform_user_id IS NULL AND expected_auth_version IS NULL
       AND expires_at = DATE_ADD(issued_at, INTERVAL 5 MINUTE))
      OR (challenge_kind = 'rebind' AND parent_challenge_id IS NOT NULL
       AND target_platform_user_id IS NOT NULL AND expected_auth_version IS NOT NULL
       AND expected_auth_version > 0 AND expires_at = DATE_ADD(issued_at, INTERVAL 3 MINUTE))),
  CHECK ((consumed_at IS NULL AND seal_key_ref IS NOT NULL AND sealed_context IS NOT NULL
       AND OCTET_LENGTH(seal_key_ref) > 0 AND OCTET_LENGTH(sealed_context) > 16)
      OR (consumed_at IS NOT NULL AND consumed_at >= issued_at AND consumed_at < expires_at
       AND seal_key_ref IS NULL AND sealed_context IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE auth_miniapp_session (
  token_digest BINARY(32) NOT NULL,
  appid VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  app_audience VARCHAR(12) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  platform_user_id BIGINT UNSIGNED NOT NULL,
  auth_version BIGINT UNSIGNED NOT NULL,
  session_epoch BINARY(16) NOT NULL,
  store_id BIGINT UNSIGNED NULL,
  staff_id BIGINT UNSIGNED NULL,
  staff_session_generation BIGINT UNSIGNED NULL,
  store_staff_session_generation BIGINT UNSIGNED NULL,
  issued_at DATETIME(3) NOT NULL,
  idle_expires_at DATETIME(3) NOT NULL,
  hard_expires_at DATETIME(3) NOT NULL,
  revoked_at DATETIME(3) NULL,
  PRIMARY KEY (token_digest),
  KEY ix_session_user (platform_user_id, hard_expires_at, token_digest),
  KEY ix_session_expiry (hard_expires_at, token_digest),
  CONSTRAINT fk_session_app_audience FOREIGN KEY (appid, app_audience)
    REFERENCES auth_wechat_app (appid, app_audience),
  CONSTRAINT fk_session_user FOREIGN KEY (platform_user_id) REFERENCES platform_user (platform_user_id),
  CONSTRAINT fk_session_staff FOREIGN KEY (store_id, staff_id, platform_user_id)
    REFERENCES staff (store_id, staff_id, platform_user_id),
  CHECK (auth_version > 0),
  CHECK ((store_id IS NULL AND staff_id IS NULL AND staff_session_generation IS NULL
       AND store_staff_session_generation IS NULL)
      OR (app_audience = 'staff' AND store_id IS NOT NULL AND staff_id IS NOT NULL
       AND staff_session_generation IS NOT NULL AND staff_session_generation > 0
       AND store_staff_session_generation IS NOT NULL AND store_staff_session_generation > 0)),
  CHECK (hard_expires_at = DATE_ADD(issued_at, INTERVAL 12 HOUR)),
  CHECK (idle_expires_at > issued_at AND idle_expires_at <= hard_expires_at),
  CHECK (revoked_at IS NULL OR revoked_at >= issued_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE private_media (
  private_media_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  scope_kind VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  scope_id BIGINT UNSIGNED NOT NULL,
  owner_user_id BIGINT UNSIGNED NULL,
  store_id BIGINT UNSIGNED NULL,
  uploaded_by_user_id BIGINT UNSIGNED NOT NULL,
  uploaded_by_staff_id BIGINT UNSIGNED NULL,
  upload_appid VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  media_purpose VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  object_key VARBINARY(192) NOT NULL,
  media_state VARCHAR(12) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  declared_mime VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  declared_size INT UNSIGNED NOT NULL,
  object_version VARBINARY(192) NULL,
  verified_sha256 BINARY(32) NULL,
  issued_at DATETIME(3) NOT NULL,
  upload_expires_at DATETIME(3) NOT NULL,
  verified_at DATETIME(3) NULL,
  revoked_at DATETIME(3) NULL,
  PRIMARY KEY (private_media_id),
  UNIQUE KEY uq_private_media_object (object_key),
  UNIQUE KEY uq_private_media_scope (private_media_id, scope_kind, scope_id, media_purpose),
  KEY ix_private_media_upload_expiry (media_state, upload_expires_at, private_media_id),
  CONSTRAINT fk_private_media_owner FOREIGN KEY (owner_user_id) REFERENCES platform_user (platform_user_id),
  CONSTRAINT fk_private_media_store FOREIGN KEY (store_id) REFERENCES store (store_id),
  CONSTRAINT fk_private_media_uploader FOREIGN KEY (uploaded_by_user_id) REFERENCES platform_user (platform_user_id),
  CONSTRAINT fk_private_media_staff FOREIGN KEY (store_id, uploaded_by_staff_id, uploaded_by_user_id)
    REFERENCES staff (store_id, staff_id, platform_user_id),
  CONSTRAINT fk_private_media_app FOREIGN KEY (upload_appid) REFERENCES auth_wechat_app (appid),
  CHECK ((scope_kind = 'user' AND owner_user_id IS NOT NULL AND owner_user_id = scope_id
       AND uploaded_by_user_id = owner_user_id AND store_id IS NULL AND uploaded_by_staff_id IS NULL)
      OR (scope_kind = 'store' AND store_id IS NOT NULL AND store_id = scope_id AND owner_user_id IS NULL
       AND uploaded_by_staff_id IS NOT NULL)),
  CHECK ((scope_kind = 'user' AND media_purpose IN ('owner_pet','store_front','business_license'))
      OR (scope_kind = 'store' AND media_purpose IN
       ('service_photo','boarding_care','boarding_health','intake_document','store_front','business_license','product_image'))),
  CHECK (OCTET_LENGTH(object_key) > 0),
  CHECK (declared_size > 0 AND declared_mime IN ('image/jpeg','image/png','image/webp')),
  CHECK (media_purpose <> 'store_front' OR
         (declared_size <= 3145728 AND declared_mime IN ('image/jpeg','image/png'))),
  CHECK (media_purpose <> 'business_license' OR
    (declared_size <= 10485760 AND declared_mime IN ('image/jpeg','image/png'))),
  CHECK (upload_expires_at = DATE_ADD(issued_at, INTERVAL 10 MINUTE)),
  CHECK ((object_version IS NULL AND verified_sha256 IS NULL AND verified_at IS NULL)
      OR (object_version IS NOT NULL AND OCTET_LENGTH(object_version) > 0
       AND verified_sha256 IS NOT NULL AND verified_at IS NOT NULL
       AND verified_at >= issued_at AND verified_at < upload_expires_at)),
  CHECK ((media_state = 'pending' AND revoked_at IS NULL AND verified_at IS NULL)
      OR (media_state = 'verified' AND revoked_at IS NULL AND verified_at IS NOT NULL)
      OR (media_state = 'revoked' AND revoked_at IS NOT NULL AND revoked_at >= issued_at))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE private_media_attachment (
  media_attachment_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  private_media_id BIGINT UNSIGNED NOT NULL,
  scope_kind VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  scope_id BIGINT UNSIGNED NOT NULL,
  media_purpose VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  resource_kind VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  resource_id BIGINT UNSIGNED NOT NULL,
  resource_slot VARBINARY(64) NOT NULL,
  attached_at DATETIME(3) NOT NULL,
  detached_at DATETIME(3) NULL,
  active_guard TINYINT UNSIGNED GENERATED ALWAYS AS
    (CASE WHEN detached_at IS NULL THEN 1 END) STORED,
  PRIMARY KEY (media_attachment_id),
  UNIQUE KEY uq_private_media_active (private_media_id, active_guard),
  UNIQUE KEY uq_private_media_resource_slot
    (scope_kind, scope_id, resource_kind, resource_id, media_purpose, resource_slot, active_guard),
  CONSTRAINT fk_private_media_attachment_scope FOREIGN KEY (private_media_id, scope_kind, scope_id, media_purpose)
    REFERENCES private_media (private_media_id, scope_kind, scope_id, media_purpose),
  CHECK ((media_purpose = 'owner_pet' AND resource_kind = 'owner_pet')
      OR (media_purpose = 'service_photo' AND resource_kind = 'service_record')
      OR (media_purpose = 'boarding_care' AND resource_kind = 'boarding_care_event')
      OR (media_purpose = 'boarding_health' AND resource_kind IN ('boarding_stay','boarding_care_event'))
      OR (media_purpose = 'intake_document' AND resource_kind = 'stock_intake')
      OR (media_purpose IN ('store_front','business_license') AND scope_kind = 'store'
       AND resource_kind IN ('store','store_review'))
      OR (media_purpose = 'product_image' AND resource_kind = 'product_sku')),
  CHECK (resource_id > 0 AND OCTET_LENGTH(resource_slot) > 0),
  CHECK (detached_at IS NULL OR detached_at >= attached_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE invite_replay_secret (
  idempotency_record_id BIGINT UNSIGNED NOT NULL,
  store_id BIGINT UNSIGNED NOT NULL,
  creator_staff_id BIGINT UNSIGNED NOT NULL,
  staff_invitation_id BIGINT UNSIGNED NULL,
  invite_code_id BIGINT UNSIGNED NULL,
  seal_format TINYINT UNSIGNED NOT NULL DEFAULT 1,
  kms_key_ref VARBINARY(192) NOT NULL,
  wrapped_dek VARBINARY(2048) NOT NULL,
  nonce BINARY(12) NOT NULL,
  ciphertext VARBINARY(512) NOT NULL,
  sealed_at DATETIME(3) NOT NULL,
  replay_until DATETIME(3) NOT NULL,
  PRIMARY KEY (idempotency_record_id),
  UNIQUE KEY uq_replay_staff_invitation (staff_invitation_id),
  UNIQUE KEY uq_replay_invite_code (invite_code_id),
  KEY ix_invite_replay_expiry (replay_until, idempotency_record_id),
  CONSTRAINT fk_invite_replay_idempotency FOREIGN KEY (idempotency_record_id)
    REFERENCES idempotency_record (idempotency_record_id),
  CONSTRAINT fk_invite_replay_creator FOREIGN KEY (store_id, creator_staff_id)
    REFERENCES staff (store_id, staff_id),
  CONSTRAINT fk_invite_replay_staff_token FOREIGN KEY (store_id, staff_invitation_id)
    REFERENCES staff_invitation (store_id, staff_invitation_id),
  CONSTRAINT fk_invite_replay_cust_code FOREIGN KEY (store_id, invite_code_id)
    REFERENCES invite_code (store_id, invite_code_id),
  CHECK ((staff_invitation_id IS NULL) <> (invite_code_id IS NULL)),
  CHECK (seal_format = 1 AND OCTET_LENGTH(kms_key_ref) > 0
    AND OCTET_LENGTH(wrapped_dek) > 0 AND OCTET_LENGTH(ciphertext) > 16),
  CHECK (replay_until > sealed_at),
  CHECK ((staff_invitation_id IS NULL OR replay_until <= DATE_ADD(sealed_at, INTERVAL 12 HOUR))
    AND (invite_code_id IS NULL OR replay_until <= DATE_ADD(sealed_at, INTERVAL 72 HOUR)))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Durable send intent for the gated WeChat subscription channel.
-- V001 in_app_message remains the sole durable in-app projection.
CREATE TABLE outbox_channel_delivery (
  channel_delivery_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  outbox_event_id BIGINT UNSIGNED NOT NULL,
  recipient_user_id BIGINT UNSIGNED NOT NULL,
  channel_name VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  provider_dedup_key BINARY(32) NOT NULL,
  channel_state VARCHAR(12) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  send_token BINARY(16) NULL,
  attempt_count SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  last_attempt_at DATETIME(3) NULL,
  finished_at DATETIME(3) NULL,
  outcome_code VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (channel_delivery_id),
  UNIQUE KEY uq_outbox_channel_once (outbox_event_id, recipient_user_id, channel_name),
  UNIQUE KEY uq_outbox_provider_key (provider_dedup_key),
  CONSTRAINT fk_outbox_channel_event FOREIGN KEY (outbox_event_id) REFERENCES outbox_event (outbox_event_id),
  CONSTRAINT fk_outbox_channel_recipient FOREIGN KEY (recipient_user_id) REFERENCES platform_user (platform_user_id),
  CHECK (channel_name = 'wechat_subscribe'),
  CHECK ((attempt_count = 0 AND last_attempt_at IS NULL)
      OR (attempt_count > 0 AND last_attempt_at IS NOT NULL AND last_attempt_at >= created_at)),
  CHECK ((channel_state = 'sending' AND send_token IS NOT NULL
          AND attempt_count > 0 AND finished_at IS NULL)
      OR (channel_state IN ('ready','retry') AND send_token IS NULL AND finished_at IS NULL)
      OR (channel_state IN ('sent','skipped','needs_review') AND send_token IS NULL
          AND finished_at IS NOT NULL AND finished_at >= created_at AND outcome_code IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

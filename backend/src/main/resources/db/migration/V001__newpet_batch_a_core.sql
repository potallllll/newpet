-- NewPet V1 stage 09 candidate · Batch A · review migration targeting MySQL 8.0.16+.
-- Apply once to an empty schema using a migration runner. No seed or credentials.
-- Timestamps are UTC DATETIME(3), written explicitly by the application.
-- Business dates and cutoffs are computed in Asia/Shanghai.

CREATE TABLE platform_user (
  platform_user_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  verified_mobile VARCHAR(20) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  mobile_verified_at DATETIME(3) NOT NULL,
  auth_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  account_status VARCHAR(16) NOT NULL DEFAULT 'active',
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (platform_user_id),
  UNIQUE KEY uq_verified_mobile (verified_mobile),
  CHECK (account_status IN ('active','disabled','closed'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE wechat_binding (
  appid VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  openid VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  platform_user_id BIGINT UNSIGNED NOT NULL,
  bound_at DATETIME(3) NOT NULL,
  PRIMARY KEY (appid, openid),
  UNIQUE KEY uq_user_app (platform_user_id, appid),
  CONSTRAINT fk_wechat_user FOREIGN KEY (platform_user_id) REFERENCES platform_user (platform_user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE store (
  store_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  merchant_id BIGINT UNSIGNED NOT NULL,
  store_name VARCHAR(100) NOT NULL,
  store_address VARCHAR(255) NOT NULL,
  store_contact_phone VARCHAR(32) NULL,
  product_hold_rule JSON NOT NULL DEFAULT (JSON_OBJECT('kind','hours','value',24)),
  registered_mobile VARCHAR(20) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  store_front_photo_ref VARCHAR(255) NULL,
  store_business_license_ref VARCHAR(255) NULL,
  store_status VARCHAR(16) NOT NULL DEFAULT 'active',
  store_profile_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  site_config_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  store_profile_activated_at DATETIME(3) NULL,
  business_timezone VARCHAR(64) NOT NULL DEFAULT 'Asia/Shanghai',
  store_business_hours JSON NOT NULL,
  store_temporary_closures JSON NOT NULL,
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (store_id),
  UNIQUE KEY uq_store_merchant (merchant_id),
  CHECK (store_status IN ('active','deactivated')),
  CHECK (business_timezone = 'Asia/Shanghai')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE staff (
  staff_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  platform_user_id BIGINT UNSIGNED NOT NULL,
  staff_role VARCHAR(16) NOT NULL,
  staff_status VARCHAR(16) NOT NULL,
  staff_display_name VARCHAR(64) NOT NULL,
  row_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (staff_id),
  UNIQUE KEY uq_staff_store_id (store_id, staff_id),
  UNIQUE KEY uq_staff_store_user (store_id, platform_user_id),
  UNIQUE KEY uq_staff_full_identity (store_id, staff_id, platform_user_id, staff_role),
  CONSTRAINT fk_staff_store FOREIGN KEY (store_id) REFERENCES store (store_id),
  CONSTRAINT fk_staff_user FOREIGN KEY (platform_user_id) REFERENCES platform_user (platform_user_id),
  CHECK (staff_role IN ('merchant_owner','store_staff')),
  CHECK (staff_status IN ('active','disabled','removed'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- This table holds only current effective occupancy, maintained in the same transaction.
CREATE TABLE active_staff_membership (
  platform_user_id BIGINT UNSIGNED NOT NULL,
  store_id BIGINT UNSIGNED NOT NULL,
  staff_id BIGINT UNSIGNED NOT NULL,
  staff_role VARCHAR(16) NOT NULL,
  owner_guard BIGINT UNSIGNED GENERATED ALWAYS AS
    (CASE WHEN staff_role = 'merchant_owner' THEN store_id END) STORED,
  PRIMARY KEY (platform_user_id),
  UNIQUE KEY uq_active_owner_of_store (owner_guard),
  UNIQUE KEY uq_active_staff_id (staff_id),
  CONSTRAINT fk_active_identity FOREIGN KEY (store_id, staff_id, platform_user_id, staff_role)
    REFERENCES staff (store_id, staff_id, platform_user_id, staff_role)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE staff_invitation (
  staff_invitation_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  invite_token_digest BINARY(32) NOT NULL,
  staff_invitation_created_by BIGINT UNSIGNED NOT NULL,
  created_at DATETIME(3) NOT NULL,
  staff_invitation_expires_at DATETIME(3) NOT NULL,
  staff_invitation_used_by BIGINT UNSIGNED NULL,
  staff_invitation_used_at DATETIME(3) NULL,
  PRIMARY KEY (staff_invitation_id),
  UNIQUE KEY uq_staff_invite_token (invite_token_digest),
  KEY ix_staff_invite_expiry (store_id, staff_invitation_expires_at),
  CONSTRAINT fk_staff_invite_creator FOREIGN KEY (store_id, staff_invitation_created_by)
    REFERENCES staff (store_id, staff_id),
  CONSTRAINT fk_staff_invite_user FOREIGN KEY (staff_invitation_used_by) REFERENCES platform_user (platform_user_id),
  CHECK (staff_invitation_expires_at = DATE_ADD(created_at, INTERVAL 12 HOUR)),
  CHECK ((staff_invitation_used_by IS NULL) = (staff_invitation_used_at IS NULL)),
  CHECK (staff_invitation_used_at IS NULL OR
    (staff_invitation_used_at >= created_at AND staff_invitation_used_at < staff_invitation_expires_at))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE store_customer (
  customer_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  platform_user_id BIGINT UNSIGNED NULL,
  customer_name VARCHAR(64) NOT NULL,
  customer_contact_mobile VARCHAR(24) NULL,
  customer_contact_wechat VARCHAR(128) NULL,
  binding_state VARCHAR(20) NOT NULL DEFAULT 'unbound',
  row_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (customer_id),
  UNIQUE KEY uq_customer_store_id (store_id, customer_id),
  UNIQUE KEY uq_customer_user_identity (store_id, customer_id, platform_user_id),
  UNIQUE KEY uq_customer_bound_user (store_id, platform_user_id),
  KEY ix_customer_contact (store_id, customer_contact_mobile),
  CONSTRAINT fk_customer_store FOREIGN KEY (store_id) REFERENCES store (store_id),
  CONSTRAINT fk_customer_user FOREIGN KEY (platform_user_id) REFERENCES platform_user (platform_user_id),
  CHECK ((binding_state = 'bound' AND platform_user_id IS NOT NULL) OR
    (binding_state IN ('unbound','conflict') AND platform_user_id IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- The owner's canonical pet survives a store switch. A store-local record may exist before binding.
CREATE TABLE owner_pet (
  owner_pet_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  platform_user_id BIGINT UNSIGNED NOT NULL,
  pet_name VARCHAR(64) NOT NULL,
  species VARCHAR(24) NOT NULL,
  breed VARCHAR(64) NULL,
  profile_json JSON NOT NULL,
  row_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (owner_pet_id),
  UNIQUE KEY uq_owner_pet_identity (platform_user_id, owner_pet_id),
  CONSTRAINT fk_owner_pet_user FOREIGN KEY (platform_user_id) REFERENCES platform_user (platform_user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE store_pet (
  store_pet_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  customer_id BIGINT UNSIGNED NOT NULL,
  owner_pet_id BIGINT UNSIGNED NULL,
  owner_platform_user_id BIGINT UNSIGNED NULL,
  pet_name VARCHAR(64) NOT NULL,
  species VARCHAR(24) NOT NULL,
  breed VARCHAR(64) NULL,
  archived_at DATETIME(3) NULL,
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (store_pet_id),
  UNIQUE KEY uq_store_pet (store_id, store_pet_id),
  UNIQUE KEY uq_store_customer_pet (store_id, customer_id, store_pet_id),
  UNIQUE KEY uq_store_pet_identity (store_id, owner_pet_id),
  CONSTRAINT fk_store_pet_customer FOREIGN KEY (store_id, customer_id)
    REFERENCES store_customer (store_id, customer_id),
  CONSTRAINT fk_store_pet_bound_customer FOREIGN KEY (store_id, customer_id, owner_platform_user_id)
    REFERENCES store_customer (store_id, customer_id, platform_user_id),
  CONSTRAINT fk_store_pet_owner_pet FOREIGN KEY (owner_platform_user_id, owner_pet_id)
    REFERENCES owner_pet (platform_user_id, owner_pet_id),
  CHECK ((owner_pet_id IS NULL) = (owner_platform_user_id IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE service_item (
  service_item_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  business_item_category VARCHAR(12) NOT NULL,
  service_item_name VARCHAR(100) NOT NULL,
  service_item_description VARCHAR(500) NULL,
  reference_price DECIMAL(19,2) NOT NULL,
  service_item_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  pinned_at DATETIME(3) NULL,
  service_item_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  PRIMARY KEY (service_item_id),
  UNIQUE KEY uq_service_store (store_id, service_item_id),
  KEY ix_service_catalog (store_id, business_item_category, service_item_enabled, pinned_at),
  CONSTRAINT fk_service_item_store FOREIGN KEY (store_id) REFERENCES store (store_id),
  CHECK (business_item_category IN ('wash','groom','other')),
  CHECK (reference_price > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE appointment (
  appointment_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  customer_id BIGINT UNSIGNED NOT NULL,
  appointment_type VARCHAR(16) NOT NULL,
  appointment_status VARCHAR(20) NOT NULL,
  requested_start_at DATETIME(3) NOT NULL,
  confirmed_start_at DATETIME(3) NULL,
  expected_checkout_at DATETIME(3) NULL,
  special_request VARCHAR(500) NULL,
  appointment_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (appointment_id),
  UNIQUE KEY uq_appointment_store (store_id, appointment_id),
  UNIQUE KEY uq_appointment_customer (store_id, customer_id, appointment_id),
  KEY ix_appointment_queue (store_id, appointment_status, requested_start_at, appointment_id),
  KEY ix_confirmed_slots (store_id, confirmed_start_at, appointment_id),
  CONSTRAINT fk_appointment_customer FOREIGN KEY (store_id, customer_id)
    REFERENCES store_customer (store_id, customer_id),
  CHECK (appointment_type IN ('wash_groom','boarding')),
  CHECK (appointment_status IN ('pending','confirmed','rejected','cancelled','expired','completed')),
  CHECK (appointment_type <> 'boarding' OR expected_checkout_at IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE appointment_revision (
  appointment_revision_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  customer_id BIGINT UNSIGNED NOT NULL,
  appointment_id BIGINT UNSIGNED NOT NULL,
  base_appointment_version BIGINT UNSIGNED NOT NULL,
  revision_kind VARCHAR(12) NOT NULL,
  revision_status VARCHAR(16) NOT NULL,
  proposed_start_at DATETIME(3) NOT NULL,
  proposed_checkout_at DATETIME(3) NULL,
  change_deadline_at DATETIME(3) NULL,
  initiated_by_type VARCHAR(12) NOT NULL,
  initiated_by_id BIGINT UNSIGNED NOT NULL,
  created_at DATETIME(3) NOT NULL,
  pending_guard BIGINT UNSIGNED GENERATED ALWAYS AS
    (CASE WHEN revision_status = 'pending' THEN appointment_id END) STORED,
  PRIMARY KEY (appointment_revision_id),
  UNIQUE KEY uq_appointment_open_proposal (pending_guard),
  UNIQUE KEY uq_revision_store_customer (store_id, customer_id, appointment_revision_id),
  KEY ix_appointment_history (store_id, appointment_id, created_at),
  CONSTRAINT fk_revision_appointment FOREIGN KEY (store_id, customer_id, appointment_id)
    REFERENCES appointment (store_id, customer_id, appointment_id),
  CHECK (revision_kind IN ('initial','change')),
  CHECK (revision_status IN ('pending','accepted','rejected','withdrawn','expired','superseded')),
  CHECK (initiated_by_type IN ('customer','staff')),
  CHECK (revision_kind <> 'change' OR change_deadline_at IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE appointment_revision_item (
  store_id BIGINT UNSIGNED NOT NULL,
  customer_id BIGINT UNSIGNED NOT NULL,
  appointment_revision_id BIGINT UNSIGNED NOT NULL,
  line_no SMALLINT UNSIGNED NOT NULL,
  store_pet_id BIGINT UNSIGNED NOT NULL,
  service_item_id BIGINT UNSIGNED NULL,
  service_item_snapshot JSON NULL,
  PRIMARY KEY (appointment_revision_id, line_no),
  CONSTRAINT fk_appointment_item_revision FOREIGN KEY (store_id, customer_id, appointment_revision_id)
    REFERENCES appointment_revision (store_id, customer_id, appointment_revision_id),
  CONSTRAINT fk_appointment_item_pet FOREIGN KEY (store_id, customer_id, store_pet_id)
    REFERENCES store_pet (store_id, customer_id, store_pet_id),
  CONSTRAINT fk_appointment_item_service FOREIGN KEY (store_id, service_item_id)
    REFERENCES service_item (store_id, service_item_id),
  CHECK ((service_item_id IS NULL) = (service_item_snapshot IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE product_category (
  product_category_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  product_category_name VARCHAR(64) NOT NULL,
  product_category_sort_order INT NOT NULL DEFAULT 0,
  product_category_is_fallback BOOLEAN NOT NULL DEFAULT FALSE,
  fallback_guard BIGINT UNSIGNED GENERATED ALWAYS AS
    (CASE WHEN product_category_is_fallback = TRUE THEN store_id END) STORED,
  PRIMARY KEY (product_category_id),
  UNIQUE KEY uq_category_store (store_id, product_category_id),
  UNIQUE KEY uq_category_fallback (fallback_guard),
  CONSTRAINT fk_category_store FOREIGN KEY (store_id) REFERENCES store (store_id),
  CHECK (product_category_is_fallback IN (0,1))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- V1 1 product : 1 SKU. The two logical identities remain distinct.
CREATE TABLE product_sku (
  sku_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  product_id BIGINT UNSIGNED NOT NULL,
  product_category_id BIGINT UNSIGNED NOT NULL,
  product_name VARCHAR(128) NOT NULL,
  spec_label VARCHAR(128) NOT NULL,
  barcode VARCHAR(64) NULL,
  sale_price DECIMAL(19,2) NOT NULL,
  on_hand_inventory_qty INT NOT NULL DEFAULT 0,
  reserved_inventory_qty INT NOT NULL DEFAULT 0,
  available_inventory_qty INT GENERATED ALWAYS AS (on_hand_inventory_qty - reserved_inventory_qty) STORED,
  product_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  boarding_feed_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  recommended_rank INT NULL,
  product_detail JSON NOT NULL,
  row_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  PRIMARY KEY (sku_id),
  UNIQUE KEY uq_sku_store (store_id, sku_id),
  UNIQUE KEY uq_one_sku_per_product (store_id, product_id),
  KEY ix_catalog_visibility (store_id, product_enabled, recommended_rank),
  CONSTRAINT fk_sku_category FOREIGN KEY (store_id, product_category_id)
    REFERENCES product_category (store_id, product_category_id),
  CHECK (sale_price >= 0),
  CHECK (on_hand_inventory_qty >= reserved_inventory_qty AND reserved_inventory_qty >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- The non-null generated scope uses 0 only for an anonymous order.
-- Explicit customer IDs are positive, so composite FKs always compare identity even for cash sales.
CREATE TABLE consumption_order (
  order_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  customer_id BIGINT UNSIGNED NULL,
  customer_scope_id BIGINT UNSIGNED GENERATED ALWAYS AS (COALESCE(customer_id, 0)) STORED,
  appointment_id BIGINT UNSIGNED NULL,
  recovery_of_order_id BIGINT UNSIGNED NULL,
  order_type VARCHAR(20) NOT NULL,
  order_status VARCHAR(20) NOT NULL,
  source_channel VARCHAR(32) NOT NULL,
  business_scenario VARCHAR(24) NOT NULL DEFAULT 'normal',
  order_performance_staff_id BIGINT UNSIGNED NULL,
  order_hold_expires_at DATETIME(3) NULL,
  order_amount_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  occurred_at DATETIME(3) NOT NULL,
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (order_id),
  UNIQUE KEY uq_order_store (store_id, order_id),
  UNIQUE KEY uq_order_customer_identity (store_id, customer_id, order_id),
  UNIQUE KEY uq_order_customer_scope (store_id, order_id, customer_scope_id),
  UNIQUE KEY uq_order_customer_scenario (store_id, order_id, customer_id, business_scenario),
  UNIQUE KEY uq_order_appointment (store_id, appointment_id),
  UNIQUE KEY uq_order_recovery (store_id, recovery_of_order_id),
  KEY ix_order_queue (store_id, order_status, created_at, order_id),
  KEY ix_order_attribution (store_id, order_performance_staff_id, created_at, order_id),
  CONSTRAINT fk_order_store FOREIGN KEY (store_id) REFERENCES store (store_id),
  CONSTRAINT fk_order_customer FOREIGN KEY (store_id, customer_id) REFERENCES store_customer (store_id, customer_id),
  CONSTRAINT fk_order_appointment FOREIGN KEY (store_id, customer_id, appointment_id)
    REFERENCES appointment (store_id, customer_id, appointment_id),
  CONSTRAINT fk_order_recovery FOREIGN KEY (store_id, recovery_of_order_id) REFERENCES consumption_order (store_id, order_id),
  CONSTRAINT fk_order_staff FOREIGN KEY (store_id, order_performance_staff_id) REFERENCES staff (store_id, staff_id),
  CHECK (order_type IN ('wash_groom','independent_care','boarding','product')),
  CHECK (order_status IN ('requested','open','completed','cancelled','voided','expired')),
  CHECK (business_scenario IN ('normal','boarding_feed')),
  CHECK (customer_id IS NULL OR customer_id > 0),
  CHECK (appointment_id IS NULL OR customer_id IS NOT NULL),
  CHECK (business_scenario <> 'boarding_feed' OR (order_type = 'product' AND customer_id IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE consumption_order_item (
  order_item_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  order_id BIGINT UNSIGNED NOT NULL,
  customer_id BIGINT UNSIGNED NULL,
  customer_scope_id BIGINT UNSIGNED GENERATED ALWAYS AS (COALESCE(customer_id, 0)) STORED,
  store_pet_id BIGINT UNSIGNED NULL,
  service_item_id BIGINT UNSIGNED NULL,
  sku_id BIGINT UNSIGNED NULL,
  item_kind VARCHAR(16) NOT NULL,
  requested_quantity INT UNSIGNED NOT NULL,
  confirmed_quantity INT UNSIGNED NULL,
  item_original_unit_price DECIMAL(19,2) NOT NULL,
  item_original_amount DECIMAL(19,2) NULL,
  item_snapshot JSON NOT NULL,
  PRIMARY KEY (order_item_id),
  UNIQUE KEY uq_order_line_identity (store_id, order_id, order_item_id),
  UNIQUE KEY uq_order_line_pet (store_id, order_id, order_item_id, store_pet_id),
  UNIQUE KEY uq_order_line_sku (store_id, order_id, order_item_id, sku_id),
  CONSTRAINT fk_item_order FOREIGN KEY (store_id, order_id) REFERENCES consumption_order (store_id, order_id),
  CONSTRAINT fk_item_customer_order FOREIGN KEY (store_id, order_id, customer_scope_id)
    REFERENCES consumption_order (store_id, order_id, customer_scope_id),
  CONSTRAINT fk_item_pet FOREIGN KEY (store_id, customer_id, store_pet_id)
    REFERENCES store_pet (store_id, customer_id, store_pet_id),
  CONSTRAINT fk_item_service FOREIGN KEY (store_id, service_item_id) REFERENCES service_item (store_id, service_item_id),
  CONSTRAINT fk_item_sku FOREIGN KEY (store_id, sku_id) REFERENCES product_sku (store_id, sku_id),
  CHECK (customer_id IS NULL OR customer_id > 0),
  CHECK (requested_quantity > 0 AND item_original_unit_price >= 0),
  CHECK (store_pet_id IS NULL OR customer_id IS NOT NULL),
  CHECK (item_original_amount IS NULL OR item_original_amount >= 0),
  CHECK ((item_kind = 'product' AND sku_id IS NOT NULL AND service_item_id IS NULL) OR
         (item_kind = 'service' AND sku_id IS NULL AND store_pet_id IS NOT NULL) OR
         (item_kind = 'boarding' AND sku_id IS NULL AND service_item_id IS NULL AND
          store_pet_id IS NOT NULL AND item_original_unit_price > 0))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE service_record (
  service_record_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  order_id BIGINT UNSIGNED NOT NULL,
  -- Main service line for this pet; care add-ons are sibling lines and share this progress.
  order_item_id BIGINT UNSIGNED NOT NULL,
  store_pet_id BIGINT UNSIGNED NOT NULL,
  service_type VARCHAR(12) NOT NULL,
  service_internal_status VARCHAR(16) NOT NULL,
  service_record_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  start_check JSON NULL,
  completion_check JSON NULL,
  service_summary TEXT NULL,
  service_started_at DATETIME(3) NULL,
  service_completed_at DATETIME(3) NULL,
  service_started_by BIGINT UNSIGNED NULL,
  service_completed_by BIGINT UNSIGNED NULL,
  result_revision INT UNSIGNED NOT NULL DEFAULT 0,
  viewed_result_revision INT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (service_record_id),
  UNIQUE KEY uq_service_record_store (store_id, service_record_id),
  UNIQUE KEY uq_service_pet_identity (store_id, store_pet_id, service_record_id),
  UNIQUE KEY uq_progress_per_pet (store_id, order_id, store_pet_id),
  KEY ix_service_queue (store_id, service_internal_status, service_started_at),
  CONSTRAINT fk_record_pet_line FOREIGN KEY (store_id, order_id, order_item_id, store_pet_id)
    REFERENCES consumption_order_item (store_id, order_id, order_item_id, store_pet_id),
  CONSTRAINT fk_service_starter FOREIGN KEY (store_id, service_started_by) REFERENCES staff (store_id, staff_id),
  CONSTRAINT fk_service_completer FOREIGN KEY (store_id, service_completed_by) REFERENCES staff (store_id, staff_id),
  CHECK (service_type IN ('wash','groom','other')),
  CHECK (service_internal_status IN ('not_started','in_progress','completed','cancelled','interrupted')),
  CHECK (viewed_result_revision <= result_revision)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE service_media (
  service_media_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  service_record_id BIGINT UNSIGNED NOT NULL,
  comparison_group VARCHAR(16) NOT NULL,
  media_side VARCHAR(8) NOT NULL,
  media_ref VARCHAR(255) NOT NULL,
  recorded_at DATETIME(3) NOT NULL,
  PRIMARY KEY (service_media_id),
  UNIQUE KEY uq_comparison_slot (store_id, service_record_id, comparison_group, media_side),
  CONSTRAINT fk_media_service FOREIGN KEY (store_id, service_record_id)
    REFERENCES service_record (store_id, service_record_id),
  CHECK (comparison_group IN ('skin','ears','eyes','mouth','nails','coat','full_body')),
  CHECK (media_side IN ('before','after'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE boarding_stay (
  boarding_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  order_id BIGINT UNSIGNED NOT NULL,
  customer_id BIGINT UNSIGNED NOT NULL,
  order_item_id BIGINT UNSIGNED NOT NULL,
  store_pet_id BIGINT UNSIGNED NOT NULL,
  boarding_status VARCHAR(24) NOT NULL,
  check_in_at DATETIME(3) NOT NULL,
  expected_checkout_at DATETIME(3) NOT NULL,
  actual_checkout_at DATETIME(3) NULL,
  boarding_checkout_confirmed_at DATETIME(3) NULL,
  boarding_billable_nights INT UNSIGNED NULL,
  intake_details JSON NOT NULL,
  row_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  in_store_pet_guard BIGINT UNSIGNED GENERATED ALWAYS AS
    (CASE WHEN boarding_status = 'in_store' THEN store_pet_id END) STORED,
  PRIMARY KEY (boarding_id),
  UNIQUE KEY uq_boarding_store (store_id, boarding_id),
  UNIQUE KEY uq_boarding_customer (store_id, boarding_id, customer_id),
  UNIQUE KEY uq_boarding_order (store_id, order_id, boarding_id),
  UNIQUE KEY uq_boarding_order_line (store_id, order_id, boarding_id, order_item_id),
  UNIQUE KEY uq_stay_by_item (store_id, order_item_id),
  UNIQUE KEY uq_one_active_stay (store_id, in_store_pet_guard),
  KEY ix_boarding_queue (store_id, boarding_status, expected_checkout_at),
  CONSTRAINT fk_boarding_customer_order FOREIGN KEY (store_id, customer_id, order_id)
    REFERENCES consumption_order (store_id, customer_id, order_id),
  CONSTRAINT fk_boarding_pet_line FOREIGN KEY (store_id, order_id, order_item_id, store_pet_id)
    REFERENCES consumption_order_item (store_id, order_id, order_item_id, store_pet_id),
  CHECK (boarding_status IN ('in_store','checked_out','cancelled')),
  CHECK (expected_checkout_at > check_in_at),
  CHECK ((boarding_status = 'checked_out' AND actual_checkout_at IS NOT NULL
          AND boarding_checkout_confirmed_at IS NOT NULL
          AND boarding_billable_nights IS NOT NULL
          AND actual_checkout_at >= check_in_at) OR
        (boarding_status <> 'checked_out' AND actual_checkout_at IS NULL
          AND boarding_checkout_confirmed_at IS NULL AND boarding_billable_nights IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE boarding_care_event (
  boarding_event_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  boarding_id BIGINT UNSIGNED NOT NULL,
  boarding_event_type VARCHAR(16) NOT NULL,
  boarding_event_content VARCHAR(500) NULL,
  media_refs JSON NULL,
  boarding_event_visibility VARCHAR(20) NOT NULL,
  occurred_at DATETIME(3) NOT NULL,
  recorded_at DATETIME(3) NOT NULL,
  boarding_event_created_by_staff_id BIGINT UNSIGNED NOT NULL,
  boarding_event_performed_by_staff_id BIGINT UNSIGNED NULL,
  row_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  PRIMARY KEY (boarding_event_id),
  KEY ix_boarding_timeline (store_id, boarding_id, occurred_at, boarding_event_id),
  CONSTRAINT fk_event_boarding FOREIGN KEY (store_id, boarding_id) REFERENCES boarding_stay (store_id, boarding_id),
  CONSTRAINT fk_event_creator FOREIGN KEY (store_id, boarding_event_created_by_staff_id) REFERENCES staff (store_id, staff_id),
  CONSTRAINT fk_event_performer FOREIGN KEY (store_id, boarding_event_performed_by_staff_id) REFERENCES staff (store_id, staff_id),
  CHECK (boarding_event_type IN ('feeding','walking','cage_cleaning','other')),
  CHECK (boarding_event_visibility IN ('customer_visible','store_internal'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Boarding snacks are regular product orders linked to an existing stay.
CREATE TABLE boarding_product_order (
  store_id BIGINT UNSIGNED NOT NULL,
  order_id BIGINT UNSIGNED NOT NULL,
  boarding_id BIGINT UNSIGNED NOT NULL,
  customer_id BIGINT UNSIGNED NOT NULL,
  business_scenario VARCHAR(24) NOT NULL DEFAULT 'boarding_feed',
  PRIMARY KEY (store_id, order_id),
  CONSTRAINT fk_boarding_product_order FOREIGN KEY (store_id, order_id, customer_id, business_scenario)
    REFERENCES consumption_order (store_id, order_id, customer_id, business_scenario),
  CONSTRAINT fk_boarding_product_stay FOREIGN KEY (store_id, boarding_id, customer_id)
    REFERENCES boarding_stay (store_id, boarding_id, customer_id),
  CHECK (business_scenario = 'boarding_feed')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE order_settlement (
  settlement_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  order_id BIGINT UNSIGNED NOT NULL,
  settlement_scope VARCHAR(16) NOT NULL,
  settlement_status VARCHAR(16) NOT NULL,
  original_receivable_amount DECIMAL(19,2) NULL,
  final_receivable_amount DECIMAL(19,2) NULL,
  manual_adjustment_amount DECIMAL(19,2) GENERATED ALWAYS AS
    (final_receivable_amount - original_receivable_amount) STORED,
  is_on_hold BOOLEAN NOT NULL DEFAULT FALSE,
  order_held_at DATETIME(3) NULL,
  order_hold_released_at DATETIME(3) NULL,
  settled_at DATETIME(3) NULL,
  waiver_reason VARCHAR(255) NULL,
  created_at DATETIME(3) NOT NULL,
  whole_order_guard BIGINT UNSIGNED GENERATED ALWAYS AS
    (CASE WHEN settlement_scope = 'whole_order' THEN order_id END) STORED,
  PRIMARY KEY (settlement_id),
  UNIQUE KEY uq_one_whole_settlement (whole_order_guard),
  UNIQUE KEY uq_settlement_store (store_id, settlement_id),
  UNIQUE KEY uq_settlement_order (store_id, order_id, settlement_id),
  KEY ix_settlement_queue (store_id, settlement_status, order_held_at, settlement_id),
  KEY ix_settlement_hold (store_id, is_on_hold, order_held_at, settlement_id),
  CONSTRAINT fk_settlement_order FOREIGN KEY (store_id, order_id) REFERENCES consumption_order (store_id, order_id),
  CHECK (settlement_scope IN ('whole_order','boarding_batch')),
  CHECK (settlement_status IN ('pending','paid','waived','cancelled')),
  CHECK (original_receivable_amount IS NULL OR original_receivable_amount >= 0),
  CHECK (final_receivable_amount IS NULL OR final_receivable_amount >= 0),
  CHECK ((settlement_status IN ('paid','waived')) = (settled_at IS NOT NULL)),
  CHECK (settlement_status NOT IN ('paid','waived') OR
    (final_receivable_amount IS NOT NULL AND original_receivable_amount IS NOT NULL)),
  CHECK ((is_on_hold = TRUE AND settlement_status = 'pending' AND order_held_at IS NOT NULL
      AND order_hold_released_at IS NULL) OR
    (is_on_hold = FALSE AND (
      (order_held_at IS NULL AND order_hold_released_at IS NULL) OR
      (order_held_at IS NOT NULL AND order_hold_released_at IS NOT NULL
        AND order_hold_released_at >= order_held_at)))),
  CHECK ((settlement_status = 'waived' AND final_receivable_amount = 0
      AND waiver_reason IS NOT NULL AND CHAR_LENGTH(TRIM(waiver_reason)) > 0) OR
    (settlement_status <> 'waived' AND waiver_reason IS NULL)),
  CHECK (settlement_status <> 'paid' OR final_receivable_amount > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Assigned once at confirmed checkout; amounts may be adjusted before financial settlement through the documented action.
CREATE TABLE boarding_settlement_item (
  store_id BIGINT UNSIGNED NOT NULL,
  order_id BIGINT UNSIGNED NOT NULL,
  settlement_id BIGINT UNSIGNED NOT NULL,
  boarding_id BIGINT UNSIGNED NOT NULL,
  order_item_id BIGINT UNSIGNED NOT NULL,
  rate_snapshot DECIMAL(19,2) NOT NULL,
  nights_snapshot INT UNSIGNED NOT NULL,
  base_amount DECIMAL(19,2) GENERATED ALWAYS AS (rate_snapshot * nights_snapshot) STORED,
  PRIMARY KEY (boarding_id),
  UNIQUE KEY uq_boarding_line_charged_once (store_id, order_item_id),
  KEY ix_batch_lines (store_id, settlement_id),
  CONSTRAINT fk_batch_settlement FOREIGN KEY (store_id, order_id, settlement_id)
    REFERENCES order_settlement (store_id, order_id, settlement_id),
  CONSTRAINT fk_batch_stay_item FOREIGN KEY (store_id, order_id, boarding_id, order_item_id)
    REFERENCES boarding_stay (store_id, order_id, boarding_id, order_item_id),
  CHECK (rate_snapshot > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE wallet_account (
  wallet_account_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  customer_id BIGINT UNSIGNED NOT NULL,
  principal_balance DECIMAL(19,2) NOT NULL DEFAULT 0,
  bonus_balance DECIMAL(19,2) NOT NULL DEFAULT 0,
  row_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  PRIMARY KEY (wallet_account_id),
  UNIQUE KEY uq_wallet_store (store_id, wallet_account_id),
  UNIQUE KEY uq_wallet_customer (store_id, customer_id),
  UNIQUE KEY uq_wallet_owner (store_id, customer_id, wallet_account_id),
  CONSTRAINT fk_wallet_customer FOREIGN KEY (store_id, customer_id) REFERENCES store_customer (store_id, customer_id),
  CHECK (principal_balance >= 0 AND bonus_balance >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE wallet_recharge (
  recharge_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  wallet_account_id BIGINT UNSIGNED NOT NULL,
  recharge_paid_amount DECIMAL(19,2) NOT NULL,
  recharge_bonus_amount DECIMAL(19,2) NOT NULL DEFAULT 0,
  payment_method VARCHAR(16) NOT NULL,
  -- Coupon-only gifts also require this note in the atomic recharge/issuance transaction.
  gift_note VARCHAR(255) NULL,
  occurred_at DATETIME(3) NOT NULL,
  created_at DATETIME(3) NOT NULL,
  staff_id BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (recharge_id),
  UNIQUE KEY uq_recharge_store (store_id, recharge_id),
  UNIQUE KEY uq_recharge_wallet (store_id, wallet_account_id, recharge_id),
  KEY ix_recharge_order_date (store_id, created_at, recharge_id),
  KEY ix_recharge_transaction_date (store_id, occurred_at, recharge_id),
  CONSTRAINT fk_recharge_wallet FOREIGN KEY (store_id, wallet_account_id) REFERENCES wallet_account (store_id, wallet_account_id),
  CONSTRAINT fk_recharge_staff FOREIGN KEY (store_id, staff_id) REFERENCES staff (store_id, staff_id),
  CHECK (recharge_paid_amount > 0 AND recharge_bonus_amount >= 0),
  CHECK (payment_method IN ('wechat','alipay','cash','other')),
  CHECK (recharge_bonus_amount = 0 OR (gift_note IS NOT NULL AND CHAR_LENGTH(TRIM(gift_note)) > 0))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE wallet_recharge_refund (
  recharge_refund_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  wallet_account_id BIGINT UNSIGNED NOT NULL,
  recharge_id BIGINT UNSIGNED NOT NULL,
  returned_principal DECIMAL(19,2) NOT NULL,
  recalled_bonus DECIMAL(19,2) NOT NULL DEFAULT 0,
  refund_mode VARCHAR(16) NOT NULL,
  refund_reason VARCHAR(255) NOT NULL,
  occurred_at DATETIME(3) NOT NULL,
  created_at DATETIME(3) NOT NULL,
  staff_id BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (recharge_refund_id),
  UNIQUE KEY uq_recharge_refund_store (store_id, recharge_refund_id),
  KEY ix_recharge_refunds (store_id, recharge_id, recharge_refund_id),
  CONSTRAINT fk_recharge_refund_parent FOREIGN KEY (store_id, wallet_account_id, recharge_id)
    REFERENCES wallet_recharge (store_id, wallet_account_id, recharge_id),
  CONSTRAINT fk_recharge_refund_staff FOREIGN KEY (store_id, staff_id) REFERENCES staff (store_id, staff_id),
  CHECK (returned_principal > 0 AND recalled_bonus >= 0 AND CHAR_LENGTH(TRIM(refund_reason)) > 0),
  CHECK (refund_mode IN ('standard','owner_manual')),
  CHECK (refund_mode <> 'owner_manual' OR recalled_bonus = 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Optional evidence for one real external payment allocated across independent orders.
CREATE TABLE external_collection_evidence (
  external_collection_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  payment_method VARCHAR(16) NOT NULL,
  reference_digest BINARY(32) NOT NULL,
  verified_amount DECIMAL(19,2) NOT NULL,
  occurred_at DATETIME(3) NOT NULL,
  PRIMARY KEY (external_collection_id),
  UNIQUE KEY uq_external_ref (store_id, payment_method, reference_digest),
  UNIQUE KEY uq_external_method (store_id, external_collection_id, payment_method),
  CHECK (payment_method IN ('wechat','alipay','cash','other')),
  CHECK (verified_amount > 0),
  CONSTRAINT fk_external_collection_store FOREIGN KEY (store_id) REFERENCES store (store_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE payment_record (
  payment_record_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  order_id BIGINT UNSIGNED NOT NULL,
  customer_id BIGINT UNSIGNED NULL,
  customer_scope_id BIGINT UNSIGNED GENERATED ALWAYS AS (COALESCE(customer_id, 0)) STORED,
  settlement_id BIGINT UNSIGNED NOT NULL,
  record_kind VARCHAR(24) NOT NULL,
  total_payment_amount DECIMAL(19,2) NOT NULL,
  payment_occurred_at DATETIME(3) NOT NULL,
  payment_confirmed_at DATETIME(3) NOT NULL,
  payment_confirmed_by_staff_id BIGINT UNSIGNED NULL,
  actor_platform_id BIGINT UNSIGNED NULL,
  verified_fact_ref VARCHAR(191) NULL,
  initial_guard BIGINT UNSIGNED GENERATED ALWAYS AS
    (CASE WHEN record_kind = 'initial_settlement' THEN settlement_id END) STORED,
  PRIMARY KEY (payment_record_id),
  UNIQUE KEY uq_initial_per_settlement (initial_guard),
  UNIQUE KEY uq_payment_settlement (store_id, settlement_id, payment_record_id),
  UNIQUE KEY uq_payment_customer_scope (store_id, settlement_id, payment_record_id, customer_scope_id),
  KEY ix_payment_business_date (store_id, payment_occurred_at, payment_record_id),
  CONSTRAINT fk_payment_settlement FOREIGN KEY (store_id, order_id, settlement_id)
    REFERENCES order_settlement (store_id, order_id, settlement_id),
  CONSTRAINT fk_payment_customer_order FOREIGN KEY (store_id, order_id, customer_scope_id)
    REFERENCES consumption_order (store_id, order_id, customer_scope_id),
  CONSTRAINT fk_payment_staff FOREIGN KEY (store_id, payment_confirmed_by_staff_id)
    REFERENCES staff (store_id, staff_id),
  CHECK (record_kind IN ('initial_settlement','supplement_collection')),
  CHECK (customer_id IS NULL OR customer_id > 0),
  CHECK (total_payment_amount > 0),
  CHECK ((payment_confirmed_by_staff_id IS NULL) <> (actor_platform_id IS NULL)),
  CHECK (record_kind <> 'supplement_collection' OR verified_fact_ref IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE payment_split (
  payment_split_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  settlement_id BIGINT UNSIGNED NOT NULL,
  payment_record_id BIGINT UNSIGNED NOT NULL,
  customer_id BIGINT UNSIGNED NULL,
  customer_scope_id BIGINT UNSIGNED GENERATED ALWAYS AS (COALESCE(customer_id, 0)) STORED,
  split_slot TINYINT UNSIGNED NOT NULL,
  payment_method VARCHAR(16) NOT NULL,
  payment_amount DECIMAL(19,2) NOT NULL,
  wallet_account_id BIGINT UNSIGNED NULL,
  wallet_principal_part DECIMAL(19,2) NOT NULL DEFAULT 0,
  wallet_bonus_part DECIMAL(19,2) NOT NULL DEFAULT 0,
  external_collection_id BIGINT UNSIGNED NULL,
  PRIMARY KEY (payment_split_id),
  UNIQUE KEY uq_payment_slot (payment_record_id, split_slot),
  UNIQUE KEY uq_payment_method (payment_record_id, payment_method),
  UNIQUE KEY uq_payment_split_source (store_id, settlement_id, payment_split_id, payment_method),
  KEY ix_external_allocation (store_id, external_collection_id),
  CONSTRAINT fk_split_payment FOREIGN KEY (store_id, settlement_id, payment_record_id)
    REFERENCES payment_record (store_id, settlement_id, payment_record_id),
  CONSTRAINT fk_split_payment_customer FOREIGN KEY (store_id, settlement_id, payment_record_id, customer_scope_id)
    REFERENCES payment_record (store_id, settlement_id, payment_record_id, customer_scope_id),
  CONSTRAINT fk_split_wallet FOREIGN KEY (store_id, customer_id, wallet_account_id)
    REFERENCES wallet_account (store_id, customer_id, wallet_account_id),
  CONSTRAINT fk_split_external FOREIGN KEY (store_id, external_collection_id, payment_method)
    REFERENCES external_collection_evidence (store_id, external_collection_id, payment_method),
  CHECK (customer_id IS NULL OR customer_id > 0),
  CHECK (split_slot IN (1,2) AND payment_amount > 0),
  CHECK (payment_method IN ('wallet','wechat','alipay','cash','other')),
  CHECK (wallet_principal_part >= 0 AND wallet_bonus_part >= 0),
  CHECK ((payment_method = 'wallet' AND wallet_account_id IS NOT NULL AND customer_id IS NOT NULL
      AND external_collection_id IS NULL AND payment_amount = wallet_principal_part + wallet_bonus_part)
    OR (payment_method <> 'wallet' AND wallet_account_id IS NULL
      AND wallet_principal_part = 0 AND wallet_bonus_part = 0))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE refund_record (
  refund_record_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  order_id BIGINT UNSIGNED NOT NULL,
  settlement_id BIGINT UNSIGNED NOT NULL,
  refund_requested_amount DECIMAL(19,2) NOT NULL,
  refund_reason VARCHAR(255) NOT NULL,
  refunded_at DATETIME(3) NOT NULL,
  refund_recorded_at DATETIME(3) NOT NULL,
  refund_recorded_by_staff_id BIGINT UNSIGNED NULL,
  actor_platform_id BIGINT UNSIGNED NULL,
  PRIMARY KEY (refund_record_id),
  UNIQUE KEY uq_refund_settlement (store_id, settlement_id, refund_record_id),
  KEY ix_refund_date (store_id, refunded_at, refund_record_id),
  CONSTRAINT fk_refund_settlement FOREIGN KEY (store_id, order_id, settlement_id)
    REFERENCES order_settlement (store_id, order_id, settlement_id),
  CONSTRAINT fk_refund_staff FOREIGN KEY (store_id, refund_recorded_by_staff_id) REFERENCES staff (store_id, staff_id),
  CHECK (refund_requested_amount > 0 AND CHAR_LENGTH(TRIM(refund_reason)) > 0),
  CHECK ((refund_recorded_by_staff_id IS NULL) <> (actor_platform_id IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE refund_allocation (
  refund_allocation_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  settlement_id BIGINT UNSIGNED NOT NULL,
  refund_record_id BIGINT UNSIGNED NOT NULL,
  payment_split_id BIGINT UNSIGNED NOT NULL,
  refund_method VARCHAR(16) NOT NULL,
  refund_method_amount DECIMAL(19,2) NOT NULL,
  principal_refund DECIMAL(19,2) NOT NULL DEFAULT 0,
  bonus_refund DECIMAL(19,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (refund_allocation_id),
  UNIQUE KEY uq_refund_allocation_store (store_id, refund_allocation_id),
  UNIQUE KEY uq_refund_source_once (refund_record_id, payment_split_id),
  KEY ix_refund_by_original_split (store_id, settlement_id, payment_split_id),
  CONSTRAINT fk_allocation_refund FOREIGN KEY (store_id, settlement_id, refund_record_id)
    REFERENCES refund_record (store_id, settlement_id, refund_record_id),
  CONSTRAINT fk_allocation_source FOREIGN KEY (store_id, settlement_id, payment_split_id, refund_method)
    REFERENCES payment_split (store_id, settlement_id, payment_split_id, payment_method),
  CHECK (refund_method_amount > 0 AND principal_refund >= 0 AND bonus_refund >= 0),
  CHECK ((refund_method = 'wallet' AND refund_method_amount = principal_refund + bonus_refund)
    OR (refund_method <> 'wallet' AND principal_refund = 0 AND bonus_refund = 0))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Stable refund staging is scoped to the original order. No asset moves while editing.
CREATE TABLE refund_request (
  refund_request_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  order_id BIGINT UNSIGNED NOT NULL,
  settlement_id BIGINT UNSIGNED NOT NULL,
  editing_staff_id BIGINT UNSIGNED NULL,
  editing_platform_id BIGINT UNSIGNED NULL,
  refund_request_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  request_state VARCHAR(16) NOT NULL,
  request_payload JSON NOT NULL,
  created_at DATETIME(3) NOT NULL,
  draft_guard BIGINT UNSIGNED GENERATED ALWAYS AS
    (CASE WHEN request_state = 'editing' THEN order_id END) STORED,
  PRIMARY KEY (refund_request_id),
  UNIQUE KEY uq_order_open_refund_request (draft_guard),
  CONSTRAINT fk_refund_request_settlement FOREIGN KEY (store_id, order_id, settlement_id)
    REFERENCES order_settlement (store_id, order_id, settlement_id),
  CONSTRAINT fk_refund_request_actor FOREIGN KEY (store_id, editing_staff_id) REFERENCES staff (store_id, staff_id),
  CHECK (request_state IN ('editing','confirmed','closed')),
  CHECK ((editing_staff_id IS NULL) <> (editing_platform_id IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE wallet_ledger (
  balance_ledger_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  wallet_account_id BIGINT UNSIGNED NOT NULL,
  event_kind VARCHAR(24) NOT NULL,
  fact_id BIGINT UNSIGNED NOT NULL,
  principal_before DECIMAL(19,2) NOT NULL,
  bonus_before DECIMAL(19,2) NOT NULL,
  principal_delta DECIMAL(19,2) NOT NULL,
  bonus_delta DECIMAL(19,2) NOT NULL,
  principal_after DECIMAL(19,2) GENERATED ALWAYS AS (principal_before + principal_delta) STORED,
  bonus_after DECIMAL(19,2) GENERATED ALWAYS AS (bonus_before + bonus_delta) STORED,
  occurred_at DATETIME(3) NOT NULL,
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (balance_ledger_id),
  UNIQUE KEY uq_wallet_fact (store_id, event_kind, fact_id),
  UNIQUE KEY uq_wallet_ledger_scope (store_id, wallet_account_id, balance_ledger_id),
  KEY ix_wallet_ledger (store_id, wallet_account_id, created_at, balance_ledger_id),
  CONSTRAINT fk_ledger_wallet FOREIGN KEY (store_id, wallet_account_id) REFERENCES wallet_account (store_id, wallet_account_id),
  CHECK (principal_before >= 0 AND bonus_before >= 0 AND principal_after >= 0 AND bonus_after >= 0),
  CHECK ((event_kind IN ('recharge','consumption_refund') AND principal_delta >= 0 AND bonus_delta >= 0
      AND principal_delta + bonus_delta > 0)
    OR (event_kind IN ('consumption','recharge_refund') AND principal_delta <= 0 AND bonus_delta <= 0
      AND principal_delta + bonus_delta < 0))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Each gift balance adjustment names the original recharge and the consuming or restoring ledger fact.
CREATE TABLE wallet_bonus_allocation (
  store_id BIGINT UNSIGNED NOT NULL,
  wallet_account_id BIGINT UNSIGNED NOT NULL,
  recharge_id BIGINT UNSIGNED NOT NULL,
  balance_ledger_id BIGINT UNSIGNED NOT NULL,
  delta_amount DECIMAL(19,2) NOT NULL,
  PRIMARY KEY (balance_ledger_id, recharge_id),
  KEY ix_gift_source_balance (store_id, wallet_account_id, recharge_id, balance_ledger_id),
  CONSTRAINT fk_bonus_allocation_recharge FOREIGN KEY (store_id, wallet_account_id, recharge_id)
    REFERENCES wallet_recharge (store_id, wallet_account_id, recharge_id),
  CONSTRAINT fk_bonus_allocation_ledger FOREIGN KEY (store_id, wallet_account_id, balance_ledger_id)
    REFERENCES wallet_ledger (store_id, wallet_account_id, balance_ledger_id),
  CHECK (delta_amount <> 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE coupon_template (
  coupon_template_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  coupon_name VARCHAR(100) NOT NULL,
  terms_json JSON NOT NULL,
  coupon_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  row_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  PRIMARY KEY (coupon_template_id),
  UNIQUE KEY uq_template_store (store_id, coupon_template_id),
  CONSTRAINT fk_template_store FOREIGN KEY (store_id) REFERENCES store (store_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE invite_code (
  invite_code_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  invite_code_digest BINARY(32) NOT NULL,
  invite_code_content_type VARCHAR(20) NOT NULL,
  coupon_template_id BIGINT UNSIGNED NULL,
  service_item_id BIGINT UNSIGNED NULL,
  sku_id BIGINT UNSIGNED NULL,
  terms_snapshot JSON NOT NULL,
  created_by_staff_id BIGINT UNSIGNED NOT NULL,
  created_at DATETIME(3) NOT NULL,
  expires_at DATETIME(3) NOT NULL,
  PRIMARY KEY (invite_code_id),
  UNIQUE KEY uq_store_invite_code (store_id, invite_code_digest),
  UNIQUE KEY uq_invite_store (store_id, invite_code_id),
  CONSTRAINT fk_code_template FOREIGN KEY (store_id, coupon_template_id)
    REFERENCES coupon_template (store_id, coupon_template_id),
  CONSTRAINT fk_code_service FOREIGN KEY (store_id, service_item_id) REFERENCES service_item (store_id, service_item_id),
  CONSTRAINT fk_code_sku FOREIGN KEY (store_id, sku_id) REFERENCES product_sku (store_id, sku_id),
  CONSTRAINT fk_code_staff FOREIGN KEY (store_id, created_by_staff_id) REFERENCES staff (store_id, staff_id),
  CHECK (expires_at = DATE_ADD(created_at, INTERVAL 72 HOUR)),
  CHECK ((invite_code_content_type = 'coupon' AND coupon_template_id IS NOT NULL AND service_item_id IS NULL AND sku_id IS NULL)
    OR (invite_code_content_type = 'service_activity' AND coupon_template_id IS NULL AND service_item_id IS NOT NULL AND sku_id IS NULL)
    OR (invite_code_content_type = 'product_activity' AND coupon_template_id IS NULL AND service_item_id IS NULL AND sku_id IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE coupon_instance (
  coupon_instance_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  customer_id BIGINT UNSIGNED NOT NULL,
  coupon_template_id BIGINT UNSIGNED NULL,
  source_recharge_id BIGINT UNSIGNED NULL,
  source_wallet_id BIGINT UNSIGNED NULL,
  source_invite_code_id BIGINT UNSIGNED NULL,
  coupon_source_type VARCHAR(16) NOT NULL,
  entitlement_kind VARCHAR(20) NOT NULL,
  terms_snapshot JSON NOT NULL,
  valid_from DATETIME(3) NOT NULL,
  valid_until DATETIME(3) NOT NULL,
  removed_at DATETIME(3) NULL,
  row_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  PRIMARY KEY (coupon_instance_id),
  UNIQUE KEY uq_coupon_store (store_id, coupon_instance_id),
  UNIQUE KEY uq_coupon_customer (store_id, customer_id, coupon_instance_id, entitlement_kind),
  UNIQUE KEY uq_one_code_redemption (store_id, source_invite_code_id),
  KEY ix_coupon_wallet (store_id, customer_id, valid_until, coupon_instance_id),
  KEY ix_recharge_coupons (store_id, source_recharge_id),
  CONSTRAINT fk_coupon_customer FOREIGN KEY (store_id, customer_id) REFERENCES store_customer (store_id, customer_id),
  CONSTRAINT fk_coupon_template FOREIGN KEY (store_id, coupon_template_id) REFERENCES coupon_template (store_id, coupon_template_id),
  CONSTRAINT fk_coupon_wallet_owner FOREIGN KEY (store_id, customer_id, source_wallet_id)
    REFERENCES wallet_account (store_id, customer_id, wallet_account_id),
  CONSTRAINT fk_coupon_recharge FOREIGN KEY (store_id, source_wallet_id, source_recharge_id)
    REFERENCES wallet_recharge (store_id, wallet_account_id, recharge_id),
  CONSTRAINT fk_coupon_invite FOREIGN KEY (store_id, source_invite_code_id) REFERENCES invite_code (store_id, invite_code_id),
  CHECK (valid_until > valid_from),
  CHECK (entitlement_kind IN ('coupon','service_activity','product_activity')),
  CHECK ((entitlement_kind = 'coupon') = (coupon_template_id IS NOT NULL)),
  CHECK ((coupon_source_type = 'manual_grant' AND source_recharge_id IS NULL
      AND source_wallet_id IS NULL AND source_invite_code_id IS NULL AND entitlement_kind = 'coupon')
    OR (coupon_source_type = 'recharge_gift' AND source_recharge_id IS NOT NULL
      AND source_wallet_id IS NOT NULL AND source_invite_code_id IS NULL AND entitlement_kind = 'coupon')
    OR (coupon_source_type = 'invite_code' AND source_recharge_id IS NULL
      AND source_wallet_id IS NULL AND source_invite_code_id IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE coupon_settlement_lock (
  store_id BIGINT UNSIGNED NOT NULL,
  coupon_instance_id BIGINT UNSIGNED NOT NULL,
  customer_id BIGINT UNSIGNED NOT NULL,
  entitlement_kind VARCHAR(20) NOT NULL,
  order_id BIGINT UNSIGNED NOT NULL,
  settlement_id BIGINT UNSIGNED NOT NULL,
  lock_token BINARY(16) NOT NULL,
  locked_at DATETIME(3) NOT NULL,
  lock_expires_at DATETIME(3) NOT NULL,
  ordinary_order_guard BIGINT UNSIGNED GENERATED ALWAYS AS
    (CASE WHEN entitlement_kind = 'coupon' THEN order_id END) STORED,
  PRIMARY KEY (coupon_instance_id),
  UNIQUE KEY uq_ordinary_coupon_lock_per_order (ordinary_order_guard),
  KEY ix_coupon_lock_expiry (lock_expires_at, coupon_instance_id),
  CONSTRAINT fk_lock_coupon FOREIGN KEY (store_id, customer_id, coupon_instance_id, entitlement_kind)
    REFERENCES coupon_instance (store_id, customer_id, coupon_instance_id, entitlement_kind),
  CONSTRAINT fk_lock_order_customer FOREIGN KEY (store_id, customer_id, order_id)
    REFERENCES consumption_order (store_id, customer_id, order_id),
  CONSTRAINT fk_lock_settlement FOREIGN KEY (store_id, order_id, settlement_id)
    REFERENCES order_settlement (store_id, order_id, settlement_id),
  CHECK (lock_expires_at > locked_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE coupon_redemption (
  store_id BIGINT UNSIGNED NOT NULL,
  coupon_instance_id BIGINT UNSIGNED NOT NULL,
  customer_id BIGINT UNSIGNED NOT NULL,
  order_id BIGINT UNSIGNED NOT NULL,
  settlement_id BIGINT UNSIGNED NOT NULL,
  entitlement_kind VARCHAR(20) NOT NULL,
  calculation_snapshot JSON NOT NULL,
  coupon_redeemed_at DATETIME(3) NOT NULL,
  ordinary_order_guard BIGINT UNSIGNED GENERATED ALWAYS AS
    (CASE WHEN entitlement_kind = 'coupon' THEN order_id END) STORED,
  PRIMARY KEY (coupon_instance_id),
  UNIQUE KEY uq_ordinary_coupon_per_order (ordinary_order_guard),
  KEY ix_coupon_redemption_scope (store_id, settlement_id),
  CONSTRAINT fk_redemption_coupon FOREIGN KEY (store_id, customer_id, coupon_instance_id, entitlement_kind)
    REFERENCES coupon_instance (store_id, customer_id, coupon_instance_id, entitlement_kind),
  CONSTRAINT fk_redemption_order_customer FOREIGN KEY (store_id, customer_id, order_id)
    REFERENCES consumption_order (store_id, customer_id, order_id),
  CONSTRAINT fk_redemption_settlement FOREIGN KEY (store_id, order_id, settlement_id)
    REFERENCES order_settlement (store_id, order_id, settlement_id),
  CHECK (entitlement_kind IN ('coupon','service_activity','product_activity'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE inventory_reservation (
  store_id BIGINT UNSIGNED NOT NULL,
  order_id BIGINT UNSIGNED NOT NULL,
  order_item_id BIGINT UNSIGNED NOT NULL,
  sku_id BIGINT UNSIGNED NOT NULL,
  reserved_qty INT UNSIGNED NOT NULL,
  reservation_status VARCHAR(12) NOT NULL,
  expires_at DATETIME(3) NULL,
  row_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  PRIMARY KEY (order_item_id),
  KEY ix_reservation_due (reservation_status, expires_at, order_item_id),
  KEY ix_sku_current_reservations (store_id, sku_id, reservation_status),
  CONSTRAINT fk_reservation_line FOREIGN KEY (store_id, order_id, order_item_id, sku_id)
    REFERENCES consumption_order_item (store_id, order_id, order_item_id, sku_id),
  CONSTRAINT fk_reservation_sku FOREIGN KEY (store_id, sku_id) REFERENCES product_sku (store_id, sku_id),
  CHECK (reserved_qty > 0 AND reservation_status IN ('held','released','sold'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE stock_intake (
  stock_intake_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  stock_intake_method VARCHAR(16) NOT NULL,
  intake_status VARCHAR(12) NOT NULL,
  stock_intake_row_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  stock_intake_confirmed_by_staff_id BIGINT UNSIGNED NULL,
  stock_intake_posted_at DATETIME(3) NULL,
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (stock_intake_id),
  UNIQUE KEY uq_intake_store (store_id, stock_intake_id),
  KEY ix_intake_history (store_id, stock_intake_posted_at, stock_intake_id),
  CONSTRAINT fk_intake_store FOREIGN KEY (store_id) REFERENCES store (store_id),
  CONSTRAINT fk_intake_staff FOREIGN KEY (store_id, stock_intake_confirmed_by_staff_id) REFERENCES staff (store_id, staff_id),
  CHECK (stock_intake_method IN ('manual','ai_photo')),
  CHECK (intake_status IN ('editing','posted','abandoned')),
  CHECK ((intake_status = 'posted') =
    (stock_intake_confirmed_by_staff_id IS NOT NULL AND stock_intake_posted_at IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE stock_intake_item (
  stock_intake_item_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  stock_intake_id BIGINT UNSIGNED NOT NULL,
  sku_id BIGINT UNSIGNED NULL,
  item_input JSON NOT NULL,
  stock_intake_quantity INT UNSIGNED NULL,
  purchase_unit_price DECIMAL(19,2) NULL,
  PRIMARY KEY (stock_intake_item_id),
  KEY ix_intake_lines (store_id, stock_intake_id),
  CONSTRAINT fk_intake_item_header FOREIGN KEY (store_id, stock_intake_id)
    REFERENCES stock_intake (store_id, stock_intake_id),
  CONSTRAINT fk_intake_item_sku FOREIGN KEY (store_id, sku_id) REFERENCES product_sku (store_id, sku_id),
  CHECK (stock_intake_quantity IS NULL OR stock_intake_quantity > 0),
  CHECK (purchase_unit_price IS NULL OR purchase_unit_price >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE stock_intake_document (
  store_id BIGINT UNSIGNED NOT NULL,
  stock_intake_id BIGINT UNSIGNED NOT NULL,
  document_slot SMALLINT UNSIGNED NOT NULL,
  media_ref VARCHAR(255) NOT NULL,
  image_fingerprint BINARY(32) NOT NULL,
  PRIMARY KEY (stock_intake_id, document_slot),
  KEY ix_intake_fingerprint (store_id, image_fingerprint),
  CONSTRAINT fk_intake_doc_header FOREIGN KEY (store_id, stock_intake_id)
    REFERENCES stock_intake (store_id, stock_intake_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE product_return (
  product_return_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  order_id BIGINT UNSIGNED NOT NULL,
  order_item_id BIGINT UNSIGNED NOT NULL,
  sku_id BIGINT UNSIGNED NOT NULL,
  returned_qty INT UNSIGNED NOT NULL,
  resale_qty INT UNSIGNED NOT NULL,
  received_at DATETIME(3) NOT NULL,
  recorded_at DATETIME(3) NOT NULL,
  received_by_staff_id BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (product_return_id),
  KEY ix_return_by_item (store_id, order_id, order_item_id),
  CONSTRAINT fk_return_item FOREIGN KEY (store_id, order_id, order_item_id, sku_id)
    REFERENCES consumption_order_item (store_id, order_id, order_item_id, sku_id),
  CONSTRAINT fk_return_actor FOREIGN KEY (store_id, received_by_staff_id) REFERENCES staff (store_id, staff_id),
  CHECK (returned_qty > 0 AND resale_qty <= returned_qty)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE inventory_movement (
  inventory_movement_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  sku_id BIGINT UNSIGNED NOT NULL,
  fact_type VARCHAR(20) NOT NULL,
  fact_id BIGINT UNSIGNED NOT NULL,
  fact_sequence BIGINT UNSIGNED NOT NULL DEFAULT 1,
  on_hand_before INT NOT NULL,
  reserved_before INT NOT NULL,
  on_hand_delta INT NOT NULL,
  reserved_delta INT NOT NULL,
  on_hand_after INT GENERATED ALWAYS AS (on_hand_before + on_hand_delta) STORED,
  reserved_after INT GENERATED ALWAYS AS (reserved_before + reserved_delta) STORED,
  occurred_at DATETIME(3) NOT NULL,
  recorded_at DATETIME(3) NOT NULL,
  PRIMARY KEY (inventory_movement_id),
  UNIQUE KEY uq_inventory_fact (store_id, fact_type, fact_id, fact_sequence, sku_id),
  KEY ix_inventory_card (store_id, sku_id, recorded_at, inventory_movement_id),
  CONSTRAINT fk_inventory_sku FOREIGN KEY (store_id, sku_id) REFERENCES product_sku (store_id, sku_id),
  CHECK (fact_type IN ('reserve','release','sale','intake','return','adjust')),
  CHECK (on_hand_before >= reserved_before AND reserved_before >= 0
     AND on_hand_after >= reserved_after AND reserved_after >= 0),
  CHECK ((fact_type = 'reserve' AND on_hand_delta = 0 AND reserved_delta > 0)
    OR (fact_type = 'release' AND on_hand_delta = 0 AND reserved_delta < 0)
    OR (fact_type = 'sale' AND on_hand_delta < 0 AND reserved_delta IN (0, on_hand_delta))
    OR (fact_type IN ('intake','return') AND on_hand_delta > 0 AND reserved_delta = 0)
    OR (fact_type = 'adjust' AND on_hand_delta <> 0 AND reserved_delta = 0))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE wash_ai_report (
  order_id BIGINT UNSIGNED NOT NULL,
  store_id BIGINT UNSIGNED NOT NULL,
  requested_by_user_id BIGINT UNSIGNED NOT NULL,
  ai_report_status VARCHAR(16) NOT NULL,
  attempt_number INT UNSIGNED NOT NULL DEFAULT 1,
  request_token BINARY(16) NOT NULL,
  input_snapshot_ref VARCHAR(255) NOT NULL,
  entitlement_evidence_ref VARCHAR(191) NOT NULL,
  report_content LONGTEXT NULL,
  requested_at DATETIME(3) NOT NULL,
  completed_at DATETIME(3) NULL,
  PRIMARY KEY (order_id),
  UNIQUE KEY uq_ai_attempt_token (request_token),
  CONSTRAINT fk_ai_report_order FOREIGN KEY (store_id, order_id) REFERENCES consumption_order (store_id, order_id),
  CONSTRAINT fk_ai_report_requester FOREIGN KEY (requested_by_user_id) REFERENCES platform_user (platform_user_id),
  CHECK (ai_report_status IN ('generating','ready','failed')),
  CHECK ((ai_report_status = 'ready' AND report_content IS NOT NULL AND completed_at IS NOT NULL) OR
    (ai_report_status <> 'ready' AND report_content IS NULL AND completed_at IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE idempotency_record (
  idempotency_record_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  scope_kind VARCHAR(12) NOT NULL,
  scope_id BIGINT UNSIGNED NOT NULL,
  actor_kind VARCHAR(12) NOT NULL,
  actor_id BIGINT UNSIGNED NOT NULL,
  action_key VARCHAR(80) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  idempotency_key VARBINARY(128) NOT NULL,
  request_hash BINARY(32) NOT NULL,
  record_state VARCHAR(12) NOT NULL,
  result_object_type VARCHAR(48) NULL,
  result_object_id VARCHAR(64) NULL,
  result_code VARCHAR(48) NULL,
  created_at DATETIME(3) NOT NULL,
  completed_at DATETIME(3) NULL,
  PRIMARY KEY (idempotency_record_id),
  UNIQUE KEY uq_idem_scoped_action (scope_kind, scope_id, actor_kind, actor_id, action_key, idempotency_key),
  KEY ix_idem_created_at (created_at),
  CHECK (scope_kind IN ('store','platform','user')),
  CHECK (actor_kind IN ('customer','staff','platform','system')),
  CHECK ((record_state = 'processing' AND completed_at IS NULL AND result_code IS NULL)
    OR (record_state = 'completed' AND completed_at IS NOT NULL AND result_code IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE audit_log (
  audit_log_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NULL,
  actor_type VARCHAR(16) NOT NULL,
  actor_id BIGINT UNSIGNED NOT NULL,
  action_key VARCHAR(80) NOT NULL,
  object_type VARCHAR(48) NOT NULL,
  object_id VARCHAR(64) NOT NULL,
  old_state JSON NULL,
  new_state JSON NULL,
  audit_reason VARCHAR(255) NULL,
  related_request_id VARCHAR(64) NOT NULL,
  audit_created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (audit_log_id),
  KEY ix_audit_store_time (store_id, audit_created_at, audit_log_id),
  KEY ix_audit_object (store_id, object_type, object_id, audit_log_id),
  CONSTRAINT fk_audit_store FOREIGN KEY (store_id) REFERENCES store (store_id),
  CHECK (actor_type IN ('customer','owner','staff','platform','system')),
  CHECK (old_state IS NOT NULL OR new_state IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE outbox_event (
  outbox_event_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NULL,
  stable_event_key VARBINARY(191) NOT NULL,
  event_type VARCHAR(64) NOT NULL,
  subject_id VARCHAR(64) NOT NULL,
  event_payload JSON NOT NULL,
  delivery_state VARCHAR(16) NOT NULL DEFAULT 'pending',
  next_attempt_at DATETIME(3) NOT NULL,
  lease_until DATETIME(3) NULL,
  lease_token BINARY(16) NULL,
  attempt_count INT UNSIGNED NOT NULL DEFAULT 0,
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (outbox_event_id),
  UNIQUE KEY uq_business_event (stable_event_key),
  KEY ix_outbox_due (delivery_state, next_attempt_at, outbox_event_id),
  KEY ix_outbox_stale_lease (delivery_state, lease_until, outbox_event_id),
  CONSTRAINT fk_outbox_store FOREIGN KEY (store_id) REFERENCES store (store_id),
  CHECK (delivery_state IN ('pending','leased','delivered','needs_review')),
  CHECK ((delivery_state = 'leased' AND lease_token IS NOT NULL AND lease_until IS NOT NULL)
    OR (delivery_state <> 'leased' AND lease_token IS NULL AND lease_until IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE in_app_message (
  message_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  outbox_event_id BIGINT UNSIGNED NOT NULL,
  store_id BIGINT UNSIGNED NULL,
  recipient_user_id BIGINT UNSIGNED NOT NULL,
  message_type VARCHAR(64) NOT NULL,
  message_priority VARCHAR(12) NOT NULL,
  visible_payload JSON NOT NULL,
  created_at DATETIME(3) NOT NULL,
  read_at DATETIME(3) NULL,
  PRIMARY KEY (message_id),
  UNIQUE KEY uq_message_once (outbox_event_id, recipient_user_id, message_type),
  KEY ix_message_timeline (recipient_user_id, store_id, created_at, message_id),
  CONSTRAINT fk_message_event FOREIGN KEY (outbox_event_id) REFERENCES outbox_event (outbox_event_id),
  CONSTRAINT fk_message_store FOREIGN KEY (store_id) REFERENCES store (store_id),
  CONSTRAINT fk_message_user FOREIGN KEY (recipient_user_id) REFERENCES platform_user (platform_user_id),
  CHECK (message_priority IN ('normal','important'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- A cart holds intent. Inventory and revenue change only at later original-order actions.
CREATE TABLE shopping_cart (
  cart_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  customer_id BIGINT UNSIGNED NOT NULL,
  cart_note VARCHAR(500) NULL,
  row_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  PRIMARY KEY (cart_id),
  UNIQUE KEY uq_active_cart (store_id, customer_id),
  UNIQUE KEY uq_cart_store (store_id, cart_id),
  CONSTRAINT fk_cart_customer FOREIGN KEY (store_id, customer_id) REFERENCES store_customer (store_id, customer_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE shopping_cart_item (
  cart_item_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  store_id BIGINT UNSIGNED NOT NULL,
  cart_id BIGINT UNSIGNED NOT NULL,
  sku_id BIGINT UNSIGNED NOT NULL,
  cart_quantity INT UNSIGNED NOT NULL,
  PRIMARY KEY (cart_item_id),
  UNIQUE KEY uq_cart_sku (store_id, cart_id, sku_id),
  CONSTRAINT fk_cart_line_header FOREIGN KEY (store_id, cart_id) REFERENCES shopping_cart (store_id, cart_id),
  CONSTRAINT fk_cart_line_sku FOREIGN KEY (store_id, sku_id) REFERENCES product_sku (store_id, sku_id),
  CHECK (cart_quantity > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE pet_weight_record (
  pet_weight_record_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  owner_pet_id BIGINT UNSIGNED NULL,
  store_id BIGINT UNSIGNED NULL,
  store_pet_id BIGINT UNSIGNED NULL,
  service_record_id BIGINT UNSIGNED NULL,
  weight_value DECIMAL(8,3) NOT NULL,
  weight_measured_at DATETIME(3) NOT NULL,
  weight_source_type VARCHAR(12) NOT NULL,
  weight_recorded_by_id BIGINT UNSIGNED NULL,
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (pet_weight_record_id),
  KEY ix_weight_owner (owner_pet_id, weight_measured_at, pet_weight_record_id),
  KEY ix_weight_store (store_id, store_pet_id, weight_measured_at, pet_weight_record_id),
  CONSTRAINT fk_weight_owner_pet FOREIGN KEY (owner_pet_id) REFERENCES owner_pet (owner_pet_id),
  CONSTRAINT fk_weight_store_pet FOREIGN KEY (store_id, store_pet_id) REFERENCES store_pet (store_id, store_pet_id),
  CONSTRAINT fk_weight_service FOREIGN KEY (store_id, store_pet_id, service_record_id)
    REFERENCES service_record (store_id, store_pet_id, service_record_id),
  CHECK (weight_value > 0),
  CHECK ((weight_source_type = 'customer' AND owner_pet_id IS NOT NULL AND store_id IS NULL
          AND store_pet_id IS NULL AND service_record_id IS NULL) OR
         (weight_source_type = 'staff' AND owner_pet_id IS NULL AND store_id IS NOT NULL
          AND store_pet_id IS NOT NULL AND service_record_id IS NULL) OR
         (weight_source_type = 'service' AND owner_pet_id IS NULL AND store_id IS NOT NULL
          AND store_pet_id IS NOT NULL AND service_record_id IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;


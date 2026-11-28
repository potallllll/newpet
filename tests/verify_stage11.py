"""Run V001/V002 MySQL probes with synthetic data in disposable schemas."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from hashlib import sha256
from pathlib import Path
import re
import subprocess
from threading import Barrier
from time import monotonic
from uuid import uuid4


ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "backend/src/main/resources/db/migration"
V001 = MIGRATIONS / "V001__newpet_batch_a_core.sql"
V002 = MIGRATIONS / "V002__newpet_batch_a_runtime_foundations.sql"
V001_SHA256 = "c340be6abd87501f07f57a169bb5895162f7f4bf46505196f7188eed9392f632"
NOW = "'2026-11-26 02:00:00.000'"
FUTURE = "'2026-11-26 03:00:00.000'"
EPOCH = "UNHEX(REPEAT('ea',16))"
SEED_V001 = f"""
INSERT INTO platform_user(platform_user_id,verified_mobile,mobile_verified_at,created_at) VALUES
  (1,'+8613700000101',{NOW},{NOW}),(2,'+8613700000102',{NOW},{NOW}),
  (3,'+8613700000103',{NOW},{NOW});
INSERT INTO wechat_binding (appid,openid,platform_user_id,bound_at) VALUES
  ('wx-probe-customer','fixture-left',1,{NOW}),('wx-probe-staff','fixture-right',1,{NOW}),
  ('wx-probe-other','fixture-left',1,{NOW}),('wx-probe-customer','fixture-user-2',2,{NOW});
INSERT INTO store(store_id,merchant_id,store_name,store_address,registered_mobile,
  store_business_hours,store_temporary_closures,created_at) VALUES
  (11,21,'Synthetic Store A','A','+8613700000104',JSON_ARRAY(),JSON_ARRAY(),{NOW}),
  (12,22,'Synthetic Store B','B','+8613700000105',JSON_ARRAY(),JSON_ARRAY(),{NOW});
INSERT INTO staff(staff_id,store_id,platform_user_id,staff_role,staff_status,staff_display_name,created_at) VALUES
  (41,11,1,'merchant_owner','active','Owner A',{NOW}),(42,11,2,'store_staff','active','Staff A',{NOW}),
  (43,12,3,'merchant_owner','active','Owner B',{NOW});
INSERT INTO active_staff_membership(platform_user_id,store_id,staff_id,staff_role) VALUES
  (1,11,41,'merchant_owner'),(2,11,42,'store_staff'),(3,12,43,'merchant_owner');
INSERT INTO staff_invitation(staff_invitation_id,store_id,invite_token_digest,staff_invitation_created_by,
  created_at,staff_invitation_expires_at) VALUES
  (51,11,UNHEX(REPEAT('1a',32)),41,{NOW},DATE_ADD({NOW},INTERVAL 12 HOUR)),
  (52,12,UNHEX(REPEAT('1b',32)),43,{NOW},DATE_ADD({NOW},INTERVAL 12 HOUR));
INSERT INTO service_item(service_item_id,store_id,business_item_category,service_item_name,reference_price)
  VALUES (61,11,'wash','Wash',55.00);
INSERT INTO invite_code(invite_code_id,store_id,invite_code_digest,invite_code_content_type,service_item_id,
  terms_snapshot,created_by_staff_id,created_at,expires_at)
  VALUES (62,11,UNHEX(REPEAT('2a',32)),'service_activity',61,JSON_OBJECT(),41,{NOW},DATE_ADD({NOW},INTERVAL 72 HOUR));
INSERT INTO product_category(product_category_id,store_id,product_category_name,product_category_is_fallback)
  VALUES (74,11,'Other',1);
INSERT INTO product_sku(sku_id,store_id,product_id,product_category_id,product_name,spec_label,
  sale_price,on_hand_inventory_qty,reserved_inventory_qty,product_detail)
  VALUES (75,11,76,74,'Food','One pack',10.00,10,6,JSON_OBJECT());
INSERT INTO consumption_order(order_id,store_id,order_type,order_status,source_channel,
  order_performance_staff_id,order_hold_expires_at,occurred_at,created_at) VALUES
  (81,11,'product','open','fixture',41,{FUTURE},{NOW},{NOW}),
  (82,11,'product','open','fixture',41,{FUTURE},{NOW},{NOW}),
  (83,11,'product','open','fixture',41,NULL,{NOW},{NOW});
INSERT INTO consumption_order_item(order_item_id,store_id,order_id,sku_id,item_kind,
  requested_quantity,confirmed_quantity,item_original_unit_price,item_snapshot) VALUES
  (91,11,81,75,'product',2,2,10,JSON_OBJECT()),(92,11,82,75,'product',2,2,10,JSON_OBJECT()),
  (93,11,83,75,'product',2,2,10,JSON_OBJECT());
INSERT INTO inventory_reservation(store_id,order_id,order_item_id,sku_id,reserved_qty,reservation_status,expires_at)
  VALUES (11,81,91,75,2,'held',{FUTURE}),(11,82,92,75,2,'held',{FUTURE}),(11,83,93,75,2,'held',NULL);
"""


def mysql_connection(args):
    auth = [f"--defaults-extra-file={args.defaults_extra_file}"] if args.defaults_extra_file else ["--no-defaults"]
    common = [*auth, f"--user={args.user}", "--default-character-set=utf8mb4"]
    if args.pipe:
        return common + ["--protocol=PIPE", f"--socket={args.pipe}"]
    return common + ["--protocol=TCP", f"--host={args.host}", f"--port={args.port}"]


class Probe:
    def __init__(self, args):
        self.connection = mysql_connection(args)
        self.mysql = [args.mysql_client, *self.connection, "--connect-timeout=5", "--batch", "--skip-column-names", "--raw"]
        stem = "newpet_stage11_" + uuid4().hex[:14]
        self.schema = stem
        self.fresh_schema = stem + "_fresh"
        self.restore_schema = stem + "_restored"
        self.created = []
        self.passed = 0

    def execute(self, sql, schema=None):
        target = self.mysql + ([schema] if schema else [])
        sql = "SET time_zone='+00:00';\n" + sql
        return subprocess.run(target, input=sql, encoding="utf-8", capture_output=True, timeout=45)

    def query(self, sql, schema=None):
        result = self.execute(sql, schema)
        if result.returncode:
            raise RuntimeError(result.stderr.strip())
        return result.stdout.strip()

    def create_schema(self, name):
        self.query(f"CREATE DATABASE {name} CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;")
        self.created.append(name)

    def cleanup(self):
        for schema in reversed(self.created):
            self.query(f"DROP DATABASE {schema};")

    def run_sql(self, sql):
        return self.query(sql, self.schema)

    def passed_check(self, label):
        self.passed += 1
        print(f"PASS {label}", flush=True)

    def expect(self, label, sql, expected):
        actual = self.run_sql(sql)
        if actual != expected:
            raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")
        self.passed_check(label)

    def reject(self, label, sql, code):
        result = self.execute(sql, self.schema)
        match = re.search(r"ERROR (\d+)", result.stderr)
        if not result.returncode or not match or int(match.group(1)) != code:
            raise AssertionError(f"{label}: expected MySQL {code}, got {result.stderr!r}")
        self.passed_check(label)

    def race(self, label, statements, expected):
        ready = Barrier(len(statements), timeout=10)

        def run(statement):
            ready.wait()
            return self.run_sql(statement)

        with ThreadPoolExecutor(max_workers=len(statements)) as pool:
            results = list(pool.map(run, statements))
        if sorted(results) != sorted(expected):
            raise AssertionError(f"{label}: {results!r} != {expected!r}")
        self.passed_check(label)

    def backup_restore(self, dumper):
        start = monotonic()
        dump = subprocess.run([dumper, *self.connection, "--single-transaction", "--skip-lock-tables",
                               "--no-tablespaces", "--set-gtid-purged=OFF", "--hex-blob", self.schema],
                              capture_output=True, timeout=90)
        if dump.returncode or not dump.stdout:
            raise RuntimeError(dump.stderr.decode("utf-8", errors="replace").strip())
        backed_up = monotonic()
        self.create_schema(self.restore_schema)
        self.query(dump.stdout.decode("utf-8"), self.restore_schema)
        integrity = """
          SELECT (SELECT COUNT(*) FROM platform_user),
                 (SELECT COUNT(*) FROM auth_wechat_group),
                 (SELECT COUNT(*) FROM auth_miniapp_session),
                 (SELECT COUNT(*) FROM private_media_attachment WHERE detached_at IS NULL),
                 (SELECT COUNT(*) FROM invite_replay_secret),
                 (SELECT COUNT(*) FROM outbox_channel_delivery WHERE channel_state='needs_review'),
                 (SELECT COUNT(*) FROM in_app_message),
                 (SELECT COUNT(*) FROM inventory_movement),
                 (SELECT SUM(reserved_inventory_qty) FROM product_sku);
        """
        if self.run_sql(integrity) != self.query(integrity, self.restore_schema):
            raise AssertionError("synthetic recovery invariants differ")
        binary_facts = """
          SELECT HEX(token_digest),HEX(session_epoch) FROM auth_miniapp_session ORDER BY token_digest;
          SELECT idempotency_record_id,HEX(nonce),HEX(ciphertext) FROM invite_replay_secret ORDER BY idempotency_record_id;
          SELECT private_media_id,HEX(verified_sha256) FROM private_media ORDER BY private_media_id;
        """
        if self.run_sql(binary_facts) != self.query(binary_facts, self.restore_schema):
            raise AssertionError("synthetic recovery changed encrypted bytes or digests")
        constraints = "SELECT COUNT(*) FROM information_schema.table_constraints WHERE table_schema=DATABASE();"
        if self.run_sql(constraints) != self.query(constraints, self.restore_schema):
            raise AssertionError("synthetic recovery lost constraints")
        self.passed_check(f"logical backup and restore: dump {backed_up-start:.2f}s, total {monotonic()-start:.2f}s")

    def point_in_time_restore(self, binlog_client, binlog_dir):
        def position():
            statement = "SHOW BINARY LOG STATUS;" if self.query("SELECT VERSION();").startswith("8.4") else "SHOW MASTER STATUS;"
            fields = self.query(statement).split("\t")
            if len(fields) < 2 or not re.fullmatch(r"[A-Za-z0-9_.-]+\.\d+", fields[0]) or not fields[1].isdigit():
                raise AssertionError("isolated source must have binary logging enabled")
            return fields[0], int(fields[1])

        server_binlog_dir = Path(self.query("SELECT @@GLOBAL.log_bin_basename;")).parent.resolve()
        if server_binlog_dir != binlog_dir.resolve():
            raise AssertionError("local binary log directory does not match the isolated source")
        start_name, start_pos = position()
        self.run_sql("UPDATE platform_user SET auth_version=3 WHERE platform_user_id=1;")
        stop_name, stop_pos = position()
        self.run_sql("UPDATE platform_user SET auth_version=4 WHERE platform_user_id=1;")
        if start_name != stop_name or stop_pos <= start_pos:
            raise AssertionError("logical PITR fixture expected one segment with a non-empty interval")
        start = monotonic()
        replay = subprocess.run(
            [binlog_client, "--no-defaults", "--disable-log-bin", "--skip-gtids",
             f"--start-position={start_pos}", f"--stop-position={stop_pos}",
             f"--rewrite-db={self.schema}->{self.restore_schema}", f"--database={self.restore_schema}",
             str(binlog_dir / start_name)],
            capture_output=True, timeout=45,
        )
        if replay.returncode or not replay.stdout:
            raise RuntimeError(replay.stderr.decode("utf-8", errors="replace").strip())
        self.query(replay.stdout.decode("utf-8"), self.restore_schema)
        value = "SELECT auth_version FROM platform_user WHERE platform_user_id=1;"
        if self.query(value, self.restore_schema) != "3" or self.run_sql(value) != "4":
            raise AssertionError("selected commit was not recovered, or a later commit was applied")
        self.passed_check(f"point-in-time replay includes the chosen commit and excludes the later commit ({monotonic()-start:.2f}s)")


def verify_identity(probe):
    probe.run_sql(f"""
      INSERT INTO auth_wechat_app(appid,app_audience,open_platform_namespace,enabled) VALUES
        ('wx-probe-customer','customer','issuer-a',1),('wx-probe-staff','staff','issuer-a',1),
        ('wx-probe-other','customer','issuer-b',1);
      INSERT INTO auth_wechat_group(wechat_group_id,open_platform_namespace,unionid_digest,platform_user_id,
        group_state,evidence_observed_at) VALUES
        (101,'issuer-a',UNHEX(REPEAT('a1',32)),1,'active',{NOW});
      INSERT INTO auth_wechat_binding_group(appid,openid,platform_user_id,open_platform_namespace,wechat_group_id,linked_at)
        VALUES ('wx-probe-customer','fixture-left',1,'issuer-a',101,{NOW}),
               ('wx-probe-staff','fixture-right',1,'issuer-a',101,{NOW});
    """)
    probe.expect("two AppID bindings point to the same trusted group",
                 "SELECT COUNT(*) FROM auth_wechat_binding_group WHERE wechat_group_id=101;", "2")
    group = f"""INSERT INTO auth_wechat_group(open_platform_namespace,unionid_digest,platform_user_id,
       group_state,evidence_observed_at) VALUES"""
    probe.reject("same issuer and UnionID cannot point to a second User",
                 f"{group} ('issuer-a',UNHEX(REPEAT('a1',32)),2,'active',{NOW});", 1062)
    probe.reject("one User cannot have two active WeChat groups in the same issuer",
                 f"{group} ('issuer-a',UNHEX(REPEAT('a2',32)),1,'active',{NOW});", 1062)
    binding = """INSERT INTO auth_wechat_binding_group
       (appid,openid,platform_user_id,open_platform_namespace,wechat_group_id,linked_at) VALUES"""
    probe.reject("identical OpenID from a different issuer cannot join the group",
                 f"{binding} ('wx-probe-other','fixture-left',1,'issuer-a',101,{NOW});", 1452)
    probe.reject("a different User cannot attach its V001 binding to the group",
                 f"{binding} ('wx-probe-customer','fixture-user-2',2,'issuer-a',101,{NOW});", 1452)

    challenge = """INSERT INTO auth_wechat_challenge
       (wechat_challenge_id,challenge_token_digest,appid,session_epoch,challenge_kind,parent_challenge_id,
        target_platform_user_id,expected_auth_version,seal_key_ref,sealed_context,issued_at,expires_at) VALUES"""
    def challenge_row(pk, appid, kind, parent="NULL", user="NULL", version="NULL"):
        ttl = 5 if kind == "phone" else 3
        return (f"({pk},UNHEX(LPAD(HEX({pk}),64,'0')),'{appid}',{EPOCH},'{kind}',"
                f"{parent},{user},{version},'fixture-key',REPEAT('z',32),{NOW},DATE_ADD({NOW},INTERVAL {ttl} MINUTE))")

    probe.run_sql(f"{challenge} {challenge_row(201,'wx-probe-customer','phone')};")
    consume = f"""
      UPDATE auth_wechat_challenge SET consumed_at=DATE_ADD({NOW},INTERVAL 1 SECOND),
        seal_key_ref=NULL,sealed_context=NULL WHERE wechat_challenge_id=201
        AND consumed_at IS NULL AND expires_at>DATE_ADD({NOW},INTERVAL 1 SECOND);
      SELECT ROW_COUNT();
    """
    probe.race("concurrent challenge consumption succeeds once", [consume, consume], ["0", "1"])
    wrong = challenge_row(202, "wx-probe-staff", "rebind", "201", "1", "1")
    probe.reject("rebind cannot link a parent from a different AppID", f"{challenge} {wrong};", 1452)
    one = challenge_row(203, "wx-probe-customer", "rebind", "201", "1", "1")
    probe.run_sql(f"{challenge} {one};")
    second = challenge_row(204, "wx-probe-customer", "rebind", "201", "1", "1")
    probe.reject("one phone challenge cannot produce two rebind challenges", f"{challenge} {second};", 1062)
    probe.reject("consumption at exact challenge expiry is invalid", """UPDATE auth_wechat_challenge SET
      consumed_at=expires_at, seal_key_ref=NULL, sealed_context=NULL WHERE wechat_challenge_id=203;""", 3819)
    probe.reject("consumed challenge must remove its sealed context", f"""UPDATE auth_wechat_challenge SET
      consumed_at=DATE_ADD({NOW},INTERVAL 2 SECOND) WHERE wechat_challenge_id=203;""", 3819)

    session = """INSERT INTO auth_miniapp_session
      (token_digest,appid,app_audience,platform_user_id,auth_version,session_epoch,store_id,staff_id,
       staff_session_generation,store_staff_session_generation,issued_at,idle_expires_at,hard_expires_at) VALUES"""
    def session_row(token, appid, audience, store="NULL", staff="NULL", staff_gen="NULL", store_gen="NULL"):
        return (f"(UNHEX(REPEAT('{token}',32)),'{appid}','{audience}',1,1,{EPOCH},{store},{staff},"
                f"{staff_gen},{store_gen},{NOW},DATE_ADD({NOW},INTERVAL 2 HOUR),DATE_ADD({NOW},INTERVAL 12 HOUR))")

    customer = session_row("aa", "wx-probe-customer", "customer")
    employee = session_row("bb", "wx-probe-staff", "staff", "11", "41", "1", "1")
    probe.run_sql(f"{session} {customer}, {employee};")
    probe.reject("wrong AppID and audience cannot be paired",
                 f"{session} {session_row('cc','wx-probe-customer','staff')};", 1452)
    probe.reject("nullable staff scope cannot omit the generations",
                 f"{session} {session_row('cc','wx-probe-staff','staff','11','41')};", 3819)
    probe.reject("session cannot link another store's staff identity",
                 f"{session} {session_row('cc','wx-probe-staff','staff','12','43','1','1')};", 1452)

    def visible_sessions(epoch=EPOCH, instant=FUTURE):
        return f"""SELECT COUNT(*) FROM auth_miniapp_session s
          JOIN auth_wechat_app a ON a.appid=s.appid AND a.enabled=1
          JOIN platform_user u USING(platform_user_id)
          LEFT JOIN active_staff_membership m ON m.platform_user_id=s.platform_user_id AND m.staff_id=s.staff_id
          LEFT JOIN staff f ON f.staff_id=m.staff_id
          LEFT JOIN store t ON t.store_id=m.store_id
          WHERE u.account_status='active' AND s.auth_version=u.auth_version AND s.session_epoch={epoch}
            AND s.revoked_at IS NULL AND s.idle_expires_at>{instant} AND s.hard_expires_at>{instant}
            AND (s.app_audience='customer' OR (f.staff_status='active' AND t.store_status='active'
              AND f.staff_session_generation=s.staff_session_generation
              AND t.store_staff_session_generation=s.store_staff_session_generation));"""

    probe.expect("both established audiences authenticate against current SQL state", visible_sessions(), "2")
    probe.expect("idle expiry equality rejects both old credentials",
                 visible_sessions(instant=f"DATE_ADD({NOW},INTERVAL 2 HOUR)"), "0")
    probe.expect("a restored database with a new epoch cannot revive sessions",
                 visible_sessions(epoch="UNHEX(REPEAT('ee',16))"), "0")
    probe.expect("staff disable and restore invalidates only old staff credential", f"""
      START TRANSACTION;
      DELETE FROM active_staff_membership WHERE staff_id=41;
      UPDATE staff SET staff_status='disabled',staff_session_generation=2 WHERE staff_id=41;
      COMMIT;
      START TRANSACTION;
      UPDATE staff SET staff_status='active',staff_session_generation=3 WHERE staff_id=41;
      INSERT INTO active_staff_membership(platform_user_id,store_id,staff_id,staff_role)
        VALUES (1,11,41,'merchant_owner');
      COMMIT;
      {visible_sessions()}
    """, "1")
    new_staff_session = session_row("cc", "wx-probe-staff", "staff", "11", "41", "3", "1")
    probe.expect("fresh login after staff restore uses the current generation",
                 f"{session} {new_staff_session}; " + visible_sessions(), "2")
    probe.expect("stop and restore of a store invalidates the store generation", f"""
      UPDATE store SET store_status='deactivated',store_staff_session_generation=2 WHERE store_id=11;
      UPDATE store SET store_status='active',store_staff_session_generation=3 WHERE store_id=11;
      {visible_sessions()}
    """, "1")
    new_store_session = session_row("dd", "wx-probe-staff", "staff", "11", "41", "3", "3")
    probe.expect("fresh login after store restore gets the current store generation",
                 f"{session} {new_store_session}; " + visible_sessions(), "2")
    probe.expect("rebind auth_version invalidates both audiences",
                 "UPDATE platform_user SET auth_version=2 WHERE platform_user_id=1; " + visible_sessions(), "0")


def verify_media_and_invites(probe):
    media = f"""
      INSERT INTO private_media(private_media_id,scope_kind,scope_id,store_id,uploaded_by_user_id,
        uploaded_by_staff_id,upload_appid,media_purpose,object_key,media_state,declared_mime,declared_size,
        object_version,verified_sha256,issued_at,upload_expires_at,verified_at) VALUES
        (301,'store',11,11,1,41,'wx-probe-staff','business_license','fixture-object-1','verified','image/png',
         128,'v1',UNHEX(REPEAT('9a',32)),{NOW},DATE_ADD({NOW},INTERVAL 10 MINUTE),{NOW}),
        (302,'store',11,11,1,41,'wx-probe-staff','business_license','fixture-object-2','verified','image/png',
         128,'v1',UNHEX(REPEAT('9b',32)),{NOW},DATE_ADD({NOW},INTERVAL 10 MINUTE),{NOW});
    """
    probe.run_sql(media)

    media_intent = """INSERT INTO private_media
      (private_media_id,scope_kind,scope_id,store_id,uploaded_by_user_id,uploaded_by_staff_id,
        upload_appid,media_purpose,object_key,media_state,declared_mime,declared_size,issued_at,upload_expires_at)
      VALUES"""

    def intent(pk, purpose, mime, size):
        return (f"{media_intent} ({pk},'store',11,11,1,41,'wx-probe-staff','{purpose}',"
                f"'fixture-format-{pk}','pending','{mime}',{size},{NOW},"
                f"DATE_ADD({NOW},INTERVAL 10 MINUTE));")

    for pk, mime in ((303, "image/jpeg"), (304, "image/png")):
        probe.expect(f"shopfront accepts {mime} at 3 MiB", intent(pk, "store_front", mime, 3145728) +
                     f" SELECT declared_mime FROM private_media WHERE private_media_id={pk};", mime)
    probe.reject("shopfront rejects WebP", intent(305, "store_front", "image/webp", 128), 3819)
    probe.reject("shopfront rejects more than 3 MiB", intent(305, "store_front", "image/jpeg", 3145729), 3819)
    probe.reject("business license still rejects WebP", intent(305, "business_license", "image/webp", 128), 3819)
    probe.expect("other authorized image purpose still accepts WebP",
                 intent(305, "product_image", "image/webp", 128) +
                 " SELECT declared_mime FROM private_media WHERE private_media_id=305;", "image/webp")
    probe.reject("a store media intent cannot omit the actor's Store Staff ID",
                 "UPDATE private_media SET uploaded_by_staff_id=NULL WHERE private_media_id=301;", 3819)
    probe.reject("a private object cannot claim a larger than approved business license",
                 "UPDATE private_media SET declared_size=10485761 WHERE private_media_id=301;", 3819)
    probe.reject("a verified private object must have an immutable storage version",
                 "UPDATE private_media SET object_version=NULL WHERE private_media_id=301;", 3819)
    attachment = """INSERT INTO private_media_attachment
        (private_media_id,scope_kind,scope_id,media_purpose,resource_kind,resource_id,resource_slot,attached_at) VALUES"""
    probe.reject("foreign store attachment to a valid private object is rejected",
                 f"{attachment} (301,'store',12,'business_license','store',12,'license',{NOW});", 1452)
    probe.reject("license cannot be attached as a different purpose",
                 f"{attachment} (301,'store',11,'product_image','product_sku',75,'photo',{NOW});", 1452)
    probe.run_sql(f"{attachment} (301,'store',11,'business_license','store',11,'license',{NOW});")
    probe.reject("an unchanged occupied attachment slot cannot be replaced concurrently",
                 f"{attachment} (302,'store',11,'business_license','store',11,'license',{NOW});", 1062)
    probe.expect("replacing the active attachment preserves the original history", f"""
      START TRANSACTION;
      UPDATE private_media_attachment SET detached_at={FUTURE} WHERE private_media_id=301;
      {attachment} (302,'store',11,'business_license','store',11,'license',{FUTURE});
      COMMIT;
      SELECT COUNT(*), SUM(active_guard IS NOT NULL) FROM private_media_attachment;
    """, "2\t1")

    probe.run_sql(f"""
      INSERT INTO idempotency_record(idempotency_record_id,scope_kind,scope_id,actor_kind,actor_id,action_key,
        idempotency_key,request_hash,record_state,result_object_type,result_object_id,result_code,created_at,completed_at)
        VALUES (401,'store',11,'staff',41,'createStaffInvitation','fixture-retry-1',UNHEX(REPEAT('be',32)),
                'completed','staff_invitation','51','ok',{NOW},{NOW}),
               (402,'store',11,'staff',41,'createInviteCode','fixture-retry-2',UNHEX(REPEAT('bf',32)),
                'completed','invite_code','62','ok',{NOW},{NOW});
    """)
    secret = """INSERT INTO invite_replay_secret(idempotency_record_id,store_id,creator_staff_id,staff_invitation_id,
        invite_code_id,kms_key_ref,wrapped_dek,nonce,ciphertext,sealed_at,replay_until) VALUES"""
    def sealed(idem, staff_invite, code, hours):
        return (f"({idem},11,41,{staff_invite},{code},'fixture-kms',REPEAT('d',32),UNHEX(REPEAT('aa',12)),"
                f"REPEAT('c',32),{NOW},DATE_ADD({NOW},INTERVAL {hours} HOUR))")

    probe.reject("sealed result cannot point to both invite types", f"{secret} {sealed(401,51,62,12)};", 3819)
    probe.reject("sealed result cannot point to an invite in another Store", f"{secret} {sealed(401,52,'NULL',12)};", 1452)
    probe.reject("staff invite replay can never extend past the 12 hour window",
                 f"{secret} {sealed(401,51,'NULL',13)};", 3819)
    probe.run_sql(f"{secret} {sealed(401,51,'NULL',12)}, {sealed(402,'NULL',62,72)};")
    probe.reject("generic receipt cannot be deleted before its sealed result expires",
                 "DELETE FROM idempotency_record WHERE idempotency_record_id=401;", 1451)
    probe.expect("expired seal purge preserves replay receipt and original invitation", f"""
      DELETE FROM invite_replay_secret WHERE replay_until <= DATE_ADD({NOW},INTERVAL 12 HOUR);
      SELECT (SELECT COUNT(*) FROM invite_replay_secret),
             (SELECT COUNT(*) FROM idempotency_record WHERE idempotency_record_id=401),
             (SELECT COUNT(*) FROM staff_invitation WHERE staff_invitation_id=51);
    """, "1\t1\t1")


def verify_boarding_media(probe):
    probe.run_sql(f"""
      INSERT INTO store_customer(customer_id,store_id,customer_name,created_at)
        VALUES (611,11,'Synthetic boarding customer',{NOW});
      INSERT INTO store_pet(store_pet_id,store_id,customer_id,pet_name,species,created_at)
        VALUES (612,11,611,'Synthetic boarding pet','dog',{NOW});
      INSERT INTO consumption_order(order_id,store_id,customer_id,order_type,order_status,
        source_channel,occurred_at,created_at)
        VALUES (613,11,611,'boarding','open','fixture',{NOW},{NOW});
      INSERT INTO consumption_order_item(order_item_id,store_id,order_id,customer_id,store_pet_id,
        item_kind,requested_quantity,item_original_unit_price,item_snapshot)
        VALUES (614,11,613,611,612,'boarding',1,30.00,JSON_OBJECT());
      INSERT INTO boarding_stay(boarding_id,store_id,order_id,customer_id,order_item_id,store_pet_id,
        boarding_status,check_in_at,expected_checkout_at,intake_details)
        VALUES (615,11,613,611,614,612,'in_store',{NOW},{FUTURE},JSON_OBJECT());
      INSERT INTO private_media(private_media_id,scope_kind,scope_id,store_id,uploaded_by_user_id,
        uploaded_by_staff_id,upload_appid,media_purpose,object_key,media_state,declared_mime,declared_size,
        object_version,verified_sha256,issued_at,upload_expires_at,verified_at) VALUES
        (310,'store',11,11,1,41,'wx-probe-staff','boarding_health','fixture-boarding-intake','verified',
          'image/png',128,'v1',UNHEX(REPEAT('ba',32)),{NOW},DATE_ADD({NOW},INTERVAL 10 MINUTE),{NOW}),
        (311,'store',11,11,1,41,'wx-probe-staff','boarding_health','fixture-boarding-health-event','verified',
          'image/png',128,'v1',UNHEX(REPEAT('bb',32)),{NOW},DATE_ADD({NOW},INTERVAL 10 MINUTE),{NOW}),
        (312,'store',11,11,1,41,'wx-probe-staff','boarding_care','fixture-boarding-care-event','verified',
          'image/png',128,'v1',UNHEX(REPEAT('bc',32)),{NOW},DATE_ADD({NOW},INTERVAL 10 MINUTE),{NOW});
    """)
    attachment = """INSERT INTO private_media_attachment
        (private_media_id,scope_kind,scope_id,media_purpose,resource_kind,resource_id,resource_slot,attached_at) VALUES"""
    probe.expect("intake health media attaches to its boarding stay without a care event", f"""
      {attachment} (310,'store',11,'boarding_health','boarding_stay',615,'intake-health-1',{NOW});
      SELECT a.private_media_id, (SELECT COUNT(*) FROM boarding_care_event WHERE boarding_id=s.boarding_id)
        FROM private_media_attachment a JOIN boarding_stay s
          ON s.store_id=a.scope_id AND s.boarding_id=a.resource_id
        WHERE a.private_media_id=310 AND a.resource_kind='boarding_stay' AND a.detached_at IS NULL;
    """, "310\t0")
    probe.reject("ordinary care media cannot attach directly to the boarding stay",
                 f"{attachment} (312,'store',11,'boarding_care','boarding_stay',615,'care-1',{NOW});", 3819)
    probe.reject("boarding health media cannot use an attachment scope from another store",
                 f"{attachment} (311,'store',12,'boarding_health','boarding_stay',615,'intake-health-1',{NOW});", 1452)
    probe.expect("health and care media still attach to an existing same-store care event", f"""
      INSERT INTO boarding_care_event(boarding_event_id,store_id,boarding_id,boarding_event_type,
        boarding_event_visibility,occurred_at,recorded_at,boarding_event_created_by_staff_id)
        VALUES (616,11,615,'other','store_internal',{NOW},{NOW},41);
      {attachment} (311,'store',11,'boarding_health','boarding_care_event',616,'health-1',{NOW}),
                   (312,'store',11,'boarding_care','boarding_care_event',616,'care-1',{NOW});
      SELECT COUNT(*) FROM private_media_attachment a
        JOIN boarding_care_event e ON e.store_id=a.scope_id AND e.boarding_event_id=a.resource_id
        WHERE a.resource_kind='boarding_care_event' AND e.boarding_id=615 AND a.detached_at IS NULL;
    """, "2")


def verify_workers(probe):
    probe.run_sql(f"""
      INSERT INTO outbox_event(outbox_event_id,store_id,stable_event_key,event_type,subject_id,event_payload,
        next_attempt_at,created_at) VALUES (501,11,'fixture-event','service.completed','7',JSON_OBJECT(),{NOW},{NOW});
    """)

    def claim(token):
        return f"""
          START TRANSACTION;
          SET @claimed=(SELECT outbox_event_id FROM outbox_event WHERE delivery_state='pending'
            AND next_attempt_at<={FUTURE} ORDER BY next_attempt_at,outbox_event_id LIMIT 1 FOR UPDATE SKIP LOCKED);
          UPDATE outbox_event SET delivery_state='leased',lease_token=UNHEX(REPEAT('{token}',16)),
            lease_until=DATE_ADD({FUTURE},INTERVAL 30 SECOND),attempt_count=attempt_count+1 WHERE outbox_event_id=@claimed;
          SELECT ROW_COUNT();
          COMMIT;
        """

    probe.race("two Outbox workers claim the same due event once", [claim("c1"), claim("c2")], ["0", "1"])
    probe.expect("due indexes exist and the first lease was issued", """
      SELECT (SELECT COUNT(DISTINCT index_name) FROM information_schema.statistics
               WHERE table_schema=DATABASE() AND table_name='outbox_event'
                 AND index_name IN ('ix_outbox_due','ix_outbox_stale_lease')),
             attempt_count FROM outbox_event WHERE outbox_event_id=501;
    """, "2\t1")
    old_token = probe.run_sql("SELECT HEX(lease_token) FROM outbox_event WHERE outbox_event_id=501;")
    if not re.fullmatch(r"[A-F0-9]{32}", old_token):
        raise AssertionError("unexpected lease token")
    cutoff = f"DATE_ADD({FUTURE},INTERVAL 30 SECOND)"
    probe.expect("lease recovers at equality then a new token claims the same event", f"""
      UPDATE outbox_event SET delivery_state='pending',lease_token=NULL,lease_until=NULL
        WHERE outbox_event_id=501 AND delivery_state='leased' AND lease_until<={cutoff};
      SELECT ROW_COUNT();
      UPDATE outbox_event SET delivery_state='leased',lease_token=UNHEX(REPEAT('cf',16)),
        lease_until=DATE_ADD({cutoff},INTERVAL 30 SECOND),attempt_count=attempt_count+1 WHERE outbox_event_id=501;
    """, "1")
    probe.expect("stale Outbox acknowledgement cannot overwrite a new lease", f"""
      UPDATE outbox_event SET delivery_state='delivered',lease_token=NULL,lease_until=NULL
        WHERE outbox_event_id=501 AND lease_token=UNHEX('{old_token}') AND lease_until>{cutoff};
      SELECT ROW_COUNT();
    """, "0")
    message = f"""INSERT INTO in_app_message(outbox_event_id,store_id,recipient_user_id,message_type,
      message_priority,visible_payload,created_at) VALUES (501,11,1,'service.completed','important',JSON_OBJECT(),{FUTURE});"""
    probe.run_sql(message)
    probe.reject("standalone notification projection cannot repeat per event and recipient", message, 1062)
    send_intent = f"""
      INSERT INTO outbox_channel_delivery(outbox_event_id,recipient_user_id,channel_name,provider_dedup_key,
        channel_state,send_token,attempt_count,last_attempt_at,created_at)
        VALUES (501,1,'wechat_subscribe',UNHEX(REPEAT('e1',32)),'sending',UNHEX(REPEAT('cf',16)),1,{FUTURE},{NOW});
    """
    probe.run_sql(send_intent)
    probe.reject("unknown external delivery cannot be represented as a second send intent", send_intent, 1062)
    probe.expect("unresolved external attempt is kept as needs_review", f"""
      UPDATE outbox_channel_delivery SET channel_state='needs_review',send_token=NULL,
        finished_at={cutoff}, outcome_code='provider_unconfirmed'
        WHERE outbox_event_id=501 AND channel_state='sending' AND send_token=UNHEX(REPEAT('cf',16));
      SELECT channel_state,attempt_count FROM outbox_channel_delivery WHERE outbox_event_id=501;
    """, "needs_review\t1")

    def inventory(order_id, moment, expiry):
        state, reservation, kind = ("expired", "released", "release") if expiry else ("completed", "sold", "sale")
        deadline = f"order_hold_expires_at<={moment}" if expiry else f"(order_hold_expires_at IS NULL OR order_hold_expires_at>{moment})"
        on_hand_delta = "0" if expiry else "-2"
        return f"""
          START TRANSACTION;
          SET @order_version=(SELECT order_amount_version FROM consumption_order WHERE order_id={order_id} FOR UPDATE);
          UPDATE consumption_order SET order_status='{state}',order_amount_version=order_amount_version+1
            WHERE order_id={order_id} AND store_id=11 AND order_status='open'
              AND order_amount_version=@order_version AND {deadline};
          SET @won=ROW_COUNT();
          SELECT sku_id INTO @sku FROM product_sku WHERE store_id=11 AND sku_id=75 FOR UPDATE;
          INSERT INTO inventory_movement(store_id,sku_id,fact_type,fact_id,on_hand_before,reserved_before,
            on_hand_delta,reserved_delta,occurred_at,recorded_at)
            SELECT 11,75,'{kind}',{order_id},on_hand_inventory_qty,reserved_inventory_qty,{on_hand_delta},-2,{moment},{moment}
              FROM product_sku WHERE sku_id=@sku AND @won=1;
          UPDATE inventory_reservation SET reservation_status='{reservation}',row_version=row_version+1
              WHERE order_id={order_id} AND reservation_status='held' AND @won=1;
          UPDATE product_sku SET on_hand_inventory_qty=on_hand_inventory_qty+({on_hand_delta}),
            reserved_inventory_qty=reserved_inventory_qty-2 WHERE sku_id=@sku AND @won=1;
          SELECT @won;
          COMMIT;
        """

    probe.race("expiry and late settlement compete on the same root at the cutoff",
               [inventory(81, FUTURE, True), inventory(81, FUTURE, False)], ["0", "1"])
    probe.expect("expiry releases only the matching reservation and keeps physical stock",
                 """SELECT o.order_status,r.reservation_status,p.on_hand_inventory_qty,p.reserved_inventory_qty
                 FROM consumption_order o JOIN inventory_reservation r USING(order_id)
                 JOIN product_sku p USING(sku_id) WHERE o.order_id=81;""", "expired\treleased\t10\t4")
    probe.expect("completed settlement wins before expiry", inventory(82, NOW, False), "1")
    probe.expect("scan after settlement cannot release sold stock", inventory(82, FUTURE, True), "0")
    probe.expect("stores without automatic cancellation keep NULL deadline", inventory(83, FUTURE, True), "0")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mysql-client", default="mysql")
    parser.add_argument("--mysqldump", help="optional client to run the logical restore drill")
    parser.add_argument("--mysqlbinlog", help="optional client for the isolated local PITR drill")
    parser.add_argument("--local-binlog-dir", type=Path, help="directory of the isolated source binary logs")
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--pipe", help="named pipe of a disposable Windows MySQL instance")
    target.add_argument("--host", help="host of an isolated MySQL instance")
    parser.add_argument("--port", type=int, default=3306)
    parser.add_argument("--defaults-extra-file")
    parser.add_argument("--user", default="root")
    args = parser.parse_args()
    if bool(args.mysqlbinlog) != bool(args.local_binlog_dir) or (args.mysqlbinlog and not args.mysqldump):
        parser.error("local PITR requires --mysqldump, --mysqlbinlog and --local-binlog-dir")
    raw_v001 = V001.read_bytes()
    if sha256(raw_v001).hexdigest() != V001_SHA256:
        raise AssertionError("V001 differs from the approved Stage 09 artifact")
    probe = Probe(args)
    print(f"MySQL {probe.query('SELECT VERSION();')}", flush=True)
    try:
        v002 = V002.read_text(encoding="utf-8")
        probe.create_schema(probe.fresh_schema)
        probe.query(raw_v001.decode("utf-8"), probe.fresh_schema)
        probe.query(v002, probe.fresh_schema)
        if probe.query("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE();",
                       probe.fresh_schema) != "63":
            raise AssertionError("fresh V001 then V002 should install 63 tables")
        probe.passed_check("fresh V001 then V002 installs 63 tables")
        probe.create_schema(probe.schema)
        probe.run_sql(raw_v001.decode("utf-8"))
        probe.run_sql(SEED_V001)
        probe.run_sql(v002)
        probe.expect("V002 incrementally upgrades a populated V001 to 63 tables", """
          SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE();
        """, "63")
        probe.expect("V001 bindings and original invited stores preserved; no AppID or group is inferred", """
          SELECT (SELECT COUNT(*) FROM wechat_binding), (SELECT COUNT(*) FROM staff_invitation),
            (SELECT COUNT(*) FROM auth_wechat_binding_group),(SELECT COUNT(*) FROM auth_wechat_app);
        """, "4\t2\t0\t0")
        probe.expect("existing staff and stores get generation one without changed role or status", """
          SELECT (SELECT SUM(staff_session_generation) FROM staff WHERE staff_status='active'),
            (SELECT SUM(store_staff_session_generation) FROM store WHERE store_status='active');
        """, "3\t2")
        verify_identity(probe)
        verify_media_and_invites(probe)
        verify_boarding_media(probe)
        verify_workers(probe)
        if args.mysqldump:
            probe.backup_restore(args.mysqldump)
        if args.mysqlbinlog:
            probe.point_in_time_restore(args.mysqlbinlog, args.local_binlog_dir)
        print(f"{probe.passed} probes passed.", flush=True)
    finally:
        probe.cleanup()


if __name__ == "__main__":
    main()

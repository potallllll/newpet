"""Validate the Stage 08 document and its contract artifacts. No API server is contacted."""
from __future__ import annotations

import argparse
from collections import Counter
import csv
from hashlib import sha256
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = ROOT / "contracts"
MUTATIONS = {"post", "put", "patch", "delete"}
NO_KEY_POSTS = {"exchangeWeChat", "verifyWeChatPhone", "previewStaffInvitation", "matchQuickOrderAppointment"}
PUBLIC = {"exchangeWeChat", "listPublicStores", "getPublicStore", "getPublicBusinessHours",
          "listPublicAppointmentServices", "listPublicProducts", "getPublicProduct"}
CHALLENGE = {"verifyWeChatPhone", "confirmWeChatRebind"}
V001_SHA256 = "c340be6abd87501f07f57a169bb5895162f7f4bf46505196f7188eed9392f632"
APPOINTMENT_PROJECTIONS = {"awaiting_customer", "awaiting_store"}
REQUIRED_REASONS = {
    "WaiveConfirm": "waiver_reason",
    "RefundConfirm": "refund_reason",
    "RechargeRefundInput": "wallet_change_reason",
}
OWNER_PERMISSIONS = {
    "createStaffInvitation": "invite_employee",
    "listStoreStaff": "employee_list",
    "disableStaff": "disable_employee",
    "restoreStaff": "restore_employee",
    "removeStaff": "remove_employee",
    "getBusinessSettings": "business_settings",
    "replaceBusinessSettings": "business_settings",
    "createServiceItem": "create_service_item",
    "updateServiceItem": "edit_service_item",
    "disableServiceItem": "disable_service_item",
    "restoreServiceItem": "restore_service_item",
    "getStorePerformance": "business_statistics",
    "createCouponTemplate": "create_coupon_template",
    "updateCouponTemplate": "edit_coupon_template",
    "createInviteCode": "create_invite_code",
}
CONDITIONAL_OWNER_PERMISSIONS = {
    "listStaffOrders": {"order_performance_staff_id_filter": "business_statistics"},
    "updateCouponTemplate": {"template_disable": "disable_coupon_template",
                             "template_restore": "restore_coupon_template"},
    "listGrantableTemplates": {"template_state_is_disabled_or_all": "coupon_management"},
    "recordRechargeRefund": {"refund_mode_is_owner_manual": "record_manual_recharge_refund"},
    "changeOrderAttribution": {"outside_staff_self_transfer_rules": "change_order_attribution"},
    "createMediaUploadIntent": {"existing_store_sensitive_profile_upload": "store_profile"},
    "getAuthorizedMediaDownload": {"store_business_license_download": "store_profile"},
}
BUSINESS_ERRORS = (
    ("recordInitialPayment", 409, "RECEIVABLE_AMOUNT_CONFLICT"),
    ("recordRechargeRefund", 409, "RECHARGE_REFUND_OWNER_MANUAL_REQUIRED"),
    ("recordRechargeRefund", 403, "OWNER_REQUIRED_FOR_RECHARGE_REFUND"),
    ("recordRechargeRefund", 422, "RECHARGE_REFUND_MODE_INELIGIBLE"),
    ("listGrantableTemplates", 403, "ACTION_FORBIDDEN"),
)
SCOPED_ALIAS_EXCEPTIONS = {("Problem", "status")}  # RFC problem HTTP status, not a business state.
EXPECTED = {
    "createAppointment": ("customer", "A1_CORE"), "confirmAppointment": ("staff", "A1_CORE"),
    "convertAppointment": ("staff", "A1_CORE"), "startService": ("staff", "A1_CORE"),
    "completeService": ("staff", "A1_CORE"), "confirmBoardingCheckout": ("staff", "A1_CORE"),
    "correctBoardingCheckoutTimes": ("staff", "A1_CORE"), "recordInitialPayment": ("staff", "A1_CORE"),
    "confirmConsumptionRefund": ("staff", "A1_CORE"), "getOwnOrder": ("customer", "A1_CORE"),
    "createCouponTemplate": ("owner", "A2_ENABLER"), "createInviteCode": ("owner", "A_DEPENDENT"),
    "adjustInventory": ("staff", "A1_CORE"), "startOwnWashAiReport": ("customer", "A_DEPENDENT"),
}


def walk(node):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)


def resolve(spec, ref):
    assert ref.startswith("#/"), ref
    node = spec
    for segment in ref[2:].split("/"):
        node = node[segment.replace("~1", "/").replace("~0", "~")]
    return node


def csv_rows(name, key):
    with (CONTRACTS / name).open(encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    assert len(rows) == len({row[key] for row in rows}), name
    return {row[key]: row for row in rows}


def read_registry():
    source = (ROOT / "docs" / "FIELD-REGISTRY.md").read_text(encoding="utf-8")
    tick = chr(96)
    row_pattern = (r"^\|\s*(F-[A-Z0-9]+-\d{3})\s*\|\s*" + tick
                   + r"([a-z0-9_]+)" + tick + r"\s*\|\s*([CSPD])\s*\|")
    rows = re.findall(row_pattern, source, re.M)
    assert len(rows) == len({field_id for field_id, _, _ in rows}), "duplicate field registry ID"
    registry = {field_id: (name, status) for field_id, name, status in rows}
    expected = int(re.search(r"^> field_count: (\d+)", source, re.M).group(1))
    assert len(registry) == expected, "field registry count does not match its metadata"
    retired = {name for name, status in registry.values() if status == "D"}
    alias_section = source.split("## 23.", 1)[1].split("## 24.", 1)[0]
    aliases = set()
    for label in re.findall(r"^\|\s*([^|]+?)\s*\|", alias_section, re.M):
        if label.startswith((tick, "单一 ")) and "作为渠道" not in label:
            aliases.update(re.findall(tick + r"([a-z0-9_]+)" + tick, label))
    return registry, retired, aliases


def check_registered_ids(row, registry, label):
    ids = row["registered_field_ids"].split(" | ") if row["registered_field_ids"] else []
    for field_id in ids:
        assert field_id in registry, (label, field_id)
        assert registry[field_id][1] != "D", (label, "retired ID", field_id)
    if "status" in row:
        expected = set(filter(None, row["status"].split(" | ")))
        assert expected == {registry[field_id][1] for field_id in ids}, (label, "field status mismatch")
        assert bool(ids) == (row["mapping_class"] == "registry"), (label, "invalid mapping class")


def check_request_model(spec, schema, location, visited):
    """Inspect actual request data definitions, skipping conditional predicates."""
    if "$ref" in schema:
        reference = schema["$ref"]
        if reference not in visited:
            visited.add(reference)
            check_request_model(spec, resolve(spec, reference), reference, visited)
    if schema.get("type") == "object" or {"additionalProperties", "properties"} & schema.keys():
        assert schema.get("additionalProperties") is False, (location, "request object must be closed")
    if schema.get("type") == "array" or "items" in schema:
        limit = schema.get("maxItems")
        assert isinstance(limit, int) and limit >= schema.get("minItems", 0), (location, "missing array cap")
        check_request_model(spec, schema["items"], location + "[]", visited)
    for key, value in schema.get("properties", {}).items():
        check_request_model(spec, value, f"{location}.{key}", visited)
    for keyword in ("oneOf", "anyOf", "allOf"):
        for number, part in enumerate(schema.get(keyword, [])):
            # A type/properties-free guard or a properties-only allOf narrows an already defined model.
            if keyword == "allOf" and not ({"$ref", "type", "additionalProperties"} & part.keys()):
                continue
            check_request_model(spec, part, f"{location}.{keyword}[{number}]", visited)


def check_structure(spec):
    matrix = csv_rows("authorization-matrix.csv", "operation_id")
    fields = csv_rows("field-trace.csv", "api_property")
    assert spec["openapi"] == "3.1.0"
    assert spec["servers"][0]["url"] == "/api/v1"
    registry, retired, aliases = read_registry()
    ref_count = 0
    for node in walk(spec):
        if "$ref" in node:
            resolve(spec, node["$ref"])
            ref_count += 1
    all_properties = set()
    field_locations = {}
    for name, schema in spec["components"]["schemas"].items():
        for node in walk(schema):
            for field in node.get("properties", {}):
                assert field not in retired, (name, "retired field", field)
                assert field not in aliases or (name, field) in SCOPED_ALIAS_EXCEPTIONS, (name, "retired alias", field)
                all_properties.add(field)
                field_locations.setdefault(field, set()).add(name)
    assert set(fields) == all_properties
    assert "F-ORD-013" in fields["manual_adjustment_amount"]["registered_field_ids"].split(" | ")
    for field, row in fields.items():
        check_registered_ids(row, registry, field)
        assert set(row["schemas"].split(" | ")) == field_locations[field], (field, "schema trace differs")
    operations = {}
    traced_parameters = {}
    visited_request_schemas = set()
    for path, methods in spec["paths"].items():
        for method, op in methods.items():
            name = op["operationId"]
            assert name not in operations, name
            operations[name] = op
            c = op["x-access"]
            row = matrix[name]
            assert (row["path"], row["method"], row["policy"], row["iteration"]) == (
                path, method.upper(), c["policy"], op["x-iteration"]), name
            assert all(op[key] for key in ("x-source", "x-storage", "x-release-gate")), name
            assert c["scope"] == row["object_scope"] and row["audiences"] == " | ".join(c["audience"]), name
            assert row["registered_permission_key"] == (c["permission_key"] or ""), name
            conditional = c.get("conditional_permissions", [])
            assert row["conditional_permission_keys"] == " | ".join(
                f"{rule['when']}={rule['permission_key']}" for rule in conditional), name
            assert all(rule["policy"] == "owner" for rule in conditional), name
            assert len(conditional) == len({rule["when"] for rule in conditional}), name
            assert row["version"] == " | ".join(op["x-version"]), name
            assert row["gate"] == op["x-release-gate"], name
            params = [resolve(spec, p["$ref"]) for p in op["parameters"]]
            assert set(re.findall(r"\{(\w+)\}", path)) == {p["name"] for p in params if p["in"] == "path"}
            assert len({(p["in"], p["name"]) for p in params}) == len(params), name
            for param in params:
                assert param["name"] not in retired | aliases, (name, "retired parameter", param["name"])
                if param["in"] in {"header", "query"}:
                    traced_parameters.setdefault((param["in"], param["name"]), set()).add(name)
            private = c["policy"] != "public" or name == "exchangeWeChat"
            assert "500" in op["responses"], name
            for response in op["responses"].values():
                resolved = resolve(spec, response["$ref"]) if "$ref" in response else response
                if private:
                    cache = resolved["headers"]["Cache-Control"]
                    assert resolve(spec, cache["$ref"])["schema"]["const"] == "no-store", name
            error = resolve(spec, op["responses"]["500"]["$ref"])
            assert error["content"]["application/problem+json"]["schema"]["$ref"].endswith("/Problem"), name
            if name in PUBLIC:
                assert c["policy"] == "public" and op["security"] == [], name
            elif name in CHALLENGE:
                assert c["policy"] == "challenge" and op["security"] == [{"WeChatChallenge": []}], name
            else:
                assert c["policy"] in {"user", "customer", "staff", "owner"}
                assert op["security"] == [{"MiniappAccess": []}], name
            if path.startswith("/staff/"):
                assert c["policy"] == "staff" and c["audience"] == ["staff"], name
            if path.startswith("/owner/") and name != "registerOwnerStore":
                assert c["policy"] == "owner" and c["audience"] == ["staff"], name
            if path.startswith("/customer/"):
                assert c["policy"] in {"customer", "user"} and c["audience"] == ["customer"], name
            keyed = method in MUTATIONS and name not in NO_KEY_POSTS | {"logoutSession"}
            assert (op["x-idempotency"] == "required") is keyed, name
            assert any(p["name"] == "Idempotency-Key" and p["required"] for p in params) is keyed, name
            if method in MUTATIONS:
                assert {"400", "409", "422", "503"} <= set(op["responses"]), name
            if "requestBody" in op:
                schema = op["requestBody"]["content"]["application/json"]["schema"]
                check_request_model(spec, schema, name, visited_request_schemas)
    with (CONTRACTS / "parameter-trace.csv").open(encoding="utf-8-sig", newline="") as handle:
        parameter_rows = list(csv.DictReader(handle))
    tracked = {(row["location"], row["parameter"]): row for row in parameter_rows}
    assert len(parameter_rows) == len(tracked) and set(tracked) == set(traced_parameters)
    for key, row in tracked.items():
        assert set(row["operations"].split(" | ")) == traced_parameters[key], key
        assert row["note"], key
        check_registered_ids(row, registry, key)
    assert matrix.keys() == operations.keys()
    assert {name: op["x-access"]["permission_key"] for name, op in operations.items()
            if op["x-access"]["policy"] == "owner"} == {
        name: "staff_owner." + key for name, key in OWNER_PERMISSIONS.items()
    }
    assert {name: {rule["when"]: rule["permission_key"] for rule in op["x-access"]["conditional_permissions"]}
            for name, op in operations.items() if op["x-access"].get("conditional_permissions")} == {
        name: {when: "staff_owner." + key for when, key in rules.items()}
        for name, rules in CONDITIONAL_OWNER_PERMISSIONS.items()
    }
    assert operations["recordRechargeRefund"]["x-access"]["policy"] == "staff"
    assert operations["changeOrderAttribution"]["x-access"]["policy"] == "staff"
    assert operations["registerOwnerStore"]["x-access"]["policy"] == "user"
    assert not operations["registerOwnerStore"]["x-access"].get("activation_guard")
    for name in ("createMediaUploadIntent", "completeMediaUpload"):
        assert operations[name]["x-access"]["activation_guard"] == {
            "existing_store_sensitive_profile_upload": "deferred_until_stage05_profile_review",
        }
        assert "既有门店资料" in matrix[name]["object_scope"]
    assert any(resolve(spec, p["$ref"])["name"] == "If-Match"
               and resolve(spec, p["$ref"])["required"]
               for p in operations["deleteUnusedProduct"]["parameters"])
    assert operations["removeStoreProductCategory"]["x-concurrency"] == "transactional_category_and_fallback_lock"
    for name in ("listRecharges", "listOwnPerformanceOrders"):
        assert name in traced_parameters[("query", "customer_mobile")]
    assert "本人归属" in operations["listOwnPerformanceOrders"]["x-access"]["scope"]

    for name, expected_schema in {
        "getOwnAppointment": "CustomerAppointmentDetail", "getStaffAppointment": "StaffAppointmentDetail",
        "listStaffAppointments": "StaffAppointmentList", "listOwnAppointments": "AppointmentList",
    }.items():
        result = operations[name]["responses"]["200"]["content"]["application/json"]["schema"]
        assert result["properties"]["data"]["$ref"].endswith("/" + expected_schema), name
    assert spec["paths"]["/staff/products/{sku_id}/inventory-adjustments"]["post"]["operationId"] == "adjustInventory"
    assert "/staff/sku/{sku_id}/inventory-adjustments" not in spec["paths"]
    assert "get" not in spec["paths"]["/owner/coupon-templates"]
    assert spec["paths"]["/staff/coupon-templates"]["get"]["operationId"] == "listGrantableTemplates"
    template_parameters = [resolve(spec, p["$ref"]) for p in operations["listGrantableTemplates"]["parameters"]]
    state_query = next(p for p in template_parameters if p["name"] == "template_state")
    assert state_query["schema"] == {"type": "string", "enum": ["active", "disabled", "all"], "default": "active"}
    for name, expected in EXPECTED.items():
        op = operations[name]
        assert (op["x-access"]["policy"], op["x-iteration"]) == expected, name
    response_fields = spec["components"]["schemas"]
    assert "Reason" not in response_fields
    assert {(schema_name, field) for schema_name, schema in response_fields.items()
            for field, value in schema.get("properties", {}).items()
            if value.get("$ref") == "#/components/schemas/RequiredReason"} == set(REQUIRED_REASONS.items())
    for schema_name, field in REQUIRED_REASONS.items():
        assert field in response_fields[schema_name]["required"]
    assert response_fields["PaymentConfirm"]["properties"]["final_receivable_amount"]["x-use"] == "assertion_only"
    assert "final_receivable_amount" in response_fields["PaymentConfirm"]["required"]
    assert "refunded_at" in response_fields["RefundConfirm"]["required"]
    assert "refund_mode" in response_fields["RechargeRefundInput"]["required"]
    for name, status, code in BUSINESS_ERRORS:
        examples = operations[name]["responses"][str(status)]["content"]["application/problem+json"]["examples"]
        assert code in response_fields["Problem"]["properties"]["code"]["enum"]
        assert examples[code]["value"]["code"] == code
        assert examples[code]["value"]["status"] == status
    assert "order_performance_staff_id" not in response_fields["CustomerOrder"]["properties"]
    assert {"available_balance", "principal_balance", "bonus_balance"} <= set(response_fields["CustomerWallet"]["properties"])
    assert "wallet_principal_part" not in response_fields["CustomerSettlement"]["properties"]
    assert "order_collection_note" not in response_fields["CustomerSettlement"]["properties"]
    assert "verified_mobile" not in response_fields["RebindChallenge"]["properties"]
    print(f"{len(operations)} operations, {len(spec['paths'])} paths, {len(response_fields)} schemas, "
          f"{len(fields)} traced properties, {ref_count} resolvable references.")
    print("Iteration:", dict(Counter(op["x-iteration"] for op in operations.values())))
    print(f"{len(registry)} registered fields ({len(retired)} retired), "
          f"{len(tracked)} traced header/query names, and recursive request model coverage verified.")
    print("Authorization matrix, route audiences, idempotency, error responses and private cache headers passed.")
    print(f"{len(OWNER_PERMISSIONS)} owner endpoints and "
          f"{sum(map(len, CONDITIONAL_OWNER_PERMISSIONS.values()))} conditional owner permissions verified.")


def check_v001(spec, path):
    contents = path.read_bytes()
    assert sha256(contents).hexdigest() == V001_SHA256, path
    ddl = contents.decode("utf-8-sig")
    schemas = spec["components"]["schemas"]

    tables = {
        match.group("table").lower(): match.group("body")
        for match in re.finditer(
            r"^\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:\`)?(?P<table>\w+)(?:\`)?"
            r"\s*\((?P<body>.*?)^\)\s*ENGINE\s*=",
            ddl, re.M | re.S | re.I,
        )
    }

    def check_enum(table, field):
        assert table in tables, f"V001 table {table} was not found in {path}"
        pattern = (r"\bCHECK\s*\(\s*(?:\`)?" + re.escape(field)
                   + r"(?:\`)?\s+IN\s*\(([^)]+)\)")
        match = re.search(pattern, tables[table], re.I)
        assert match, f"V001 CHECK enum {table}.{field} was not found in {path}"
        return set(re.findall(r"'([^']+)'", match.group(1)))

    statuses = set(schemas["AppointmentSummary"]["properties"]["appointment_status"]["enum"])
    database_statuses = check_enum("appointment", "appointment_status")
    assert statuses == database_statuses | APPOINTMENT_PROJECTIONS, (statuses, database_statuses)
    assert APPOINTMENT_PROJECTIONS.isdisjoint(database_statuses)
    refund_modes = check_enum("wallet_recharge_refund", "refund_mode")
    for name in ("RechargeRefund", "RechargeRefundInput"):
        assert set(schemas[name]["properties"]["refund_mode"]["enum"]) == refund_modes, (name, refund_modes)
    settlements = check_enum("order_settlement", "settlement_status")
    assert set(schemas["Settlement"]["properties"]["settlement_status"]["enum"]) == settlements, settlements
    assert re.search(r"UNIQUE\s+KEY\s+\w+\s*\(\s*payment_record_id\s*,\s*payment_method\s*\)",
                     tables["payment_split"], re.I), "V001 payment_split must protect split channel uniqueness"
    print("V001 SHA-256, appointment and settlement states, refund modes and tender uniqueness verified.")


def check_standards(spec):
    from jsonschema import Draft202012Validator, FormatChecker
    from openapi_spec_validator import validate

    validate(spec)
    print("OpenAPI 3.1 standard validation passed.")
    cases = []

    def case(label, name, payload, accepted):
        cases.append((label, name, payload, accepted))

    def with_field(base, **change):
        return {**base, **change}

    def without(base, name):
        return {k: v for k, v in base.items() if k != name}

    case("ID is represented as string", "Id", "18446744073709551615", True)
    case("ID must not pass through JS number", "Id", 123, False)
    case("money has two decimal positions", "Money", "80.00", True)
    case("money rejects a number", "Money", 80, False)
    case("zero does not pass positive tender", "PositiveMoney", "0.00", False)
    case("rebind needs an explicit affirmative action", "RebindConfirm", {"confirmed": True}, True)
    case("implicit rebind is denied", "RebindConfirm", {"confirmed": False}, False)
    case("frontend cannot self-assign a role", "RebindConfirm", {"confirmed": True, "role_key": "merchant_owner"}, False)

    date = "2026-12-05T10:00:00+08:00"
    appointment = {"appointment_type": "wash", "requested_start_at": date,
                   "items": [{"pet_id": "41", "service_item_id": "7"}]}
    case("customer appointment with selected service", "AppointmentInput", appointment, True)
    case("service appointment requires project", "AppointmentInput", with_field(appointment, items=[{"pet_id":"41"}]), False)
    case("care cannot be booked by customer", "AppointmentInput", with_field(appointment, appointment_type="other"), False)
    case("boarding needs expected checkout", "AppointmentInput", with_field(appointment, appointment_type="boarding"), False)
    case("boarding with expected checkout", "AppointmentInput", with_field(appointment, appointment_type="boarding",
         boarding_checkout_at="2026-12-06T10:00:00+08:00",items=[{"pet_id":"41"}]), True)
    case("date without timezone rejected", "AppointmentInput", with_field(appointment, requested_start_at="2026-12-05T10:00:00"), False)
    booking_items = appointment["items"]
    appointment_summary = {
        "appointment_id": "13", "store_id": "7", "appointment_type": "wash",
        "appointment_version": "2", "requested_start_at": date, "confirmed_start_at": None,
        "boarding_checkout_at": None, "items": booking_items, "active_proposal": None,
        "appointment_cancel_reason": None, "store_response_reason": None,
    }
    for status in ("pending", "confirmed", "rejected", "cancelled", "expired", "completed"):
        case(f"V001 appointment state {status}", "AppointmentSummary",
             with_field(appointment_summary, appointment_status=status), True)
    proposal = {"reschedule_proposal_id": "19", "reschedule_proposed_by_actor_type": "staff",
                "reschedule_proposal_expires_at": date, "requested_start_at": date,
                "items": booking_items, "boarding_checkout_at": None, "store_response_reason": None}
    awaiting = with_field(appointment_summary, appointment_status="awaiting_customer", active_proposal=proposal)
    case("store proposal waits for customer while retaining original confirmed time", "AppointmentSummary",
         with_field(awaiting, confirmed_start_at="2026-12-05T09:00:00+08:00"), True)
    case("customer proposal waits for store", "AppointmentSummary",
         with_field(awaiting, appointment_status="awaiting_store",
                    active_proposal=with_field(proposal, reschedule_proposed_by_actor_type="customer")), True)
    case("waiting projection needs an active proposal", "AppointmentSummary", with_field(awaiting, active_proposal=None), False)
    case("proposal initiator and waiting projection must agree", "AppointmentSummary",
         with_field(awaiting, appointment_status="awaiting_store"), False)
    case("terminal appointment cannot expose an active proposal", "AppointmentSummary",
         with_field(awaiting, appointment_status="expired"), False)
    case("confirmed no-show has cancelled state and stable result code", "AppointmentSummary",
         with_field(appointment_summary, appointment_status="cancelled", confirmed_start_at=date,
                    appointment_cancel_reason="no_show"), True)
    case("confirmation timeout cannot be labelled no-show", "AppointmentSummary",
         with_field(appointment_summary, appointment_status="expired", appointment_cancel_reason="no_show"), False)

    payment = {"order_amount_version": "11", "final_receivable_amount": "80.00",
               "payment_occurred_at": date, "payment_splits": [
                   {"payment_method": "wallet", "payment_amount": "30.00"},
                   {"payment_method": "cash", "payment_amount": "50.00"}]}
    case("two tender composition", "PaymentConfirm", payment, True)
    case("external payment needs actual time", "PaymentConfirm", without(payment, "payment_occurred_at"), False)
    case("three tender slots denied", "PaymentConfirm", with_field(payment, payment_splits=[
         *payment["payment_splits"], {"payment_method":"wechat","payment_amount":"1.00"}]), False)
    case("client cannot send wallet component", "Tender",
         {"payment_method":"wallet","payment_amount":"30.00","wallet_principal_part":"5.00"}, False)
    case("zero amount follows waiver rather than payment", "PaymentConfirm", with_field(payment,final_receivable_amount="0.00"), False)
    case("payment requires the displayed receivable assertion", "PaymentConfirm",
         without(payment, "final_receivable_amount"), False)
    case("waiver with reason", "WaiveConfirm", {"order_amount_version":"11","waiver_reason":"本次免单"}, True)
    case("waiver blank reason", "WaiveConfirm", {"order_amount_version":"11","waiver_reason":"  "}, False)
    refund = {"order_amount_version": "11", "refund_request_version": "3",
              "refund_reason": "已线下退款", "refunded_at": date}
    case("consumption refund with actual occurrence time", "RefundConfirm", refund, True)
    case("consumption refund needs reason", "RefundConfirm", without(refund, "refund_reason"), False)
    case("consumption refund needs actual occurrence time", "RefundConfirm", without(refund, "refunded_at"), False)
    case("consumption refund timestamp needs timezone", "RefundConfirm",
         with_field(refund, refunded_at="2026-12-05T10:00:00"), False)

    recharge_refund = {"row_version": "11", "returned_principal": "40.00",
                       "wallet_change_reason": "已线下退款", "occurred_at": date, "refund_mode": "standard"}
    case("explicit standard recharge refund", "RechargeRefundInput", recharge_refund, True)
    case("explicit owner-manual recharge refund", "RechargeRefundInput",
         with_field(recharge_refund, refund_mode="owner_manual"), True)
    case("recharge refund requires a mode", "RechargeRefundInput", without(recharge_refund, "refund_mode"), False)
    case("recharge refund rejects an unsupported mode", "RechargeRefundInput",
         with_field(recharge_refund, refund_mode="auto"), False)
    case("recharge refund needs actual occurrence time", "RechargeRefundInput",
         without(recharge_refund, "occurred_at"), False)
    nonempty_reason_bodies = {
        "RefundConfirm": refund, "RechargeRefundInput": recharge_refund,
        "WaiveConfirm": {"order_amount_version": "11", "waiver_reason": "本次免单"},
    }
    for name, field in REQUIRED_REASONS.items():
        for value in (None, "", " \t "):
            case(f"{name} rejects empty required reason {value!r}", name,
                 with_field(nonempty_reason_bodies[name], **{field: value}), False)

    recharge={"row_version":"11","recharge_paid_amount":"100.00","recharge_bonus_amount":"0.00",
              "payment_method":"cash","occurred_at":date}
    coupon = with_field(recharge,recharge_bonus_coupon_items=[{"coupon_template_id":"18","coupon_grant_quantity":1}])
    case("recharge without gifts does not demand a note", "RechargeInput", recharge, True)
    case("coupon-only recharge without note blocked", "RechargeInput", coupon, False)
    case("coupon-only recharge whitespace note blocked", "RechargeInput", with_field(coupon,wallet_note=" \t "), False)
    case("coupon-only recharge with note accepted", "RechargeInput", with_field(coupon,wallet_note="本次赠券"), True)
    case("bonus balance only still needs note", "RechargeInput", with_field(recharge,recharge_bonus_amount="1.00"), False)

    care={"service_record_version":"3","post_service_has_new_abnormality":True}
    case("completion abnormality requires explanation", "FinishService", care, False)
    case("completion can contain no photos", "FinishService", with_field(care,new_abnormality_note="已记录"), True)
    product={"product_category_id":"12","product_name":"样例主粮","sale_price":"5.00"}
    case("single SKU with omitted specification", "ProductInput", product, True)
    case("single SKU optional structure", "ProductInput", with_field(product,sku_spec_values={"label":"200 g"}), True)
    case("multiple SKU alternatives rejected", "ProductInput", with_field(product,sku_spec_values=["A","B"]), False)
    case("activity code cannot set its expiry or quantity", "InviteCodeInput",
         {"invite_code_content_type":"service_activity","service_item_id":"2",
          "invite_code_activity_description":"一次到店礼","quantity":2}, False)
    case("code contains one existing service activity", "InviteCodeInput",
         {"invite_code_content_type":"service_activity","service_item_id":"2","invite_code_activity_description":"一次到店礼"}, True)
    case("retired coupon amount field is not writable", "AmountEdit",
         {"order_amount_version":"11","final_receivable_amount":"10.00","coupon_discount_amount":"2.00"}, False)

    product_items = [{"order_item_id": "3", "confirmed_quantity": 1}]
    optional_reason_bodies = {
        "MemberChange": {"row_version": "1"},
        "MemberName": {"row_version": "1", "staff_display_name": "小李"},
        "ServiceResultEdit": {"service_record_version": "1"},
        "ServiceCancelInput": {"service_record_version": "1"},
        "StaffAppointmentCancelInput": {"appointment_version": "1"},
        "CheckoutTimeCorrection": {"order_amount_version": "1", "items": [
            {"boarding_id": "1", "row_version": "2", "check_in_at": date, "actual_checkout_at": date}
        ]},
        "AppointmentVersion": {"appointment_version": "1"},
        "AppointmentReject": {"appointment_version": "1"},
        "AppointmentReschedule": {"appointment_version": "1", "requested_start_at": date},
        "ServiceTransition": {"service_record_version": "1"},
        "BoardingRate": {"row_version": "1", "order_amount_version": "1", "item_original_unit_price": "2.00"},
        "AmountVersion": {"order_amount_version": "1"},
        "AmountEdit": {"order_amount_version": "1", "final_receivable_amount": "3.00"},
        "Supplement": {"order_amount_version": "1", "verified_fact_ref": "fact-1", "payment_occurred_at": date,
                       "payment_splits": [{"payment_method": "cash", "payment_amount": "2.00"}]},
        "PerformanceAttribution": {"order_amount_version": "1", "order_performance_staff_id": "2"},
        "CouponGrant": {"items": [{"coupon_template_id": "3", "coupon_grant_quantity": 1}]},
        "CouponRemove": {"coupon_instance_ids": ["3"]},
        "ConfirmProductRequest": {"order_amount_version": "1", "order_performance_staff_id": "2",
                                  "items": product_items, "final_receivable_amount": "3.00"},
        "ProductRequestEdit": {"order_amount_version": "1", "items": product_items},
        "InventoryAdjust": {"row_version": "1", "on_hand_inventory_qty": 4},
    }
    optional_reasons = [
        (name, field) for name, schema in spec["components"]["schemas"].items()
        for field, value in schema.get("properties", {}).items()
        if value.get("$ref") == "#/components/schemas/OptionalReason"
    ]
    assert Counter(name for name, _ in optional_reasons) == Counter(optional_reason_bodies.keys())
    for name, field in optional_reasons:
        body = optional_reason_bodies[name]
        case(f"{name} accepts omitted optional reason", name, body, True)
        for value in (None, "", " \t ", "现场核对", 17):
            case(f"{name} optional reason {value!r}", name, with_field(body, **{field: value}),
                 not isinstance(value, int))

    customer_detail = with_field(awaiting, special_request="请继续原来的饮食")
    staff_list_item = with_field(awaiting, customer_name="李女士",
                                 items=[with_field(booking_items[0], pet_name="豆豆")])
    staff_detail = with_field(
        staff_list_item, customer_id="6", customer_contact_mobile="13800000000",
        customer_contact_wechat=None, special_request="请继续原来的饮食",
        items=[with_field(staff_list_item["items"][0], pet_type="dog", pet_breed=None)],
    )
    for name, body in (("CustomerAppointmentDetail", customer_detail),
                       ("StaffAppointmentSummary", staff_list_item), ("StaffAppointmentDetail", staff_detail)):
        case(f"{name} preserves a valid waiting projection", name, body, True)
        case(f"{name} rejects terminal state with active proposal", name,
             with_field(body, appointment_status="expired"), False)
    case("staff appointment pagination uses staff display fields", "StaffAppointmentList",
         {"items": [staff_list_item], "next_cursor": None}, True)
    case("staff list does not leak customer contact", "StaffAppointmentSummary",
         with_field(staff_list_item, customer_contact_mobile="13800000000"), False)
    case("customer detail does not leak staff-only customer ID", "CustomerAppointmentDetail",
         with_field(customer_detail, customer_id="6"), False)
    case("customer detail includes nullable special request", "CustomerAppointmentDetail",
         with_field(customer_detail, special_request=None), True)
    case("staff detail includes authorized local contact", "StaffAppointmentDetail",
         without(staff_detail, "customer_contact_mobile"), False)
    case("appointment write still rejects profile projection", "AppointmentInput",
         with_field(appointment, items=[with_field(booking_items[0], pet_name="豆豆")]), False)
    case("appointment array rejects 21 pets", "AppointmentInput",
         with_field(appointment, items=[{"pet_id": str(n), "service_item_id": "7"} for n in range(1, 22)]), False)
    checkout = optional_reason_bodies["CheckoutTimeCorrection"]
    case("first checkout remains valid without audit reason", "CheckoutBatch", checkout, True)
    case("first checkout is not a correction request", "CheckoutBatch", with_field(checkout, audit_reason=""), False)
    case("correction needs per-pet version", "CheckoutTimeCorrection",
         with_field(checkout, items=[without(checkout["items"][0], "row_version")]), False)

    terms = {"applicable_scope": {"business_types": ["wash"]}, "validity_days": 20}
    full = with_field(terms, coupon_type="full_reduction", minimum_spend="50.00", discount_amount="5.00")
    direct = with_field(terms, coupon_type="direct_discount", discount_amount="5.00")
    percentage = with_field(terms, coupon_type="percentage_discount", discount_rate="0.90")
    for body in (full, direct, percentage, with_field(percentage, max_discount_amount="10.00")):
        case(f"valid coupon {body}", "CouponTemplateTerms", body, True)
    for body in (without(full, "minimum_spend"), with_field(full, minimum_spend="0.00"),
                 with_field(full, discount_amount="0.00"), without(direct, "discount_amount"),
                 with_field(direct, max_discount_amount="10.00"), without(percentage, "discount_rate"),
                 with_field(percentage, discount_rate="0.0000"), with_field(percentage, discount_rate="1.0000"),
                 with_field(percentage, discount_rate="0.9\n"),
                 with_field(percentage, discount_amount="5.00")):
        case(f"invalid coupon {body}", "CouponTemplateTerms", body, False)
    template = {"coupon_name": "熟客券", "terms": full, "coupon_note": "门店备注"}
    case("new coupon template accepts an optional note", "CouponTemplateInput", template, True)
    template_edit = with_field(template, row_version="1", coupon_enabled=True)
    case("coupon template edit accepts a note", "CouponTemplateEdit", template_edit, True)
    case("authorized template read includes optional note", "CouponTemplate",
         with_field(template_edit, coupon_template_id="1"), True)
    old_coupon = {"coupon_instance_id": "1", "coupon_template_id": "4", "coupon_name": "历史券",
                  "entitlement_kind": "coupon", "coupon_status": "used", "coupon_source_type": "manual_grant",
                  "valid_from": date, "valid_until": date, "terms": with_field(percentage, discount_rate="0.0000"),
                  "invite_code_activity_description": None}
    case("old authorized coupon snapshot keeps original terms", "Coupon", old_coupon, True)
    case("customer coupon does not expose template note", "Coupon",
         with_field(old_coupon, coupon_note="门店备注"), False)

    cash = {"payment_method": "cash", "payment_amount": "2.00"}
    supplement = optional_reason_bodies["Supplement"]
    facts = {"order_amount_version": "1", "verified_fact_ref": "receipt-1",
             "payment_splits": [cash], "actual_sale_at": date, "actual_handover_at": date}
    case("external supplemental payment needs actual time", "Supplement",
         without(supplement, "payment_occurred_at"), False)
    case("wallet-only supplemental payment has server debit time", "Supplement",
         with_field(without(supplement, "payment_occurred_at"),
                    payment_splits=[with_field(cash, payment_method="wallet")]), True)
    case("handover and sale times do not replace payment time", "TimeFacts", facts, False)
    case("late product recovery with actual payment time", "TimeFacts",
         with_field(facts, payment_occurred_at=date), True)
    case("late product recovery with verified payment reference", "TimeFacts",
         with_field(facts, payment_splits=[with_field(cash, external_collection_id="8")]), True)
    case("late product recovery needs time for every unreferenced external split", "TimeFacts",
         with_field(facts, payment_splits=[with_field(cash, external_collection_id="8"),
                                           with_field(cash, payment_method="wechat")]), False)
    for name, body in (("PaymentConfirm", payment), ("Supplement", supplement),
                       ("TimeFacts", with_field(facts, payment_occurred_at=date))):
        case(f"{name} rejects duplicate channels with distinct amounts", name,
             with_field(body, payment_splits=[cash, with_field(cash, payment_amount="3.00")]), False)
        case(f"{name} accepts different channels in either order", name,
             with_field(body, payment_splits=[cash, with_field(cash, payment_method="wallet")]), True)

    case("signed invite token is passed as issued", "InviteProof", {"invite_token": "fixture.token-1"}, True)
    case("opaque invite token with extra spaces is rejected", "InviteProof",
         {"invite_token": " fixture.token-1 "}, False)
    case("opaque authentication token with a newline is rejected", "WeChatExchange",
         {"wx_login_code": "fixture-token\n"}, False)
    case("member name cannot be whitespace", "MemberName",
         {"row_version": "1", "staff_display_name": "  "}, False)
    case("local contact cannot consist of whitespace", "LocalCustomerInput",
         {"customer_name": "李女士", "customer_contact_wechat": "  "}, False)
    case("local contact can be a nonblank WeChat handle", "LocalCustomerInput",
         {"customer_name": "李女士", "customer_contact_wechat": "wx-fixture"}, True)
    case("product name cannot be whitespace", "ProductInput", with_field(product, product_name="  "), False)
    case("evidence reference cannot be whitespace", "Supplement",
         with_field(supplement, verified_fact_ref="  "), False)

    normal = {"result": "no_obvious_issue"}
    check_kinds = [
        {"check_kind": "wash_groom", **dict.fromkeys(("skin", "ears", "eyes", "mouth", "nails", "coat"), normal)},
        {"check_kind": "independent_care", "general": normal},
    ]
    for check in check_kinds:
        section = "skin" if check["check_kind"] == "wash_groom" else "general"
        start = {"service_record_version": "1", "pre_service_check_items": check}
        case("normal service start", "StartService", start, True)
        for outcome in ("abnormal", "unable_to_check"):
            inspection = {"result": outcome, "note": "已如实告知"}
            abnormal = with_field(check, **{section: inspection})
            case("abnormal check needs owner decision", "StartService",
                 with_field(start, pre_service_check_items=abnormal), False)
            case("abnormal check needs nonblank explanation", "StartService",
                 with_field(start, pre_service_check_items=with_field(
                     check, owner_decision="continue", **{section: with_field(inspection, note=" ")})), False)
            approved = with_field(abnormal, owner_decision="continue")
            stopped = with_field(abnormal, owner_decision="stop")
            case("owner authorized continuation", "StartService",
                 with_field(start, pre_service_check_items=approved), True)
            case("owner stop blocks service start", "StartService",
                 with_field(start, pre_service_check_items=stopped), False)
            case("record owner stop without starting service", "ServiceCancelInput",
                 with_field(start, pre_service_check_items=stopped), True)
            case("continue is not a stop record", "ServiceCancelInput",
                 with_field(start, pre_service_check_items=approved), False)
            item = {"pet_id": "1", "service_item_id": "2", "item_original_unit_price": "5.00",
                    "pre_service_check_items": stopped}
            quick = {"customer_id": "1", "entry_kind": "member", "items": [item]}
            case("owner stop blocks fast order and automatic start", "QuickOrder", quick, False)
            case("owner continue allows fast order and automatic start", "QuickOrder",
                 with_field(quick, items=[with_field(item, pre_service_check_items=approved)]), True)

    for outcome in ("abnormal", "unable_to_check"):
        boarding = {"pet_id": "1", "item_original_unit_price": "5.00", "check_in_at": date,
                    "expected_checkout_at": date, "boarding_admission_check_status": outcome,
                    "boarding_admission_decision": "accepted"}
        case("abnormal boarding intake needs a real note", "BoardingPetInput", boarding, False)
        confirmed = with_field(boarding, boarding_admission_notes="已沟通")
        case("accepted boarding intake carries its explanation", "NewBoarding",
             {"customer_id": "1", "items": [confirmed]}, True)
        case("declined boarding cannot create a stay", "NewBoarding",
             {"customer_id": "1", "items": [with_field(confirmed, boarding_admission_decision="declined")]}, False)
        case("declined boarding cannot convert an appointment to a stay", "VisitConversionInput",
             {"appointment_version": "1", "boarded_pets": [
                 with_field(confirmed, boarding_admission_decision="declined")
             ]}, False)
        declined = {"pet_id": "1", "boarding_admission_check_status": outcome,
                    "boarding_admission_notes": "已沟通", "boarding_admission_decision": "declined"}
        case("staff cancel can preserve declined intake", "StaffAppointmentCancelInput",
             {"appointment_version": "1", "declined_boarding_checks": [declined]}, True)
        case("declined intake still requires abnormality explanation", "StaffAppointmentCancelInput",
             {"appointment_version": "1", "declined_boarding_checks": [
                 without(declined, "boarding_admission_notes")
             ]}, False)

    for purpose, limit in (("store_front", 3145728), ("business_license", 10485760)):
        for mime in ("image/jpeg", "image/png", "image/webp"):
            intent = {"media_purpose": purpose, "mime_type": mime, "size_bytes": limit}
            case(f"{purpose} format {mime} at limit", "MediaIntentInput", intent, mime != "image/webp")
        case(f"{purpose} rejects 1 byte over its limit", "MediaIntentInput",
             with_field(intent, mime_type="image/jpeg", size_bytes=limit + 1), False)
    case("other media do not inherit the profile file cap", "MediaIntentInput",
         {"media_purpose": "product_image", "mime_type": "image/webp", "size_bytes": 10485761}, True)

    interrupted = {"service_record_id": "1", "order_id": "2", "pet_id": "3", "service_type": "wash",
                   "service_customer_status": "interrupted", "service_summary": None,
                   "service_result_version": None, "media": []}
    photo = {"comparison_group": "full_body", "media_stage": "before", "media_asset_ref": "photo-1"}
    case("interrupted customer response has no result", "CustomerService", interrupted, True)
    for field, value in (("service_summary", "过程"), ("service_result_version", "1"), ("media", [photo])):
        case(f"interruption hides {field}", "CustomerService", with_field(interrupted, **{field: value}), False)
    case("in-progress customer service still shows authorized photos", "CustomerService",
         with_field(interrupted, service_customer_status="in_progress", media=[photo]), True)

    operations = {operation["operationId"]: operation for methods in spec["paths"].values()
                  for operation in methods.values()}
    for name, status, code in BUSINESS_ERRORS:
        problem = operations[name]["responses"][str(status)]["content"]["application/problem+json"]
        case(f"{name} error {code} shape", "Problem", problem["examples"][code]["value"], True)

    for response_name in ("InternalError", "PrivateInternalError"):
        problem = spec["components"]["responses"][response_name]["content"]["application/problem+json"]["example"]
        assert (problem["status"], problem["code"]) == (500, "INTERNAL_ERROR")
        case(f"{response_name} safe HTTP 500 response", "Problem", problem, True)

    for label, name, payload, expected in cases:
        wrapper={"$schema":spec["jsonSchemaDialect"],"$ref":"#/components/schemas/"+name,
                 "components":{"schemas":spec["components"]["schemas"]}}
        validator=Draft202012Validator(wrapper,format_checker=FormatChecker())
        error = next(validator.iter_errors(payload), None)
        passed = error is None
        assert passed is expected, f"{label}: got {passed}, expected {expected}; {error and error.message}"
    print(f"{len(cases)} JSON Schema request and response examples passed.")


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--standards", action="store_true", help="also uses OpenAPI and JSON Schema validators")
    parser.add_argument("--v001", type=Path, help="also checks database constraints in the pinned V001 SQL")
    args=parser.parse_args()
    spec=json.loads((CONTRACTS/"openapi.batch-a.json").read_text(encoding="utf-8"))
    check_structure(spec)
    if args.v001 is not None:
        check_v001(spec, args.v001)
    if args.standards:
        check_standards(spec)


if __name__ == "__main__":
    main()

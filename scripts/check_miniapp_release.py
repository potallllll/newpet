"""Check both compiled WeChat mini programs against protected production metadata."""

import argparse
from hashlib import sha256
import json
from pathlib import Path
import re
import sys


ROLES = ("customer", "staff")
APPID = re.compile(r"wx[0-9a-f]{16}", re.ASCII)


class GateError(ValueError):
    pass


def read_object(path):
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise GateError("release inputs must be JSON objects")
    return value


def appid_pair(value, label):
    if not isinstance(value, dict) or set(value) != set(ROLES):
        raise GateError(f"{label}: both audience mappings must be defined")
    if any(not isinstance(appid, str) or not APPID.fullmatch(appid) for appid in value.values()):
        raise GateError(f"{label}: placeholder, tourist or invalid AppID")
    if len(set(value.values())) != len(ROLES):
        raise GateError(f"{label}: customer and staff AppIDs must differ")
    return value


def inspect_artifact(root):
    if not root.is_dir() or root.is_symlink():
        raise GateError("compiled artifact must be a regular directory")
    entries = sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix())
    for entry in entries:
        if entry.is_symlink() or (not entry.is_file() and not entry.is_dir()):
            raise GateError("compiled artifact contains a link or a special file")
        if entry.name.lower() == "project.private.config.json":
            raise GateError("compiled artifact contains a private project override")
    project = read_object(root / "project.config.json")
    read_object(root / "app.json")

    manifest = []
    for entry in entries:
        if entry.is_file():
            with entry.open("rb") as handle:
                digest = sha256()
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
            manifest.append([entry.relative_to(root).as_posix(), digest.hexdigest()])
    content_id = sha256(json.dumps(manifest, separators=(",", ":")).encode("utf-8")).hexdigest()
    return project.get("appid"), content_id


def check_release(mode, customer_artifact, staff_artifact, release_policy, backend_effective,
                  phase, approved_receipt):
    if mode != "release":
        raise GateError("upload gate requires release mode")
    policy = read_object(release_policy)
    backend = read_object(backend_effective)
    if policy.get("environment") != "production" or backend.get("auth_environment") != "production":
        raise GateError("protected policy and effective backend must both be production")
    if backend.get("mock_auth_enabled") is not False:
        raise GateError("production mock authentication must be explicitly disabled")
    official = appid_pair(policy.get("official_appids"), "protected policy")
    test_ids = policy.get("known_test_appids")
    if not isinstance(test_ids, list) or any(
        not isinstance(value, str) or not APPID.fullmatch(value) for value in test_ids
    ):
        raise GateError("protected policy must list known real test AppIDs")
    if set(official.values()) & set(test_ids):
        raise GateError("protected policy allows a known test AppID")
    if appid_pair(backend.get("appids"), "effective backend") != official:
        raise GateError("effective backend role mapping differs from the protected production policy")

    roots = (customer_artifact, staff_artifact)
    customer_root, staff_root = (root.resolve() for root in roots)
    if customer_root.is_relative_to(staff_root) or staff_root.is_relative_to(customer_root):
        raise GateError("customer and staff build directories must be separate")
    digests = {}
    for role, root in zip(ROLES, roots, strict=True):
        appid, digest = inspect_artifact(root)
        if appid != official[role]:
            raise GateError(f"{role}: compiled AppID differs from the protected production policy")
        digests[role] = digest
    if phase == "upload":
        if approved_receipt is None:
            raise GateError("upload requires a receipt from the authenticated build job")
        if read_object(approved_receipt).get("artifact_tree_sha256") != digests:
            raise GateError("upload artifacts differ from the approved build receipt")
    return digests


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--phase", choices=("build", "upload"), default="build")
    parser.add_argument("--approved-receipt", type=Path)
    parser.add_argument("--customer-artifact", type=Path, required=True)
    parser.add_argument("--staff-artifact", type=Path, required=True)
    parser.add_argument("--release-policy", type=Path, required=True)
    parser.add_argument("--backend-effective", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = check_release(**vars(args))
    except GateError as exc:
        print(f"Release rejected: {exc}", file=sys.stderr)
        return 1
    except (OSError, UnicodeError, ValueError):
        print("Release rejected: a required artifact or JSON input is absent or invalid.", file=sys.stderr)
        return 1
    print(json.dumps({"artifact_tree_sha256": result}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())

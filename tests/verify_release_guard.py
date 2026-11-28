"""Exercise the release gate on separate synthetic build outputs and policies."""

import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parents[1]
GUARD = ROOT / "scripts/check_miniapp_release.py"
CUSTOMER = "wx0000000000000001"
STAFF = "wx0000000000000002"
TEST = "wx0000000000000003"


def write_json(path, value):
    path.write_text(json.dumps(value), encoding="utf-8")


def main():
    with TemporaryDirectory(prefix="newpet-stage11-release-") as temp:
        fixture = Path(temp)
        customer = fixture / "customer"
        staff = fixture / "staff"
        for app in (customer, staff):
            app.mkdir()
            write_json(app / "app.json", {"pages": ["pages/index"]})
            (app / "app.js").write_text("App({});\n", encoding="utf-8")
        policy_path = fixture / "production-policy.json"
        backend_path = fixture / "effective-backend.json"
        policy = {"environment": "production", "official_appids": {"customer": CUSTOMER, "staff": STAFF},
                  "known_test_appids": [TEST]}
        backend = {"auth_environment": "production", "mock_auth_enabled": False,
                   "appids": {"customer": CUSTOMER, "staff": STAFF}}
        count = 0

        def gate(name, valid, customer_id=CUSTOMER, staff_id=STAFF, production_policy=policy,
                 backend_config=backend, mode="release", staff_root=staff, phase="build", receipt=None):
            nonlocal count
            write_json(customer / "project.config.json", {"appid": customer_id})
            write_json(staff / "project.config.json", {"appid": staff_id})
            write_json(policy_path, production_policy)
            write_json(backend_path, backend_config)
            command = [sys.executable, "-B", str(GUARD), "--mode", mode, "--phase", phase,
                       "--customer-artifact", str(customer), "--staff-artifact", str(staff_root),
                       "--release-policy", str(policy_path), "--backend-effective", str(backend_path)]
            if receipt:
                command.extend(["--approved-receipt", str(receipt)])
            proc = subprocess.run(
                command,
                capture_output=True,
                encoding="utf-8",
                timeout=20,
            )
            if valid:
                assert proc.returncode == 0, proc.stderr
                digests = json.loads(proc.stdout)["artifact_tree_sha256"]
                assert set(digests) == {"customer", "staff"}
                assert all(len(value) == 64 for value in digests.values())
            else:
                assert proc.returncode == 1, (name, proc.stdout, proc.stderr)
                assert not proc.stdout
                assert "Release rejected" in proc.stderr
                assert all(appid not in proc.stderr for appid in (CUSTOMER, STAFF, TEST))
                digests = None
            count += 1
            print(f"PASS {name}")
            return digests

        first = gate("protected independent production artifacts", True)
        receipt_path = fixture / "approved-receipt.json"
        write_json(receipt_path, {"artifact_tree_sha256": first})
        gate("upload verifies the approved artifact receipt", True, phase="upload", receipt=receipt_path)
        gate("upload fails when the build receipt is absent", False, phase="upload")
        gate("development mode cannot upload", False, mode="development")
        gate("customer placeholder rejected", False, customer_id="YOUR_CUSTOMER_APPID")
        gate("staff placeholder rejected", False, staff_id="YOUR_STAFF_APPID")
        gate("tourist simulator AppID rejected", False, customer_id="touristappid")
        gate("compiled test AppID rejected", False, customer_id=TEST)
        gate("known test AppID rejected even if placed in production allowlist", False,
             production_policy={**policy, "official_appids": {"customer": TEST, "staff": STAFF}})
        gate("same compiled AppID in both artifacts rejected", False, staff_id=CUSTOMER)
        gate("swapped customer and staff build outputs rejected", False, customer_id=STAFF, staff_id=CUSTOMER)
        gate("non-production backend rejected", False, backend_config={**backend, "auth_environment": "integration"})
        gate("backend sender mapping mismatch rejected", False,
             backend_config={**backend, "appids": {"customer": STAFF, "staff": CUSTOMER}})
        gate("production mock authentication rejected", False, backend_config={**backend, "mock_auth_enabled": True})
        gate("same build directory cannot serve both roles", False, staff_root=customer)
        private_override = staff / "project.private.config.json"
        write_json(private_override, {"appid": TEST})
        gate("private project override rejected", False)
        private_override.unlink()
        (staff / "app.json").unlink()
        gate("missing compiled app manifest rejected", False)
        write_json(staff / "app.json", {"pages": ["pages/index"]})
        (staff / "app.js").write_text("App({changed:true});\n", encoding="utf-8")
        second = gate("same AppID with rebuilt application is accepted for a new digest", True)
        assert first["staff"] != second["staff"] and first["customer"] == second["customer"]
        gate("modified code cannot be uploaded using the old receipt", False, phase="upload", receipt=receipt_path)
        print(f"{count} release gate cases passed.")


if __name__ == "__main__":
    main()

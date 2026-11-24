import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "migrate_to_docker", Path(__file__).resolve().parents[1] / "migrate-to-docker.py"
)
migrator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(migrator)


class MigrationTests(unittest.TestCase):
    def test_profile_list_preserves_dd_prefix_and_orders_default_first(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile_dir = root / "config/proxy"
            profile_dir.mkdir(parents=True)
            (profile_dir / "profiles.json").write_text(json.dumps({"profiles": [
                {"name": "mobile", "secret": "22" * 16, "backend": "127.0.0.1:2398", "carrier_mode": "websocket"},
                {"name": "default", "secret": "dd" + "11" * 16, "backend": "127.0.0.1:2398", "carrier_mode": "https"}
            ]}))
            profiles = migrator.profile_list(root)
            self.assertEqual([p["name"] for p in profiles], ["default", "mobile"])
            self.assertEqual(profiles[0]["secret"], "dd" + "11" * 16)
            self.assertEqual(migrator.canonical_secret(profiles[0]["secret"]), "11" * 16)

    def test_duplicate_canonical_secrets_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile_dir = root / "config/proxy"
            profile_dir.mkdir(parents=True)
            secret = "11" * 16
            (profile_dir / "profiles.json").write_text(json.dumps({"profiles": [
                {"name": "default", "secret": secret, "backend": "127.0.0.1:2398", "carrier_mode": "https"},
                {"name": "mobile", "secret": "dd" + secret, "backend": "127.0.0.1:2398", "carrier_mode": "https"}
            ]}))
            with self.assertRaises(migrator.MigrationError):
                migrator.profile_list(root)

    def test_env_update_preserves_comments_and_unrelated_settings(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".env"
            path.write_text("# operator settings\nDOMAIN=old.example\nKEEP_ME=yes\n")
            result = migrator.update_env_text(path, {"DOMAIN": "new.example", "PANEL_PASSWORD": "new-secret-value"})
            text = result.decode()
            self.assertIn("# operator settings", text)
            self.assertIn("DOMAIN=new.example", text)
            self.assertIn("KEEP_ME=yes", text)
            self.assertIn("PANEL_PASSWORD=new-secret-value", text)


if __name__ == "__main__":
    unittest.main()

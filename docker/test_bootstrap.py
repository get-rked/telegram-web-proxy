import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("bootstrap", Path(__file__).with_name("bootstrap.py"))
bootstrap = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bootstrap)


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.config_dir = root / "config"
        self.mtproxy_dir = root / "mtproxy"
        self.profiles_dir = root / "profiles"
        self.config_dir.mkdir()
        self.mtproxy_dir.mkdir()
        self.profiles_dir.mkdir()
        self.patches = [
            patch.object(bootstrap, "CONFIG_DIR", self.config_dir),
            patch.object(bootstrap, "MTPROXY_DIR", self.mtproxy_dir),
            patch.object(bootstrap, "PROFILES_DIR", self.profiles_dir),
            patch.object(bootstrap, "DOMAIN", "proxy.example.test"),
            patch.object(bootstrap, "UID", os.getuid()),
            patch.object(bootstrap, "GID", os.getgid()),
        ]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.temp.cleanup()

    def test_first_run_creates_matching_secrets_and_token_key(self):
        bootstrap.main()
        profile = json.loads((self.profiles_dir / "profiles.json").read_text())["profiles"][0]
        secret = (self.mtproxy_dir / "secret").read_text().strip()
        self.assertEqual(profile["secret"], secret)
        self.assertEqual(len(bytes.fromhex(secret)), 16)
        self.assertEqual((self.config_dir / "token.key").stat().st_size, 32)
        self.assertEqual((self.config_dir / "token.key").stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.profiles_dir / "profiles.json").stat().st_mode & 0o777, 0o600)
        config = json.loads((self.config_dir / "config.json").read_text())
        self.assertEqual(config["admin_listen"], "127.0.0.1:8081")

    def test_second_run_preserves_secrets_and_token_key(self):
        bootstrap.main()
        secret_before = (self.mtproxy_dir / "secret").read_bytes()
        token_before = (self.config_dir / "token.key").read_bytes()
        bootstrap.main()
        self.assertEqual((self.mtproxy_dir / "secret").read_bytes(), secret_before)
        self.assertEqual((self.config_dir / "token.key").read_bytes(), token_before)

    def test_mismatched_existing_secrets_fail_closed(self):
        (self.profiles_dir / "profiles.json").write_text(json.dumps({"profiles": [{
            "name": "default", "secret": "00" * 16,
            "backend": "127.0.0.1:2398", "carrier_mode": "https"
        }]}))
        (self.mtproxy_dir / "secret").write_text("11" * 16 + "\n")
        with self.assertRaises(SystemExit):
            bootstrap.main()

    def test_hostname_change_backs_up_existing_config(self):
        bootstrap.main()
        path = self.config_dir / "config.json"
        config = json.loads(path.read_text())
        config["public_hostname"] = "old.example.test"
        path.write_text(json.dumps(config))
        bootstrap.main()
        self.assertEqual(json.loads(path.read_text())["public_hostname"], "proxy.example.test")
        self.assertTrue(list(self.config_dir.glob("config.json.backup-*")))


if __name__ == "__main__":
    unittest.main()

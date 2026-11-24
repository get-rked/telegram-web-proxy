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
        self.panel_auth_dir = root / "panel-auth"
        self.panel_credentials_dir = root / "panel-credentials"
        self.panel_route_dir = root / "panel-route"
        self.config_dir.mkdir()
        self.mtproxy_dir.mkdir()
        self.profiles_dir.mkdir()
        self.panel_auth_dir.mkdir()
        self.panel_credentials_dir.mkdir()
        self.panel_route_dir.mkdir()
        self.patches = [
            patch.object(bootstrap, "CONFIG_DIR", self.config_dir),
            patch.object(bootstrap, "MTPROXY_DIR", self.mtproxy_dir),
            patch.object(bootstrap, "PROFILES_DIR", self.profiles_dir),
            patch.object(bootstrap, "PANEL_AUTH_DIR", self.panel_auth_dir),
            patch.object(bootstrap, "PANEL_CREDENTIALS_DIR", self.panel_credentials_dir),
            patch.object(bootstrap, "PANEL_ROUTE_DIR", self.panel_route_dir),
            patch.object(bootstrap, "DOMAIN", "proxy.example.test"),
            patch.object(bootstrap, "RELAY_PORT", 18080),
            patch.object(bootstrap, "ADMIN_PORT", 18081),
            patch.dict(os.environ, {"PANEL_PRINT_CREDENTIALS": "0"}),
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
        self.assertEqual(config["listen"], "127.0.0.1:18080")
        self.assertEqual(config["admin_listen"], "127.0.0.1:18081")
        auth = json.loads((self.panel_auth_dir / "panel-auth.json").read_text())
        self.assertTrue(auth["base_path"].startswith("/panel-"))
        self.assertEqual(len(bytes.fromhex(auth["password_salt"])), 32)
        self.assertEqual(len(bytes.fromhex(auth["password_hash"])), 32)
        credentials = (self.panel_credentials_dir / "panel-credentials.txt").read_text()
        self.assertIn(auth["base_path"], credentials)
        self.assertEqual((self.panel_auth_dir / "panel-auth.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.panel_credentials_dir / "panel-credentials.txt").stat().st_mode & 0o777, 0o600)
        route = (self.panel_route_dir / "panel-route.caddy").read_text()
        self.assertIn("handle_path " + auth["base_path"] + "/*", route)
        self.assertTrue(route.endswith("\n"), "Caddy route must contain real line endings")
        nginx_route = (self.panel_route_dir / "panel-route.nginx.conf").read_text()
        self.assertTrue(nginx_route.endswith("\n"), "Nginx route must contain real line endings")
        self.assertIn("location ^~ " + auth["base_path"] + "/", nginx_route)

    def test_first_run_preserves_dd_prefix_for_web_proxy_and_normalizes_mtproxy_secret(self):
        (self.mtproxy_dir / "secret").write_text("dd" + "ab" * 16 + "\n")
        bootstrap.main()
        profile = json.loads((self.profiles_dir / "profiles.json").read_text())["profiles"][0]
        self.assertEqual(profile["secret"], "dd" + "ab" * 16)
        self.assertEqual((self.mtproxy_dir / "secret").read_text(), "ab" * 16 + "\n")

    def test_second_run_preserves_secrets_and_token_key(self):
        bootstrap.main()
        secret_before = (self.mtproxy_dir / "secret").read_bytes()
        token_before = (self.config_dir / "token.key").read_bytes()
        panel_auth_before = (self.panel_auth_dir / "panel-auth.json").read_bytes()
        panel_credentials_before = (self.panel_credentials_dir / "panel-credentials.txt").read_bytes()
        bootstrap.main()
        self.assertEqual((self.mtproxy_dir / "secret").read_bytes(), secret_before)
        self.assertEqual((self.config_dir / "token.key").read_bytes(), token_before)
        self.assertEqual((self.panel_auth_dir / "panel-auth.json").read_bytes(), panel_auth_before)
        self.assertEqual((self.panel_credentials_dir / "panel-credentials.txt").read_bytes(), panel_credentials_before)

    def test_mismatched_existing_secrets_fail_closed(self):
        (self.profiles_dir / "profiles.json").write_text(json.dumps({"profiles": [{
            "name": "default", "secret": "00" * 16,
            "backend": "127.0.0.1:2398", "carrier_mode": "https"
        }]}))
        (self.mtproxy_dir / "secret").write_text("11" * 16 + "\n")
        with self.assertRaises(SystemExit):
            bootstrap.main()

    def test_dd_prefixed_profiles_match_multiple_canonical_mtproxy_secrets(self):
        default = "dd" + "12" * 16
        mobile = "34" * 16
        (self.profiles_dir / "profiles.json").write_text(json.dumps({"profiles": [
            {"name": "default", "secret": default, "backend": "127.0.0.1:2398", "carrier_mode": "https"},
            {"name": "mobile", "secret": mobile, "backend": "127.0.0.1:2398", "carrier_mode": "websocket"}
        ]}))
        (self.mtproxy_dir / "secret").write_text("12" * 16 + "\n" + mobile + "\n")
        bootstrap.main()
        self.assertEqual((self.mtproxy_dir / "secret").read_text().splitlines(), ["12" * 16, mobile])

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

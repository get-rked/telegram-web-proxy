import importlib.util
import json
import tempfile
import unittest
import sys
from unittest.mock import patch
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

    def test_full_migration_prepares_docker_files_without_touching_native_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "native"
            repo = root / "repo"
            for path in (
                "config/proxy", "config/mtproxy", "data/website",
            ):
                (source / path).mkdir(parents=True, exist_ok=True)
            for path in (
                "docker/config", "docker/profiles", "docker/mtproxy",
                "docker/site", "docker/nginx/certs",
            ):
                (repo / path).mkdir(parents=True, exist_ok=True)
            (repo / "docker/Caddyfile").write_text("proxy.example.test {\\n    reverse_proxy {$TPROXY_LISTEN}\\n}\\n")
            (repo / "docker/nginx/default.conf").write_text("proxy_pass http://${TPROXY_LISTEN};\\n")
            config = {
                "public_hostname": "proxy.example.test",
                "listen": "127.0.0.1:9080",
                "admin_listen": "127.0.0.1:9081",
                "public_dir": str(source / "data/website"),
                "token_key_file": str(source / "config/proxy/token.key"),
            }
            config_path = source / "config/proxy/config.json"
            config_path.write_text(json.dumps(config))
            (source / "config/proxy/profiles.json").write_text(json.dumps({"profiles": [
                {"name": "default", "secret": "dd" + "12" * 16, "backend": "127.0.0.1:2398", "carrier_mode": "https"},
                {"name": "mobile", "secret": "34" * 16, "backend": "127.0.0.1:2398", "carrier_mode": "websocket"},
            ]}))
            (source / "config/proxy/token.key").write_bytes(b"k" * 32)
            (source / "config/proxy/acme-email").write_text("admin@example.test")
            (source / "config/proxy/web-server").write_text("caddy")
            (source / "config/mtproxy/mtproxy.env").write_text(
                'MTPROXY_SECRETS="' + "12" * 16 + " -S " + "34" * 16 + '"\n'
                "MTPROXY_WORKERS=2\nMTPROXY_MAX_CONNECTIONS=30\n"
                "MTPROXY_NAT_ARGS=--nat-info 10.0.0.2:203.0.113.4\n"
            )
            (source / "data/website/index.html").write_text("native-site")
            original_config = config_path.read_bytes()
            migrator.REPO = repo
            with patch.object(migrator, "backup_paths", return_value=root / "backup.tar.gz"), patch.object(migrator.os, "geteuid", return_value=0), patch.object(sys, "argv", ["migrate-to-docker.py", "--source-dir", str(source)]):
                self.assertEqual(migrator.main(), 0)
            with patch.object(migrator, "backup_paths", return_value=root / "backup.tar.gz"), patch.object(migrator.os, "geteuid", return_value=0), patch.object(sys, "argv", ["migrate-to-docker.py", "--source-dir", str(source), "--apply"]):
                self.assertEqual(migrator.main(), 0)
            migrated = json.loads((repo / "docker/config/config.json").read_text())
            self.assertEqual(migrated["listen"], "127.0.0.1:9080")
            self.assertEqual(migrated["public_dir"], "/srv/tproxy-site")
            self.assertEqual((repo / "docker/config/token.key").read_bytes(), b"k" * 32)
            self.assertEqual((repo / "docker/site/index.html").read_text(), "native-site")
            self.assertEqual((repo / "docker/mtproxy/secret").read_text().splitlines(), ["12" * 16, "34" * 16])
            env = (repo / ".env").read_text()
            self.assertIn("TPROXY_LISTEN=127.0.0.1:9080", env)
            self.assertIn("MTPROXY_WORKERS=2", env)
            self.assertIn("MTPROXY_MAX_CONNECTIONS=30", env)
            self.assertIn("MTPROXY_NAT_INFO=10.0.0.2:203.0.113.4", env)
            self.assertEqual(config_path.read_bytes(), original_config)

    def test_site_copy_preserves_previous_destination_and_verifies_new_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "native-site"
            destination = root / "docker/site"
            source.mkdir()
            destination.mkdir(parents=True)
            (source / "index.html").write_text("new native site")
            (source / "assets").mkdir()
            (source / "assets/app.js").write_text("console.log('new')")
            (destination / "index.html").write_text("tracked Docker placeholder")

            migrator.copy_tree_atomic(source, destination)

            self.assertEqual((destination / "index.html").read_text(), "new native site")
            self.assertEqual((destination / "assets/app.js").read_text(), "console.log('new')")
            previous = list(root.glob("docker/site.before-migration.*"))
            self.assertEqual(len(previous), 1)
            self.assertEqual((previous[0] / "index.html").read_text(), "tracked Docker placeholder")
            self.assertEqual(migrator.tree_manifest(source), migrator.tree_manifest(destination))

    def test_backup_paths_verifies_archive_and_writes_sha256_sidecar(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            source.mkdir()
            (source / "secret.txt").write_text("backup payload")
            archive = migrator.backup_paths([source], root / "backups")
            checksum = archive.with_suffix(archive.suffix + ".sha256")
            self.assertTrue(archive.is_file())
            self.assertTrue(checksum.is_file())
            self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
            self.assertEqual(checksum.stat().st_mode & 0o777, 0o600)
            self.assertIn(archive.name, checksum.read_text())

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

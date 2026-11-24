import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "migrate_docker_auto", Path(__file__).resolve().parents[1] / "migrate-docker-auto.py"
)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class RunningContainerCheckTests(unittest.TestCase):
    def test_empty_project_does_not_require_compose_env(self):
        with patch.object(runner, "cmd", return_value=("", 0)) as mocked:
            self.assertEqual(runner.running_project_containers(), [])
        mocked.assert_called_once_with([
            "docker", "ps",
            "--filter", "label=com.docker.compose.project=telegram-web-proxy",
            "--format", "{{.Names}}",
        ], False)

    def test_running_project_containers_are_returned_by_name(self):
        with patch.object(runner, "cmd", return_value=("relay\npanel\n", 0)):
            self.assertEqual(runner.running_project_containers(), ["relay", "panel"])

    def test_docker_ps_failure_aborts_instead_of_assuming_empty_project(self):
        with patch.object(runner, "cmd", return_value=("Cannot connect to daemon", 1)):
            with self.assertRaisesRegex(runner.MigrationAbort, "Не удалось проверить"):
                runner.running_project_containers()


    def test_caddy_global_and_nested_directives_are_not_mistaken_for_sites(self):
        caddyfile = """
{
    email {$ACME_EMAIL}
    admin off
    servers {
        protocols h1 h2
    }
}
{$TPROXY_HOSTNAME} {
    encode zstd gzip
    reverse_proxy 127.0.0.1:8090 {
        transport http {
            keepalive 30s
        }
    }
    handle_errors {
        respond "unavailable" 503
    }
}
"""
        self.assertEqual(runner.caddy_site_names(caddyfile), set())

    def test_caddy_parser_detects_a_second_top_level_site(self):
        caddyfile = """
{
    email admin@example.test
}
proxy.example.test {
    respond "one"
}
other.example.test {
    respond "two"
}
"""
        self.assertEqual(
            runner.caddy_site_names(caddyfile),
            {"proxy.example.test", "other.example.test"},
        )


if __name__ == "__main__":
    unittest.main()

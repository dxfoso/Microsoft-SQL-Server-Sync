import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PROJECT_ROOT = ROOT.parents[1]


class ChartContractsTests(unittest.TestCase):
    def test_backend_does_not_require_admin_key_for_public_health(self):
        backend_deployment = (
            ROOT / "templates" / "backend-deployment.yaml"
        ).read_text(encoding="utf-8")
        self.assertNotIn("TRU_ADMIN_REQUIRE_KEY", backend_deployment)
        self.assertNotIn("TRU_ADMIN_KEY", backend_deployment)

    def test_backend_secret_only_manages_postgres_url(self):
        backend_secret = (ROOT / "templates" / "backend-secret.yaml").read_text(
            encoding="utf-8"
        )
        self.assertIn("TRU_POSTGRESQL_URL", backend_secret)
        self.assertNotIn("admin secret", backend_secret)
        self.assertNotIn("TRU_ADMIN_KEY", backend_secret)

    def test_values_do_not_expose_dead_admin_block(self):
        values_yaml = (ROOT / "values.yaml").read_text(encoding="utf-8")
        self.assertNotIn("\nadmin:\n", values_yaml)
        self.assertNotIn("sql-sync-admin", values_yaml)

    def test_values_keep_production_pod_defaults_and_use_endpoint_upstreams(self):
        values_yaml = (ROOT / "values.yaml").read_text(encoding="utf-8")
        self.assertIn("frontend:\n  replicas: 2\n", values_yaml)
        self.assertIn("backend:\n  enabled: true\n  replicas: 2\n", values_yaml)
        self.assertNotIn('nginx.ingress.kubernetes.io/service-upstream: "true"', values_yaml)
        self.assertIn(
            'nginx.ingress.kubernetes.io/proxy-next-upstream: "error timeout http_502 http_503 http_504"',
            values_yaml,
        )
        self.assertIn(
            'nginx.ingress.kubernetes.io/proxy-next-upstream-tries: "3"',
            values_yaml,
        )
        self.assertIn(
            'nginx.ingress.kubernetes.io/proxy-next-upstream-timeout: "120"',
            values_yaml,
        )

    def test_ingress_routes_public_backend_paths_to_backend_service(self):
        ingress = (ROOT / "templates" / "ingress.yaml").read_text(encoding="utf-8")
        self.assertIn("- path: /ready", ingress)
        self.assertIn("- path: /bench", ingress)
        self.assertIn("- path: /metrics", ingress)

    def test_backend_deployment_uses_configured_replica_count(self):
        backend_deployment = (
            ROOT / "templates" / "backend-deployment.yaml"
        ).read_text(encoding="utf-8")
        self.assertIn("replicas: {{ .Values.backend.replicas }}", backend_deployment)

    def test_runtime_config_keeps_public_admin_health_ungated(self):
        tru_json = (PROJECT_ROOT / "business" / "tru.json").read_text(
            encoding="utf-8"
        )
        self.assertIn('"adminRequireKey": false', tru_json)
        self.assertIn('"requireKey": false', tru_json)


if __name__ == "__main__":
    unittest.main()

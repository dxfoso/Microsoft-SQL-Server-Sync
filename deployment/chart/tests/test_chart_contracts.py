import json
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PROJECT_ROOT = ROOT.parents[1]


class ChartContractsTests(unittest.TestCase):
    def test_auto_scheduler_is_not_deployed_suspended(self):
        cronjob = (ROOT / "templates" / "auto-scheduler-cronjob.yaml").read_text(
            encoding="utf-8"
        )
        self.assertIn('suspend: false', cronjob)

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
        self.assertIn("frontend:\n  replicas: 1\n", values_yaml)
        self.assertIn("backend:\n  enabled: true\n  replicas: 1\n", values_yaml)
        self.assertNotIn('nginx.ingress.kubernetes.io/service-upstream: "true"', values_yaml)
        self.assertIn(
            'nginx.ingress.kubernetes.io/proxy-next-upstream: "error timeout http_502 http_503 http_504"',
            values_yaml,
        )
        self.assertIn(
            'nginx.ingress.kubernetes.io/proxy-http-version: "1.1"',
            values_yaml,
        )
        self.assertIn(
            'nginx.ingress.kubernetes.io/connection-proxy-header: "keep-alive"',
            values_yaml,
        )
        self.assertIn(
            'nginx.ingress.kubernetes.io/proxy-next-upstream-tries: "3"',
            values_yaml,
        )
        self.assertIn(
            'nginx.ingress.kubernetes.io/proxy-body-size: "100m"',
            values_yaml,
        )
        self.assertIn(
            'nginx.ingress.kubernetes.io/proxy-read-timeout: "900"',
            values_yaml,
        )
        self.assertIn(
            'nginx.ingress.kubernetes.io/proxy-send-timeout: "900"',
            values_yaml,
        )
        self.assertIn(
            'nginx.ingress.kubernetes.io/proxy-next-upstream-timeout: "900"',
            values_yaml,
        )

    def test_chart_does_not_keep_dead_sync_engine_mode_wiring(self):
        values_yaml = (ROOT / "values.yaml").read_text(encoding="utf-8")
        frontend_deployment = (ROOT / "templates" / "deployment.yaml").read_text(
            encoding="utf-8"
        )
        backend_deployment = (
            ROOT / "templates" / "backend-deployment.yaml"
        ).read_text(encoding="utf-8")

        self.assertNotIn("syncEngine:", values_yaml)
        self.assertNotIn("symmetricds:", values_yaml)
        self.assertNotIn("SQL_SYNC_ENGINE_MODE", frontend_deployment)
        self.assertNotIn("SQL_SYNC_ENGINE_MODE", backend_deployment)
        self.assertNotIn("syncEngineMode", values_yaml)
        self.assertNotIn(".Values.frontend.syncEngineMode", frontend_deployment)
        self.assertNotIn(".Values.backend.env.syncEngineMode", backend_deployment)

    def test_chart_removes_legacy_sync_runtime_resources(self):
        ingress = (ROOT / "templates" / "ingress.yaml").read_text(encoding="utf-8")
        pvc = (ROOT / "templates" / "pvc.yaml").read_text(encoding="utf-8")
        helpers = (ROOT / "templates" / "_helpers.tpl").read_text(encoding="utf-8")

        self.assertNotIn("- path: /sync", ingress)
        self.assertNotIn("symmetricds", helpers)
        self.assertNotIn("symmetricds", pvc)

    def test_chart_derives_frontend_api_route_from_central_ingress(self):
        values_yaml = (ROOT / "values.yaml").read_text(encoding="utf-8")
        frontend_deployment = (ROOT / "templates" / "deployment.yaml").read_text(
            encoding="utf-8"
        )
        pvc = (ROOT / "templates" / "pvc.yaml").read_text(encoding="utf-8")
        helpers = (ROOT / "templates" / "_helpers.tpl").read_text(encoding="utf-8")

        self.assertNotIn("backendBaseUrl", values_yaml)
        self.assertNotIn("apiBaseUrl", values_yaml)
        self.assertNotIn("publicBaseUrl", values_yaml)
        self.assertNotIn("publicHost", values_yaml)
        self.assertIn('value: "/call"', frontend_deployment)
        self.assertNotIn(".Values.frontend.backendBaseUrl", frontend_deployment)
        self.assertIn("mountPath: /app/data/client-updates", frontend_deployment)
        self.assertIn("sync-admin-web.frontendClientUpdatesPvcName", frontend_deployment)
        self.assertIn("frontendClientUpdatesPvcName", helpers)
        self.assertIn("frontend.clientUpdates.size", pvc)

    def test_chart_default_images_are_not_latest(self):
        values_yaml = (ROOT / "values.yaml").read_text(encoding="utf-8")

        self.assertNotIn(":latest", values_yaml)
        self.assertNotIn("image: postgres:16-alpine", values_yaml)
        self.assertIn(
            "image: registry.cloud.divclouds.com/microsoft-sql-server-sync/frontend:dev",
            values_yaml,
        )
        self.assertIn(
            "image: registry.cloud.divclouds.com/microsoft-sql-server-sync/backend:dev",
            values_yaml,
        )
        self.assertIn("image: docker.io/library/postgres:16-alpine", values_yaml)
    def test_postgres_password_is_secret_backed(self):
        postgres_deployment = (
            ROOT / "templates" / "postgres-deployment.yaml"
        ).read_text(encoding="utf-8")
        postgres_secret = (ROOT / "templates" / "postgres-secret.yaml").read_text(
            encoding="utf-8"
        )
        helpers = (ROOT / "templates" / "_helpers.tpl").read_text(encoding="utf-8")

        self.assertIn("valueFrom:", postgres_deployment)
        self.assertIn("secretKeyRef:", postgres_deployment)
        self.assertIn("include \"sync-admin-web.postgresSecretName\"", postgres_deployment)
        self.assertNotIn("value: {{ .Values.postgres.password", postgres_deployment)
        self.assertIn("kind: Secret", postgres_secret)
        self.assertIn("POSTGRES_PASSWORD", postgres_secret)
        self.assertIn("sync-admin-web.postgresSecretName", helpers)
        self.assertNotIn("sync-admin-web.adminSecretName", helpers)

    def test_chart_removes_legacy_postgres_compat_job(self):
        self.assertFalse(
            (ROOT / "templates" / "postgres-compat-migration-job.yaml").exists()
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
        self.assertIn(".Values.nodeSelector", backend_deployment)
        self.assertIn(".Values.tolerations", backend_deployment)
        self.assertNotIn(".Values.backend.nodeSelector", backend_deployment)
        self.assertNotIn(".Values.backend.tolerations", backend_deployment)

    def test_all_workloads_inherit_cloud_selected_scheduling(self):
        values_yaml = (ROOT / "values.yaml").read_text(encoding="utf-8")
        self.assertNotIn("kubernetes.io/hostname: rack", values_yaml)
        self.assertNotIn("\n  nodeSelector:\n", values_yaml)
        self.assertNotIn("\n  tolerations:\n", values_yaml)

        for template_name in (
            "deployment.yaml",
            "backend-deployment.yaml",
            "postgres-deployment.yaml",
        ):
            template = (ROOT / "templates" / template_name).read_text(
                encoding="utf-8"
            )
            self.assertIn(".Values.nodeSelector", template)
            self.assertIn(".Values.tolerations", template)
            self.assertIn(".Values.affinity", template)

    def test_postgres_deployment_uses_workload_specific_scheduling(self):
        postgres_deployment = (
            ROOT / "templates" / "postgres-deployment.yaml"
        ).read_text(encoding="utf-8")
        self.assertNotIn(".Values.postgres.nodeSelector", postgres_deployment)
        self.assertNotIn(".Values.postgres.tolerations", postgres_deployment)

    def test_backend_probes_use_tolerant_configured_thresholds(self):
        values_yaml = (ROOT / "values.yaml").read_text(encoding="utf-8")
        backend_deployment = (
            ROOT / "templates" / "backend-deployment.yaml"
        ).read_text(encoding="utf-8")

        self.assertIn("timeoutSeconds: 5", values_yaml)
        self.assertIn("failureThreshold: 6", values_yaml)
        self.assertIn(
            "timeoutSeconds: {{ .Values.backend.readinessProbe.timeoutSeconds }}",
            backend_deployment,
        )
        self.assertIn(
            "failureThreshold: {{ .Values.backend.livenessProbe.failureThreshold }}",
            backend_deployment,
        )

    def test_backend_sets_memory_cap_below_pod_limit(self):
        values_yaml = (ROOT / "values.yaml").read_text(encoding="utf-8")
        backend_deployment = (
            ROOT / "templates" / "backend-deployment.yaml"
        ).read_text(encoding="utf-8")

        self.assertIn('truMemoryCapMb: "6144"', values_yaml)
        self.assertIn('truWasmTimeoutMs: "30000"', values_yaml)
        self.assertIn("memory: 8Gi", values_yaml)
        self.assertIn("TRU_MEMORY_CAP_MB", backend_deployment)
        self.assertIn(".Values.backend.env.truMemoryCapMb", backend_deployment)
        self.assertIn("TRU_WASM_TIMEOUT_MS", backend_deployment)
        self.assertIn(".Values.backend.env.truWasmTimeoutMs", backend_deployment)

    def test_runtime_config_keeps_public_admin_health_ungated(self):
        tru_config = json.loads(
            (PROJECT_ROOT / "business" / "tru.json").read_text(encoding="utf-8")
        )
        self.assertIs(tru_config["adminRequireKey"], False)
        self.assertIs(tru_config["admin"]["requireKey"], False)
        self.assertIs(tru_config["settings"]["admin"]["requireKey"], False)


if __name__ == "__main__":
    unittest.main()

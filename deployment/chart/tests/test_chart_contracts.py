import json
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

    def test_chart_declares_symmetricds_sync_engine(self):
        values_yaml = (ROOT / "values.yaml").read_text(encoding="utf-8")
        frontend_deployment = (ROOT / "templates" / "deployment.yaml").read_text(
            encoding="utf-8"
        )
        backend_deployment = (
            ROOT / "templates" / "backend-deployment.yaml"
        ).read_text(encoding="utf-8")

        self.assertIn("syncEngine:\n  mode: symmetricDs", values_yaml)
        self.assertNotIn("postgresCustomSync", values_yaml)
        self.assertIn("SQL_SYNC_ENGINE_MODE", frontend_deployment)
        self.assertIn("SQL_SYNC_ENGINE_MODE", backend_deployment)
        self.assertNotIn("syncEngineMode", values_yaml)
        self.assertNotIn(".Values.frontend.syncEngineMode", frontend_deployment)
        self.assertNotIn(".Values.backend.env.syncEngineMode", backend_deployment)

    def test_chart_runs_symmetricds_runtime_behind_sync_path(self):
        values_yaml = (ROOT / "values.yaml").read_text(encoding="utf-8")
        ingress = (ROOT / "templates" / "ingress.yaml").read_text(encoding="utf-8")
        symmetricds_deployment = (
            ROOT / "templates" / "symmetricds-deployment.yaml"
        ).read_text(encoding="utf-8")
        symmetricds_service = (
            ROOT / "templates" / "symmetricds-service.yaml"
        ).read_text(encoding="utf-8")
        symmetricds_config = (
            ROOT / "templates" / "symmetricds-configmap.yaml"
        ).read_text(encoding="utf-8")
        pvc = (ROOT / "templates" / "pvc.yaml").read_text(encoding="utf-8")
        helpers = (ROOT / "templates" / "_helpers.tpl").read_text(encoding="utf-8")

        self.assertIn("symmetricds:\n  enabled: true\n", values_yaml)
        self.assertIn("image: docker.io/jumpmind/symmetricds:3.16.10", values_yaml)
        self.assertIn("initImage: docker.io/library/busybox:1.36.1", values_yaml)
        self.assertNotIn("jumpmind/symmetricds:latest", values_yaml)
        self.assertIn("- path: /sync", ingress)
        self.assertIn("include \"sync-admin-web.symmetricdsFullname\"", ingress)
        self.assertIn("kind: Deployment", symmetricds_deployment)
        self.assertIn("app.kubernetes.io/component: symmetricds", symmetricds_deployment)
        self.assertIn("startupProbe:", symmetricds_deployment)
        self.assertIn("readinessProbe:", symmetricds_deployment)
        self.assertIn("livenessProbe:", symmetricds_deployment)
        self.assertIn("tcpSocket:", symmetricds_deployment)
        self.assertIn("initContainers:", symmetricds_deployment)
        self.assertIn("render-engine-config", symmetricds_deployment)
        self.assertIn("printf '\\ndb.password=%s\\n'", symmetricds_deployment)
        self.assertIn("secretKeyRef:", symmetricds_deployment)
        self.assertIn("kind: Service", symmetricds_service)
        self.assertIn("{{ .Values.symmetricds.engineName }}.properties.tpl", symmetricds_config)
        self.assertIn("sync.url=https://{{ .Values.domain }}/sync/server", symmetricds_config)
        self.assertIn("db.driver=org.postgresql.Driver", symmetricds_config)
        self.assertNotIn("db.password=", symmetricds_config)
        self.assertIn("sync-admin-web.symmetricdsPvcName", helpers)
        self.assertIn("sync-admin-web.symmetricdsPvcName", pvc)

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
        self.assertIn("image: docker.io/jumpmind/symmetricds:3.16.10", values_yaml)

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

    def test_postgres_compat_migration_relaxes_removed_legacy_agent_columns(self):
        migration_job = (
            ROOT / "templates" / "postgres-compat-migration-job.yaml"
        ).read_text(encoding="utf-8")

        self.assertIn("kind: Job", migration_job)
        self.assertIn('"helm.sh/hook": post-install,post-upgrade', migration_job)
        self.assertIn("secretKeyRef:", migration_job)
        self.assertIn("include \"sync-admin-web.postgresSecretName\"", migration_job)
        self.assertIn("information_schema.columns", migration_job)
        self.assertIn("column_name = 'isMaster'", migration_job)
        self.assertIn('ALTER TABLE agents ALTER COLUMN \\"isMaster\\" DROP NOT NULL', migration_job)
        self.assertIn('ALTER TABLE agents ALTER COLUMN \\"isMaster\\" SET DEFAULT false', migration_job)

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
            "symmetricds-deployment.yaml",
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

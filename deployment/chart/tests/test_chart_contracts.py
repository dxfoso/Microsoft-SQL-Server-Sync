import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


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


if __name__ == "__main__":
    unittest.main()

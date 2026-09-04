import json
import os
import pathlib
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[1]


class ClientUpdateRangeTests(unittest.TestCase):
    def test_client_artifact_endpoint_serves_resumable_byte_ranges(self):
        with tempfile.TemporaryDirectory(prefix="sql-sync-range-") as temp_text:
            temp = pathlib.Path(temp_text)
            updates = temp / "updates"
            public = temp / "public"
            updates.mkdir()
            public.mkdir()
            payload = bytes(range(256)) * 8
            (updates / "payload.bin").write_bytes(payload)
            (updates / "latest.json").write_text(
                json.dumps({"version": "test", "zipUrl": "/client/payload.bin"}),
                encoding="utf-8",
            )

            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]

            env = os.environ.copy()
            env.update(
                PORT=str(port),
                CLIENT_UPDATES_DIR=str(updates),
                PUBLIC_DIR=str(public),
            )
            creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
            process = subprocess.Popen(
                ["node", "server.js"],
                cwd=ROOT / "frontend",
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=creation_flags,
            )
            try:
                response = None
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    try:
                        request = urllib.request.Request(
                            f"http://127.0.0.1:{port}/client/payload.bin",
                            headers={"Range": "bytes=100-199"},
                        )
                        response = urllib.request.urlopen(request, timeout=2)
                        break
                    except OSError:
                        time.sleep(0.1)
                self.assertIsNotNone(response, "client artifact server did not start")
                with response:
                    self.assertEqual(response.status, 206)
                    self.assertEqual(response.headers["Accept-Ranges"], "bytes")
                    self.assertEqual(response.headers["Content-Range"], "bytes 100-199/2048")
                    self.assertEqual(response.read(), payload[100:200])
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

    def test_private_backup_chunks_require_authentication_and_can_be_downloaded(self):
        with tempfile.TemporaryDirectory(prefix="sql-sync-private-export-") as temp_text:
            temp = pathlib.Path(temp_text)
            updates = temp / "updates"
            public = temp / "public"
            artifact_dir = updates / ".private-exports" / "request-1" / "source-1"
            artifact_dir.mkdir(parents=True)
            public.mkdir()
            payload = b"verified-backup-chunk"
            (artifact_dir / "00000000.part").write_bytes(payload)

            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]

            token = "private-export-test-token-0123456789"
            env = os.environ.copy()
            env.update(
                PORT=str(port),
                CLIENT_UPDATES_DIR=str(updates),
                PUBLIC_DIR=str(public),
                PRIVATE_EXPORT_TOKEN=token,
            )
            creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
            process = subprocess.Popen(
                ["node", "server.js"],
                cwd=ROOT / "frontend",
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=creation_flags,
            )
            url = (
                f"http://127.0.0.1:{port}/private-export/"
                "request-1/source-1/00000000.part"
            )
            try:
                deadline = time.monotonic() + 10
                while True:
                    try:
                        urllib.request.urlopen(url, timeout=2)
                    except urllib.error.HTTPError as error:
                        if error.code == 401:
                            break
                    except OSError:
                        if time.monotonic() >= deadline:
                            self.fail("private artifact server did not start")
                        time.sleep(0.1)
                        continue
                request = urllib.request.Request(
                    url, headers={"Authorization": f"Bearer {token}"}
                )
                with urllib.request.urlopen(request, timeout=2) as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(response.headers["Cache-Control"], "private, no-store")
                    self.assertEqual(response.read(), payload)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()

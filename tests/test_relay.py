"""Integration tests against the actual OpenSSH container. Docker is required."""
import base64
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import time
import unittest
import uuid


class Marker(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.sendall(b"SSH_BRIDGE_OK\n")


class RelayTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        for name in ("host", "device", "client", "stranger"):
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(cls.root/name)], check=True)
        cls.known = cls.root/"known_hosts"
        cls.known.write_text("test-relay " + (cls.root/"host.pub").read_text())
        envfile = cls.root/"relay.env"
        envfile.write_text(
            "RELAY_HOST_KEY_B64=" + base64.b64encode((cls.root/"host").read_bytes()).decode() + "\n" +
            "DEVICE_PUBLIC_KEY=" + (cls.root/"device.pub").read_text().strip() + "\n" +
            "CLIENT_PUBLIC_KEY=" + (cls.root/"client.pub").read_text().strip() + "\n")
        envfile.chmod(0o600)
        cls.name = "ssh-bridge-test-" + uuid.uuid4().hex[:10]
        subprocess.run(["docker", "run", "-d", "--name", cls.name, "--env-file", str(envfile),
                        "-p", "127.0.0.1::2222", os.getenv("RELAY_TEST_IMAGE", "ssh-bridge-relay:local")],
                       check=True, capture_output=True)
        cls.port = subprocess.check_output(["docker", "port", cls.name, "2222"], text=True).strip().split(":")[-1]
        cls.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Marker)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.device = subprocess.Popen(cls.ssh("device") + ["-N", "-o", "ExitOnForwardFailure=yes", "-R",
            f"127.0.0.1:22022:127.0.0.1:{cls.server.server_address[1]}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Startup readiness also verifies the permitted forwarding path.
        for _ in range(50):
            result = subprocess.run(cls.ssh("client") + ["-W", "127.0.0.1:22022"], capture_output=True, timeout=4)
            if result.returncode == 0 and result.stdout == b"SSH_BRIDGE_OK\n":
                break
            if cls.device.poll() is not None:
                cls.cleanup()
                raise AssertionError("Device tunnel exited before becoming ready")
            time.sleep(0.1)
        else:
            cls.cleanup()
            raise AssertionError("Relay did not become ready")

    @classmethod
    def ssh(cls, role, key=None):
        return ["ssh", "-T", "-p", cls.port, "-i", str(cls.root/(key or role)),
                "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "ForwardAgent=no",
                "-o", "ConnectTimeout=2", "-o", "StrictHostKeyChecking=yes", "-o", "HostKeyAlias=test-relay",
                "-o", f"UserKnownHostsFile={cls.known}", f"{role}@127.0.0.1"]

    @classmethod
    def cleanup(cls):
        if hasattr(cls, "device"):
            cls.device.terminate()
            cls.device.wait(timeout=5)
        if hasattr(cls, "server"):
            cls.server.shutdown()
            cls.server.server_close()
        if hasattr(cls, "name"):
            subprocess.run(["docker", "rm", "-f", cls.name], capture_output=True)
        cls.temp.cleanup()

    @classmethod
    def tearDownClass(cls):
        cls.cleanup()

    def attempt(self, role, *args, key=None):
        return subprocess.run(self.ssh(role, key) + list(args), capture_output=True, timeout=5)

    def test_permitted_forward(self):
        result = self.attempt("client", "-W", "127.0.0.1:22022")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"SSH_BRIDGE_OK\n")

    def test_client_cannot_reach_other_ports(self):
        result = self.attempt("client", "-W", "127.0.0.1:22")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"administratively prohibited", result.stderr)

    def test_device_cannot_open_local_forwards(self):
        result = self.attempt("device", "-W", "127.0.0.1:22022")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"administratively prohibited", result.stderr)

    def test_device_cannot_publish_other_ports(self):
        result = self.attempt("device", "-N", "-o", "ExitOnForwardFailure=yes", "-R", "127.0.0.1:22023:127.0.0.1:22")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"remote port forwarding failed", result.stderr)

    def test_client_cannot_publish_remote_ports(self):
        self.assertNotEqual(self.attempt("client", "-N", "-o", "ExitOnForwardFailure=yes",
            "-R", "127.0.0.1:22023:127.0.0.1:22").returncode, 0)

    def test_neither_role_has_a_shell(self):
        for role in ("device", "client"):
            with self.subTest(role=role):
                self.assertNotEqual(self.attempt(role, "echo", "SHOULD_NOT_RUN").returncode, 0)

    def test_unknown_key_is_rejected(self):
        result = self.attempt("client", "-W", "127.0.0.1:22022", key="stranger")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"Permission denied", result.stderr)


if __name__ == "__main__":
    unittest.main()

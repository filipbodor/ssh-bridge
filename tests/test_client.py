"""Verify adding the new client names cannot overwrite the existing access route."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

CONFIGURE = Path(__file__).resolve().parents[1]/"client/configure.py"


class ClientMigrationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.ssh = self.home/".ssh"
        (self.ssh/"config.d").mkdir(parents=True)
        self.legacy = {
            self.ssh/"config": 'Include "' + str(self.ssh/"config.d/isaac-link.conf") + '"\nHost unrelated\n    HostName example.org\n',
            self.ssh/"config.d/isaac-link.conf": 'Host isaac-student\n    HostName 127.0.0.1\n    Port 22022\n',
            self.ssh/"isaac_link_known_hosts": 'isaac-relay ssh-ed25519 LEGACY\n',
        }
        for path, value in self.legacy.items():
            path.write_text(value)
        self.before = {path: path.read_bytes() for path in self.legacy}
        for name in ["relay_identity", "laptop_identity"]:
            (self.home/name).write_text("untouched private identity fixture\n")
        for name in ["relay.pub", "laptop.pub"]:
            (self.home/name).write_text("ssh-ed25519 AAAATEST\n")

    def configure(self):
        return subprocess.run(["python3", str(CONFIGURE), "--host", "relay.example.org", "--port", "44638",
            "--relay-identity", str(self.home/"relay_identity"), "--laptop-identity", str(self.home/"laptop_identity"),
            "--relay-host-key", str(self.home/"relay.pub"), "--laptop-host-key", str(self.home/"laptop.pub")],
            env={**os.environ, "HOME": str(self.home)}, capture_output=True, text=True)

    def test_additive_and_idempotent(self):
        self.assertEqual(self.configure().returncode, 0)
        config = (self.ssh/"config").read_bytes()
        self.assertEqual(self.configure().returncode, 0)
        self.assertEqual((self.ssh/"config").read_bytes(), config)
        self.assertTrue(config.endswith(self.before[self.ssh/"config"]))
        self.assertEqual((self.ssh/"config.before-ssh-bridge").read_bytes(), self.before[self.ssh/"config"])
        for path in list(self.legacy)[1:]:
            self.assertEqual(path.read_bytes(), self.before[path])
        self.assertIn("Host ssh-bridge-workstation", (self.ssh/"config.d/ssh-bridge.conf").read_text())
        self.assertIn("Host ssh-bridge-relay", (self.ssh/"config.d/ssh-bridge.conf").read_text())

    def test_changed_pins_are_refused_without_writes(self):
        self.assertEqual(self.configure().returncode, 0)
        files = [self.ssh/"config", self.ssh/"config.d/ssh-bridge.conf", self.ssh/"ssh_bridge_known_hosts"]
        before = {path:path.read_bytes() for path in files}
        (self.home/"relay.pub").write_text("ssh-ed25519 AAAADIFFERENT\n")
        self.assertNotEqual(self.configure().returncode, 0)
        for path, value in before.items():
            self.assertEqual(path.read_bytes(), value)

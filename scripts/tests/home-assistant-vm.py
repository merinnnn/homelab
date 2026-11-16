#!/usr/bin/env python3
"""Native Linux fault tests; fake Proxmox boundary, no VM or disk mutation."""
import hashlib
import importlib.util
import json
import lzma
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'provision' / 'home-assistant-vm.py'
spec = importlib.util.spec_from_file_location('ha_installer', SOURCE)
ha = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ha)
MAC = 'BC:24:11:32:8F:61'

# A Proxmox-shaped fixture independent of the installer's guard construction.
CONFIG = '''agent: enabled=1
balloon: 0
bios: ovmf
boot: order=scsi0
cores: 2
cpu: host
description: homelab-home-assistant-v1
efidisk0: local-lvm:vm-102-disk-0,efitype=4m,pre-enrolled-keys=0,size=4M
machine: q35
memory: 4096
name: ha01
net0: virtio=BC:24:11:32:8F:61,bridge=vmbr1
onboot: 1
ostype: l26
scsi0: local-lvm:vm-102-disk-1,discard=on,iothread=1,size=32G,ssd=1
scsihw: virtio-scsi-single
serial0: socket
startup: order=20,up=30,down=120
vga: std
'''


class FakeProxmox:
    def __init__(self):
        self.calls = []
        self.output = CONFIG
        self.fail = None

    def __call__(self, *args):
        self.calls.append(args)
        if self.fail and self.fail(args):
            raise ha.Refused('injected native boundary failure')
        if args[:2] == ('qm', 'config'):
            return self.output
        if args[:4] == ('qm', 'set', '102', '--net0'):
            self.output = self.output.replace('bridge=vmbr1', 'bridge=vmbr0')
        return ''

    def mutations(self):
        return [c for c in self.calls if c[:2] in (('qm', 'create'), ('qm', 'set'), ('qm', 'resize'))]


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.state = self.root / 'state.json'
        self.marker = self.root / 'bootstrap.json'
        self.native = FakeProxmox()

    def tearDown(self):
        self.tmp.cleanup()

    def image(self):
        image = self.root / 'image.qcow2'
        image.write_bytes(b'fake import image; the image integrity function is tested separately')
        return image, ha.DISK_BYTES

    def install(self, exists=False, factory=None):
        return ha.deploy(102, MAC, 'vmbr1', self.state, lambda _: exists,
                         factory or self.image, self.native)

    def marker_write(self, owner=True):
        self.marker.write_text(json.dumps({'marker': ha.MARKER, 'vmid': 102,
                                         'mac': MAC, 'owner_initialized': owner}))
        self.marker.chmod(0o600)

    def test_create_uses_private_bridge_no_cloud_init_no_start(self):
        self.install()
        create = self.native.calls[0]
        self.assertEqual(create[:3], ('qm', 'create', '102'))
        self.assertIn(f'virtio={MAC},bridge=vmbr1', create)
        self.assertIn('ovmf', create)
        self.assertFalse(any(c[:2] == ('qm', 'start') for c in self.native.calls))
        self.assertFalse(any('cloudinit' in value for c in self.native.calls for value in c))
        self.assertEqual(json.loads(self.state.read_text())['phase'], 'complete')
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        self.assertFalse((self.root / 'image.qcow2').exists())

    def test_unknown_existing_guest_never_imports_or_mutates(self):
        with self.assertRaisesRegex(ha.Refused, 'already in use'):
            self.install(exists=True, factory=lambda: self.fail('must not download'))
        self.assertEqual(self.native.calls, [])
        self.assertFalse(self.state.exists())

    def test_fresh_creation_cannot_bypass_private_first_boot(self):
        with self.assertRaisesRegex(ha.Refused, 'isolated vmbr1'):
            ha.deploy(102, MAC, 'vmbr0', self.state, lambda _: False,
                      lambda: self.fail('must not download'), self.native)
        self.assertEqual(self.native.calls, [])
        self.assertFalse(self.state.exists())

    def test_integrity_failure_happens_before_intent_or_create(self):
        def bad_image():
            raise ha.Refused('bad image integrity')
        with self.assertRaisesRegex(ha.Refused, 'bad image'):
            self.install(factory=bad_image)
        self.assertEqual(self.native.calls, [])
        self.assertFalse(self.state.exists())

    def test_import_failure_preserves_partial_state_without_cleanup(self):
        self.native.fail = lambda c: c[:4] == ('qm', 'set', '102', '--scsi0')
        with self.assertRaisesRegex(ha.Refused, 'injected'):
            self.install()
        self.assertEqual(json.loads(self.state.read_text())['phase'], 'creating')
        self.assertFalse(any(c[:2] == ('qm', 'destroy') for c in self.native.calls))
        self.native.calls.clear()
        with self.assertRaisesRegex(ha.Refused, 'partial'):
            self.install(exists=True)
        self.assertEqual(self.native.calls, [])

    def test_repeat_only_reads_configuration_and_never_downloads(self):
        self.install()
        self.native.calls.clear()
        self.install(exists=True, factory=lambda: self.fail('must not download'))
        self.assertEqual(self.native.calls, [('qm', 'config', '102', '--current', '1')])

    def test_missing_owned_guest_refuses_empty_replacement(self):
        self.install()
        self.native.calls.clear()
        with self.assertRaisesRegex(ha.Refused, 'missing'):
            self.install(exists=False)
        self.assertEqual(self.native.calls, [])

    def test_configuration_drift_never_repaired_automatically(self):
        self.install()
        original = self.native.output
        cases = [('name: ha01', 'name: unrelated'),
                 ('memory: 4096', 'memory: 2048'),
                 ('pre-enrolled-keys=0', 'pre-enrolled-keys=1'),
                 ('vm-102-disk-1', 'vm-102-disk-9'),
                 ('bridge=vmbr1', 'bridge=vmbr0')]
        for old, new in cases:
            with self.subTest(field=old):
                self.native.output = original.replace(old, new)
                self.native.calls.clear()
                with self.assertRaises(ha.Refused):
                    self.install(exists=True)
                self.assertEqual(self.native.mutations(), [])

    def test_extra_disk_or_nic_blocks_repeat(self):
        self.install()
        original = self.native.output
        for extra in ('unused0: local-lvm:vm-102-disk-8', 'net1: virtio=BC:24:11:32:8F:62,bridge=vmbr0', 'sata0: local-lvm:vm-102-disk-7'):
            with self.subTest(device=extra):
                self.native.output = original + extra + '\n'
                self.native.calls.clear()
                with self.assertRaisesRegex(ha.Refused, 'Unexpected'):
                    self.install(exists=True)
                self.assertEqual(self.native.mutations(), [])

    def test_manifest_provenance_or_permissions_refused(self):
        self.install()
        original = self.state.read_text()
        for key, value in [('image_sha256', 'bad'), ('mac', 'BC:24:11:00:00:00'), ('phase', 'creating')]:
            state = json.loads(original)
            state[key] = value
            self.state.write_text(json.dumps(state))
            with self.assertRaises(ha.Refused):
                self.install(exists=True)
        self.state.write_text(original)
        self.state.chmod(0o644)
        with self.assertRaisesRegex(ha.Refused, 'permissions'):
            self.install(exists=True)

    def test_promotion_requires_claim_marker(self):
        self.install()
        self.native.calls.clear()
        for marker in (None, False):
            if marker is False:
                self.marker_write(False)
            with self.assertRaises(ha.Refused):
                ha.promote(102, MAC, self.state, self.marker, lambda _: True, self.native)
            self.assertEqual(self.native.mutations(), [])

    def test_promotion_changes_only_bridge_and_repeat_is_read_only(self):
        self.install()
        self.marker_write()
        original = json.loads(self.state.read_text())
        self.native.calls.clear()
        ha.promote(102, MAC, self.state, self.marker, lambda _: True, self.native)
        self.assertEqual(self.native.mutations(), [('qm', 'set', '102', '--net0', f'virtio={MAC},bridge=vmbr0')])
        final = json.loads(self.state.read_text())
        for key in ('scsi0', 'efidisk0', 'image_sha256', 'mac'):
            self.assertEqual(final[key], original[key])
        self.assertEqual(final['bridge'], 'vmbr0')
        self.native.calls.clear()
        ha.promote(102, MAC, self.state, self.marker, lambda _: True, self.native)
        self.assertEqual(self.native.mutations(), [])

    def test_failed_promotion_preserves_partial_intent(self):
        self.install()
        self.marker_write()
        self.native.fail = lambda c: c[:4] == ('qm', 'set', '102', '--net0')
        with self.assertRaises(ha.Refused):
            ha.promote(102, MAC, self.state, self.marker, lambda _: True, self.native)
        self.assertEqual(json.loads(self.state.read_text())['phase'], 'promoting')

    def test_short_fresh_disk_grows_once_never_repeat(self):
        def short_image():
            image, _ = self.image()
            return image, 16 * 1024**3
        self.install(factory=short_image)
        self.assertIn(('qm', 'resize', '102', 'scsi0', '32G'), self.native.calls)
        self.native.calls.clear()
        self.install(exists=True)
        self.assertEqual(self.native.mutations(), [])

    def test_image_pin_rejects_modified_cached_archive_before_qemu(self):
        (self.root / ha.IMAGE).write_bytes(b'wrong image')
        with self.assertRaisesRegex(ha.Refused, 'SHA256'):
            ha.prepare_image(self.root, self.native)
        self.assertEqual(self.native.calls, [])

    def test_valid_archive_is_checked_and_backing_file_refused(self):
        compressed = lzma.compress(b'synthetic qcow2 bytes')
        (self.root / ha.IMAGE).write_bytes(compressed)
        def fake_qemu(*args):
            self.native.calls.append(args)
            if args[:2] == ('qemu-img', 'info'):
                return json.dumps({'format': 'qcow2', 'virtual-size': ha.DISK_BYTES,
                                   'backing-filename': '/unrelated/disk'})
            self.fail('qemu-img check must not run after backing-file rejection')
        with patch.object(ha, 'IMAGE_BYTES', len(compressed)), patch.object(ha, 'SHA256', hashlib.sha256(compressed).hexdigest()):
            with self.assertRaisesRegex(ha.Refused, 'backing'):
                ha.prepare_image(self.root, fake_qemu)
        self.assertEqual(len(self.native.calls), 1)
        self.assertEqual(list(self.root.glob('.verified-*')), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)

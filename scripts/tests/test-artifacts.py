#!/usr/bin/env python3
"""Check both built IPAs and reject broken mixed-architecture packages."""
import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('artifact', ROOT / 'scripts/linux/artifact.py')
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)


class Artifacts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.legacy = ROOT / 'dist/podcold-linux-armv7.ipa'
        cls.modern = ROOT / 'dist/podcold-linux-arm64-ios12.ipa'
        with zipfile.ZipFile(cls.modern) as archive:
            cls.files = {n: archive.read(n) for n in archive.namelist()}
        cls.info = next(n for n in cls.files if n.endswith('.app/Info.plist'))
        cls.core = next(n for n in cls.files if n.endswith('/libswiftCore.dylib'))

    def changed(self, updates=None, remove=None):
        files = {**self.files, **(updates or {})}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'broken.ipa'
            with zipfile.ZipFile(path, 'w') as archive:
                for name, data in files.items():
                    if name != remove:
                        archive.writestr(name, data)
            return artifact.verify(path)

    def test_both_packages(self):
        for path, arch, minimum in [(self.legacy, 'armv7', '6.0'), (self.modern, 'arm64', '12.0')]:
            with self.subTest(arch=arch):
                report = artifact.verify(path)
                self.assertEqual((report['architecture'], report['minimum_ios']), (arch, minimum))
                self.assertEqual(report['runtime_libraries'], 18)

    def test_missing_runtime_rejected(self):
        with self.assertRaisesRegex(ValueError, '18 runtime'):
            self.changed(remove=self.core)

    def test_wrong_runtime_architecture_rejected(self):
        with zipfile.ZipFile(self.legacy) as archive:
            old = archive.read(self.core)
        with self.assertRaisesRegex(ValueError, 'arm64'):
            self.changed({self.core: old})

    def test_wrong_executable_architecture_rejected(self):
        executable = self.info.rsplit('/', 1)[0] + '/podcold'
        with zipfile.ZipFile(self.legacy) as archive:
            old = archive.read(executable)
        with self.assertRaisesRegex(ValueError, 'arm64'):
            self.changed({executable: old})

    def test_wrong_minimum_rejected(self):
        info = plistlib.loads(self.files[self.info])
        info['MinimumOSVersion'] = '13.0'
        with self.assertRaisesRegex(ValueError, 'minimum OS'):
            self.changed({self.info: plistlib.dumps(info)})

    def test_executable_deployment_target_rejected(self):
        executable = self.info.rsplit('/', 1)[0] + '/podcold'
        for minimum, message in [(13, 'Minimum OS is too new'), (11, 'deployment target')]:
            with self.subTest(minimum=minimum):
                data = bytearray(artifact.thin(self.files[executable], 'arm64'))
                position = 32
                for _ in range(struct.unpack_from('<I', data, 16)[0]):
                    command, size = struct.unpack_from('<II', data, position)
                    if command in (0x25, 0x32):
                        struct.pack_into('<I', data, position + (12 if command == 0x32 else 8), minimum << 16)
                        break
                    position += size
                else:
                    self.fail('Missing iOS deployment target')
                with self.assertRaisesRegex(ValueError, message):
                    self.changed({executable: data})

    def test_wrong_capability_rejected(self):
        info = plistlib.loads(self.files[self.info])
        info['UIRequiredDeviceCapabilities'] = ['armv7', 'arm64']
        with self.assertRaisesRegex(ValueError, 'CPU architecture'):
            self.changed({self.info: plistlib.dumps(info)})


if __name__ == '__main__':
    unittest.main()

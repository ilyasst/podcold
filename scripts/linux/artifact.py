#!/usr/bin/env python3
"""Prepare, package and inspect the legacy ARMv7 build using stdlib Python."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / '.build-linux'
IPA = ROOT / 'dist/podcold-linux-armv7.ipa'


def armv7(data):
    if data[:4] == b'\xca\xfe\xba\xbe':
        for i in range(struct.unpack_from('>I', data, 4)[0]):
            cpu, subtype, offset, size, _ = struct.unpack_from('>iiIII', data, 8 + i * 20)
            if cpu == 12 and subtype & 255 == 9:
                return armv7(data[offset:offset + size])
        raise ValueError('Binary has no ARMv7 slice')
    if data[:4] != b'\xce\xfa\xed\xfe' or struct.unpack_from('<ii', data, 4) != (12, 9):
        raise ValueError('Expected a 32-bit ARMv7 Mach-O binary')
    return data


def macho(data):
    data = armv7(data)
    result = {'libraries': [], 'rpaths': [], 'minimum_os': None, 'signed': False, 'symbols': []}
    position, symtab = 28, None
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, position)
        if command in (0xc, 0x80000018, 0x8000001f, 0x8000001c):
            offset = struct.unpack_from('<I', data, position + 8)[0]
            end = data.index(b'\0', position + offset, position + size)
            name = data[position + offset:end].decode()
            if command == 0x8000001c:
                result['rpaths'].append(name)
            else:
                result['libraries'].append({'name': name, 'weak': command == 0x80000018})
        elif command == 0x25:
            result['minimum_os'] = struct.unpack_from('<I', data, position + 8)[0]
        elif command == 0x1d:
            result['signed'] = True
        elif command == 2:
            symtab = struct.unpack_from('<IIII', data, position + 8)
        position += size
    if symtab:
        offset, count, strings, string_size = symtab
        for i in range(count):
            index, kind, _, flags, _ = struct.unpack_from('<IBBHI', data, offset + i * 12)
            end = data.index(b'\0', strings + index, strings + string_size)
            name = data[strings + index:end].decode()
            result['symbols'].append((name, kind, flags))
    return result


def prepare():
    project = CACHE / 'project'
    project.mkdir(parents=True, exist_ok=True)
    test_mode = '1' if os.environ.get('PODCOLD_DEVICE_TESTING') == '1' else '0'
    mode_file = project / '.device-test-mode'
    if not mode_file.exists() or mode_file.read_text() != test_mode:
        # Conditional Swift code must be recompiled when switching test mode.
        objects = project / '.theos/obj'
        if objects.exists():
            shutil.rmtree(objects)
        mode_file.write_text(test_mode)
    resources, runtime = project / 'Resources', CACHE / 'runtime'
    resources.mkdir(exist_ok=True)
    runtime.mkdir(exist_ok=True)
    source = ROOT / 'podcold/podcold'
    for destination, target in (
        (project / 'Sources', source),
        (CACHE / 'theos/sdks/iPhoneOS15.6.sdk', CACHE / 'sdks/iPhoneOS15.6.sdk'),
        (CACHE / 'theos/toolchain/linux/iphone', CACHE / 'toolchain/linux/iphone'),
        (CACHE / 'theos/toolchain/swift', CACHE / 'toolchain/linux/iphone'),
    ):
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.is_symlink():
            destination.symlink_to(os.path.relpath(target, destination.parent))
    makefile = ROOT / 'scripts/linux/Makefile'
    cached_makefile = project / 'Makefile'
    if not cached_makefile.exists() or cached_makefile.read_bytes() != makefile.read_bytes():
        # Theos does not detect changed linker flags in an incremental build.
        # Remove only generated executables so new compatibility flags take effect.
        for executable in (project / '.theos/obj').rglob('podcold.app/podcold'):
            executable.unlink()
    shutil.copy2(makefile, cached_makefile)
    for image in list(source.glob('*.png')) + list((source / 'Assets.xcassets/AppIcon.appiconset').glob('*.png')):
        shutil.copy2(image, resources / image.name)
    info = {
        'CFBundleDevelopmentRegion': 'en', 'CFBundleExecutable': 'podcold',
        'CFBundleIdentifier': 'org.ilyasst.podcold.linux', 'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': 'Podcold Linux', 'CFBundleDisplayName': 'Podcold Linux',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1',
        'CFBundleSupportedPlatforms': ['iPhoneOS'], 'LSRequiresIPhoneOS': True,
        'MinimumOSVersion': '6.0', 'UIRequiredDeviceCapabilities': ['armv7'],
        'UIDeviceFamily': [1, 2], 'UIBackgroundModes': ['audio'], 'UIFileSharingEnabled': True,
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait'],
        'CFBundleIconFiles': ['icon-57.png', 'icon-114.png', 'icon-120.png'],
    }
    (resources / 'Info.plist').write_bytes(plistlib.dumps(info))
    # Keep the runtime already demonstrated on legacy hardware, not modern iOS dylibs.
    with zipfile.ZipFile(ROOT / 'build/podcold_ios6.ipa') as original:
        for name in original.namelist():
            if '/Frameworks/' in name and name.endswith('.dylib'):
                output = runtime / Path(name).name
                output.write_bytes(armv7(original.read(name)))
                output.chmod(0o755)
    print('Prepared original app sources, resources and 18 legacy ARMv7 runtime libraries.')


def verify(path):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError('IPA has a corrupt member')
        info_path = next(n for n in archive.namelist() if n.count('/') == 2 and n.endswith('/Info.plist'))
        prefix = info_path.rsplit('/', 1)[0] + '/'
        info = plistlib.loads(archive.read(info_path))
        if info['CFBundleIdentifier'] != 'org.ilyasst.podcold.linux' or info['MinimumOSVersion'] != '6.0':
            raise ValueError('Incorrect test app identity or minimum OS')
        binaries = {info['CFBundleExecutable']: archive.read(prefix + info['CFBundleExecutable'])}
        binaries.update({Path(n).name: archive.read(n) for n in archive.namelist()
                         if n.startswith(prefix + 'Frameworks/') and n.endswith('.dylib')})
    parsed = {name: macho(data) for name, data in binaries.items()}
    if len(parsed) != 19:
        raise ValueError('Expected the executable and 18 runtime libraries')
    exports = {name: {symbol for symbol, kind, _ in entry['symbols'] if kind & 1 and kind & 14}
               for name, entry in parsed.items()}
    for name, entry in parsed.items():
        if entry['minimum_os'] is None or entry['minimum_os'] > 6 << 16:
            raise ValueError('Minimum OS is too new: ' + name)
        if not entry['signed']:
            raise ValueError('Missing code signature: ' + name)
        for library in entry['libraries']:
            dependency = Path(library['name']).name
            if dependency in parsed and library['name'] != '@rpath/' + dependency:
                raise ValueError('Bundled runtime must load from the app: ' + library['name'])
            if not library['weak'] and library['name'].startswith('@rpath/'):
                if Path(library['name']).name not in parsed:
                    raise ValueError('Missing bundled dependency: ' + library['name'])
    app = parsed[info['CFBundleExecutable']]
    if any(symbol == '_objc_allocWithZone' and kind & 14 == 0 and not flags & 0x40
           for symbol, kind, flags in app['symbols']):
        raise ValueError('Missing iOS 6 Objective-C allocation compatibility')
    # Release stripping removes arclite's private symbols; its Objective-C class
    # name survives. Its registration import must be weak on pre-iOS-8 devices.
    if (b'__ARCLite__\0' not in binaries[info['CFBundleExecutable']] or
            not any(symbol == '_objc_readClassPair' and flags & 0x40
                    for symbol, _, flags in app['symbols'])):
        raise ValueError('Missing libarclite legacy Objective-C runtime compatibility')
    if b'textView:shouldInteractWithURL:inRange:\0' not in binaries[info['CFBundleExecutable']]:
        raise ValueError('Missing iOS 7 episode-notes link delegate')
    if '@executable_path/Frameworks' not in app['rpaths']:
        raise ValueError('Missing bundled runtime search path')
    for symbol, kind, flags in app['symbols']:
        ordinal = flags >> 8
        if kind & 14 == 0 and kind & 1 and not flags & 0x40 and 0 < ordinal <= len(app['libraries']):
            name = Path(app['libraries'][ordinal - 1]['name']).name
            if name in exports and symbol not in exports[name]:
                raise ValueError('Legacy runtime lacks required symbol: ' + symbol)
    return {'architecture': 'armv7', 'minimum_ios': '6.0', 'bundle_identifier': info['CFBundleIdentifier'],
            'runtime_libraries': len(parsed) - 1, 'notes_link_delegate': True, 'sha256': hashlib.sha256(Path(path).read_bytes()).hexdigest(),
            'size_bytes': Path(path).stat().st_size, 'device_tested': False}


def package():
    staging = CACHE / 'package'
    if staging.exists():
        shutil.rmtree(staging)
    app = staging / 'Payload/PodcoldLinux.app'
    shutil.copytree(CACHE / 'project/.theos/obj/podcold.app', app)
    shutil.copytree(CACHE / 'runtime', app / 'Frameworks')
    tools = CACHE / 'toolchain/linux/iphone/bin'
    executable = app / 'podcold'
    # The iOS 6 linker can choose absolute /usr/lib/swift install names even
    # though the legacy runtime is packaged here. Rewrite every bundled runtime
    # reference, including overlays and dependencies between the dylibs.
    runtimes = list((app / 'Frameworks').glob('*.dylib'))
    runtime_names = {binary.name for binary in runtimes}
    for binary in runtimes + [executable]:
        for library in macho(binary.read_bytes())['libraries']:
            name = Path(library['name']).name
            if name in runtime_names and library['name'] != '@rpath/' + name:
                subprocess.run([str(tools / 'install_name_tool'), '-change', library['name'],
                                '@rpath/' + name, str(binary)], check=True)
    debug = os.environ.get('PODCOLD_DEBUG') == '1'
    signing_option = '-S'
    if debug:
        entitlements = CACHE / 'debug.entitlements.plist'
        entitlements.write_bytes(plistlib.dumps({'get-task-allow': True}))
        signing_option += str(entitlements)
    for binary in list((app / 'Frameworks').glob('*.dylib')) + [executable]:
        binary.chmod(0o755)
        subprocess.run([str(tools / 'ldid'), signing_option if binary == executable else '-S', str(binary)], check=True)
    IPA.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(IPA, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for file in sorted(app.rglob('*')):
            if file.is_file():
                archive.write(file, file.relative_to(staging))
    result = verify(IPA)
    result['debuggable'] = debug
    result['source_commit'] = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    result['theos_commit'] = subprocess.check_output(['git', '-C', str(CACHE / 'theos'), 'rev-parse', 'HEAD'], text=True).strip()
    result['sdk_commit'] = subprocess.check_output(['git', '-C', str(CACHE / 'sdks'), 'rev-parse', 'HEAD'], text=True).strip()
    result['swift_version'] = '5.6.1'
    (IPA.parent / 'linux-build.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    print('Created ' + str(IPA))
    print('Install and launch on the iPod to confirm runtime compatibility.')


if __name__ == '__main__':
    command = sys.argv[1] if len(sys.argv) > 1 else ''
    if command == 'prepare':
        prepare()
    elif command == 'package':
        package()
    elif command == 'verify':
        print(json.dumps(verify(Path(sys.argv[2]) if len(sys.argv) > 2 else IPA), indent=2))
    else:
        raise SystemExit('Usage: artifact.py prepare | package | verify [IPA]')

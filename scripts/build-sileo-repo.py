#!/usr/bin/env python3
"""Package the verified iOS 12 app for a flat, rootful Sileo/APT source."""
import argparse
import bz2
from email.utils import formatdate
import gzip
import hashlib
from html import escape
import importlib.util
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import zipfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('artifact', ROOT / 'scripts/linux/artifact.py')
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa', type=Path, default=ROOT / 'dist/podcold-linux-arm64-ios12.ipa')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/sileo')
    parser.add_argument('--base-url', default='https://outerheaven.caracara-boga.ts.net:10000/podcold/')
    args = parser.parse_args()
    report = artifact.verify(args.ipa)
    if report['architecture'] != 'arm64' or report['minimum_ios'] != '12.0':
        parser.error('The Sileo package requires the ARM64 iOS 12 IPA')
    revision = subprocess.check_output(['git', '-C', str(ROOT), 'rev-list', '--count', 'HEAD'], text=True).strip()
    version = '1.0.0-' + revision
    output = args.output.resolve()
    if output in (ROOT, ROOT / 'dist', ROOT / '.build-linux'):
        parser.error('Output must be a dedicated repository directory')
    base_url = args.base_url.rstrip('/') + '/'
    if urlsplit(base_url).scheme != 'https' or not urlsplit(base_url).hostname:
        parser.error('The source must have an HTTPS URL')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='podcold-sileo-', dir=output.parent) as temporary:
        stage = Path(temporary)
        package = stage / 'package'
        app = package / 'Applications/PodcoldLinux.app'
        app.mkdir(parents=True)
        with zipfile.ZipFile(args.ipa) as archive:
            info = next(n for n in archive.namelist() if n.endswith('.app/Info.plist'))
            prefix = info.rsplit('/', 1)[0] + '/'
            for entry in archive.infolist():
                if not entry.filename.startswith(prefix) or entry.is_dir():
                    continue
                relative = Path(entry.filename[len(prefix):])
                if relative.is_absolute() or '..' in relative.parts or stat.S_ISLNK(entry.external_attr >> 16):
                    raise ValueError('Unexpected app archive path')
                target = app / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(entry))
                target.chmod(0o755 if target.name == 'podcold' or target.suffix == '.dylib' else 0o644)
        control = package / 'DEBIAN'
        control.mkdir()
        (control / 'control').write_text(
            'Package: org.ilyasst.podcold.ios12\n'
            'Name: Podcold (iOS 12)\n'
            'Version: ' + version + '\n'
            'Architecture: iphoneos-arm\n'
            'Maintainer: ilyasst\n'
            'Section: Multimedia\n'
            'Priority: optional\n'
            'Depends: firmware (>= 12.0), uikittools\n'
            'Homepage: https://github.com/ilyasst/podcold\n'
            'Description: Podcast player with URL subscriptions, playlist and automatic downloads.\n'
            ' ARM64 build for jailbroken iOS 12 devices.\n'
            'Installed-Size: ' + str(sum(p.stat().st_size for p in app.rglob('*') if p.is_file()) // 1024) + '\n')
        scripts = {
            'postinst': '#!/bin/sh\nset -e\nif [ "$1" = configure ]; then\n    uicache -p /Applications/PodcoldLinux.app\nfi\n',
            'postrm': '#!/bin/sh\nset -e\ncase "$1" in\n    remove|purge) uicache -u /Applications/PodcoldLinux.app ;;\nesac\n',
        }
        for name, script in scripts.items():
            path = control / name
            path.write_text(script)
            path.chmod(0o755)
        repo = stage / 'repo'
        (repo / 'debs').mkdir(parents=True)
        # Retain two older downloads for clients with a cached package index.
        if output.exists():
            allowed = {'debs', 'Packages', 'Packages.gz', 'Packages.bz2', 'Release', 'index.html', 'source-qr.png'}
            if any(p.name not in allowed for p in output.iterdir()):
                raise ValueError('Refusing to replace a directory containing unrelated files')
            for old in sorted((output / 'debs').glob('*.deb'), key=lambda p: p.stat().st_mtime, reverse=True)[:2]:
                shutil.copy2(old, repo / 'debs' / old.name)
        deb = repo / 'debs' / ('org.ilyasst.podcold.ios12_' + version + '_iphoneos-arm.deb')
        subprocess.run(['dpkg-deb', '--root-owner-group', '-Zxz', '-z6', '--build', str(package), str(deb)], check=True)
        packages = subprocess.check_output(['dpkg-scanpackages', 'debs', '/dev/null'], cwd=repo)
        (repo / 'Packages').write_bytes(packages)
        (repo / 'Packages.gz').write_bytes(gzip.compress(packages, mtime=0))
        (repo / 'Packages.bz2').write_bytes(bz2.compress(packages))
        release = ('Origin: Podcold on Outerheaven\nLabel: Podcold\nSuite: stable\n'
                   'Codename: podcold\nArchitectures: iphoneos-arm\nComponents: main\n'
                   'Description: Personal Podcold builds for jailbroken iOS 12\n'
                   'Date: ' + formatdate(usegmt=True) + '\n')
        for label, algorithm in [('MD5Sum', 'md5'), ('SHA256', 'sha256')]:
            release += label + ':\n'
            for name in ['Packages', 'Packages.gz', 'Packages.bz2']:
                data = (repo / name).read_bytes()
                release += ' ' + hashlib.new(algorithm, data).hexdigest() + ' ' + str(len(data)) + ' ' + name + '\n'
        (repo / 'Release').write_text(release)
        (repo / 'index.html').write_text('''<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Podcold for iOS 12</title>
<style>body{font:18px -apple-system,sans-serif;max-width:36em;margin:3em auto;padding:0 1em;line-height:1.6}code{word-break:break-all}a{color:#713e9c}</style>
<h1>Podcold for iOS 12</h1>
<p>In Sileo, open <strong>Sources → +</strong> and add this source:</p>
<p><code>''' + escape(base_url) + '''</code></p>
<p>Then install <strong>Podcold (iOS 12)</strong>. This build is for the jailbroken iPod touch 6.</p>
<p><a href="debs/''' + escape(deb.name) + '''">Download the package</a></p>
<p><a href="https://github.com/ilyasst/podcold">Source code</a></p>
</html>''')
        if (output / 'source-qr.png').exists():
            shutil.copy2(output / 'source-qr.png', repo / 'source-qr.png')
        # Keep the output limited to publishable files; never serve the build tree.
        if output.exists():
            shutil.rmtree(output)
        shutil.copytree(repo, output)
    print('Created Sileo repository: ' + str(output))
    print('Package version: ' + version)


if __name__ == '__main__':
    main()

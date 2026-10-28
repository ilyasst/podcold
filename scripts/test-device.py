#!/usr/bin/env python3
"""Exercise real UIKit search and URL subscriptions on a paired iOS 7 device."""
import argparse
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'org.ilyasst.podcold.linux'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--udid', help='Defaults to the only USB-connected device')
    parser.add_argument('--install', action='store_true', help='Install the locally built test IPA first')
    parser.add_argument('--feed-url', help='Test adding this real podcast feed instead of directory search; original subscriptions are restored')
    args = parser.parse_args()
    devices = subprocess.check_output(['idevice_id', '-l'], text=True).splitlines()
    if not args.udid and len(devices) != 1:
        parser.error('Connect exactly one USB device or select it with --udid')
    udid = args.udid or devices[0]
    output = ROOT / '.build-linux/device-test'
    output.mkdir(parents=True, exist_ok=True)
    results_file = output / ('feed-results.json' if args.feed_url else 'results.json')
    results_file.unlink(missing_ok=True)

    def command(arguments, timeout=30, check=True):
        process = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
        if check and process.returncode:
            raise RuntimeError((process.stdout + process.stderr).replace(udid, '[device]'))
        return process

    def screenshot(name):
        path = output / (name + '.tiff')
        result = command(['idevicescreenshot', '-u', udid, str(path)], check=False)
        if result.returncode == 0:
            try:
                from PIL import Image
                Image.open(path).save(output / (name + '.png'))
            except ImportError:
                pass

    if args.install:
        command(['ideviceinstaller', '-u', udid, 'install', str(ROOT / 'dist/podcold-linux-armv7.ipa')], timeout=120)
        print('Installed test build.', flush=True)
    # Some legacy versions return nonzero after successfully terminating an app.
    command(['idevicedebug', '-u', udid, 'kill', BUNDLE], check=False)
    token = uuid.uuid4().hex
    logger = ['idevicesyslog', '-u', udid, '--no-colors', '--match', 'PODCOLD_DEVICE_TEST']
    if shutil.which('stdbuf'):
        logger = ['stdbuf', '-oL'] + logger
    log = subprocess.Popen(logger, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    reports, pending = [], b''
    try:
        # -- prevents GNU getopt from interpreting the app's own arguments.
        launch_args = ['--podcold-feed-test', '--podcold-feed-url=' + args.feed_url] if args.feed_url else ['--podcold-device-test']
        command(['idevicedebug', '-u', udid, '--detach', '--', 'run', BUNDLE] +
                launch_args + ['--podcold-test-token=' + token])
        deadline = time.monotonic() + (120 if args.feed_url else 65)
        while time.monotonic() < deadline:
            if not select.select([log.stdout], [], [], 1)[0]:
                continue
            chunk = os.read(log.stdout.fileno(), 65536)
            if not chunk:
                break
            pending += chunk
            while b'\n' in pending:
                raw, pending = pending.split(b'\n', 1)
                line = raw.decode(errors='replace')
                marker = 'PODCOLD_DEVICE_TEST '
                if marker not in line:
                    continue
                try:
                    report = json.loads(line.split(marker, 1)[1])
                except ValueError:
                    continue
                if report.get('run_token') != token:
                    continue
                reports.append(report)
                results_file.write_text(json.dumps(reports, indent=2) + '\n')
                print(json.dumps(report), flush=True)
                if report['stage'] == 'search_field':
                    screenshot('search-keyboard')
                if report['stage'] == 'feed_entry':
                    screenshot('feed-url')
                if report['stage'] == 'complete':
                    screenshot('feed-added' if args.feed_url else 'search-results')
                    if args.feed_url:
                        command(['idevicedebug', '-u', udid, 'kill', BUNDLE], check=False)
                        command(['idevicedebug', '-u', udid, '--detach', 'run', BUNDLE])
                    return 0 if report.get('passed') else 1
        raise RuntimeError('No current test result: confirm the developer image is mounted and the app was built with PODCOLD_DEVICE_TESTING=1.')
    finally:
        log.terminate()
        try:
            log.wait(timeout=5)
        except subprocess.TimeoutExpired:
            log.kill()
            log.wait()


if __name__ == '__main__':
    raise SystemExit(main())

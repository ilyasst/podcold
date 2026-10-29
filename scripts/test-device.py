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
    parser.add_argument('--device-model', help='Select the only connected device with this ProductType, e.g. iPod4,1')
    parser.add_argument('--playlist', action='store_true', help='Test playlist rules, warm-cache Downloads and local playback without network media')
    parser.add_argument('--install', action='store_true', help='Install the locally built test IPA first')
    parser.add_argument('--feed-url', help='Test adding this real podcast feed instead of directory search; original subscriptions are restored')
    parser.add_argument('--notes-playback', action='store_true', help='Test native notes links, download, playback and Safari background audio; requires --feed-url')
    parser.add_argument('--sleep-timer', action='store_true', help='Test sleep presets, end-of-episode, queue preservation and a short background deadline; requires --feed-url')
    parser.add_argument('--auto-episodes', action='store_true', help='Test automatic queueing, download limits and settings with temporary episode identities; requires --feed-url')
    args = parser.parse_args()
    if args.playlist and (args.auto_episodes or args.sleep_timer or args.notes_playback or args.feed_url):
        parser.error('--playlist is a standalone scenario')
    if args.auto_episodes and (args.sleep_timer or args.notes_playback):
        parser.error('Choose only one playback/automatic scenario')
    if args.auto_episodes and not args.feed_url:
        parser.error('--auto-episodes requires --feed-url')
    if args.sleep_timer and args.notes_playback:
        parser.error('Choose either --sleep-timer or --notes-playback')
    if args.sleep_timer and not args.feed_url:
        parser.error('--sleep-timer requires --feed-url')
    playback_test = args.notes_playback or args.sleep_timer or args.auto_episodes or args.playlist
    if args.notes_playback and not args.feed_url:
        parser.error('--notes-playback requires --feed-url')
    devices = subprocess.check_output(['idevice_id', '-l'], text=True).splitlines()
    if args.device_model:
        devices = [u for u in devices if subprocess.check_output(['ideviceinfo', '-u', u, '-k', 'ProductType'], text=True).strip() == args.device_model]
    if not args.udid and len(devices) != 1:
        parser.error('Connect exactly one USB device or select it with --udid')
    udid = args.udid or devices[0]
    output = ROOT / '.build-linux/device-test'
    output.mkdir(parents=True, exist_ok=True)
    results_file = output / ('playlist-results.json' if args.playlist else 'auto-results.json' if args.auto_episodes else 'sleep-results.json' if args.sleep_timer else 'notes-results.json' if args.notes_playback else 'feed-results.json' if args.feed_url else 'results.json')
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
        launch_args = [('--podcold-auto-test' if args.auto_episodes else '--podcold-sleep-test' if args.sleep_timer else '--podcold-notes-test' if args.notes_playback else '--podcold-feed-test'), '--podcold-feed-url=' + args.feed_url] if args.feed_url else ['--podcold-device-test']
        if args.playlist:
            launch_args = ['--podcold-playlist-test']
        command(['idevicedebug', '-u', udid, '--detach', '--', 'run', BUNDLE] +
                launch_args + ['--podcold-test-token=' + token])
        deadline = time.monotonic() + (180 if args.playlist else 420 if args.auto_episodes else 300 if args.sleep_timer else 240 if args.notes_playback else 120 if args.feed_url else 65)
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
                if report['stage'] == 'notes_rendered':
                    screenshot('episode-notes')
                if report['stage'] == 'auto_settings':
                    screenshot('auto-settings')
                if report['stage'] in ('playlist_downloads', 'playlist_ready'):
                    screenshot(report['stage'])
                if report['stage'] == 'sleep_menu':
                    screenshot('sleep-menu')
                if report['stage'] == 'opening_feedback':
                    time.sleep(3)
                    screenshot('feedback-safari')
                if report['stage'] == 'complete':
                    screenshot('playlist-complete' if args.playlist else 'auto-complete' if args.auto_episodes else 'sleep-complete' if args.sleep_timer else 'notes-complete' if args.notes_playback else 'feed-added' if args.feed_url else 'search-results')
                    if args.feed_url and not playback_test:
                        command(['idevicedebug', '-u', udid, 'kill', BUNDLE], check=False)
                        command(['idevicedebug', '-u', udid, '--detach', 'run', BUNDLE])
                    return 0 if report.get('passed') else 1
        raise RuntimeError('No current test result: confirm the developer image is mounted and the app was built with PODCOLD_DEVICE_TESTING=1.')
    finally:
        if playback_test:
            command(['idevicedebug', '-u', udid, 'kill', BUNDLE], check=False)
            command(['idevicedebug', '-u', udid, '--detach', 'run', BUNDLE], check=False)
        log.terminate()
        try:
            log.wait(timeout=5)
        except subprocess.TimeoutExpired:
            log.kill()
            log.wait()


if __name__ == '__main__':
    raise SystemExit(main())

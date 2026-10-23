import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'pip-sticky.sh'
RAW_URL = 'https://raw.githubusercontent.com/MagnetosphereLabs/pip-auto-sticky/main/pip-sticky.sh'


class CommandLine(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pip-cli-', dir=ROOT)
        self.directory = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def environment(self, backend):
        root = self.directory / backend
        root.mkdir()
        stubs = root / 'stubs'
        stubs.mkdir()
        for name in ['curl', 'mkdir', 'ln', 'systemctl', 'sudo', 'wmctrl', 'xprop',
                     'kpackagetool6', 'kwriteconfig6', 'qdbus6', 'gnome-extensions',
                     'gsettings', 'cosmic-ext-window-helper']:
            stub = stubs / name
            stub.write_text((ROOT / 'tests/cli_tool_stub.py').read_text())
            stub.chmod(0o755)
        temporary = root / 'temporary files'
        temporary.mkdir()
        return root, {
            **os.environ,
            'PATH': str(stubs) + os.pathsep + os.environ['PATH'],
            'XDG_DATA_HOME': str(root / 'user data'),
            'XDG_CONFIG_HOME': str(root / 'user config'),
            'TMPDIR': str(temporary),
            'FORCE_BACKEND': backend,
            'HELPER_PATH': str(stubs / 'cosmic-ext-window-helper'),
            'PIP_TEST_ROOT': str(root),
            'PIP_TEST_SCRIPT': str(SCRIPT),
            'PIP_TEST_MKDIR': shutil.which('mkdir'),
            'RAW_URL': RAW_URL,
        }

    def invoke(self, command, environment):
        result = subprocess.run(command, env=environment, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('unbound variable', result.stderr)
        return result

    def assert_installed(self, root, backend):
        installed = root / 'user data/pip-sticky/pip-sticky.sh'
        self.assertEqual(installed.read_bytes(), SCRIPT.read_bytes())
        self.assertTrue(os.access(installed, os.X_OK))
        self.assertEqual((root / 'bin/pip-sticky').resolve(), installed)
        self.assertEqual((root / 'user config/pip-sticky/state').read_text(), f'BACKEND={backend}\n')
        if backend in ('cosmic', 'x11'):
            service = (root / 'user config/systemd/user/pip-sticky.service').read_text()
            self.assertIn(f'ExecStart="{installed}" run', service)
            self.assertIn(f'Environment=PIP_STICKY_BACKEND={backend}', service)
            actions = [json.loads(line) for line in (root / 'commands.jsonl').read_text().splitlines()]
            self.assertIn(['systemctl', '--user', 'restart', 'pip-sticky.service'], actions)
        elif backend == 'kwin':
            self.assertTrue((root / 'user data/pip-sticky/pipsticky/contents/code/main.js').is_file())
        else:
            self.assertTrue((root / 'user data/gnome-shell/extensions/pip-sticky@magnetospherelabs/extension.js').is_file())
        self.assertEqual(list((root / 'temporary files').iterdir()), [])

    def test_piped_install_and_update_all_backends(self):
        for backend in ('cosmic', 'x11', 'kwin', 'gnome'):
            with self.subTest(backend=backend):
                root, environment = self.environment(backend)
                for action in ('install', 'update'):
                    result = self.invoke([
                        'bash', '-o', 'pipefail', '-c',
                        'curl -fsSL "$1" | bash -s -- "$2"', 'test', RAW_URL, action,
                    ], environment)
                    self.assertIn('Installed pip-sticky', result.stdout)
                    self.assert_installed(root, backend)

    def test_file_install_and_update_all_backends(self):
        for backend in ('cosmic', 'x11', 'kwin', 'gnome'):
            with self.subTest(backend=backend):
                root, environment = self.environment(backend)
                self.invoke(['bash', str(SCRIPT), 'install'], environment)
                self.assert_installed(root, backend)
                installed = root / 'user data/pip-sticky/pip-sticky.sh'
                self.invoke([str(installed), 'update'], environment)
                self.assert_installed(root, backend)

    def test_file_stdin_and_sourced_entry_points(self):
        for argument in ('version', 'help', '--version', '--help'):
            with self.subTest(argument=argument):
                direct = self.invoke(['bash', str(SCRIPT), argument], os.environ)
                piped = subprocess.run(['bash', '-s', '--', argument], input=SCRIPT.read_text(),
                                       text=True, capture_output=True, timeout=10)
                self.assertEqual(piped.returncode, 0, piped.stderr)
                self.assertEqual(piped.stdout, direct.stdout)
        sourced = self.invoke(['bash', '-euo', 'pipefail', '-c', 'source "$1"; echo sourced',
                               'test', str(SCRIPT)], os.environ)
        self.assertEqual(sourced.stdout, 'sourced\n')


if __name__ == '__main__':
    unittest.main()

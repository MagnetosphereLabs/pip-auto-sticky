import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'pip-sticky.sh'
ORIGINAL = b'/* Existing theme */\nbody { color: cyan; }\r\n/* Keep this exact */'


class PopoutDrag(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pip-drag-', dir=ROOT)
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.settings = self.root / 'vesktop/settings'
        self.settings.mkdir(parents=True)
        self.css = self.settings / 'quickCss.css'
        self.css.write_bytes(ORIGINAL)
        self.css.chmod(0o640)
        self.app_settings = self.settings.parent / 'settings.json'
        self.app_settings.write_bytes(b'{"nativeTitleBar":false,"customTitleBar":true,"staticTitle":true}\n')
        self.vencord_settings = self.settings / 'settings.json'
        self.vencord_settings.write_bytes(b'{"useQuickCss":true,"plugins":{"example":{"enabled":true}}}\n')

    def run_command(self, mode='install', path=None, piped=False, environment=None, success=True):
        args = ['popout-drag', mode]
        if path is not None:
            args.append(str(path))
        result = subprocess.run(
            ['bash', '-s', '--', *args] if piped else ['bash', str(SCRIPT), *args],
            input=SCRIPT.read_text() if piped else None,
            env=environment, text=True, capture_output=True, timeout=10,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def test_install_remove_preserves_css_and_settings_on_every_backend(self):
        app_before = self.app_settings.read_bytes()
        vencord_before = self.vencord_settings.read_bytes()
        for backend in ('cosmic', 'x11', 'kwin', 'gnome'):
            with self.subTest(backend=backend):
                environment = {**os.environ, 'FORCE_BACKEND': backend}
                self.run_command(path=self.css, environment=environment)
                modified = self.css.read_bytes()
                self.assertTrue(modified.startswith(ORIGINAL))
                self.assertIn(b'[data-popout-root="true"]::after', modified)
                self.assertEqual(self.css.stat().st_mode & 0o777, 0o640)
                backups = list(self.settings.glob('quickCss.css.pip-sticky-*.bak'))
                self.assertIn(ORIGINAL, [path.read_bytes() for path in backups])
                self.run_command('remove', self.css, environment=environment)
                self.assertEqual(self.css.read_bytes(), ORIGINAL)
                self.assertEqual(self.app_settings.read_bytes(), app_before)
                self.assertEqual(self.vencord_settings.read_bytes(), vencord_before)
                self.assertEqual(list(self.settings.glob('*.tmp')), [])

    def test_repeat_install_does_not_duplicate_or_rewrite(self):
        self.run_command(path=self.css)
        before = self.css.stat()
        content = self.css.read_bytes()
        backups = list(self.settings.glob('*.bak'))
        self.run_command(path=self.css)
        self.assertEqual(self.css.read_bytes(), content)
        self.assertEqual(self.css.stat().st_ino, before.st_ino)
        self.assertEqual(list(self.settings.glob('*.bak')), backups)
        self.assertEqual(content.count(b'/* pip-sticky popout-drag start */'), 1)

    def test_native_and_flatpak_custom_data_directories(self):
        for folder in ['native config/vesktop', '.var/app/dev.vencord.Vesktop/config/vesktop']:
            with self.subTest(folder=folder):
                data = self.root / folder
                (data / 'settings').mkdir(parents=True)
                environment = {**os.environ, 'VENCORD_USER_DATA_DIR': str(data)}
                self.run_command(environment=environment)
                css = data / 'settings/quickCss.css'
                self.assertIn(b'app-region: drag', css.read_bytes())
                self.assertEqual(css.stat().st_mode & 0o777, 0o600)
                self.run_command('remove', environment=environment)
                self.assertEqual(css.read_bytes(), b'')

    def test_disabled_quick_css_does_not_change_any_file(self):
        self.vencord_settings.write_text(json.dumps({'useQuickCss': False}))
        result = self.run_command(path=self.css, success=False)
        self.assertIn('Quick CSS is disabled', result.stderr)
        self.assertEqual(self.css.read_bytes(), ORIGINAL)

    def test_disabled_quick_css_is_respected_through_symlinks(self):
        target = self.root / 'theme.css'
        self.css.rename(target)
        self.css.symlink_to(target)
        self.vencord_settings.write_text('{"useQuickCss":false}')
        self.run_command(path=self.css, success=False)
        self.assertEqual(target.read_bytes(), ORIGINAL)
        self.assertEqual(list(self.settings.glob('*.bak')), [])
        self.assertFalse(json.loads(self.vencord_settings.read_text())['useQuickCss'])

    def test_invalid_settings_and_incomplete_block_are_not_overwritten(self):
        self.vencord_settings.write_text('{invalid')
        self.run_command(path=self.css, success=False)
        self.assertEqual(self.css.read_bytes(), ORIGINAL)
        self.vencord_settings.write_text('{}')
        malformed = ORIGINAL + b'\n/* pip-sticky popout-drag start */\n'
        self.css.write_bytes(malformed)
        self.run_command(path=self.css, success=False)
        self.assertEqual(self.css.read_bytes(), malformed)

    def test_piped_command_and_symlinked_quick_css(self):
        target = self.root / 'my-theme.css'
        self.css.rename(target)
        self.css.symlink_to(target)
        self.run_command(path=self.css, piped=True)
        self.assertTrue(self.css.is_symlink())
        self.assertIn(b'app-region: drag', target.read_bytes())
        self.run_command('remove', self.css, piped=True)
        self.assertTrue(self.css.is_symlink())
        self.assertEqual(target.read_bytes(), ORIGINAL)

    def test_every_selector_is_popout_only_and_controls_are_not_restyled(self):
        css = self.run_command('css').stdout
        selectors = [selector.strip() for group in re.findall(r'([^{}]+)\{', css)
                     for selector in group.split(',')]
        self.assertTrue(selectors)
        for selector in selectors:
            self.assertIn('[data-popout-root="true"]', selector)
            self.assertTrue(selector.endswith('::after'))
        self.assertNotRegex(css, r'(?m)^\s*(?:body|html|button|input|video)\s*\{')
        self.assertIn('app-region: drag !important;', css)


if __name__ == '__main__':
    unittest.main()

"""Run with python3 -m unittest discover -s tests -v; no desktop is required."""

import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "pip-sticky.sh"


def bash(body, *args):
    return subprocess.check_output(
        ["bash", "-euo", "pipefail", "-c", 'source "$1"; shift; ' + body,
         "test", str(SCRIPT), *map(str, args)], text=True,
    ).strip()


# The reported COSMIC shape: a branded main and a bare participant title.
# Use fictional names rather than recording anyone's actual call/window IDs.
WINDOWS = [
    {"id": "0x01", "app_id": "vesktop", "title": "Vesktop"},
    {"id": "0x02", "app_id": "vesktop", "title": "Example participant"},
    {"id": "0x03", "app_id": "vesktop", "title": "Example stream"},
    {"id": "0x04", "app_id": "vesktop", "title": "About Vesktop", "kind": "DIALOG"},
    {"id": "0x05", "app_id": "vesktop", "title": "Open File", "kind": "DIALOG"},
    {"id": "0x06", "app_id": "vesktop", "title": "Settings"},
    {"id": "0x07", "app_id": "vesktop", "title": "DevTools - example"},
    {"id": "0x08", "app_id": "firefox", "title": "Example participant"},
    {"id": "0x09", "app_id": "discord", "title": "#general | Example - Discord"},
    {"id": "0x0a", "app_id": "discord", "title": "Example call"},
    {"id": "0x0b", "app_id": "discordcanary", "title": "Orphan call"},
    {"id": "0x0c", "app_id": "firefox", "title": "Picture-in-Picture"},
    {"id": "0x0d", "app_id": "vesktop", "title": "Discord Popout"},
    {"id": "0x0e", "app_id": "chromium", "title": "Picture in picture"},
    {"id": "0x0f", "app_id": "notdiscord", "title": "Discord"},
    {"id": "0x10", "app_id": "notdiscord", "title": "Example participant"},
    {"id": "0x11", "app_id": "vesktop", "title": ""},
    {"id": "0x12", "app_id": "firefox", "title": "Localized PiP", "kind": "UTILITY"},
    {"id": "0x13", "app_id": "vesktop", "title": "Choose a file"},
    {"id": "0x14", "app_id": "vesktop", "title": "Renamed dialog", "kind": "DIALOG"},
    {"id": "0x15", "app_id": "vesktop", "title": "Renamed utility", "kind": "UTILITY"},
    {"id": "0x16", "app_id": "vesktop", "title": "Renamed modal", "modal": True},
]
TARGETS = ["0x02", "0x03", "0x0a", "0x0c", "0x0d", "0x0e", "0x12"]


class Regressions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pip-test-", dir=ROOT)
        self.directory = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def generate(self):
        bash('KWIN_STAGE="$1/kwin"; GNOME_DIR="$1/gnome"; '
             'have() { return 1; }; write_kwin_package; write_gnome_extension', self.directory)

    def native(self, backend, windows=WINDOWS, mode="initial"):
        self.generate()
        fixture = self.directory / "windows.json"
        fixture.write_text(json.dumps(windows))
        return json.loads(subprocess.check_output([
            "node", str(ROOT / "tests/native_harness.cjs"), backend,
            str(self.directory), str(fixture), mode,
        ], text=True))

    def cosmic(self, windows):
        fixture = self.directory / "state.json"
        fixture.write_text(json.dumps(windows))
        helper = self.directory / "helper"
        helper.write_text('#!/usr/bin/env bash\ncat "${BASH_SOURCE[0]%/*}/state.json"\n')
        helper.chmod(0o755)
        return bash('cosmic_discord_query "$1"', helper)

    def test_cosmic_reported_shape_and_main_window_guards(self):
        # COSMIC has no dialog/type metadata; only test properties it exposes.
        windows = [w for w in WINDOWS if not w.get("kind") and not w.get("modal")]
        query = self.cosmic(windows)
        self.assertEqual(re.findall(r"id = '([^']+)'", query), ["0x02", "0x03", "0x0a"])

    def test_cosmic_flatpak_and_release_channel_ids(self):
        for app_id in ["dev.vencord.Vesktop", "com.discordapp.Discord",
                       "com.discordapp.DiscordCanary", "discord-ptb", "DiscordDevelopment"]:
            with self.subTest(app_id=app_id):
                self.assertEqual(self.cosmic([
                    {"id": "main", "app_id": app_id, "title": "Discord"},
                    {"id": "call", "app_id": app_id, "title": "Example caller"},
                ]), "id = 'call'")

    def test_cosmic_ignores_invalid_json_and_never_interpolates_titles(self):
        self.assertEqual(self.cosmic({"unexpected": "object"}), "")
        self.assertEqual(self.cosmic([
            {"id": "main", "app_id": "vesktop", "title": "Vesktop"},
            {"id": "call", "app_id": "vesktop", "title": "quote' or is_active"},
            {"id": "bad' or is_active", "app_id": "vesktop", "title": "Example"},
        ]), "id = 'call'")

    def test_cosmic_applies_legacy_query_and_renamed_popout_together(self):
        self.cosmic(WINDOWS)
        helper = self.directory / "helper"
        helper.write_text('#!/usr/bin/env bash\nif [[ "$1" == state ]]; then\n'
                          'cat "${BASH_SOURCE[0]%/*}/state.json"\nelse\nprintf "%s\\n" "$@"\nfi\n')
        result = bash('cosmic_apply_once "$1"', helper)
        self.assertTrue(result.startswith("sticky\ntrue\n"))
        self.assertIn("Picture[- ]in[- ]Picture", result)
        self.assertIn("Discord Popout", result)
        self.assertIn("id = '0x02'", result)
        self.assertNotIn("Example participant", result)

    def test_native_backends_match_same_targets_and_exclude_dialogs(self):
        for backend in ["kwin", "gnome"]:
            with self.subTest(backend=backend):
                self.assertEqual(self.native(backend), TARGETS)

    def test_native_backends_handle_late_main_title_and_remember_popout(self):
        windows = [
            {"id": "main", "app_id": "vesktop", "title": ""},
            {"id": "call", "app_id": "vesktop", "title": "Example caller"},
        ]
        for backend in ["kwin", "gnome"]:
            with self.subTest(backend=backend):
                result = self.native(backend, windows, "lifecycle")
                self.assertEqual(result, {"initial": [], "late": ["call"],
                                          "renamed": ["call"], "closed": []})

    def test_native_flatpak_and_release_channels(self):
        for backend in ["kwin", "gnome"]:
            for app_id in ["dev.vencord.Vesktop", "com.discordapp.DiscordCanary", "discord-ptb"]:
                with self.subTest(backend=backend, app_id=app_id):
                    self.assertEqual(self.native(backend, [
                        {"id": "main", "app_id": app_id, "title": "Discord"},
                        {"id": "call", "app_id": app_id, "title": "Example caller"},
                    ]), ["call"])

    def test_main_title_patterns_reject_about_dialogs(self):
        result = bash('for title in "Vesktop" "#general | Server - Discord" '
                      '"#general — Discord" "Discord Canary" "About Vesktop"; do '
                      'if discord_title_is_main "$title"; then printf "yes\\n"; '
                      'else printf "no\\n"; fi; done')
        self.assertEqual(result.splitlines(), ["yes", "yes", "yes", "yes", "no"])

    def test_x11_real_wmctrl_columns_and_target_guards(self):
        lines = []
        for w in WINDOWS:
            lines.append(f'{w["id"]} 0 {w["app_id"]}.{w["app_id"]} workstation {w["title"]}')
            kind = w.get("kind", "NORMAL")
            props = f'_NET_WM_WINDOW_TYPE(ATOM) = _NET_WM_WINDOW_TYPE_{kind}\n'
            if w.get("modal"):
                props += '_NET_WM_STATE(ATOM) = _NET_WM_STATE_MODAL\n'
            (self.directory / w["id"]).write_text(props)
        (self.directory / "windows").write_text("\n".join(lines))
        result = bash('fixture_dir="$1"; '
                      'import_session_env() { :; }; '
                      'wmctrl() { if [[ "$1" == -lx ]]; then cat "$fixture_dir/windows"; '
                      'else printf "%s\\n" "$*" >> "$fixture_dir/actions"; fi; }; '
                      'xprop() { cat "$fixture_dir/$2"; }; x11_apply_once; '
                      'cat "$fixture_dir/actions"', self.directory)
        self.assertEqual(result.splitlines(), [f"-ir {wid} -b add,above,sticky" for wid in TARGETS])

    def test_x11_retains_match_but_forgets_closed_windows(self):
        result = bash('fixture_dir="$1"; import_session_env() { :; }; '
                      'xprop() { :; }; '
                      'wmctrl() { if [[ "$1" == -lx ]]; then printf "%s\\n" "$snapshot"; '
                      'else printf "%s\\n" "$2" >> "$fixture_dir/actions"; fi; }; '
                      'snapshot="0x01 0 vesktop.vesktop machine Discord Popout"; x11_apply_once; '
                      'snapshot="0x01 0 vesktop.vesktop machine Example caller"; x11_apply_once; '
                      'snapshot=""; x11_apply_once; '
                      'snapshot="0x01 0 vesktop.vesktop machine Example caller"; x11_apply_once; '
                      'cat "$fixture_dir/actions"', self.directory)
        self.assertEqual(result.splitlines(), ["0x01", "0x01"])

    def test_x11_does_not_reuse_memory_after_class_change(self):
        result = bash('import_session_env() { :; }; xprop() { :; }; '
                      'wmctrl() { if [[ "$1" == -lx ]]; then printf "%s\\n" "$snapshot"; fi; }; '
                      'snapshot="0x01 0 vesktop.vesktop machine Discord Popout"; x11_apply_once; '
                      'snapshot="0x01 0 unrelated.unrelated machine Ordinary window"; x11_apply_once; '
                      'printf "%s\\n" "${X11_MANAGED[0x01]:-forgotten}"')
        self.assertEqual(result, "forgotten")

    def test_reinstall_restarts_running_service(self):
        result = bash('write_service() { :; }; '
                      'systemctl() { printf "%s\\n" "$*"; }; enable_service cosmic')
        self.assertIn("--user enable pip-sticky.service", result)
        self.assertIn("--user restart pip-sticky.service", result)

    def test_shell_and_generated_javascript_syntax(self):
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)
        self.generate()
        subprocess.run(["node", "--check", str(self.directory / "kwin/contents/code/main.js")], check=True)
        extension = self.directory / "gnome/extension.js"
        module = extension.with_suffix(".mjs")
        module.write_text(extension.read_text())
        subprocess.run(["node", "--check", str(module)], check=True)


if __name__ == "__main__":
    unittest.main()

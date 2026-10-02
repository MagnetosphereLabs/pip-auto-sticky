#!/usr/bin/env bash
set -euo pipefail

# PiP Sticky v2
# Cross-desktop Picture-in-Picture / Discord popout helper for Linux.
#
# Supported backends:
#   - COSMIC Wayland: cosmic-ext-window-helper (preserves v1 behavior)
#   - KDE Plasma 6 / KWin: native KWin script
#   - GNOME 45-51: native GNOME Shell extension
#   - Generic X11: wmctrl (Cinnamon/XFCE/MATE/Openbox/etc.)
#
# Matching is intentionally layered:
#   1. Stable PiP/popout titles used by Firefox, Chromium and Vesktop/Discord.
#   2. Window role/type hints where the compositor exposes them.
#   3. Browser-family identity only as a guard for structural fallbacks.
#
# This catches Firefox/Chromium forks without maintaining a brittle package-ID
# allowlist, while avoiding blanket "all utility windows are PiP" rules.

VERSION="2.0.0"
APP_NAME="pip-sticky"
DESCRIPTION="Keep Picture-in-Picture and Discord popout windows sticky and above"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-1}"
COSMIC_INTERVAL_SECONDS="${COSMIC_INTERVAL_SECONDS:-${INTERVAL_SECONDS}}"
X11_INTERVAL_SECONDS="${X11_INTERVAL_SECONDS:-1}"

# Override only for testing/troubleshooting:
FORCE_BACKEND="${FORCE_BACKEND:-}"

# Change this to the final raw URL before release.
RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/MagnetosphereLabs/cosmic-firefox-pip-fix/main/pip-sticky.sh}"

DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/${APP_NAME}"
INSTALL_PATH="${DATA_DIR}/${APP_NAME}.sh"
BIN_DIR="${HOME}/.local/bin"
BIN_PATH="${BIN_DIR}/${APP_NAME}"
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/${APP_NAME}"
STATE_FILE="${CONFIG_DIR}/state"
UNIT_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
SERVICE_PATH="${UNIT_DIR}/${APP_NAME}.service"

HELPER_PATH="${HELPER_PATH:-${HOME}/.local/bin/cosmic-ext-window-helper}"
COSMIC_QUERY="${COSMIC_QUERY:-((title ~= '^Picture[- ]in[- ]Picture$'i) or (title ~= '^Discord Popout( .*)?$'i) or (title ~= ' - PiP$'i)) and not is_sticky}"
COSMIC_LIST_QUERY="${COSMIC_LIST_QUERY:-title ~= '^Picture[- ]in[- ]Picture$'i or title ~= '^Discord Popout( .*)?$'i or title ~= ' - PiP$'i}"

KWIN_ID="pipsticky"
KWIN_STAGE="${DATA_DIR}/${KWIN_ID}"
GNOME_UUID="pip-sticky@magnetospherelabs"
GNOME_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/gnome-shell/extensions/${GNOME_UUID}"

LEGACY_APP="cosmic-firefox-pip-sticky"
LEGACY_SERVICE="${HOME}/.config/systemd/user/${LEGACY_APP}.service"

# Runtime memory for X11 popouts whose titles change after creation.
declare -A X11_MANAGED=()

say() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

err() {
  printf 'ERROR: %s\n' "$*" >&2
}

have() {
  command -v "$1" >/dev/null 2>&1
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

run_priv() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif have sudo; then
    sudo "$@"
  elif have doas; then
    doas "$@"
  else
    err "This step needs root privileges, but neither sudo nor doas is installed."
    return 1
  fi
}

distro_id() {
  local id="unknown"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-unknown}"
  fi
  printf '%s\n' "${id}"
}

distro_pretty() {
  local pretty="Unknown Linux"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    pretty="${PRETTY_NAME:-${NAME:-Unknown Linux}}"
  fi
  printf '%s\n' "${pretty}"
}

package_manager() {
  if have apt-get; then
    printf '%s\n' apt
  elif have dnf; then
    printf '%s\n' dnf
  elif have pacman; then
    printf '%s\n' pacman
  elif have zypper; then
    printf '%s\n' zypper
  else
    printf '%s\n' unknown
  fi
}

install_capability() {
  local capability="$1"
  local pm pkg
  pm="$(package_manager)"

  case "${capability}:${pm}" in
    pipx:apt|pipx:dnf) pkg="pipx" ;;
    pipx:pacman) pkg="python-pipx" ;;
    pipx:zypper)
      if have python3; then
        pkg="$(python3 -c 'import sys; print(f"python{sys.version_info.major}{sys.version_info.minor}-pipx")')"
      else
        err "python3 is required to select the correct openSUSE pipx package."
        return 1
      fi
      ;;
    wmctrl:apt|wmctrl:dnf|wmctrl:pacman|wmctrl:zypper) pkg="wmctrl" ;;
    xprop:apt) pkg="x11-utils" ;;
    xprop:dnf|xprop:zypper) pkg="xprop" ;;
    xprop:pacman) pkg="xorg-xprop" ;;
    curl:apt|curl:dnf|curl:pacman|curl:zypper) pkg="curl" ;;
    *)
      err "I do not know how to install '${capability}' with package manager '${pm}'."
      return 1
      ;;
  esac

  say "Installing ${pkg}..."
  case "${pm}" in
    apt)
      run_priv apt-get update
      run_priv apt-get install -y "${pkg}"
      ;;
    dnf)
      run_priv dnf install -y "${pkg}"
      ;;
    pacman)
      run_priv pacman -S --needed --noconfirm "${pkg}"
      ;;
    zypper)
      run_priv zypper --non-interactive install "${pkg}"
      ;;
  esac
}
find_session_pid() {
  local name pid=""
  for name in cosmic-session kwin_wayland kwin_x11 gnome-shell cinnamon xfce4-session mate-session lxqt-session; do
    pid="$(pgrep -u "$(id -u)" -x "${name}" 2>/dev/null | tail -n 1 || true)"
    if [[ -n "${pid}" ]]; then
      printf '%s\n' "${pid}"
      return 0
    fi
  done
  return 1
}

import_session_env() {
  local pid key value sock
  pid="$(find_session_pid || true)"

  if [[ -n "${pid}" && -r "/proc/${pid}/environ" ]]; then
    while IFS='=' read -r key value; do
      case "${key}" in
        WAYLAND_DISPLAY|DISPLAY|XDG_CURRENT_DESKTOP|XDG_SESSION_DESKTOP|DESKTOP_SESSION|XDG_SESSION_TYPE|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|XAUTHORITY)
          export "${key}=${value}"
          ;;
      esac
    done < <(tr '\0' '\n' < "/proc/${pid}/environ")
  fi

  : "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"

  if [[ -z "${WAYLAND_DISPLAY:-}" && -d "${XDG_RUNTIME_DIR}" ]]; then
    sock="$(find "${XDG_RUNTIME_DIR}" -maxdepth 1 -type s -name 'wayland-*' 2>/dev/null | sort | head -n 1 | xargs -r basename || true)"
    if [[ -n "${sock}" ]]; then
      export WAYLAND_DISPLAY="${sock}"
    fi
  fi
}

detect_backend() {
  local desk session
  if [[ -n "${FORCE_BACKEND}" ]]; then
    case "${FORCE_BACKEND}" in
      cosmic|kwin|gnome|x11)
        printf '%s\n' "${FORCE_BACKEND}"
        return 0
        ;;
      *)
        err "Invalid FORCE_BACKEND=${FORCE_BACKEND}. Use cosmic, kwin, gnome, or x11."
        return 1
        ;;
    esac
  fi

  import_session_env
  desk="$(lower "${XDG_CURRENT_DESKTOP:-} ${XDG_SESSION_DESKTOP:-} ${DESKTOP_SESSION:-}")"
  session="$(lower "${XDG_SESSION_TYPE:-}")"

  if pgrep -u "$(id -u)" -x cosmic-session >/dev/null 2>&1 || [[ "${desk}" == *cosmic* ]]; then
    printf '%s\n' cosmic
  elif pgrep -u "$(id -u)" -x kwin_wayland >/dev/null 2>&1 ||
       pgrep -u "$(id -u)" -x kwin_x11 >/dev/null 2>&1 ||
       [[ "${desk}" == *kde* || "${desk}" == *plasma* ]]; then
    printf '%s\n' kwin
  elif pgrep -u "$(id -u)" -x gnome-shell >/dev/null 2>&1 || [[ "${desk}" == *gnome* ]]; then
    printf '%s\n' gnome
  elif [[ "${session}" == "x11" ]] ||
       [[ -z "${session}" && -z "${WAYLAND_DISPLAY:-}" && -n "${DISPLAY:-}" ]]; then
    # Do not use DISPLAY alone as proof of X11: Wayland sessions normally expose
    # DISPLAY through Xwayland. Falling back to wmctrl there would silently
    # manage only Xwayland windows and falsely claim native Wayland support.
    printf '%s\n' x11
  else
    return 1
  fi
}
saved_backend() {
  if [[ -r "${STATE_FILE}" ]]; then
    local BACKEND=""
    # shellcheck disable=SC1090
    . "${STATE_FILE}"
    if [[ -n "${BACKEND:-}" ]]; then
      printf '%s\n' "${BACKEND}"
      return 0
    fi
  fi
  detect_backend
}

write_state() {
  local backend="$1"
  mkdir -p "${CONFIG_DIR}"
  printf 'BACKEND=%q\n' "${backend}" > "${STATE_FILE}"
}

find_helper() {
  if [[ -x "${HELPER_PATH}" ]]; then
    printf '%s\n' "${HELPER_PATH}"
    return 0
  fi
  if have cosmic-ext-window-helper; then
    command -v cosmic-ext-window-helper
    return 0
  fi
  return 1
}

ensure_pipx() {
  if have pipx; then
    return 0
  fi
  install_capability pipx
}

ensure_cosmic_helper() {
  if find_helper >/dev/null 2>&1; then
    return 0
  fi

  # Prefer an already-installed modern Python tool manager before adding a
  # package-manager dependency. Both uv and pipx install the helper in an
  # isolated environment.
  if have uv; then
    say "Installing cosmic-ext-window-helper with uv..."
    uv tool install cosmic-ext-window-helper
  else
    ensure_pipx
    say "Installing cosmic-ext-window-helper with pipx..."
    pipx install cosmic-ext-window-helper
    pipx ensurepath >/dev/null 2>&1 || true
  fi

  if ! find_helper >/dev/null 2>&1; then
    err "cosmic-ext-window-helper was not found after installation."
    err "Expected it at ${HELPER_PATH} or on PATH."
    return 1
  fi
}
ensure_wmctrl() {
  if have wmctrl; then
    return 0
  fi
  install_capability wmctrl
}

ensure_xprop() {
  if have xprop; then
    return 0
  fi
  install_capability xprop
}

copy_self() {
  mkdir -p "${DATA_DIR}" "${BIN_DIR}"
  local src tmp
  src="${BASH_SOURCE[0]:-}"

  if [[ -n "${src}" && -f "${src}" ]]; then
    # `pip-sticky install` is intentionally idempotent. If this is already the
    # installed copy (including when invoked through ~/.local/bin/pip-sticky),
    # do not try to install a file onto itself.
    if [[ "$(readlink -f "${src}")" != "$(readlink -f "${INSTALL_PATH}" 2>/dev/null || printf '%s' "${INSTALL_PATH}")" ]]; then
      install -m 0755 "${src}" "${INSTALL_PATH}"
    fi
  else
    if ! have curl; then
      install_capability curl
    fi
    tmp="$(mktemp)"
    if ! curl -fsSL "${RAW_URL}" -o "${tmp}"; then
      rm -f "${tmp}"
      err "Unable to download ${RAW_URL}"
      return 1
    fi
    bash -n "${tmp}"
    install -m 0755 "${tmp}" "${INSTALL_PATH}"
    rm -f "${tmp}"
  fi

  ln -sfn "${INSTALL_PATH}" "${BIN_PATH}"
}

write_service() {
  local backend="$1"
  mkdir -p "${UNIT_DIR}"
  cat > "${SERVICE_PATH}" <<SERVICE
[Unit]
Description=${DESCRIPTION}
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart="${INSTALL_PATH}" run
Restart=always
RestartSec=2
Environment=PATH=${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=INTERVAL_SECONDS=${INTERVAL_SECONDS}
Environment=COSMIC_INTERVAL_SECONDS=${COSMIC_INTERVAL_SECONDS}
Environment=X11_INTERVAL_SECONDS=${X11_INTERVAL_SECONDS}
Environment=PIP_STICKY_BACKEND=${backend}

[Install]
WantedBy=default.target
SERVICE
}

enable_service() {
  local backend="$1"
  write_service "${backend}"
  systemctl --user import-environment \
    WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP \
    DESKTOP_SESSION XDG_SESSION_TYPE XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS \
    XAUTHORITY >/dev/null 2>&1 || true
  systemctl --user daemon-reload
  systemctl --user enable --now "${APP_NAME}.service"
}

disable_service() {
  systemctl --user disable --now "${APP_NAME}.service" >/dev/null 2>&1 || true
  rm -f "${SERVICE_PATH}"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}

write_kwin_package() {
  rm -rf "${KWIN_STAGE}"
  mkdir -p "${KWIN_STAGE}/contents/code"

  cat > "${KWIN_STAGE}/metadata.json" <<'JSON'
{
  "KPlugin": {
    "Name": "PiP Sticky",
    "Description": "Keep Picture-in-Picture and Discord popout windows above and on all desktops",
    "Id": "pipsticky",
    "Version": "2.0.0",
    "License": "MIT",
    "Website": "https://github.com/MagnetosphereLabs/cosmic-firefox-pip-fix"
  },
  "X-Plasma-API": "javascript",
  "X-Plasma-MainScript": "code/main.js",
  "KPackageStructure": "KWin/Script"
}
JSON

  cat > "${KWIN_STAGE}/contents/code/main.js" <<'JS'
/*
 * PiP Sticky - KWin backend
 *
 * KWin gives scripts compositor-native access to keepAbove and onAllDesktops,
 * so this backend is event-driven and requires no polling service.
 */

function normalized(value) {
    return String(value || "").trim().toLowerCase();
}

function compact(value) {
    return normalized(value).replace(/[^a-z0-9]/g, "");
}

function titleLooksLikePiP(title) {
    const t = normalized(title);

    // Firefox family: Picture-in-Picture
    // Chromium family: Picture in picture
    if (/^picture[- ]in[- ]picture$/i.test(t))
        return true;

    // Used by some applications/extensions and supported by the long-running
    // GNOME PiP-on-top project.
    if (/\s-\spip$/i.test(t))
        return true;

    return false;
}

function titleLooksLikeDiscordPopout(title) {
    const t = normalized(title);
    return t === "discord popout" || t.startsWith("discord popout ");
}

function identity(window) {
    return normalized([
        window.resourceClass,
        window.resourceName,
        window.desktopFileName
    ].join(" "));
}

function isFirefoxFamily(window) {
    const id = identity(window);
    return /(firefox|floorp|librewolf|waterfox|zen-browser|zen_browser|icecat)/i.test(id);
}

function roleLooksLikePiP(window) {
    const role = compact(window.windowRole);
    return role.includes("pictureinpicture") ||
           role === "pip" ||
           role === "pipwindow";
}

function isManagedTarget(window) {
    if (!window)
        return false;

    const title = normalized(window.caption);

    if (titleLooksLikePiP(title) || titleLooksLikeDiscordPopout(title))
        return true;

    // Some Chromium PiP implementations expose a stable native window role/name
    // even when Document PiP uses the originating page title.
    if (roleLooksLikePiP(window))
        return true;

    // Current Firefox GTK media PiP windows are exported as UTILITY windows.
    // Restrict this structural fallback to known Firefox-family identities so
    // unrelated utility windows from other applications are never captured.
    if (isFirefoxFamily(window) && window.utility && !window.modal)
        return true;

    return false;
}

const managedWindows = [];

function rememberManaged(window) {
    if (managedWindows.indexOf(window) === -1)
        managedWindows.push(window);
}

function forgetManaged(window) {
    const index = managedWindows.indexOf(window);
    if (index !== -1)
        managedWindows.splice(index, 1);
}

function applyRule(window) {
    if (!window)
        return;

    const alreadyManaged = managedWindows.indexOf(window) !== -1;
    if (!alreadyManaged && !isManagedTarget(window))
        return;

    if (!alreadyManaged)
        rememberManaged(window);

    let changed = false;

    if (!window.keepAbove) {
        window.keepAbove = true;
        changed = true;
    }

    if (!window.onAllDesktops) {
        window.onAllDesktops = true;
        changed = true;
    }

    if (changed)
        print("[pip-sticky] managed: " + String(window.caption || ""));
}

function safeConnect(signal, callback) {
    if (signal && signal.connect)
        signal.connect(callback);
}

function watchWindow(window) {
    if (!window)
        return;

    applyRule(window);

    // Titles/classes can settle after the toplevel is first announced.
    safeConnect(window.captionChanged, function() { applyRule(window); });
    safeConnect(window.windowClassChanged, function() { applyRule(window); });
    safeConnect(window.windowRoleChanged, function() { applyRule(window); });
    safeConnect(window.desktopFileNameChanged, function() { applyRule(window); });

    // Reassert the policy if an application changes it after creation.
    safeConnect(window.keepAboveChanged, function() { applyRule(window); });
    safeConnect(window.desktopsChanged, function() { applyRule(window); });
    safeConnect(window.closed, function() { forgetManaged(window); });
}

workspace.windowAdded.connect(watchWindow);

const existing = workspace.stackingOrder;
for (let i = 0; i < existing.length; i++)
    watchWindow(existing[i]);
JS
}
kwin_reconfigure() {
  local qdbus_cmd=""
  if have qdbus6; then
    qdbus_cmd="qdbus6"
  elif have qdbus; then
    qdbus_cmd="qdbus"
  fi

  if [[ -n "${qdbus_cmd}" ]]; then
    "${qdbus_cmd}" org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
  else
    warn "qdbus/qdbus6 not found; the KWin script will load on the next Plasma login."
  fi
}

install_kwin() {
  if ! have kpackagetool6 || ! have kwriteconfig6; then
    err "Plasma 6 tools kpackagetool6 and kwriteconfig6 are required."
    return 1
  fi

  write_kwin_package

  # Unload a previous copy before upgrading so KWin cannot keep old JS signal
  # handlers alive in the current session.
  kwriteconfig6 --file kwinrc --group Plugins --key "${KWIN_ID}Enabled" false
  kwin_reconfigure

  if ! kpackagetool6 --type=KWin/Script --upgrade "${KWIN_STAGE}" >/dev/null 2>&1; then
    kpackagetool6 --type=KWin/Script --install "${KWIN_STAGE}" >/dev/null
  fi

  kwriteconfig6 --file kwinrc --group Plugins --key "${KWIN_ID}Enabled" true
  kwin_reconfigure

  say "Installed native KWin backend."
}
uninstall_kwin() {
  if have kwriteconfig6; then
    kwriteconfig6 --file kwinrc --group Plugins --key "${KWIN_ID}Enabled" false || true
    kwin_reconfigure
  fi

  if have kpackagetool6; then
    kpackagetool6 --type=KWin/Script --remove "${KWIN_ID}" >/dev/null 2>&1 || true
  fi

  rm -rf "${KWIN_STAGE}"
}

write_gnome_extension() {
  # Disable a currently loaded copy before replacing files during upgrades.
  if have gnome-extensions; then
    gnome-extensions disable "${GNOME_UUID}" >/dev/null 2>&1 || true
  fi

  rm -rf "${GNOME_DIR}"
  mkdir -p "${GNOME_DIR}"

  cat > "${GNOME_DIR}/metadata.json" <<JSON
{
  "uuid": "${GNOME_UUID}",
  "name": "PiP Sticky",
  "description": "Keep Picture-in-Picture and Discord popout windows above and on all workspaces",
  "shell-version": ["45", "46", "47", "48", "49", "50", "51"],
  "version": 20000,
  "url": "https://github.com/MagnetosphereLabs/cosmic-firefox-pip-fix"
}
JSON

  cat > "${GNOME_DIR}/extension.js" <<'JS'
/*
 * PiP Sticky - GNOME Shell backend
 *
 * Uses Mutter's native Meta.Window make_above()/stick() API. This works for
 * both native Wayland clients and Xwayland clients because Mutter owns the
 * window policy.
 */

import Meta from 'gi://Meta';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

function normalized(value) {
    return String(value || '').trim().toLowerCase();
}

function compact(value) {
    return normalized(value).replace(/[^a-z0-9]/g, '');
}

function safeCall(window, method) {
    try {
        if (window && typeof window[method] === 'function')
            return window[method]();
    } catch (_error) {
        // Some identity accessors are backend/protocol specific.
    }
    return '';
}

function titleLooksLikePiP(title) {
    const t = normalized(title);

    if (/^picture[- ]in[- ]picture$/i.test(t))
        return true;

    if (/\s-\spip$/i.test(t))
        return true;

    return false;
}

function titleLooksLikeDiscordPopout(title) {
    const t = normalized(title);
    return t === 'discord popout' || t.startsWith('discord popout ');
}

function identity(window) {
    return normalized([
        safeCall(window, 'get_wm_class'),
        safeCall(window, 'get_wm_class_instance'),
        safeCall(window, 'get_gtk_application_id'),
        safeCall(window, 'get_sandboxed_app_id')
    ].join(' '));
}

function isFirefoxFamily(window) {
    const id = identity(window);
    return /(firefox|floorp|librewolf|waterfox|zen-browser|zen_browser|icecat)/i.test(id);
}

function roleLooksLikePiP(window) {
    const role = compact(safeCall(window, 'get_role'));
    return role.includes('pictureinpicture') ||
        role === 'pip' ||
        role === 'pipwindow';
}

function isFirefoxMediaPiP(window) {
    if (!isFirefoxFamily(window))
        return false;

    try {
        return window.get_window_type() === Meta.WindowType.UTILITY;
    } catch (_error) {
        return false;
    }
}

function isManagedTarget(window) {
    if (!window)
        return false;

    const title = safeCall(window, 'get_title');

    if (titleLooksLikePiP(title) || titleLooksLikeDiscordPopout(title))
        return true;

    if (roleLooksLikePiP(window))
        return true;

    // Firefox GTK marks Media PiP as UTILITY. The Firefox-family identity
    // guard is important: generic utility windows must never become sticky.
    if (isFirefoxMediaPiP(window))
        return true;

    return false;
}

export default class PipStickyExtension extends Extension {
    enable() {
        this._windows = new Map();

        this._windowCreatedId = global.display.connect(
            'window-created',
            (_display, window) => this._watchWindow(window)
        );

        // Include windows that already exist when the extension is enabled.
        for (const window of global.display.list_all_windows())
            this._watchWindow(window);
    }

    disable() {
        if (this._windowCreatedId) {
            global.display.disconnect(this._windowCreatedId);
            this._windowCreatedId = 0;
        }

        if (!this._windows)
            return;

        for (const [window, state] of this._windows) {
            for (const id of state.signalIds) {
                try {
                    window.disconnect(id);
                } catch (_error) {
                    // It may already have been unmanaged.
                }
            }

            // Restore only state that this extension itself introduced.
            try {
                if (state.setAbove && window.is_above())
                    window.unmake_above();
            } catch (_error) {}

            try {
                if (state.setSticky && window.is_on_all_workspaces())
                    window.unstick();
            } catch (_error) {}
        }

        this._windows.clear();
        this._windows = null;
    }

    _forgetWindow(window) {
        if (!this._windows)
            return;
        this._windows.delete(window);
    }

    _watchWindow(window) {
        if (!window || !this._windows || this._windows.has(window))
            return;

        const state = {
            signalIds: [],
            matched: false,
            setAbove: false,
            setSticky: false,
        };

        const connect = (signal, callback) => {
            try {
                state.signalIds.push(window.connect(signal, callback));
            } catch (_error) {
                // Keep compatibility across supported Mutter versions.
            }
        };

        connect('notify::title', () => this._apply(window));
        connect('notify::wm-class', () => this._apply(window));
        connect('shown', () => this._apply(window));
        connect('notify::above', () => this._apply(window));
        connect('notify::on-all-workspaces', () => this._apply(window));
        connect('unmanaged', () => this._forgetWindow(window));

        this._windows.set(window, state);
        this._apply(window);
    }

    _apply(window) {
        if (!this._windows)
            return;

        const state = this._windows.get(window);
        if (!state)
            return;

        // Once a popout has been positively identified, keep managing it even
        // if an Electron/web app later changes the title to the call/site name.
        if (!state.matched) {
            state.matched = isManagedTarget(window);
            if (!state.matched)
                return;
        }

        let changed = false;

        try {
            if (!window.is_above()) {
                window.make_above();
                state.setAbove = true;
                changed = true;
            }
        } catch (_error) {}

        try {
            if (!window.is_on_all_workspaces()) {
                window.stick();
                state.setSticky = true;
                changed = true;
            }
        } catch (_error) {}

        if (changed)
            console.log(`[pip-sticky] managed: ${safeCall(window, 'get_title')}`);
    }
}
JS
}
gnome_update_enabled_list() {
  local mode="$1"

  if ! have gsettings; then
    return 0
  fi

  if have python3; then
    python3 - "${GNOME_UUID}" "${mode}" <<'PY'
import ast
import subprocess
import sys

uuid = sys.argv[1]
mode = sys.argv[2]

schema = "org.gnome.shell"

def get_list(key):
    raw = subprocess.check_output(
        ["gsettings", "get", schema, key],
        text=True
    ).strip()
    if raw.startswith("@as "):
        raw = raw[4:]
    try:
        value = ast.literal_eval(raw)
    except Exception:
        value = []
    return list(value)

def set_list(key, value):
    rendered = "[" + ", ".join(repr(x) for x in value) + "]"
    subprocess.run(
        ["gsettings", "set", schema, key, rendered],
        check=False
    )

enabled = get_list("enabled-extensions")
disabled = get_list("disabled-extensions")

enabled = [x for x in enabled if x != uuid]
disabled = [x for x in disabled if x != uuid]

if mode == "enable":
    enabled.append(uuid)

set_list("enabled-extensions", enabled)
set_list("disabled-extensions", disabled)
PY
  fi
}

install_gnome() {
  if ! have gnome-extensions; then
    err "gnome-extensions was not found. It normally ships with GNOME Shell."
    return 1
  fi

  write_gnome_extension
  gnome_update_enabled_list enable

  # If the running Shell has already discovered the UUID (upgrade/reinstall),
  # this activates immediately. A brand-new local extension on Wayland normally
  # becomes discoverable only after the next login.
  if gnome-extensions enable "${GNOME_UUID}" >/dev/null 2>&1; then
    say "Installed and enabled native GNOME backend."
  else
    say "Installed native GNOME backend and enabled it for the next GNOME session."
    say "GNOME requires one log out / log in to discover a brand-new local extension."
  fi

  if have gsettings &&
     [[ "$(gsettings get org.gnome.shell disable-user-extensions 2>/dev/null || true)" == "true" ]]; then
    warn "GNOME's global 'Disable User Extensions' switch is on."
    warn "PiP Sticky is installed, but GNOME will not load user extensions until that switch is turned off."
  fi
}
uninstall_gnome() {
  if have gnome-extensions; then
    gnome-extensions disable "${GNOME_UUID}" >/dev/null 2>&1 || true
  fi
  gnome_update_enabled_list remove
  rm -rf "${GNOME_DIR}"
}

x11_title_is_target() {
  local title="$1"
  local t
  t="$(lower "${title}")"

  [[ "${t}" =~ ^picture[-\ ]in[-\ ]picture$ ||
     "${t}" =~ [[:space:]]-[[:space:]]pip$ ||
     "${t}" == "discord popout" ||
     "${t}" == "discord popout "* ]]
}

x11_class_is_firefox_family() {
  local klass
  klass="$(lower "$1")"
  [[ "${klass}" =~ firefox|floorp|librewolf|waterfox|zen-browser|zen_browser|icecat ]]
}

x11_hints_are_target() {
  local id="$1"
  local klass="$2"
  local props=""

  # xprop is optional. When available it gives us structural fallbacks for
  # localized Firefox PiP titles and Chromium's PictureInPictureWindow role.
  if ! have xprop; then
    return 1
  fi

  props="$(xprop -id "${id}" WM_WINDOW_ROLE _NET_WM_WINDOW_TYPE 2>/dev/null || true)"

  if printf '%s\n' "${props}" | grep -Eqi 'picture.?in.?picture|pipwindow'; then
    return 0
  fi

  if x11_class_is_firefox_family "${klass}" &&
     printf '%s\n' "${props}" | grep -q '_NET_WM_WINDOW_TYPE_UTILITY'; then
    return 0
  fi

  return 1
}

x11_is_target() {
  local id="$1"
  local klass="$2"
  local title="$3"

  x11_title_is_target "${title}" || x11_hints_are_target "${id}" "${klass}"
}

x11_apply_once() {
  local verbose="${1:-0}"
  local id desktop host klass title
  local -A seen=()

  import_session_env

  while read -r id desktop host klass title; do
    [[ -n "${id:-}" ]] || continue
    seen["${id}"]=1

    if [[ -n "${X11_MANAGED[${id}]+yes}" ]] ||
       x11_is_target "${id}" "${klass:-}" "${title:-}"; then
      X11_MANAGED["${id}"]="${klass:-unknown}"
      wmctrl -ir "${id}" -b add,above,sticky >/dev/null 2>&1 || true
      if [[ "${verbose}" == "1" ]]; then
        say "managed ${id}  class=${klass}  title=${title}"
      fi
    fi
  done < <(wmctrl -lx 2>/dev/null || true)

  # Forget closed windows so a future X11 XID reuse cannot inherit the rule.
  for id in "${!X11_MANAGED[@]}"; do
    if [[ -z "${seen[${id}]+yes}" ]]; then
      unset 'X11_MANAGED[$id]'
    fi
  done
}
run_cosmic() {
  local helper
  helper="$(find_helper || true)"
  if [[ -z "${helper}" ]]; then
    err "cosmic-ext-window-helper not found. Re-run: ${INSTALL_PATH} install"
    return 1
  fi

  say "${APP_NAME} ${VERSION} running: backend=cosmic interval=${COSMIC_INTERVAL_SECONDS}s"
  while true; do
    import_session_env
    "${helper}" sticky true "${COSMIC_QUERY}" >/dev/null 2>&1 || true
    sleep "${COSMIC_INTERVAL_SECONDS}"
  done
}

run_x11() {
  say "${APP_NAME} ${VERSION} running: backend=x11 interval=${X11_INTERVAL_SECONDS}s"
  while true; do
    x11_apply_once 0
    sleep "${X11_INTERVAL_SECONDS}"
  done
}

run_cmd() {
  local backend="${PIP_STICKY_BACKEND:-}"
  if [[ -z "${backend}" ]]; then
    backend="$(saved_backend || true)"
  fi

  case "${backend}" in
    cosmic) run_cosmic ;;
    x11) run_x11 ;;
    kwin|gnome)
      err "The ${backend} backend is compositor-native and does not use the polling service."
      return 1
      ;;
    *)
      err "No supported backend detected."
      return 1
      ;;
  esac
}

migrate_v1() {
  if [[ -f "${LEGACY_SERVICE}" ]] ||
     systemctl --user is-enabled "${LEGACY_APP}.service" >/dev/null 2>&1 ||
     systemctl --user is-active "${LEGACY_APP}.service" >/dev/null 2>&1; then
    say "Migrating v1 service to PiP Sticky v2..."
    systemctl --user disable --now "${LEGACY_APP}.service" >/dev/null 2>&1 || true
    rm -f "${LEGACY_SERVICE}"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
}
install_cmd() {
  local backend desk session

  backend="$(detect_backend || true)"
  if [[ -z "${backend}" ]]; then
    import_session_env
    desk="${XDG_CURRENT_DESKTOP:-${XDG_SESSION_DESKTOP:-unknown}}"
    session="${XDG_SESSION_TYPE:-unknown}"
    err "No supported desktop backend was detected (desktop=${desk}, session=${session})."
    err "Supported: COSMIC Wayland, KDE Plasma 6/KWin, GNOME 45-51, and standards-based X11 desktops."
    if [[ "${session}" == "wayland" ]]; then
      err "This Wayland compositor needs a compositor-specific backend; PiP Sticky will not fake support through Xwayland."
    fi
    return 1
  fi

  say "Detected: $(distro_pretty)"
  say "Desktop backend: ${backend}"

  copy_self

  case "${backend}" in
    cosmic)
      ensure_cosmic_helper
      enable_service cosmic
      ;;
    kwin)
      disable_service
      install_kwin
      ;;
    gnome)
      disable_service
      install_gnome
      ;;
    x11)
      ensure_wmctrl
      ensure_xprop
      enable_service x11
      ;;
  esac

  write_state "${backend}"
  migrate_v1

  say
  say "Installed ${APP_NAME} ${VERSION}"
  say "Command: ${BIN_PATH}"
  say "Backend: ${backend}"
  say "Targets: Firefox-family PiP, Chromium-family PiP, and Discord/Vesktop-style popouts"
}
update_cmd() {
  local tmp
  if ! have curl; then
    install_capability curl
  fi

  tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' RETURN

  say "Downloading ${RAW_URL}..."
  curl -fsSL "${RAW_URL}" -o "${tmp}"
  bash -n "${tmp}"
  install -m 0755 "${tmp}" "${INSTALL_PATH}"
  ln -sfn "${INSTALL_PATH}" "${BIN_PATH}"

  trap - RETURN
  rm -f "${tmp}"

  exec "${INSTALL_PATH}" install
}

uninstall_cmd() {
  disable_service

  # Remove every backend we may have installed, not only the backend from the
  # most recent session. This keeps uninstall clean for users who switch
  # between multiple desktop environments on the same machine.
  uninstall_kwin || true
  uninstall_gnome || true

  rm -rf "${HOME}/.local/share/kwin/scripts/${KWIN_ID}" 2>/dev/null || true

  rm -f "${BIN_PATH}"
  rm -f "${STATE_FILE}"
  rmdir "${CONFIG_DIR}" 2>/dev/null || true
  rm -f "${INSTALL_PATH}"
  rm -rf "${KWIN_STAGE}"
  rmdir "${DATA_DIR}" 2>/dev/null || true

  say "Removed ${APP_NAME}."
  say "Shared dependencies such as cosmic-ext-window-helper, pipx, wmctrl, and xprop were left installed."
}

test_cosmic() {
  local helper
  helper="$(find_helper || true)"
  if [[ -z "${helper}" ]]; then
    err "cosmic-ext-window-helper not found."
    return 1
  fi

  import_session_env
  say "Matching windows before:"
  "${helper}" list "${COSMIC_LIST_QUERY}" || true
  say
  say "Applying sticky..."
  "${helper}" sticky true "${COSMIC_QUERY}" || true
  say
  say "Matching windows after:"
  "${helper}" list "${COSMIC_LIST_QUERY}" || true
}

test_x11() {
  ensure_wmctrl
  ensure_xprop
  say "Applying above + sticky to matching X11 windows..."
  x11_apply_once 1
}

test_kwin() {
  say "KWin backend is event-driven."
  if have kreadconfig6; then
    say "Enabled: $(kreadconfig6 --file kwinrc --group Plugins --key "${KWIN_ID}Enabled" --default false 2>/dev/null || true)"
  fi
  say "Open a PiP window or Discord Popout; matching windows are managed immediately."
  say "KWin logs: journalctl --user -b | grep '\\[pip-sticky\\]'"
}

test_gnome() {
  say "GNOME backend is event-driven."
  gnome-extensions info "${GNOME_UUID}" 2>/dev/null || true
  say "Open a PiP window or Discord Popout; matching windows are managed immediately."
  say "GNOME logs: journalctl --user -b | grep '\\[pip-sticky\\]'"
}

test_cmd() {
  local backend
  backend="$(saved_backend || true)"
  case "${backend}" in
    cosmic) test_cosmic ;;
    kwin) test_kwin ;;
    gnome) test_gnome ;;
    x11) test_x11 ;;
    *)
      err "No supported backend detected."
      return 1
      ;;
  esac
}

status_cmd() {
  local backend
  backend="$(saved_backend || true)"

  say "== PiP Sticky =="
  say "Version: ${VERSION}"
  say "Distro: $(distro_pretty)"
  say "Desktop: ${XDG_CURRENT_DESKTOP:-unknown}"
  say "Session: ${XDG_SESSION_TYPE:-unknown}"
  say "Backend: ${backend:-unsupported}"
  say

  case "${backend}" in
    cosmic)
      say "== service =="
      systemctl --user --no-pager --full status "${APP_NAME}.service" || true
      say
      say "== COSMIC helper =="
      find_helper || true
      ;;
    x11)
      say "== service =="
      systemctl --user --no-pager --full status "${APP_NAME}.service" || true
      say
      say "== matching windows =="
      x11_apply_once 1 || true
      ;;
    kwin)
      say "== KWin script =="
      if have kreadconfig6; then
        say "Enabled: $(kreadconfig6 --file kwinrc --group Plugins --key "${KWIN_ID}Enabled" --default false 2>/dev/null || true)"
      fi
      if have kpackagetool6; then
        kpackagetool6 --type=KWin/Script --list 2>/dev/null | grep -i "${KWIN_ID}" || true
      fi
      ;;
    gnome)
      say "== GNOME extension =="
      gnome-extensions info "${GNOME_UUID}" 2>/dev/null || true
      if have gsettings; then
        say "User extensions globally disabled: $(gsettings get org.gnome.shell disable-user-extensions 2>/dev/null || true)"
      fi
      ;;
    *)
      warn "No supported backend detected."
      ;;
  esac
}

logs_cmd() {
  local backend
  backend="$(saved_backend || true)"
  case "${backend}" in
    cosmic|x11)
      journalctl --user -u "${APP_NAME}.service" -n 160 --no-pager || true
      ;;
    kwin|gnome)
      journalctl --user -b --no-pager | grep '\[pip-sticky\]' | tail -n 160 || true
      ;;
    *)
      err "No supported backend detected."
      return 1
      ;;
  esac
}

doctor_cmd() {
  local backend
  backend="$(saved_backend || true)"

  say "PiP Sticky doctor"
  say "version=${VERSION}"
  say "distro=$(distro_pretty)"
  say "distro_id=$(distro_id)"
  say "desktop=${XDG_CURRENT_DESKTOP:-}"
  say "session_desktop=${XDG_SESSION_DESKTOP:-}"
  say "session_type=${XDG_SESSION_TYPE:-}"
  say "display=${DISPLAY:-}"
  say "wayland_display=${WAYLAND_DISPLAY:-}"
  say "backend=${backend:-unsupported}"
  say "package_manager=$(package_manager)"
  say "systemd_user=$(systemctl --user is-system-running 2>/dev/null || true)"
  say

  case "${backend}" in
    cosmic)
      say "helper=$(find_helper || true)"
      test_cosmic || true
      ;;
    kwin)
      say "kpackagetool6=$(command -v kpackagetool6 || true)"
      say "kwriteconfig6=$(command -v kwriteconfig6 || true)"
      test_kwin || true
      ;;
    gnome)
      say "gnome_extensions=$(command -v gnome-extensions || true)"
      test_gnome || true
      ;;
    x11)
      say "wmctrl=$(command -v wmctrl || true)"
      say "xprop=$(command -v xprop || true)"
      x11_apply_once 1 || true
      ;;
  esac
}

usage() {
  cat <<USAGE
${APP_NAME} ${VERSION}

Usage:
  ${APP_NAME} install       Detect desktop, install the right backend, and enable it
  ${APP_NAME} update        Download the latest script and reinstall the active backend
  ${APP_NAME} uninstall     Remove PiP Sticky and its desktop integration
  ${APP_NAME} status        Show backend and installation health
  ${APP_NAME} test          Apply/test the active backend once
  ${APP_NAME} logs          Show recent PiP Sticky logs
  ${APP_NAME} doctor        Print diagnostics useful for bug reports
  ${APP_NAME} run           Internal polling loop for COSMIC/X11
  ${APP_NAME} version       Print version
  ${APP_NAME} help          Show this help

Supported desktop backends:
  COSMIC Wayland            cosmic-ext-window-helper; preserves v1 behavior
  KDE Plasma 6 / KWin       native KWin script; event-driven
  GNOME 45-51               native GNOME Shell extension; event-driven
  X11 desktops              wmctrl; Cinnamon/XFCE/MATE/Openbox/etc.

Default managed windows:
  Picture-in-Picture        Firefox-family title
  Picture in picture        Chromium-family title
  Discord Popout            Discord/Vesktop-style detached popout

Environment overrides:
  INTERVAL_SECONDS=1
  COSMIC_INTERVAL_SECONDS=1
  X11_INTERVAL_SECONDS=1
  FORCE_BACKEND=cosmic|kwin|gnome|x11
  HELPER_PATH=${HOME}/.local/bin/cosmic-ext-window-helper
  RAW_URL=${RAW_URL}
USAGE
}

main() {
  local cmd="${1:-help}"
  case "${cmd}" in
    install) install_cmd ;;
    update) update_cmd ;;
    uninstall) uninstall_cmd ;;
    status) status_cmd ;;
    test) test_cmd ;;
    logs) logs_cmd ;;
    doctor) doctor_cmd ;;
    run) run_cmd ;;
    version|--version|-V) say "${VERSION}" ;;
    help|-h|--help|"") usage ;;
    *)
      err "Unknown command: ${cmd}"
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"

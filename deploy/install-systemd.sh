#!/usr/bin/env bash
# Install/update this extracted package as a system-level systemd service.
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: sudo ./install-systemd.sh [options]
  --user USER       Non-root Codex account (default: SUDO_USER)
  --prefix PATH     Program directory (default: /opt/codexlink)
  --data-dir PATH   Private state directory (default: /var/lib/codexlink)
  --codex PATH      Absolute native Codex executable; applied only on first init
  --help            Show this help

Existing config.json and access-token.txt are preserved. The unit is installed
at /etc/systemd/system/codexlink.service, enabled, then restarted.
Run as the same user that has already installed and logged in to Codex.
HELP
}

RUN_USER=${SUDO_USER:-}
PREFIX=/opt/codexlink
DATA_DIR=/var/lib/codexlink
CODEX_PATH=
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --user|--prefix|--data-dir|--codex)
      (($# >= 2)) || { printf 'Missing value for %s\n' "$1" >&2; exit 2; }
      case "$1" in
        --user) RUN_USER=$2 ;;
        --prefix) PREFIX=$2 ;;
        --data-dir) DATA_DIR=$2 ;;
        --codex) CODEX_PATH=$2 ;;
      esac
      shift 2 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $EUID == 0 ]] || { echo 'Run with sudo (or root with --user USER).' >&2; exit 1; }
[[ -n $RUN_USER && $RUN_USER != root ]] || { echo 'Specify a non-root Codex account with --user USER.' >&2; exit 1; }
USER_RECORD=$(getent passwd "$RUN_USER") || { echo 'The specified user does not exist.' >&2; exit 1; }
IFS=: read -r ACCOUNT _ ACCOUNT_UID ACCOUNT_GID _ ACCOUNT_HOME _ <<< "$USER_RECORD"
[[ $ACCOUNT_UID != 0 ]] || { echo 'The service account must not have UID 0.' >&2; exit 1; }
# Keep generated systemd syntax unambiguous; paths with spaces/control/specifier
# characters need a manually maintained unit rather than this small installer.
for value in "$PREFIX" "$DATA_DIR" "$ACCOUNT_HOME"; do
  [[ $value == /* && $value =~ ^/[a-zA-Z0-9_./@+-]+$ && $value != / && $value != *'/../'* && $value != */.. ]] || {
    echo 'Use absolute paths without spaces, control characters or parent traversal.' >&2; exit 1;
  }
done
if [[ -n $CODEX_PATH ]]; then
  [[ $CODEX_PATH == /* && -x $CODEX_PATH && $CODEX_PATH =~ ^/[a-zA-Z0-9_./@+-]+$ ]] || {
    echo '--codex must name an executable at an absolute path without spaces.' >&2; exit 1;
  }
fi
for command in systemctl install runuser; do
  command -v "$command" >/dev/null || { echo "Required command missing: $command" >&2; exit 1; }
done
PACKAGE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -f $PACKAGE_DIR/CodexLink.Server ]] || { echo 'Run this script from the extracted Linux release package.' >&2; exit 1; }
[[ ! -L $DATA_DIR ]] || { echo 'The state directory must not be a symlink.' >&2; exit 1; }
[[ ! -L $DATA_DIR/config.json && ! -L $DATA_DIR/access-token.txt ]] || { echo 'State files must not be symlinks.' >&2; exit 1; }
if [[ -e $DATA_DIR/config.json && ! -f $DATA_DIR/config.json ]]; then
  echo 'Existing config.json is not a regular file.' >&2; exit 1
fi
if [[ ! -e $DATA_DIR/config.json && -e $DATA_DIR/access-token.txt ]]; then
  echo 'Found a token without config.json. Restore the matching configuration before installing.' >&2; exit 1
fi

install -d -m 0755 "$PREFIX"
install -d -m 0700 -o "$ACCOUNT_UID" -g "$ACCOUNT_GID" "$DATA_DIR"
install -m 0755 "$PACKAGE_DIR/CodexLink.Server" "$PREFIX/CodexLink.Server.next"
if [[ -f $PREFIX/CodexLink.Server ]]; then
  cp -p -- "$PREFIX/CodexLink.Server" "$PREFIX/CodexLink.Server.previous"
fi
mv -f -- "$PREFIX/CodexLink.Server.next" "$PREFIX/CodexLink.Server"
for name in README.md README.zh-CN.md LICENSE THIRD_PARTY_NOTICES.md build-info.json config.example.json devices.example.json access-token.example.txt; do
  [[ ! -f $PACKAGE_DIR/$name ]] || install -m 0644 "$PACKAGE_DIR/$name" "$PREFIX/$name"
done
if [[ -d $PACKAGE_DIR/licenses ]]; then
  install -d -m 0755 "$PREFIX/licenses"
  for file in "$PACKAGE_DIR"/licenses/*; do
    [[ ! -f $file ]] || install -m 0644 "$file" "$PREFIX/licenses/"
  done
fi
if [[ ! -e $DATA_DIR/config.json ]]; then
  # --init generates a fresh random credential and uses the private directory.
  runuser -u "$ACCOUNT" -- env CODEXLINK_DATA="$DATA_DIR" "$PREFIX/CodexLink.Server" --init
  if [[ -n $CODEX_PATH ]]; then
    # The validated path contains no JSON escape characters.
    sed -i -E "s|(\"codexPath\":[[:space:]]*)\"codex\"|\1\"$CODEX_PATH\"|" "$DATA_DIR/config.json"
  fi
fi
chown "$ACCOUNT_UID:$ACCOUNT_GID" "$DATA_DIR/config.json"
chmod 0600 "$DATA_DIR/config.json"
if [[ -f $DATA_DIR/access-token.txt ]]; then
  chown "$ACCOUNT_UID:$ACCOUNT_GID" "$DATA_DIR/access-token.txt"
  chmod 0600 "$DATA_DIR/access-token.txt"
fi
UNIT=/etc/systemd/system/codexlink.service
install -d -m 0755 /etc/systemd/system
[[ ! -f $UNIT ]] || cp -p -- "$UNIT" "$UNIT.previous"
cat > "$UNIT" <<UNIT
[Unit]
Description=CodexLink gateway
After=network.target

[Service]
Type=simple
User=$ACCOUNT
Group=$ACCOUNT_GID
WorkingDirectory=$PREFIX
Environment="CODEXLINK_DATA=$DATA_DIR"
Environment="HOME=$ACCOUNT_HOME"
Environment="PATH=$ACCOUNT_HOME/.local/bin:$ACCOUNT_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$PREFIX/CodexLink.Server
Restart=on-failure
RestartSec=3
# Preserve the independently managed shared Codex daemon.
KillMode=process
TimeoutStopSec=15
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "$UNIT"
systemctl daemon-reload
systemctl enable codexlink.service
systemctl restart codexlink.service
systemctl is-active --quiet codexlink.service
printf 'Installed and restarted codexlink.service\nProgram: %s\nPrivate state: %s\nService user: %s\n' "$PREFIX" "$DATA_DIR" "$ACCOUNT"
echo 'Check status with: sudo systemctl status codexlink.service'
echo 'Startup journal contains the GUI token; keep it private.'

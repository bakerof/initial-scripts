#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Orange Pi Scanner Appliance initial setup
# Target: Armbian/Ubuntu (tested design for Armbian 26.2.1 Noble)
# Scanner: Epson GT-2500 / ES-H300, USB ID 04b8:012b
# ============================================================

HOSTNAME_FIXED="scanner"
TIMEZONE_DEFAULT="Europe/Moscow"
SSH_PORT_DEFAULT="1978"
APP_DIR="/opt/scanner"
CONFIG_DIR="/etc/scanner"
DATA_DIR="/var/lib/scanner"
SERVICE_USER="scanservice"
SERVICE_GROUP="scanservice"
SCANNER_GROUP="scanner"
LOG_FILE="/var/log/scanner-initial-setup-$(date +%F_%H-%M-%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1

info() { echo; echo "==> $*"; }
warn() { echo; echo "WARNING: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

need_tty() { [[ -r /dev/tty ]] || die "Не найден /dev/tty. Запусти скрипт из интерактивной консоли."; }

prompt_value() {
    local var_name="$1" prompt_text="$2" default_value="${3:-}" value=""
    while true; do
        if [[ -n "$default_value" ]]; then
            read -r -p "${prompt_text} [${default_value}]: " value < /dev/tty
            value="${value:-$default_value}"
        else
            read -r -p "${prompt_text}: " value < /dev/tty
        fi
        if [[ -n "$value" ]]; then printf -v "$var_name" '%s' "$value"; return 0; fi
        echo "Значение не может быть пустым."
    done
}

prompt_password_confirm() {
    local var_name="$1" prompt_text="$2" pass1="" pass2=""
    while true; do
        read -r -s -p "$prompt_text: " pass1 < /dev/tty; echo
        read -r -s -p "Повторите пароль: " pass2 < /dev/tty; echo
        [[ -n "$pass1" ]] || { echo "Пароль не может быть пустым."; continue; }
        [[ "$pass1" == "$pass2" ]] || { echo "Пароли не совпадают."; continue; }
        printf -v "$var_name" '%s' "$pass1"; return 0
    done
}

validate_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Некорректное имя пользователя: $1"
    [[ "$1" != "$SERVICE_USER" ]] || die "Имя $SERVICE_USER зарезервировано для scanner service."
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] || die "SSH-порт должен быть числом."
    (( $1 >= 1 && $1 <= 65535 )) || die "SSH-порт должен быть 1..65535."
}

[[ "$EUID" -eq 0 ]] || die "Скрипт нужно запускать от root (sudo bash ...)."
need_tty

[[ -r /etc/os-release ]] || die "Не найден /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release

if [[ ! -f /etc/armbian-release && "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
    die "Ожидался Armbian/Ubuntu/Debian. Сейчас: ${PRETTY_NAME:-unknown}"
fi

ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

prompt_value NEW_USER "Введите имя администратора Linux" "admin"
validate_username "$NEW_USER"
prompt_password_confirm NEW_PASSWORD "Введите пароль пользователя $NEW_USER"
prompt_value SSH_PORT "Введите SSH-порт" "$SSH_PORT_DEFAULT"
validate_port "$SSH_PORT"
prompt_value TIMEZONE "Введите таймзону" "$TIMEZONE_DEFAULT"
prompt_value WEB_USER "Введите имя пользователя Web UI" "admin"
prompt_password_confirm WEB_PASSWORD "Введите пароль Web UI"

cat <<EOF

Проверь параметры:
  OS:            ${PRETTY_NAME:-unknown}
  Architecture:  $ARCH
  Hostname:      $HOSTNAME_FIXED
  Linux user:    $NEW_USER
  SSH port:      $SSH_PORT
  Timezone:      $TIMEZONE
  Web UI:        http://$HOSTNAME_FIXED.local/
  Web user:      $WEB_USER
  Scan default:  200 dpi / Color / A4 / 64 colors / JPEG Q65 (editable in Web UI)
  Web Duplex:    тот же профиль / Duplex
  SMB:           настраивается через Web UI

APT mirrors не изменяются. apt upgrade автоматически НЕ выполняется.
EOF
read -r -p "Продолжить? [y/N]: " ANSWER < /dev/tty
case "$ANSWER" in y|Y|yes|YES|Yes|д|Д|да|ДА) ;; *) die "Отменено." ;; esac

info "apt update"
apt-get update

info "Устанавливаем зависимости"
DEBIAN_FRONTEND=noninteractive apt-get -y install \
    sudo openssh-server ca-certificates curl wget gnupg lsb-release \
    nano htop net-tools iproute2 dnsutils jq git unzip zip rsync bash-completion \
    usbutils sane-utils libsane1 libsane-common \
    smbclient cifs-utils img2pdf \
    avahi-daemon avahi-utils \
    python3 python3-pil python3-flask gunicorn

info "Настраиваем timezone и hostname"
timedatectl set-timezone "$TIMEZONE"
hostnamectl set-hostname "$HOSTNAME_FIXED"
if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 $HOSTNAME_FIXED/" /etc/hosts
else
    printf '127.0.1.1 %s\n' "$HOSTNAME_FIXED" >> /etc/hosts
fi

# If Netplan already contains an explicit DHCP hostname (for example from a previous setup),
# replace only that value. We do not create or rewrite network topology.
if compgen -G '/etc/netplan/*.yaml' >/dev/null && grep -RqsE '^[[:space:]]*hostname:[[:space:]]*' /etc/netplan/*.yaml; then
    info "Обновляем существующий DHCP hostname в Netplan -> $HOSTNAME_FIXED"
    NETPLAN_BACKUP="/root/netplan-backup-$(date +%F_%H-%M-%S)"
    mkdir -p "$NETPLAN_BACKUP"
    cp -a /etc/netplan/*.yaml "$NETPLAN_BACKUP/"
    sed -i -E "s/^([[:space:]]*hostname:[[:space:]]*).*/\1$HOSTNAME_FIXED/" /etc/netplan/*.yaml
    if command -v netplan >/dev/null 2>&1; then
        netplan generate || die "Netplan validation failed. Backup: $NETPLAN_BACKUP"
        networkctl reload 2>/dev/null || true
        for iface_path in /sys/class/net/e*; do
            [[ -e "$iface_path" ]] || continue
            networkctl renew "$(basename "$iface_path")" 2>/dev/null || true
        done
    fi
fi

info "Создаем/настраиваем Linux пользователя $NEW_USER"
if ! id "$NEW_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$NEW_USER"
fi
echo "$NEW_USER:$NEW_PASSWORD" | chpasswd
usermod -aG sudo "$NEW_USER"

info "Настраиваем SSH"
cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%F_%H-%M-%S)"
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]|$)' /etc/ssh/sshd_config; then
    printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >> /etc/ssh/sshd_config
fi
mkdir -p /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/00-initial-setup.conf <<EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
X11Forwarding no
EOF
install -d -o root -g root -m 0755 /run/sshd
sshd -t
EFFECTIVE_SSH_PORT="$(sshd -T | awk '$1 == "port" {print $2; exit}')"
[[ "$EFFECTIVE_SSH_PORT" == "$SSH_PORT" ]] || die "sshd фактически выбрал порт $EFFECTIVE_SSH_PORT вместо $SSH_PORT. Проверь ранние директивы в sshd_config."
systemctl enable ssh
systemctl restart ssh

info "Создаем service account"
getent group "$SERVICE_GROUP" >/dev/null || groupadd --system "$SERVICE_GROUP"
getent group "$SCANNER_GROUP" >/dev/null || groupadd --system "$SCANNER_GROUP"
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --gid "$SERVICE_GROUP" --home-dir "$DATA_DIR" --create-home --shell /usr/sbin/nologin "$SERVICE_USER"
else
    usermod -g "$SERVICE_GROUP" "$SERVICE_USER"
fi
usermod -aG "$SCANNER_GROUP" "$SERVICE_USER"
if getent group systemd-journal >/dev/null; then
    usermod -aG systemd-journal "$SERVICE_USER"
fi

info "Настраиваем udev для Epson GT-2500 / ES-H300"
cat >/etc/udev/rules.d/70-epson-gt2500-scanner.rules <<EOF
SUBSYSTEM=="usb", ATTR{idVendor}=="04b8", ATTR{idProduct}=="012b", MODE="0660", GROUP="$SCANNER_GROUP"
EOF
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb || true

# Ensure epson2 backend is enabled. On current SANE packages it normally is.
if [[ -f /etc/sane.d/dll.conf ]] && ! grep -Eq '^[[:space:]]*epson2[[:space:]]*$' /etc/sane.d/dll.conf; then
    echo 'epson2' >> /etc/sane.d/dll.conf
fi

info "Создаем директории приложения"
install -d -o root -g root -m 0755 "$APP_DIR"
install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0700 "$CONFIG_DIR"
install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0700 "$DATA_DIR" "$DATA_DIR/spool" "$DATA_DIR/work"

if [[ ! -f "$CONFIG_DIR/config.json" ]]; then
cat >"$CONFIG_DIR/config.json" <<'EOF'
{
  "smb_path": "",
  "smb_username": "",
  "smb_domain": "",
  "scan_dpi": 200,
  "scan_mode": "Color",
  "scan_width_mm": 210,
  "scan_height_mm": 297,
  "palette_colors": 64,
  "jpeg_quality": 65
}
EOF
fi
chown "$SERVICE_USER:$SERVICE_GROUP" "$CONFIG_DIR/config.json"
chmod 0600 "$CONFIG_DIR/config.json"

info "Создаем Web UI credentials"
WEB_USER_ENV="$WEB_USER" WEB_PASSWORD_ENV="$WEB_PASSWORD" AUTH_FILE_ENV="$CONFIG_DIR/web-auth.json" python3 <<'PYAUTH'
import json, os
from pathlib import Path
from werkzeug.security import generate_password_hash
p = Path(os.environ['AUTH_FILE_ENV'])
data = {
    'username': os.environ['WEB_USER_ENV'],
    'password_hash': generate_password_hash(os.environ['WEB_PASSWORD_ENV']),
}
p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
os.chmod(p, 0o600)
PYAUTH
chown "$SERVICE_USER:$SERVICE_GROUP" "$CONFIG_DIR/web-auth.json"

if [[ ! -s "$CONFIG_DIR/web-secret" ]]; then
    python3 - <<'PYSECRET' >"$CONFIG_DIR/web-secret"
import secrets
print(secrets.token_hex(32))
PYSECRET
fi
chown "$SERVICE_USER:$SERVICE_GROUP" "$CONFIG_DIR/web-secret"
chmod 0600 "$CONFIG_DIR/web-secret"

info "Устанавливаем scanner application"
cat >"$APP_DIR/common.py" <<'PYCOMMON'
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any

CONFIG_DIR = Path('/etc/scanner')
CONFIG_FILE = CONFIG_DIR / 'config.json'
CREDS_FILE = CONFIG_DIR / 'smb-credentials'
AUTH_FILE = CONFIG_DIR / 'web-auth.json'
SECRET_FILE = CONFIG_DIR / 'web-secret'

DATA_DIR = Path('/var/lib/scanner')
SPOOL_DIR = DATA_DIR / 'spool'
WORK_DIR = DATA_DIR / 'work'
LAST_JOB_FILE = DATA_DIR / 'last-job.json'

RUN_DIR = Path('/run/scanner')
WORKER_STATE_FILE = RUN_DIR / 'worker-state.json'
UPLOAD_STATE_FILE = RUN_DIR / 'upload-state.json'
CHILD_PID_FILE = RUN_DIR / 'scanimage.pid'
DUPLEX_REQUEST_FILE = RUN_DIR / 'duplex.request'
RETRY_REQUEST_FILE = RUN_DIR / 'retry.request'
UPLOAD_LOCK_FILE = RUN_DIR / 'upload.lock'

DEFAULT_CONFIG = {
    'smb_path': '',
    'smb_username': '',
    'smb_domain': '',
    'scan_dpi': 200,
    'scan_mode': 'Color',
    'scan_width_mm': 210,
    'scan_height_mm': 297,
    'palette_colors': 64,
    'jpeg_quality': 65,
}


def load_json(path: Path, default: Any) -> Any:
    try:
        with path.open('r', encoding='utf-8') as fh:
            return json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return default


def atomic_write_json(path: Path, data: Any, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp')
    with tmp.open('w', encoding='utf-8') as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write('\n')
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def atomic_write_text(path: Path, text: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp')
    with tmp.open('w', encoding='utf-8') as fh:
        fh.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def load_config() -> dict[str, Any]:
    cfg = dict(DEFAULT_CONFIG)
    loaded = load_json(CONFIG_FILE, {})
    if isinstance(loaded, dict):
        for key, default in DEFAULT_CONFIG.items():
            value = loaded.get(key)
            if isinstance(default, int):
                if isinstance(value, int) and not isinstance(value, bool):
                    cfg[key] = value
            elif isinstance(default, str):
                if isinstance(value, str):
                    cfg[key] = value
    return cfg


def read_credentials() -> dict[str, str]:
    result = {'username': '', 'password': '', 'domain': ''}
    try:
        lines = CREDS_FILE.read_text(encoding='utf-8').splitlines()
    except OSError:
        return result
    for line in lines:
        if '=' not in line:
            continue
        key, value = line.split('=', 1)
        key = key.strip().lower()
        value = value.strip()
        if key in result:
            result[key] = value
    return result


def validate_single_line(value: str, field: str) -> str:
    if '\n' in value or '\r' in value:
        raise ValueError(f'{field}: переносы строк недопустимы')
    return value.strip()


def save_smb_settings(path: str, username: str, password: str | None, domain: str) -> None:
    path = validate_single_line(path, 'SMB path')
    username = validate_single_line(username, 'SMB username')
    domain = validate_single_line(domain, 'SMB domain')
    if password is not None:
        validate_single_line(password, 'SMB password')

    if path:
        parse_smb_path(path)
        if not username:
            raise ValueError('Для SMB нужно указать имя пользователя')

    old = read_credentials()
    effective_password = old.get('password', '') if password is None else password

    cfg = load_config()
    cfg.update({
        'smb_path': path,
        'smb_username': username,
        'smb_domain': domain,
    })
    atomic_write_json(CONFIG_FILE, cfg)

    if path or username or effective_password or domain:
        lines = [f'username = {username}', f'password = {effective_password}']
        if domain:
            lines.append(f'domain = {domain}')
        atomic_write_text(CREDS_FILE, '\n'.join(lines) + '\n', 0o600)



def _parse_int_setting(value: str, field: str, minimum: int, maximum: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        raise ValueError(f'{field}: требуется целое число')
    if not minimum <= number <= maximum:
        raise ValueError(f'{field}: допустимо {minimum}..{maximum}')
    return number


def save_scan_settings(
    dpi: str,
    scan_mode: str,
    width_mm: str,
    height_mm: str,
    palette_colors: str,
    jpeg_quality: str,
) -> None:
    dpi_i = _parse_int_setting(dpi, 'DPI', 75, 600)
    width_i = _parse_int_setting(width_mm, 'Ширина', 50, 216)
    height_i = _parse_int_setting(height_mm, 'Высота', 50, 356)
    colors_i = _parse_int_setting(palette_colors, 'Количество цветов', 2, 256)
    quality_i = _parse_int_setting(jpeg_quality, 'JPEG quality', 30, 95)

    scan_mode = validate_single_line(scan_mode, 'Режим')
    if scan_mode not in {'Color', 'Gray'}:
        raise ValueError('Режим: допустимы только Color или Gray')

    cfg = load_config()
    cfg.update({
        'scan_dpi': dpi_i,
        'scan_mode': scan_mode,
        'scan_width_mm': width_i,
        'scan_height_mm': height_i,
        'palette_colors': colors_i,
        'jpeg_quality': quality_i,
    })
    atomic_write_json(CONFIG_FILE, cfg)

def parse_smb_path(raw: str) -> tuple[str, str]:
    normalized = raw.strip().replace('\\', '/')
    parts = [p for p in normalized.split('/') if p]
    if len(parts) < 2:
        raise ValueError('SMB путь должен быть вида //server/share или //server/share/folder')
    server, share = parts[0], parts[1]
    if not server or not share:
        raise ValueError('Некорректный SMB путь')
    remote_dir = '/'.join(parts[2:])
    return f'//{server}/{share}', remote_dir


def _smb_quote(value: str) -> str:
    return value.replace('\\', '\\\\').replace('"', '\\"')


def smb_test(timeout: int = 15) -> tuple[bool, str]:
    cfg = load_config()
    if not cfg['smb_path']:
        return False, 'SMB путь не настроен'
    if not CREDS_FILE.exists():
        return False, 'SMB credentials не настроены'
    try:
        share, remote_dir = parse_smb_path(cfg['smb_path'])
    except ValueError as exc:
        return False, str(exc)

    command = 'ls'
    if remote_dir:
        command = f'cd "{_smb_quote(remote_dir)}"; ls'
    try:
        proc = subprocess.run(
            ['smbclient', share, '-A', str(CREDS_FILE), '-c', command],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, f'SMB: {exc}'

    output = (proc.stdout or '').strip()
    if proc.returncode == 0:
        return True, 'SMB доступен'
    tail = output.splitlines()[-1] if output else f'код {proc.returncode}'
    return False, tail[:300]


def smb_upload(local_path: Path, timeout: int = 30) -> tuple[bool, str]:
    cfg = load_config()
    if not cfg['smb_path'] or not CREDS_FILE.exists():
        return False, 'SMB не настроен'
    try:
        share, remote_dir = parse_smb_path(cfg['smb_path'])
    except ValueError as exc:
        return False, str(exc)

    commands: list[str] = []
    if remote_dir:
        commands.append(f'cd "{_smb_quote(remote_dir)}"')
    commands.append(f'put "{_smb_quote(str(local_path))}" "{_smb_quote(local_path.name)}"')

    try:
        proc = subprocess.run(
            ['smbclient', share, '-A', str(CREDS_FILE), '-c', '; '.join(commands)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, f'SMB upload: {exc}'

    output = (proc.stdout or '').strip()
    if proc.returncode == 0:
        return True, 'uploaded'
    tail = output.splitlines()[-1] if output else f'код {proc.returncode}'
    return False, tail[:300]
PYCOMMON

cat >"$APP_DIR/worker.py" <<'PYWORKER'
from __future__ import annotations

import fcntl
import logging
import os
import shutil
import signal
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path

from PIL import Image

from common import (
    CHILD_PID_FILE,
    DUPLEX_REQUEST_FILE,
    LAST_JOB_FILE,
    RETRY_REQUEST_FILE,
    RUN_DIR,
    SPOOL_DIR,
    UPLOAD_LOCK_FILE,
    UPLOAD_STATE_FILE,
    WORKER_STATE_FILE,
    WORK_DIR,
    atomic_write_json,
    load_config,
    smb_upload,
)

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
LOG = logging.getLogger('scanner-worker')
STOP = threading.Event()
STATE_LOCK = threading.Lock()
CURRENT_PROCESS: subprocess.Popen[str] | None = None

def set_worker_state(status: str, message: str = '', mode: str = '', sane: str = '') -> None:
    with STATE_LOCK:
        atomic_write_json(WORKER_STATE_FILE, {
            'status': status,
            'message': message,
            'mode': mode,
            'sane': sane,
            'updated_at': datetime.now().isoformat(timespec='seconds'),
        })


def set_upload_state(status: str, message: str = '', filename: str = '') -> None:
    atomic_write_json(UPLOAD_STATE_FILE, {
        'status': status,
        'message': message,
        'filename': filename,
        'updated_at': datetime.now().isoformat(timespec='seconds'),
    })


def stop_handler(signum, frame) -> None:  # noqa: ARG001
    STOP.set()
    proc = CURRENT_PROCESS
    if proc and proc.poll() is None:
        try:
            proc.terminate()
        except OSError:
            pass


def detect_sane() -> str:
    try:
        proc = subprocess.run(
            ['scanimage', '-L'],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return f'SANE error: {exc}'
    text = (proc.stdout or '').strip()
    if proc.returncode == 0 and text:
        return text.splitlines()[0][:500]
    return text.splitlines()[-1][:500] if text else 'Scanner not found by SANE'


def make_job_dir(mode: str) -> Path:
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    path = WORK_DIR / f'{stamp}-{mode.lower()}'
    suffix = 1
    while path.exists():
        path = WORK_DIR / f'{stamp}-{mode.lower()}-{suffix}'
        suffix += 1
    path.mkdir(parents=True, mode=0o700)
    return path



def get_scan_profile() -> dict[str, int | str]:
    cfg = load_config()
    return {
        'dpi': int(cfg.get('scan_dpi', 200)),
        'scan_mode': str(cfg.get('scan_mode', 'Color')),
        'width_mm': int(cfg.get('scan_width_mm', 210)),
        'height_mm': int(cfg.get('scan_height_mm', 297)),
        'palette_colors': int(cfg.get('palette_colors', 64)),
        'jpeg_quality': int(cfg.get('jpeg_quality', 65)),
    }


def profile_text(profile: dict[str, int | str]) -> str:
    mode = str(profile['scan_mode'])
    if mode == 'Color':
        compression = f"{profile['palette_colors']} colors / JPEG Q{profile['jpeg_quality']}"
    else:
        compression = f"Gray / JPEG Q{profile['jpeg_quality']}"
    return (
        f"{profile['dpi']} dpi / {mode} / "
        f"{profile['width_mm']}x{profile['height_mm']} mm / {compression}"
    )

def _run_scanimage_process(
    cmd: list[str],
    mode: str,
    sane_desc: str,
    job_dir: Path,
    *,
    stdout_file: Path | None = None,
    initial_status: str = 'scanning',
    initial_message: str = '',
    quiet: bool = False,
) -> tuple[int, list[str]]:
    global CURRENT_PROCESS

    set_worker_state(initial_status, initial_message, mode, sane_desc)
    if not quiet:
        LOG.info('Starting %s scan phase: %s', mode, ' '.join(cmd))

    output_lines: list[str] = []
    out_fh = None
    try:
        if stdout_file is not None:
            out_fh = stdout_file.open('wb')
            proc = subprocess.Popen(
                cmd,
                stdout=out_fh,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
        else:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
    except OSError as exc:
        if out_fh is not None:
            out_fh.close()
        set_worker_state('error', str(exc), mode, sane_desc)
        return 127, [str(exc)]

    CURRENT_PROCESS = proc
    CHILD_PID_FILE.write_text(str(proc.pid), encoding='ascii')
    os.chmod(CHILD_PID_FILE, 0o600)

    stream = proc.stderr if stdout_file is not None else proc.stdout

    def log_reader() -> None:
        if stream is None:
            return
        for line in stream:
            line = line.rstrip()
            if not line:
                continue
            output_lines.append(line)
            if not quiet:
                LOG.info('scanimage: %s', line)
                lower = line.lower()
                if 'scanning page' in lower or 'scanned page' in lower:
                    set_worker_state('scanning', f'{mode} scan in progress', mode, sane_desc)

    reader = threading.Thread(target=log_reader, name='scanimage-log', daemon=True)
    reader.start()

    while proc.poll() is None and not STOP.is_set():
        try:
            has_page_data = any(p.stat().st_size > 0 for p in job_dir.glob('page_*.tiff'))
        except OSError:
            has_page_data = False
        if has_page_data:
            set_worker_state('scanning', f'{mode} scan in progress', mode, sane_desc)
        time.sleep(0.2)

    if STOP.is_set() and proc.poll() is None:
        proc.terminate()

    rc = proc.wait()
    reader.join(timeout=2)
    if out_fh is not None:
        out_fh.close()
    CURRENT_PROCESS = None
    try:
        CHILD_PID_FILE.unlink()
    except FileNotFoundError:
        pass
    return rc, output_lines


def run_scan(mode: str, wait_for_button: bool) -> bool:
    # Do not start a new document if the local safety spool is nearly full.
    try:
        free_bytes = shutil.disk_usage('/var/lib/scanner').free
    except OSError:
        free_bytes = 0
    if free_bytes and free_bytes < 256 * 1024 * 1024:
        set_worker_state('error', 'Недостаточно места: свободно менее 256 MB', mode)
        LOG.error('Not enough free disk space to start scan: %s bytes', free_bytes)
        time.sleep(10)
        return False

    job_dir = make_job_dir(mode)
    batch_pattern = str(job_dir / 'page_%04d.tiff')
    sane_desc = detect_sane()
    profile = get_scan_profile()
    LOG.info('Scan profile: %s', profile_text(profile))
    base_cmd = [
        'scanimage',
        '--source', 'Automatic Document Feeder',
        '--adf-mode', mode,
        '--resolution', str(profile['dpi']),
        '--mode', str(profile['scan_mode']),
        '-l', '0',
        '-t', '0',
        '-x', str(profile['width_mm']),
        '-y', str(profile['height_mm']),
        '--format=tiff',
    ]

    scanimage_rc = 0

    if wait_for_button:
        # Epson epson2 waits for the physical button only for this first page.
        # Using --wait-for-button together with --batch would wait again before
        # every following page, so Simplex is intentionally two-stage:
        #   1) first page -> stdout, with --wait-for-button=yes
        #   2) remaining ADF pages -> batch, without --wait-for-button
        first_page = job_dir / 'page_0001.tiff'
        first_cmd = [*base_cmd, '--wait-for-button=yes']
        rc_first, first_output = _run_scanimage_process(
            first_cmd,
            mode,
            sane_desc,
            job_dir,
            stdout_file=first_page,
            initial_status='waiting',
            initial_message='Ожидание физической кнопки Epson',
            quiet=True,
        )

        if STOP.is_set():
            shutil.rmtree(job_dir, ignore_errors=True)
            return False

        # Web Duplex deliberately interrupts the idle first-page waiter.
        if DUPLEX_REQUEST_FILE.exists() and (not first_page.exists() or first_page.stat().st_size == 0):
            LOG.info('Simplex button wait interrupted for pending duplex request')
            shutil.rmtree(job_dir, ignore_errors=True)
            return False

        if not first_page.exists() or first_page.stat().st_size == 0:
            try:
                first_page.unlink()
            except FileNotFoundError:
                pass
            # Empty ADF before a real job is an idle condition, not a scanner error.
            text = '\n'.join(first_output).lower()
            if rc_first == 7 or 'document feeder out of documents' in text:
                set_worker_state('waiting', 'Ожидание документа и физической кнопки Epson', mode, sane_desc)
                shutil.rmtree(job_dir, ignore_errors=True)
                return False

            LOG.warning('First-page scanimage exited rc=%s without a page', rc_first)
            set_worker_state('error', f'scanimage rc={rc_first}; first page missing', mode, sane_desc)
            shutil.rmtree(job_dir, ignore_errors=True)
            time.sleep(5)
            return False

        scanimage_rc = rc_first
        set_worker_state('scanning', 'Simplex: первый лист получен, сканируем остаток ADF', mode, sane_desc)

        rest_cmd = [
            *base_cmd,
            f'--batch={batch_pattern}',
            '--batch-start=2',
        ]
        rc_rest, _ = _run_scanimage_process(
            rest_cmd,
            mode,
            sane_desc,
            job_dir,
            initial_status='scanning',
            initial_message='Simplex: сканирование остатка ADF',
        )
        scanimage_rc = rc_rest
    else:
        # Web Duplex starts immediately and scans the complete ADF as one batch.
        cmd = [*base_cmd, f'--batch={batch_pattern}']
        scanimage_rc, _ = _run_scanimage_process(
            cmd,
            mode,
            sane_desc,
            job_dir,
            initial_status='scanning',
            initial_message='Duplex scan',
        )

    pages = sorted(p for p in job_dir.glob('page_*.tiff') if p.stat().st_size > 0)
    if not pages:
        LOG.warning('scanimage exited rc=%s without pages', scanimage_rc)
        set_worker_state('error', f'scanimage rc={scanimage_rc}; pages=0', mode, sane_desc)
        shutil.rmtree(job_dir, ignore_errors=True)
        time.sleep(5)
        return False

    # For ADF batch mode rc=7 after the final page means simply "feeder empty".
    # A job with one or more real TIFF pages is therefore valid regardless of
    # the final feeder-empty return code.
    #
    # Scanner acquisition stays lossless TIFF. Before PDF assembly each page
    # is reduced to an adaptive 64-colour palette and encoded as JPEG Q65.
    # img2pdf then embeds those JPEG streams without recompressing them.
    set_worker_state(
        'processing',
        f"Оптимизация {profile_text(profile)}: {len(pages)} стр.",
        mode,
        sane_desc,
    )

    jpeg_pages: list[Path] = []
    try:
        for index, tiff_path in enumerate(pages, start=1):
            jpeg_path = job_dir / f'compressed_{index:04d}.jpg'
            with Image.open(tiff_path) as image:
                if profile['scan_mode'] == 'Color':
                    rgb = image.convert('RGB')
                    prepared = rgb.quantize(
                        colors=int(profile['palette_colors']),
                        method=Image.Quantize.FASTOCTREE,
                        dither=Image.Dither.NONE,
                    ).convert('RGB')
                    prepared.save(
                        jpeg_path,
                        'JPEG',
                        quality=int(profile['jpeg_quality']),
                        subsampling=2,
                        optimize=True,
                        dpi=(int(profile['dpi']), int(profile['dpi'])),
                    )
                else:
                    prepared = image.convert('L')
                    prepared.save(
                        jpeg_path,
                        'JPEG',
                        quality=int(profile['jpeg_quality']),
                        optimize=True,
                        dpi=(int(profile['dpi']), int(profile['dpi'])),
                    )
            if not jpeg_path.exists() or jpeg_path.stat().st_size == 0:
                raise RuntimeError(f'JPEG conversion produced empty file: {jpeg_path.name}')
            jpeg_pages.append(jpeg_path)
    except Exception as exc:
        LOG.error('JPEG optimization failed: %s', exc)
        set_worker_state('error', f'JPEG optimization: {exc}', mode, sane_desc)
        return False

    stamp = datetime.now().strftime('%Y-%m-%d_%H-%M-%S')
    pdf_tmp = job_dir / f'scan_{stamp}.pdf'
    try:
        result = subprocess.run(
            ['img2pdf', *[str(p) for p in jpeg_pages], '-o', str(pdf_tmp)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=180,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        LOG.error('img2pdf failed: %s', exc)
        set_worker_state('error', f'img2pdf: {exc}', mode, sane_desc)
        return False

    if result.returncode != 0 or not pdf_tmp.exists() or pdf_tmp.stat().st_size == 0:
        message = (result.stdout or '').strip().splitlines()
        tail = message[-1] if message else f'rc={result.returncode}'
        LOG.error('img2pdf failed: %s', tail)
        set_worker_state('error', f'img2pdf: {tail[:250]}', mode, sane_desc)
        return False

    SPOOL_DIR.mkdir(parents=True, exist_ok=True)
    target = SPOOL_DIR / pdf_tmp.name
    suffix = 1
    while target.exists():
        target = SPOOL_DIR / f'{pdf_tmp.stem}_{suffix}.pdf'
        suffix += 1
    shutil.move(str(pdf_tmp), str(target))

    last_job = {
        'filename': target.name,
        'pages': len(pages),
        'mode': mode,
        'scan_profile': profile_text(profile),
        'scanimage_rc': scanimage_rc,
        'created_at': datetime.now().isoformat(timespec='seconds'),
        'size_bytes': target.stat().st_size,
        'result': 'queued',
    }
    atomic_write_json(LAST_JOB_FILE, last_job)
    LOG.info('PDF created: %s (%s pages)', target, len(pages))
    shutil.rmtree(job_dir, ignore_errors=True)

    # Wake uploader immediately.
    RETRY_REQUEST_FILE.touch(mode=0o600, exist_ok=True)
    set_worker_state('idle', f'PDF готов: {target.name}', mode, sane_desc)
    return True

def upload_queue_once() -> None:
    cfg = load_config()
    if not cfg.get('smb_path'):
        set_upload_state('not_configured', 'SMB путь не настроен')
        return

    UPLOAD_LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    with UPLOAD_LOCK_FILE.open('a+', encoding='utf-8') as lockfh:
        try:
            fcntl.flock(lockfh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return

        files = sorted(SPOOL_DIR.glob('*.pdf'))
        if not files:
            set_upload_state('idle', 'Очередь пуста')
            return

        for pdf in files:
            if STOP.is_set():
                return
            set_upload_state('uploading', 'Отправка SMB', pdf.name)
            ok, message = smb_upload(pdf)
            if not ok:
                LOG.warning('SMB upload failed for %s: %s', pdf.name, message)
                set_upload_state('error', message, pdf.name)
                return
            try:
                pdf.unlink()
            except OSError as exc:
                LOG.error('Uploaded but cannot remove spool file %s: %s', pdf, exc)
                set_upload_state('error', f'Uploaded, local delete failed: {exc}', pdf.name)
                return
            LOG.info('SMB upload successful: %s', pdf.name)
            last_job = {}
            try:
                from common import load_json
                last_job = load_json(LAST_JOB_FILE, {})
            except Exception:
                last_job = {}
            if isinstance(last_job, dict) and last_job.get('filename') == pdf.name:
                last_job['result'] = 'uploaded'
                last_job['uploaded_at'] = datetime.now().isoformat(timespec='seconds')
                atomic_write_json(LAST_JOB_FILE, last_job)
            set_upload_state('ok', 'SMB upload successful', pdf.name)


def uploader_loop() -> None:
    next_periodic = 0.0
    while not STOP.is_set():
        now = time.monotonic()
        forced = RETRY_REQUEST_FILE.exists()
        if forced:
            try:
                RETRY_REQUEST_FILE.unlink()
            except FileNotFoundError:
                pass
        if forced or now >= next_periodic:
            upload_queue_once()
            next_periodic = time.monotonic() + 60.0
        STOP.wait(2.0)


def main() -> None:
    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)

    RUN_DIR.mkdir(parents=True, exist_ok=True)
    SPOOL_DIR.mkdir(parents=True, exist_ok=True)
    WORK_DIR.mkdir(parents=True, exist_ok=True)

    sane_desc = detect_sane()
    LOG.info('SANE: %s', sane_desc)
    set_worker_state('starting', 'Worker started', '', sane_desc)

    uploader = threading.Thread(target=uploader_loop, name='smb-uploader', daemon=True)
    uploader.start()

    while not STOP.is_set():
        if DUPLEX_REQUEST_FILE.exists():
            try:
                DUPLEX_REQUEST_FILE.unlink()
            except FileNotFoundError:
                pass
            run_scan('Duplex', wait_for_button=False)
            if not STOP.is_set():
                time.sleep(1)
            continue

        run_scan('Simplex', wait_for_button=True)
        if not STOP.is_set():
            time.sleep(0.5)

    set_worker_state('stopped', 'Worker stopped')
    uploader.join(timeout=3)


if __name__ == '__main__':
    main()
PYWORKER

cat >"$APP_DIR/app.py" <<'PYAPP'
from __future__ import annotations

import json
import os
import shutil
import signal
import socket
import subprocess
from functools import wraps
from pathlib import Path

from flask import Flask, Response, flash, redirect, render_template_string, request, url_for
from werkzeug.security import check_password_hash

from common import (
    AUTH_FILE,
    CHILD_PID_FILE,
    CREDS_FILE,
    DUPLEX_REQUEST_FILE,
    LAST_JOB_FILE,
    RETRY_REQUEST_FILE,
    SECRET_FILE,
    SPOOL_DIR,
    UPLOAD_STATE_FILE,
    WORKER_STATE_FILE,
    load_config,
    load_json,
    read_credentials,
    save_scan_settings,
    save_smb_settings,
    smb_test,
)

app = Flask(__name__)
try:
    app.secret_key = SECRET_FILE.read_text(encoding='utf-8').strip()
except OSError:
    app.secret_key = 'scanner-fallback-secret-change-me'


def auth_required(fn):
    @wraps(fn)
    def wrapped(*args, **kwargs):
        data = load_json(AUTH_FILE, {})
        auth = request.authorization
        if (
            not auth
            or auth.username != data.get('username')
            or not check_password_hash(data.get('password_hash', ''), auth.password or '')
        ):
            return Response('Authentication required', 401, {'WWW-Authenticate': 'Basic realm="scanner"'})
        return fn(*args, **kwargs)
    return wrapped


def fmt_bytes(value: int) -> str:
    size = float(value)
    for unit in ('B', 'KB', 'MB', 'GB', 'TB'):
        if size < 1024 or unit == 'TB':
            return f'{size:.1f} {unit}'
        size /= 1024
    return f'{size:.1f} TB'


def system_status() -> dict[str, str]:
    result: dict[str, str] = {'hostname': socket.gethostname()}
    try:
        ip_out = subprocess.run(
            ['ip', '-4', '-br', 'addr', 'show', 'up'],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=3,
            check=False,
        ).stdout
        ips = []
        for line in ip_out.splitlines():
            fields = line.split()
            if not fields or fields[0] == 'lo':
                continue
            for field in fields[2:]:
                if '/' in field and field[0].isdigit():
                    ips.append(f'{fields[0]}: {field}')
        result['ip'] = ', '.join(ips) if ips else '—'
    except Exception:
        result['ip'] = '—'

    try:
        uptime = int(float(Path('/proc/uptime').read_text().split()[0]))
        days, rem = divmod(uptime, 86400)
        hours, rem = divmod(rem, 3600)
        minutes = rem // 60
        result['uptime'] = f'{days}d {hours}h {minutes}m' if days else f'{hours}h {minutes}m'
    except Exception:
        result['uptime'] = '—'

    try:
        load1, load5, load15 = os.getloadavg()
        result['load'] = f'{load1:.2f} / {load5:.2f} / {load15:.2f}'
    except OSError:
        result['load'] = '—'

    temp = '—'
    for candidate in Path('/sys/class/thermal').glob('thermal_zone*/temp'):
        try:
            raw = float(candidate.read_text().strip())
            temp = f'{raw / 1000:.1f} °C' if raw > 1000 else f'{raw:.1f} °C'
            break
        except Exception:
            continue
    result['temp'] = temp

    try:
        meminfo = {}
        for line in Path('/proc/meminfo').read_text().splitlines():
            if ':' in line:
                key, val = line.split(':', 1)
                meminfo[key] = int(val.strip().split()[0]) * 1024
        total = meminfo.get('MemTotal', 0)
        avail = meminfo.get('MemAvailable', 0)
        used = max(total - avail, 0)
        result['ram'] = f'{fmt_bytes(used)} / {fmt_bytes(total)}'
    except Exception:
        result['ram'] = '—'

    try:
        disk = shutil.disk_usage('/var/lib/scanner')
        result['disk'] = f'{fmt_bytes(disk.free)} free / {fmt_bytes(disk.total)}'
    except OSError:
        result['disk'] = '—'
    return result



def queue_stats() -> tuple[int, str]:
    count = 0
    total = 0
    for path in SPOOL_DIR.glob('*.pdf'):
        try:
            stat = path.stat()
        except OSError:
            continue
        count += 1
        total += stat.st_size
    return count, fmt_bytes(total)


def usb_status() -> str:
    try:
        proc = subprocess.run(
            ['lsusb'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, timeout=5, check=False
        )
    except Exception:
        return 'lsusb error'
    for line in proc.stdout.splitlines():
        lower = line.lower()
        if '04b8:012b' in lower:
            return line
    for line in proc.stdout.splitlines():
        if 'epson' in line.lower() or '04b8:' in line.lower():
            return line
    return 'not connected'


def journal_tail() -> str:
    try:
        proc = subprocess.run(
            ['journalctl', '-u', 'scanner-worker.service', '-n', '30', '--no-pager', '-o', 'cat'],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=5,
            check=False,
        )
        return (proc.stdout or '').strip()
    except Exception as exc:
        return f'journalctl: {exc}'


PAGE = r'''<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Scanner</title>
<style>
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#f4f5f7;margin:0;color:#202124}
main{max-width:980px;margin:24px auto;padding:0 16px}.card{background:#fff;border:1px solid #ddd;border-radius:10px;padding:18px;margin-bottom:16px}
h1{margin:0 0 16px;font-size:28px}h2{font-size:18px;margin:0 0 12px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px}
.item{background:#f8f9fa;border-radius:7px;padding:10px}.label{font-size:12px;color:#666}.value{font-weight:600;margin-top:3px;word-break:break-word}
.ok{color:#177245}.bad{color:#b3261e}.wait{color:#8a5700}label{display:block;font-size:13px;margin:10px 0 4px}input,select{width:100%;box-sizing:border-box;padding:9px;border:1px solid #bbb;border-radius:6px;background:#fff}
button{padding:9px 13px;margin:8px 6px 0 0;border:1px solid #aaa;border-radius:6px;background:#fff;cursor:pointer}button.primary{background:#1a73e8;color:#fff;border-color:#1a73e8}button.danger{background:#b3261e;color:#fff;border-color:#b3261e}
.flash{padding:10px;border-radius:6px;background:#e8f0fe;margin-bottom:10px}pre{white-space:pre-wrap;background:#111;color:#ddd;padding:12px;border-radius:7px;max-height:320px;overflow:auto;font-size:12px}
small{color:#666}
</style>
</head><body><main>
<h1>Scanner</h1>
{% with messages = get_flashed_messages() %}{% for message in messages %}<div class="flash">{{ message }}</div>{% endfor %}{% endwith %}
<div class="card"><h2>Состояние</h2><div class="grid">
<div class="item"><div class="label">Scanner worker</div><div class="value">{{ worker.status or '—' }}{% if worker.mode %} / {{ worker.mode }}{% endif %}</div><small>{{ worker.message or '' }}</small></div>
<div class="item"><div class="label">USB scanner</div><div class="value">{{ usb }}</div></div>
<div class="item"><div class="label">SANE</div><div class="value">{{ worker.sane or '—' }}</div></div>
<div class="item"><div class="label">SMB</div><div class="value">{{ upload.status or ('configured' if configured else 'not configured') }}</div><small>{{ upload.message or '' }}</small></div>
<div class="item"><div class="label">Очередь</div><div class="value">{{ queue_count }} file(s), {{ queue_size }}</div></div>
<div class="item"><div class="label">Последний скан</div><div class="value">{% if last.filename %}{{ last.filename }}{% else %}—{% endif %}</div><small>{% if last.pages %}{{ last.pages }} стр., {{ last.mode }}, {{ last.result }}{% endif %}{% if last.scan_profile %}<br>{{ last.scan_profile }}{% endif %}</small></div>
</div></div>

<div class="card"><h2>Orange Pi</h2><div class="grid">
<div class="item"><div class="label">Hostname</div><div class="value">{{ sys.hostname }}</div></div>
<div class="item"><div class="label">IP</div><div class="value">{{ sys.ip }}</div></div>
<div class="item"><div class="label">Uptime</div><div class="value">{{ sys.uptime }}</div></div>
<div class="item"><div class="label">CPU temperature</div><div class="value">{{ sys.temp }}</div></div>
<div class="item"><div class="label">Load 1/5/15</div><div class="value">{{ sys.load }}</div></div>
<div class="item"><div class="label">RAM</div><div class="value">{{ sys.ram }}</div></div>
<div class="item"><div class="label">Storage</div><div class="value">{{ sys.disk }}</div></div>
</div></div>

<div class="card"><h2>Сканирование и сжатие</h2>
<form method="post" action="{{ url_for('scan_settings') }}">
<div class="grid">
<div>
<label>DPI</label>
<input type="number" name="scan_dpi" min="75" max="600" step="25" value="{{ cfg.scan_dpi }}">
</div>
<div>
<label>Режим</label>
<select name="scan_mode">
<option value="Color" {% if cfg.scan_mode == 'Color' %}selected{% endif %}>Color</option>
<option value="Gray" {% if cfg.scan_mode == 'Gray' %}selected{% endif %}>Gray</option>
</select>
</div>
<div>
<label>Ширина, мм</label>
<input type="number" name="scan_width_mm" min="50" max="216" step="1" value="{{ cfg.scan_width_mm }}">
</div>
<div>
<label>Высота, мм</label>
<input type="number" name="scan_height_mm" min="50" max="356" step="1" value="{{ cfg.scan_height_mm }}">
</div>
<div>
<label>Количество цветов</label>
<select name="palette_colors">
{% for n in [16,32,64,128,256] %}
<option value="{{ n }}" {% if cfg.palette_colors == n %}selected{% endif %}>{{ n }}</option>
{% endfor %}
</select>
<small>Используется только в режиме Color.</small>
</div>
<div>
<label>JPEG quality</label>
<input type="number" name="jpeg_quality" min="30" max="95" step="1" value="{{ cfg.jpeg_quality }}">
</div>
</div>
<button class="primary" type="submit">Сохранить профиль</button>
<small>Применяется со следующего задания. Текущий scan job не меняется.</small>
</form></div>

<div class="card"><h2>SMB</h2>
<form method="post" action="{{ url_for('settings') }}">
<label>Путь</label><input name="smb_path" value="{{ cfg.smb_path }}" placeholder="//192.168.100.11/share/folder">
<label>Имя пользователя</label><input name="smb_username" value="{{ cfg.smb_username }}" autocomplete="username">
<label>Пароль</label><input type="password" name="smb_password" value="" placeholder="{% if password_set %}пароль уже задан; оставь пустым, чтобы не менять{% else %}введите пароль{% endif %}" autocomplete="new-password">
<label>Domain / Workgroup (необязательно)</label><input name="smb_domain" value="{{ cfg.smb_domain }}">
<button class="primary" name="action" value="save">Сохранить</button>
<button name="action" value="test">Сохранить и проверить SMB</button>
</form></div>

<div class="card"><h2>Управление</h2>
<form method="post" action="{{ url_for('control') }}">
<button class="primary" name="action" value="duplex">Сканировать Duplex</button>
<button name="action" value="retry">Повторить отправку очереди</button>
<button name="action" value="restart">Перезапустить scanner-worker</button>
<button class="danger" name="action" value="reboot" onclick="return confirm('Перезагрузить scanner?')">Reboot</button>
</form>
<small>Текущий профиль: {{ cfg.scan_dpi }} dpi / {{ cfg.scan_mode }} / {{ cfg.scan_width_mm }}×{{ cfg.scan_height_mm }} мм / {% if cfg.scan_mode == 'Color' %}{{ cfg.palette_colors }} colors / {% endif %}JPEG Q{{ cfg.jpeg_quality }}. Физическая кнопка запускает Simplex; Web — Duplex.</small>
</div>

<div class="card"><h2>Последние события</h2><pre>{{ logs }}</pre></div>
</main></body></html>'''


@app.get('/')
@auth_required
def index():
    cfg = load_config()
    worker = load_json(WORKER_STATE_FILE, {})
    upload = load_json(UPLOAD_STATE_FILE, {})
    last = load_json(LAST_JOB_FILE, {})
    queue_count, queue_size = queue_stats()
    return render_template_string(
        PAGE,
        cfg=cfg,
        worker=worker,
        upload=upload,
        last=last,
        usb=usb_status(),
        configured=bool(cfg.get('smb_path') and CREDS_FILE.exists()),
        password_set=bool(read_credentials().get('password')),
        queue_count=queue_count,
        queue_size=queue_size,
        sys=system_status(),
        logs=journal_tail(),
    )



@app.post('/scan-settings')
@auth_required
def scan_settings():
    try:
        save_scan_settings(
            request.form.get('scan_dpi', ''),
            request.form.get('scan_mode', ''),
            request.form.get('scan_width_mm', ''),
            request.form.get('scan_height_mm', ''),
            request.form.get('palette_colors', ''),
            request.form.get('jpeg_quality', ''),
        )
    except ValueError as exc:
        flash(f'Ошибка профиля сканирования: {exc}')
        return redirect(url_for('index'))

    flash('Профиль сканирования сохранён; будет применён к следующему заданию')
    return redirect(url_for('index'))

@app.post('/settings')
@auth_required
def settings():
    path = request.form.get('smb_path', '').strip()
    username = request.form.get('smb_username', '').strip()
    domain = request.form.get('smb_domain', '').strip()
    password_value = request.form.get('smb_password', '')
    password = password_value if password_value else None
    try:
        save_smb_settings(path, username, password, domain)
    except ValueError as exc:
        flash(f'Ошибка настроек: {exc}')
        return redirect(url_for('index'))

    if request.form.get('action') == 'test':
        ok, message = smb_test()
        flash(('SMB OK: ' if ok else 'SMB ERROR: ') + message)
    else:
        flash('SMB настройки сохранены')
    return redirect(url_for('index'))


@app.post('/control')
@auth_required
def control():
    action = request.form.get('action', '')
    if action == 'duplex':
        state = load_json(WORKER_STATE_FILE, {})
        status = state.get('status', '')
        if status in {'scanning', 'processing'}:
            flash('Scanner busy: текущее сканирование ещё не закончено')
            return redirect(url_for('index'))
        DUPLEX_REQUEST_FILE.touch(mode=0o600, exist_ok=True)
        if status == 'waiting':
            try:
                pid = int(CHILD_PID_FILE.read_text(encoding='ascii').strip())
                os.kill(pid, signal.SIGTERM)
            except (OSError, ValueError):
                pass
        flash('Duplex scan поставлен на запуск')

    elif action == 'retry':
        RETRY_REQUEST_FILE.touch(mode=0o600, exist_ok=True)
        flash('Повторная отправка очереди запрошена')

    elif action == 'restart':
        proc = subprocess.run(
            ['sudo', '-n', '/usr/bin/systemctl', 'restart', 'scanner-worker.service'],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False
        )
        flash('scanner-worker перезапущен' if proc.returncode == 0 else f'Ошибка restart: {proc.stdout[-250:]}')

    elif action == 'reboot':
        subprocess.Popen(['sudo', '-n', '/usr/bin/systemctl', 'reboot'])
        return '<html><body><h3>Scanner перезагружается…</h3></body></html>'

    else:
        flash('Неизвестная команда')
    return redirect(url_for('index'))
PYAPP

chown root:root "$APP_DIR"/*.py
chmod 0644 "$APP_DIR"/*.py
python3 -m py_compile "$APP_DIR/common.py" "$APP_DIR/worker.py" "$APP_DIR/app.py"

info "Настраиваем sudo только для Web reboot/restart worker"
cat >/etc/sudoers.d/scanner-web <<EOF
$SERVICE_USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart scanner-worker.service, /usr/bin/systemctl reboot
EOF
chmod 0440 /etc/sudoers.d/scanner-web
visudo -cf /etc/sudoers.d/scanner-web

info "Создаем systemd services"
cat >/etc/systemd/system/scanner-worker.service <<EOF
[Unit]
Description=Scanner worker (Epson ADF -> PDF -> SMB)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
SupplementaryGroups=$SCANNER_GROUP
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/python3 $APP_DIR/worker.py
Restart=always
RestartSec=3
RuntimeDirectory=scanner
RuntimeDirectoryMode=0700
RuntimeDirectoryPreserve=restart
UMask=0077
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$DATA_DIR /run/scanner
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/scanner-web.service <<EOF
[Unit]
Description=Scanner Web UI
After=network-online.target scanner-worker.service
Wants=network-online.target
Requires=scanner-worker.service

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
WorkingDirectory=$APP_DIR
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/gunicorn --workers 1 --threads 2 --bind 0.0.0.0:80 --access-logfile - --error-logfile - app:app
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$CONFIG_DIR $DATA_DIR /run/scanner

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable avahi-daemon scanner-worker.service scanner-web.service
systemctl restart avahi-daemon

info "Проверяем scanner USB/SANE до запуска worker"
if lsusb | grep -qi '04b8:012b'; then
    echo "USB Epson 04b8:012b: FOUND"
else
    warn "USB Epson 04b8:012b сейчас не найден. Сервис всё равно будет установлен."
fi

if runuser -u "$SERVICE_USER" -- scanimage -L; then
    echo "SANE check as $SERVICE_USER: OK"
else
    warn "SANE не увидел scanner от имени $SERVICE_USER. Если scanner подключен, переподключи USB после установки и проверь scanimage -L."
fi

info "Запускаем scanner services"
systemctl restart scanner-worker.service
systemctl restart scanner-web.service
sleep 2

info "Проверки"
echo "Hostname: $(hostname)"
echo "Architecture: $ARCH"
echo "SSH effective settings:"
sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|x11forwarding) ' || true
echo
systemctl --no-pager --full status scanner-worker.service || true
echo
systemctl --no-pager --full status scanner-web.service || true

echo
cat <<EOF
==================== ГОТОВО ====================
Hostname:        $HOSTNAME_FIXED
Web UI:          http://$HOSTNAME_FIXED.local/
Web port:        80
Web user:        $WEB_USER
SSH:             ssh -p $SSH_PORT $NEW_USER@$HOSTNAME_FIXED.local

Default scan:    200 dpi / Color / A4 / 64 colors / JPEG Q65 (editable in Web UI)
Start Simplex:   физическая кнопка Epson
Duplex:          кнопка в Web UI
SMB:             настраивается в Web UI
Local spool:     $DATA_DIR/spool

Services:
  scanner-worker.service
  scanner-web.service

Initial setup log:
  $LOG_FILE

ВАЖНО: Web UI работает по обычному HTTP внутри LAN.
Web/SMB credentials по сети не шифруются TLS этим сервисом.
=================================================
EOF

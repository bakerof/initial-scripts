#!/usr/bin/env bash
set -euo pipefail

# =========================
# Ubuntu initial setup script
# =========================

TIMEZONE_DEFAULT="Europe/Moscow"
YANDEX_MIRROR_URL="http://mirror.yandex.ru/ubuntu"
LOG_FILE="/var/log/ubuntu-initial-setup-$(date +%F_%H-%M-%S).log"

# =========================
# Logging
# =========================
exec > >(tee -a "$LOG_FILE") 2>&1

# =========================
# Helpers
# =========================
die() {
  echo "Ошибка: $*" >&2
  exit 1
}

info() {
  echo
  echo "==> $*"
}

need_tty() {
  [[ -r /dev/tty ]] || die "Не найден /dev/tty. Запусти скрипт из интерактивной консоли."
}

prompt_value() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-}"
  local value=""

  while true; do
    if [[ -n "$default_value" ]]; then
      read -r -p "${prompt_text} [${default_value}]: " value < /dev/tty
      value="${value:-$default_value}"
    else
      read -r -p "${prompt_text}: " value < /dev/tty
    fi

    if [[ -n "$value" ]]; then
      printf -v "$var_name" '%s' "$value"
      return 0
    fi

    echo "Значение не может быть пустым."
  done
}

prompt_password_confirm() {
  local var_name="$1"
  local pass1=""
  local pass2=""

  while true; do
    read -r -s -p "Введите пароль для нового пользователя: " pass1 < /dev/tty
    echo
    read -r -s -p "Повторите пароль: " pass2 < /dev/tty
    echo

    if [[ -z "$pass1" ]]; then
      echo "Пароль не может быть пустым."
      continue
    fi

    if [[ "$pass1" != "$pass2" ]]; then
      echo "Пароли не совпадают. Повторите ввод."
      continue
    fi

    printf -v "$var_name" '%s' "$pass1"
    return 0
  done
}

validate_username() {
  local username="$1"

  if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    die "Некорректное имя пользователя: ${username}. Используй lowercase латиницу, цифры, _ или -, первый символ — буква или _."
  fi
}

validate_ssh_port() {
  local port="$1"

  if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    die "SSH-порт должен быть числом."
  fi

  if (( port < 1 || port > 65535 )); then
    die "SSH-порт должен быть в диапазоне 1-65535."
  fi
}

detect_ubuntu_codename() {
  if [[ -n "${VERSION_CODENAME:-}" ]]; then
    UBUNTU_CODENAME="${VERSION_CODENAME}"
    return 0
  fi

  if command -v lsb_release >/dev/null 2>&1; then
    UBUNTU_CODENAME="$(lsb_release -cs)"
    return 0
  fi

  die "Не удалось определить Ubuntu codename."
}

configure_ubuntu_mirror() {
  local mirror_url="$1"
  local backup_dir="/root/apt-sources-backup-$(date +%F_%H-%M-%S)"

  info "Настраиваем Ubuntu mirror: ${mirror_url}"
  info "Ubuntu codename: ${UBUNTU_CODENAME}"

  mkdir -p "$backup_dir"

  if [[ -f /etc/apt/sources.list ]]; then
    cp -a /etc/apt/sources.list "$backup_dir/sources.list"
  fi

  if compgen -G "/etc/apt/sources.list.d/*" >/dev/null; then
    cp -a /etc/apt/sources.list.d/* "$backup_dir/" 2>/dev/null || true
  fi

  info "Backup apt sources сохранен в: ${backup_dir}"

  # Отключаем старые .sources/.list, чтобы не было дублей.
  if [[ -d /etc/apt/sources.list.d ]]; then
    find /etc/apt/sources.list.d -maxdepth 1 \
      \( -name "*.sources" -o -name "*.list" \) \
      -exec mv {} {}.disabled-by-initial-setup \; 2>/dev/null || true
  fi

  cat > /etc/apt/sources.list <<EOF
deb ${mirror_url} ${UBUNTU_CODENAME} main restricted universe multiverse
deb ${mirror_url} ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb ${mirror_url} ${UBUNTU_CODENAME}-security main restricted universe multiverse
deb ${mirror_url} ${UBUNTU_CODENAME}-backports main restricted universe multiverse
EOF
}

confirm_action() {
  local answer=""

  echo
  echo "Проверь параметры:"
  echo "  Ubuntu:        ${PRETTY_NAME:-unknown}"
  echo "  Codename:      ${UBUNTU_CODENAME}"
  echo "  Пользователь:  ${NEW_USER}"
  echo "  SSH порт:      ${SSH_PORT}"
  echo "  Таймзона:      ${TIMEZONE}"
  echo "  Mirror Yandex: ${USE_YANDEX_MIRROR}"
  echo
  read -r -p "Продолжить? [y/N]: " answer < /dev/tty

  case "$answer" in
    y|Y|yes|YES|Yes|д|Д|да|ДА)
      return 0
      ;;
    *)
      die "Операция отменена пользователем."
      ;;
  esac
}

# =========================
# Root check
# =========================
if [[ "$EUID" -ne 0 ]]; then
  die "Скрипт нужно запускать от root."
fi

need_tty

# =========================
# OS check
# =========================
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
    die "Этот скрипт рассчитан на Ubuntu. Текущая система: ${PRETTY_NAME:-unknown}"
  fi
else
  die "Не найден /etc/os-release."
fi

detect_ubuntu_codename

# =========================
# Interactive input
# =========================
prompt_value NEW_USER "Введите имя нового пользователя"
validate_username "$NEW_USER"

prompt_password_confirm NEW_PASSWORD

prompt_value SSH_PORT "Введите SSH-порт" "22"
validate_ssh_port "$SSH_PORT"

prompt_value TIMEZONE "Введите таймзону" "$TIMEZONE_DEFAULT"

prompt_value USE_YANDEX_MIRROR "Заменить Ubuntu mirror на mirror.yandex.ru? yes/no" "yes"

case "$USE_YANDEX_MIRROR" in
  y|Y|yes|YES|Yes|д|Д|да|ДА)
    USE_YANDEX_MIRROR="yes"
    ;;
  *)
    USE_YANDEX_MIRROR="no"
    ;;
esac

confirm_action

# =========================
# Optional mirror replacement
# =========================
if [[ "$USE_YANDEX_MIRROR" == "yes" ]]; then
  configure_ubuntu_mirror "$YANDEX_MIRROR_URL"
else
  info "Оставляем текущие apt sources без изменений"
fi

# =========================
# apt update / upgrade
# =========================
info "Очищаем apt cache и lists"
apt-get clean
rm -rf /var/lib/apt/lists/*
mkdir -p /var/lib/apt/lists/partial

info "apt update"
apt-get update

info "apt upgrade"
DEBIAN_FRONTEND=noninteractive apt-get -y upgrade

# =========================
# Packages
# =========================
info "Устанавливаем базовые пакеты"
DEBIAN_FRONTEND=noninteractive apt-get -y install \
  sudo \
  openssh-server \
  ca-certificates \
  curl \
  wget \
  gnupg \
  lsb-release \
  nano \
  htop \
  net-tools \
  iproute2 \
  dnsutils \
  jq \
  git \
  unzip \
  zip \
  rsync \
  bash-completion \
  software-properties-common

# =========================
# Timezone
# =========================
info "Настраиваем таймзону: ${TIMEZONE}"
timedatectl set-timezone "${TIMEZONE}"

info "Текущая таймзона"
timedatectl | sed -n '1,8p' || true

# =========================
# User
# =========================
info "Создаем пользователя: ${NEW_USER}"

if id "${NEW_USER}" >/dev/null 2>&1; then
  echo "Пользователь ${NEW_USER} уже существует"
else
  useradd -m -s /bin/bash "${NEW_USER}"
  echo "Пользователь ${NEW_USER} создан"
fi

info "Устанавливаем пароль пользователю ${NEW_USER}"
echo "${NEW_USER}:${NEW_PASSWORD}" | chpasswd

info "Добавляем пользователя ${NEW_USER} в группу sudo"
usermod -aG sudo "${NEW_USER}"

info "Проверяем группы пользователя"
id "${NEW_USER}"
groups "${NEW_USER}"

info "Проверяем sudo-права пользователя"
sudo -l -U "${NEW_USER}" || true

# =========================
# SSH config
# =========================
info "Делаем backup sshd_config"
cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%F_%H-%M-%S)"

info "Проверяем Include для /etc/ssh/sshd_config.d/*.conf"
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]|$)' /etc/ssh/sshd_config; then
  echo "" >> /etc/ssh/sshd_config
  echo "Include /etc/ssh/sshd_config.d/*.conf" >> /etc/ssh/sshd_config
fi

info "Создаем SSH override-файл"
mkdir -p /etc/ssh/sshd_config.d

cat > /etc/ssh/sshd_config.d/99-initial-setup.conf <<EOF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
X11Forwarding no
EOF

info "Проверяем конфигурацию sshd"
sshd -t

info "Включаем и перезапускаем SSH"
systemctl enable ssh
systemctl restart ssh

info "Статус SSH"
systemctl status ssh --no-pager -l || true

info "Проверяем примененные параметры sshd"
sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|x11forwarding) '

info "Проверяем прослушивание SSH-порта"
ss -tulpn | grep ":${SSH_PORT}" || true

# =========================
# Final checks
# =========================
info "Проверка apt sources"
cat /etc/apt/sources.list || true

if [[ -d /etc/apt/sources.list.d ]]; then
  ls -la /etc/apt/sources.list.d || true
fi

info "Проверка DNS"
getent hosts github.com || true
getent hosts mirror.yandex.ru || true

echo
echo "========== ГОТОВО =========="
echo "Лог: ${LOG_FILE}"
echo "Ubuntu: ${PRETTY_NAME:-unknown}"
echo "Codename: ${UBUNTU_CODENAME}"
echo "Таймзона: ${TIMEZONE}"
echo "Пользователь: ${NEW_USER}"
echo "SSH порт: ${SSH_PORT}"
echo "Root login по SSH: отключен"
echo "PasswordAuthentication: включен"
echo "Ubuntu mirror заменен: ${USE_YANDEX_MIRROR}"
echo
echo "Подключение:"
echo "ssh ${NEW_USER}@<SERVER_IP> -p ${SSH_PORT}"
echo "============================"

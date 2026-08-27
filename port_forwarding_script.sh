#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Interactive TCP/UDP port forward:
#   SERVER:LISTEN_PORT -> NEW_DEST_IP:NEW_DEST_PORT
#
# Старые правила не удаляет и не меняет.
# ============================================================

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Запусти скрипт через sudo:"
    echo "sudo bash $0"
    exit 1
  fi
}

is_valid_port() {
  local port="$1"

  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 )) || return 1

  return 0
}

is_valid_ipv4() {
  local ip="$1"

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  local IFS='.'
  read -r o1 o2 o3 o4 <<< "$ip"

  for octet in "$o1" "$o2" "$o3" "$o4"; do
    (( octet >= 0 && octet <= 255 )) || return 1
  done

  return 0
}

show_busy_ports() {
  echo
  echo "Занятые локальные TCP/UDP-порты по ss:"
  echo "---------------------------------------"

  if command -v ss >/dev/null 2>&1; then
    ss -H -tuln | awk '
      {
        proto=$1
        local_addr=$5

        # IPv6 вида [::]:80
        if (local_addr ~ /^\[.*\]:[0-9]+$/) {
          sub(/^.*\]:/, "", local_addr)
          port=local_addr
        }
        # IPv4/обычный вид 0.0.0.0:80 или *:80
        else {
          n=split(local_addr, parts, ":")
          port=parts[n]
        }

        if (port ~ /^[0-9]+$/) {
          key=proto "/" port
          ports[key]=1
        }
      }
      END {
        for (key in ports) print key
      }
    ' | sort -t/ -k2,2n -k1,1 || true
  else
    echo "Команда ss не найдена."
  fi

  echo
  echo "DNAT-порты, уже занятые в iptables PREROUTING:"
  echo "----------------------------------------------"

  iptables-save -t nat 2>/dev/null | awk '
    /-A PREROUTING/ && /--dport/ && /DNAT/ {
      proto="any"
      port=""

      for (i=1; i<=NF; i++) {
        if ($i == "-p") proto=$(i+1)
        if ($i == "--dport") port=$(i+1)
      }

      if (port != "") print proto "/" port "  " $0
    }
  ' | sort -t/ -k2,2n -k1,1 || true

  echo
}

is_port_used_by_ss() {
  local port="$1"

  ss -H -tuln | awk -v p="$port" '
    {
      local_addr=$5

      if (local_addr ~ /^\[.*\]:[0-9]+$/) {
        sub(/^.*\]:/, "", local_addr)
        found_port=local_addr
      } else {
        n=split(local_addr, parts, ":")
        found_port=parts[n]
      }

      if (found_port == p) {
        found=1
      }
    }
    END {
      exit found ? 0 : 1
    }
  '
}

is_port_used_by_iptables_dnat() {
  local port="$1"

  iptables-save -t nat 2>/dev/null | grep -Eq -- "-A PREROUTING .*--dport[[:space:]]+${port}([[:space:]]|$).*DNAT"
}

ask_listen_port() {
  local port

  while true; do
    read -rp "Введите входящий порт на этом сервере, например 9095: " port

    if ! is_valid_port "$port"; then
      echo "Ошибка: порт должен быть числом от 1 до 65535."
      continue
    fi

    if is_port_used_by_ss "$port"; then
      echo "Ошибка: порт $port уже занят локальным процессом."
      echo "Выбери другой порт."
      continue
    fi

    if is_port_used_by_iptables_dnat "$port"; then
      echo "Ошибка: порт $port уже используется в iptables DNAT PREROUTING."
      echo "Выбери другой порт или сначала проверь существующие правила."
      continue
    fi

    LISTEN_PORT="$port"
    break
  done
}

ask_dest_ip() {
  local ip

  while true; do
    read -rp "Введите новый destination IP, например 1.2.3.4: " ip

    if ! is_valid_ipv4 "$ip"; then
      echo "Ошибка: нужен IPv4-адрес, например 1.2.3.4."
      continue
    fi

    NEW_DEST_IP="$ip"
    break
  done
}

ask_dest_port() {
  local port

  while true; do
    read -rp "Введите новый destination port: " port

    if ! is_valid_port "$port"; then
      echo "Ошибка: порт должен быть числом от 1 до 65535."
      continue
    fi

    NEW_DEST_PORT="$port"
    break
  done
}

confirm_settings() {
  echo
  echo "Будут добавлены правила:"
  echo "  входящий порт: ${LISTEN_PORT}"
  echo "  назначение:    ${NEW_DEST_IP}:${NEW_DEST_PORT}"
  echo
  echo "Старые правила удаляться или изменяться не будут."
  echo

  read -rp "Продолжить? [y/N]: " answer

  case "$answer" in
    y|Y|yes|YES|да|Да|ДА)
      return 0
      ;;
    *)
      echo "Отменено."
      exit 0
      ;;
  esac
}

backup_iptables() {
  BACKUP_FILE="/root/iptables-backup-before-forward-${LISTEN_PORT}-$(date +%F_%H-%M-%S).rules"
  iptables-save > "$BACKUP_FILE"
  echo "Бэкап правил сохранен: $BACKUP_FILE"
}

enable_ip_forwarding() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null; then
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-ip-forward.conf
  fi

  echo "IPv4 forwarding включен."
}

add_dnat_rule() {
  local proto="$1"

  if iptables -t nat -C PREROUTING -p "$proto" --dport "$LISTEN_PORT" \
    -j DNAT --to-destination "${NEW_DEST_IP}:${NEW_DEST_PORT}" 2>/dev/null; then
    echo "${proto^^} DNAT уже существует, не дублирую."
  else
    iptables -t nat -A PREROUTING -p "$proto" --dport "$LISTEN_PORT" \
      -j DNAT --to-destination "${NEW_DEST_IP}:${NEW_DEST_PORT}"
    echo "${proto^^} DNAT добавлен."
  fi
}

add_masquerade_rule() {
  local proto="$1"

  if iptables -t nat -C POSTROUTING -p "$proto" -d "$NEW_DEST_IP" --dport "$NEW_DEST_PORT" \
    -j MASQUERADE 2>/dev/null; then
    echo "${proto^^} MASQUERADE уже существует, не дублирую."
  else
    iptables -t nat -A POSTROUTING -p "$proto" -d "$NEW_DEST_IP" --dport "$NEW_DEST_PORT" \
      -j MASQUERADE
    echo "${proto^^} MASQUERADE добавлен."
  fi
}

save_rules() {
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
    echo "Правила сохранены через netfilter-persistent."
  elif [[ -d /etc/iptables ]]; then
    iptables-save > /etc/iptables/rules.v4
    echo "Правила сохранены в /etc/iptables/rules.v4."
  else
    echo
    echo "ВНИМАНИЕ: правила добавлены, но автосохранение не найдено."
    echo "После перезагрузки они могут пропасть."
    echo
    echo "Для сохранения после перезагрузки можно установить:"
    echo "apt install iptables-persistent"
  fi
}

show_result() {
  echo
  echo "Итоговые NAT-правила:"
  echo "---------------------"
  iptables-save -t nat | grep -E "${LISTEN_PORT}|${NEW_DEST_IP}|MASQUERADE" || true

  echo
  echo "Готово."
}

main() {
  require_root

  echo "Интерактивное добавление port-forwarding правила."
  echo "Старые правила не удаляются и не изменяются."

  show_busy_ports

  ask_listen_port
  ask_dest_ip
  ask_dest_port
  confirm_settings

  backup_iptables
  enable_ip_forwarding

  add_dnat_rule "tcp"
  add_dnat_rule "udp"

  add_masquerade_rule "tcp"
  add_masquerade_rule "udp"

  save_rules
  show_result
}

main "$@"
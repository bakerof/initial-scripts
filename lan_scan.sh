#!/bin/bash

echo "========================================"
echo "       LOCAL NETWORK PORT SCANNER"
echo "========================================"
echo

read -r -p "Subnet (example: 192.168.100.0/24) [192.168.100.0/24]: " SUBNET
SUBNET="${SUBNET:-192.168.100.0/24}"

read -r -p "TCP port (example: 80) [80]: " PORT
PORT="${PORT:-80}"

# Validate IPv4 /24 subnet
if [[ ! "$SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/24$ ]]; then
    echo "Error: only IPv4 /24 subnets supported."
    exit 1
fi

PREFIX="${SUBNET%.*}"
IFS='.' read -r A B C <<< "$PREFIX"

for OCTET in "$A" "$B" "$C"; do
    if (( 10#$OCTET > 255 )); then
        echo "Error: invalid subnet."
        exit 1
    fi
done

if [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
    echo "Error: invalid port."
    exit 1
fi

PORT=$((10#$PORT))
if (( PORT < 1 || PORT > 65535 )); then
    echo "Error: port must be 1-65535."
    exit 1
fi

TMPDIR_SCAN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SCAN"' EXIT
RESULTS="$TMPDIR_SCAN/results"

touch "$RESULTS"

echo
echo "Scanning $SUBNET on TCP port $PORT..."

# Step 1: Parallel port scan
for i in {1..254}; do
    (
        IP="$PREFIX.$i"

        if nc -z -G 1 "$IP" "$PORT" 2>/dev/null; then
            echo "$IP" >> "$RESULTS"
        fi
    ) &

    if (( i % 50 == 0 )); then
        wait
    fi
done

wait

COUNT=$(wc -l < "$RESULTS" | tr -d ' ')

# Step 2: Resolve hostnames
resolve_hostname() {
    local IP="$1"
    local NAME=""
    local REVERSE=""
    local PID=""
    local OUTFILE="$TMPDIR_SCAN/dnssd_${IP}"

    # 1. macOS system resolver (DNS + Bonjour/mDNS)
    NAME=$(dscacheutil -q host -a ip_address "$IP" 2>/dev/null |
           awk '/^name:/ {print $2; exit}')

    # 2. Standard reverse DNS
    if [[ -z "$NAME" ]]; then
        NAME=$(dig +time=1 +tries=1 +short -x "$IP" 2>/dev/null |
               head -n 1)
    fi

    # 3. Explicit DNS-SD reverse PTR query
    if [[ -z "$NAME" ]]; then
        IFS='.' read -r A B C D <<< "$IP"
        REVERSE="$D.$C.$B.$A.in-addr.arpa."

        dns-sd -q "$REVERSE" PTR > "$OUTFILE" 2>&1 &
        PID=$!

        sleep 2

        kill "$PID" 2>/dev/null
        wait "$PID" 2>/dev/null

        NAME=$(awk '$6=="PTR" && $7=="IN" {
            print $8
            exit
        }' "$OUTFILE")
    fi

    NAME="${NAME%.}"
    [[ -z "$NAME" ]] && NAME="-"

    printf "%s" "$NAME"
}

echo "Resolving hostnames for $COUNT devices..."

# Step 3: Collect final results
FINAL="$TMPDIR_SCAN/final"
touch "$FINAL"

if [[ -s "$RESULTS" ]]; then
    while IFS= read -r IP; do
        NAME=$(resolve_hostname "$IP")
        printf "%s\t%s\n" "$IP" "$NAME" >> "$FINAL"
    done < <(sort -t. -k4,4n "$RESULTS")
fi

# Step 4: Final table
echo
echo "=========================================================="
printf "%-18s %-35s\n" "IP ADDRESS" "HOSTNAME"
echo "----------------------------------------------------------"

if [[ -s "$FINAL" ]]; then
    while IFS=$'\t' read -r IP NAME; do
        printf "%-18s %-35s\n" "$IP" "$NAME"
    done < "$FINAL"
else
    echo "No devices found."
fi

echo "----------------------------------------------------------"
echo "Total found: $COUNT"
echo "=========================================================="

#!/usr/bin/env bash

set -u

usage() {
    cat <<'EOF'
IP-калькулятор

Использование:
  ./ipcalc.sh
  ./ipcalc.sh 172.16.0.1 24
  ./ipcalc.sh 172.16.0.1/24
  ./ipcalc.sh 172.16.0.1 255.255.255.0

Маска принимается как bitmask 0-32 или netmask, например 24, /24, 255.255.255.0.
EOF
}

die() {
    echo "Ошибка: $*" >&2
    echo >&2
    usage >&2
    exit 1
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

ip_to_int() {
    local ip="$1"
    local a b c d extra

    IFS=. read -r a b c d extra <<< "$ip"
    [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1

    for octet in "$a" "$b" "$c" "$d"; do
        is_uint "$octet" || return 1
        ((octet >= 0 && octet <= 255)) || return 1
    done

    echo $(((a << 24) | (b << 16) | (c << 8) | d))
}

int_to_ip() {
    local value="$1"
    printf "%d.%d.%d.%d" \
        $(((value >> 24) & 255)) \
        $(((value >> 16) & 255)) \
        $(((value >> 8) & 255)) \
        $((value & 255))
}

int_to_hex() {
    local value="$1"
    printf "%02X.%02X.%02X.%02X" \
        $(((value >> 24) & 255)) \
        $(((value >> 16) & 255)) \
        $(((value >> 8) & 255)) \
        $((value & 255))
}

int_to_bin32() {
    local value="$1"
    local bits=""
    local i

    for ((i = 31; i >= 0; i--)); do
        bits+=$(((value >> i) & 1))
    done

    echo "$bits"
}

format_bits_part() {
    local bits="$1"
    local start="$2"
    local length="$3"
    local result=""
    local i

    ((length > 0)) || return 0

    for ((i = 0; i < length; i++)); do
        if ((i > 0 && (start + i) % 8 == 0)); then
            result+="."
        fi
        result+="${bits:start + i:1}"
    done

    echo "$result"
}

int_to_marked_bin() {
    local value="$1"
    local prefix="$2"
    local bits net_bits host_bits

    bits=$(int_to_bin32 "$value")
    net_bits=$(format_bits_part "$bits" 0 "$prefix")
    host_bits=$(format_bits_part "$bits" "$prefix" "$((32 - prefix))")

    if ((prefix == 0)); then
        echo "| $host_bits"
    elif ((prefix == 32)); then
        echo "$net_bits |"
    else
        echo "$net_bits | $host_bits"
    fi
}

prefix_to_netmask() {
    local prefix="$1"

    if ((prefix == 0)); then
        echo 0
    else
        echo $(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
    fi
}

netmask_to_prefix() {
    local mask="$1"
    local mask_int expected prefix

    mask_int=$(ip_to_int "$mask") || return 1

    for ((prefix = 0; prefix <= 32; prefix++)); do
        expected=$(prefix_to_netmask "$prefix")
        if ((mask_int == expected)); then
            echo "$prefix"
            return 0
        fi
    done

    return 1
}

parse_mask() {
    local mask="${1#/}"

    if [[ "$mask" == *.* ]]; then
        netmask_to_prefix "$mask" || return 1
        return 0
    fi

    is_uint "$mask" || return 1
    ((mask >= 0 && mask <= 32)) || return 1
    echo "$mask"
}

print_row() {
    local name="$1"
    local value="$2"
    local hex="${3:-}"
    local bin="${4:-}"

    printf "%s\t%s\t%s\t%s\n" "$name" "$value" "$hex" "$bin"
}

render_table() {
    if command -v column >/dev/null 2>&1; then
        column -t -s $'\t'
    else
        cat
    fi
}

read_input() {
    local input_ip input_mask

    read -r -p "Введите IP или CIDR (например 172.16.0.1 или 172.16.0.1/24): " input_ip

    if [[ "$input_ip" == */* ]]; then
        IP="${input_ip%%/*}"
        MASK="${input_ip#*/}"
    else
        IP="$input_ip"
        read -r -p "Введите маску (например 24 или 255.255.255.0): " input_mask
        MASK="$input_mask"
    fi
}

main() {
    local ip="${1:-}"
    local mask="${2:-}"
    local ip_int prefix netmask wildcard network broadcast hostmin hostmax hosts

    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    if [[ $# -eq 0 ]]; then
        read_input
        ip="$IP"
        mask="$MASK"
    elif [[ $# -eq 1 && "$ip" == */* ]]; then
        mask="${ip#*/}"
        ip="${ip%%/*}"
    elif [[ $# -ne 2 ]]; then
        die "нужно передать IP и маску, либо один аргумент в формате IP/маска"
    fi

    ip_int=$(ip_to_int "$ip") || die "IP '$ip' выглядит подозрительно. Нужно 4 числа от 0 до 255 через точку"
    prefix=$(parse_mask "$mask") || die "маска '$mask' неправильная. Нужен prefix 0-32 или корректная netmask"

    netmask=$(prefix_to_netmask "$prefix")
    wildcard=$((netmask ^ 0xFFFFFFFF))
    network=$((ip_int & netmask))
    broadcast=$((network | wildcard))

    if ((prefix == 32)); then
        hostmin=$network
        hostmax=$network
        hosts=1
    elif ((prefix == 31)); then
        hostmin=$network
        hostmax=$broadcast
        hosts=2
    else
        hostmin=$((network + 1))
        hostmax=$((broadcast - 1))
        hosts=$(( (1 << (32 - prefix)) - 2 ))
    fi

    {
        echo
        print_row "Имя" "Значение" "16-ричный код" "Бинарное значение"
        print_row "----------" "------------------" "---------------" "--------------------------------------"
        print_row "Адрес" "$(int_to_ip "$ip_int")" "$(int_to_hex "$ip_int")" "$(int_to_marked_bin "$ip_int" "$prefix")"
        print_row "Bitmask" "$prefix"
        print_row "Netmask" "$(int_to_ip "$netmask")" "$(int_to_hex "$netmask")" "$(int_to_marked_bin "$netmask" "$prefix")"
        print_row "Wildcard" "$(int_to_ip "$wildcard")" "$(int_to_hex "$wildcard")" "$(int_to_marked_bin "$wildcard" "$prefix")"
        print_row "Network" "$(int_to_ip "$network")" "$(int_to_hex "$network")" "$(int_to_marked_bin "$network" "$prefix")"
        print_row "Broadcast" "$(int_to_ip "$broadcast")" "$(int_to_hex "$broadcast")" "$(int_to_marked_bin "$broadcast" "$prefix")"
        print_row "Hostmin" "$(int_to_ip "$hostmin")" "$(int_to_hex "$hostmin")" "$(int_to_marked_bin "$hostmin" "$prefix")"
        print_row "Hostmax" "$(int_to_ip "$hostmax")" "$(int_to_hex "$hostmax")" "$(int_to_marked_bin "$hostmax" "$prefix")"
        print_row "Hosts" "$hosts"
    } | render_table
    echo
}

main "$@"

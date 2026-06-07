#!/bin/bash
# Общие переменные модуля 1. Первый запуск спрашивает вариативные данные.
# Конфиг хранится рядом со скриптами, чтобы его можно было скопировать
# на каждую ВМ вместе с файлами первого модуля.

MODULE1_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOCAL_CONFIG_PATH="${MODULE1_LOCAL_CONFIG:-$MODULE1_DIR/demo2026-module1.conf}"
SYSTEM_CONFIG_PATH="${MODULE1_SYSTEM_CONFIG:-/etc/demo2026-module1.conf}"

if [[ -n "${MODULE1_CONFIG:-}" ]]; then
    CONFIG_PATH="$MODULE1_CONFIG"
elif [[ -f "$LOCAL_CONFIG_PATH" ]]; then
    CONFIG_PATH="$LOCAL_CONFIG_PATH"
elif [[ -f "$SYSTEM_CONFIG_PATH" ]]; then
    CONFIG_PATH="$SYSTEM_CONFIG_PATH"
else
    CONFIG_PATH="$LOCAL_CONFIG_PATH"
fi

ip_to_int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

int_to_ip() {
    local ip="$1"
    echo "$(( (ip >> 24) & 255 )).$(( (ip >> 16) & 255 )).$(( (ip >> 8) & 255 )).$(( ip & 255 ))"
}

prefix_to_netmask() {
    local prefix="$1"
    local mask=$(( 0xffffffff << (32 - prefix) & 0xffffffff ))
    int_to_ip "$mask"
}

cidr_network() {
    local cidr="$1" ip prefix ip_int mask
    ip="${cidr%/*}"
    prefix="${cidr#*/}"
    ip_int=$(ip_to_int "$ip")
    mask=$(( 0xffffffff << (32 - prefix) & 0xffffffff ))
    int_to_ip "$(( ip_int & mask ))"
}

cidr_prefix() {
    echo "${1#*/}"
}

cidr_host() {
    local cidr="$1" offset="$2" net prefix size
    net=$(ip_to_int "$(cidr_network "$cidr")")
    prefix=$(cidr_prefix "$cidr")
    size=$(( 1 << (32 - prefix) ))
    if (( offset < 0 )); then
        offset=$(( size + offset ))
    fi
    int_to_ip "$(( net + offset ))"
}

ask_value() {
    local var_name="$1" prompt="$2" default_value="$3" value
    read -r -p "$prompt [$default_value]: " value
    printf -v "$var_name" '%s' "${value:-$default_value}"
}

ask_prefix() {
    local var_name="$1" prompt="$2" default_prefix="$3" allowed="$4" value
    while true; do
        read -r -p "$prompt [$default_prefix] (доступно: $allowed): " value
        value="${value:-$default_prefix}"
        value="${value#/}"
        if [[ " $allowed " == *" $value "* ]]; then
            printf -v "$var_name" '%s' "$value"
            return
        fi
        echo "Введите одну из масок: $allowed" >&2
    done
}

ask_secret() {
    local var_name="$1" prompt="$2" default_value="$3" value
    read -r -s -p "$prompt [по умолчанию: $default_value]: " value
    echo
    printf -v "$var_name" '%s' "${value:-$default_value}"
}

write_config() {
    umask 077
    mkdir -p "$(dirname "$CONFIG_PATH")"
    : > "$CONFIG_PATH"
    for var_name in \
        DOMAIN TIMEZONE PUBLIC_DNS DNS_FORWARDER \
        HQ_SRV_VLAN_ID HQ_CLI_VLAN_ID MGMT_VLAN_ID \
        HQ_SRV_NET_CIDR HQ_CLI_NET_CIDR MGMT_NET_CIDR BR_SRV_NET_CIDR \
        SRV_USER SRV_PASSWORD SRV_UID RTR_USER RTR_PASSWORD \
        SSH_PORT SSH_MAX_AUTH_TRIES SSH_BANNER OSPF_PASSWORD SAMBA_ADMIN_PASS
    do
        printf '%s=%q\n' "$var_name" "${!var_name}" >> "$CONFIG_PATH"
    done
    chmod 600 "$CONFIG_PATH" 2>/dev/null || true

    if [[ "$CONFIG_PATH" != "$SYSTEM_CONFIG_PATH" && $EUID -eq 0 ]]; then
        cp "$CONFIG_PATH" "$SYSTEM_CONFIG_PATH" 2>/dev/null || true
        chmod 600 "$SYSTEM_CONFIG_PATH" 2>/dev/null || true
    fi
}

create_config() {
    echo "Первичная настройка переменных модуля 1."
    echo "Файл ответов будет сохранен: $CONFIG_PATH"
    echo "Скопируйте этот файл на остальные машины рядом со скриптами, чтобы адресация совпала."

    ask_value DOMAIN "DNS-суффикс/домен" "au-team.irpo"
    ask_value TIMEZONE "Часовой пояс" "Europe/Moscow"
    ask_value PUBLIC_DNS "Публичный DNS для клиентов/маршрутизаторов" "8.8.8.8"
    ask_value DNS_FORWARDER "DNS forwarder для BIND" "77.88.8.7"

    ask_value HQ_SRV_VLAN_ID "VLAN для HQ-SRV" "100"
    ask_value HQ_CLI_VLAN_ID "VLAN для HQ-CLI" "200"
    ask_value MGMT_VLAN_ID "VLAN управления" "999"

    ask_prefix HQ_SRV_PREFIX "Маска сети HQ-SRV, не более 32 адресов" "27" "27 28 29 30"
    ask_prefix HQ_CLI_PREFIX "Маска сети HQ-CLI, не менее 16 адресов" "27" "24 25 26 27"
    ask_prefix MGMT_PREFIX "Маска сети управления, не более 8 адресов" "29" "29 30"
    ask_prefix BR_SRV_PREFIX "Маска сети BR-SRV, не более 16 адресов" "28" "28 29 30"

    HQ_SRV_NET_CIDR="172.16.10.0/$HQ_SRV_PREFIX"
    HQ_CLI_NET_CIDR="172.16.20.0/$HQ_CLI_PREFIX"
    MGMT_NET_CIDR="172.16.99.0/$MGMT_PREFIX"
    BR_SRV_NET_CIDR="172.16.30.0/$BR_SRV_PREFIX"

    ask_value SRV_USER "Пользователь серверов HQ-SRV/BR-SRV" "sshuser"
    ask_secret SRV_PASSWORD "Пароль пользователя серверов" "P@ssw0rd"
    ask_value SRV_UID "UID пользователя серверов" "2026"
    ask_value RTR_USER "Пользователь маршрутизаторов HQ-RTR/BR-RTR" "net_admin"
    ask_secret RTR_PASSWORD "Пароль пользователя маршрутизаторов" "P@ssw0rd"
    ask_value SSH_PORT "Порт SSH на серверах" "2026"
    ask_value SSH_MAX_AUTH_TRIES "Количество попыток входа SSH" "2"
    ask_value SSH_BANNER "SSH banner" "Authorized access only"
    ask_secret OSPF_PASSWORD "Пароль OSPF MD5" "P@ssw0rd"
    ask_secret SAMBA_ADMIN_PASS "Пароль администратора Samba, если используется test.sh" "P@ssw0rd"

    write_config
}

load_module1_config() {
    if [[ "${RESET_MODULE1_CONFIG:-0}" == "1" || ! -f "$CONFIG_PATH" ]]; then
        create_config
    fi

    # shellcheck source=/etc/demo2026-module1.conf
    source "$CONFIG_PATH"

    DOMAIN="${DOMAIN:-au-team.irpo}"
    TIMEZONE="${TIMEZONE:-Europe/Moscow}"
    PUBLIC_DNS="${PUBLIC_DNS:-8.8.8.8}"
    DNS_FORWARDER="${DNS_FORWARDER:-77.88.8.7}"

    ISP_HQ_ISP_IP="172.16.1.1"
    ISP_HQ_RTR_IP="172.16.1.2"
    ISP_HQ_NET_CIDR="172.16.1.0/28"
    ISP_BR_ISP_IP="172.16.2.1"
    ISP_BR_RTR_IP="172.16.2.2"
    ISP_BR_NET_CIDR="172.16.2.0/28"

    HQ_SRV_NET_IP=$(cidr_network "$HQ_SRV_NET_CIDR")
    HQ_SRV_PREFIX=$(cidr_prefix "$HQ_SRV_NET_CIDR")
    HQ_SRV_NETMASK=$(prefix_to_netmask "$HQ_SRV_PREFIX")
    HQ_SRV_GW_IP=$(cidr_host "$HQ_SRV_NET_CIDR" 1)
    HQ_SRV_IP=$(cidr_host "$HQ_SRV_NET_CIDR" 2)

    HQ_CLI_NET_IP=$(cidr_network "$HQ_CLI_NET_CIDR")
    HQ_CLI_PREFIX=$(cidr_prefix "$HQ_CLI_NET_CIDR")
    HQ_CLI_NETMASK=$(prefix_to_netmask "$HQ_CLI_PREFIX")
    HQ_CLI_GW_IP=$(cidr_host "$HQ_CLI_NET_CIDR" 1)
    HQ_CLI_FIRST_DHCP_IP=$(cidr_host "$HQ_CLI_NET_CIDR" 2)
    HQ_CLI_LAST_DHCP_IP=$(cidr_host "$HQ_CLI_NET_CIDR" -2)
    HQ_CLI_DNS_IP="$HQ_CLI_FIRST_DHCP_IP"

    MGMT_NET_IP=$(cidr_network "$MGMT_NET_CIDR")
    MGMT_PREFIX=$(cidr_prefix "$MGMT_NET_CIDR")
    MGMT_GW_IP=$(cidr_host "$MGMT_NET_CIDR" 1)

    BR_SRV_NET_IP=$(cidr_network "$BR_SRV_NET_CIDR")
    BR_SRV_PREFIX=$(cidr_prefix "$BR_SRV_NET_CIDR")
    BR_SRV_NETMASK=$(prefix_to_netmask "$BR_SRV_PREFIX")
    BR_SRV_GW_IP=$(cidr_host "$BR_SRV_NET_CIDR" 1)
    BR_SRV_IP=$(cidr_host "$BR_SRV_NET_CIDR" 2)

    GRE_NET_CIDR="192.168.0.0/30"
    BR_GRE_IP="192.168.0.1"
    HQ_GRE_IP="192.168.0.2"
}

load_module1_config

#!/bin/bash
# Скрипт автоматической настройки сетевых интерфейсов через NetworkManager
# Поддерживаемые хосты: isp, hq-rtr, br-rtr, hq-srv (короткое имя, регистр не важен)

set -e

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: скрипт должен выполняться от root" >&2
    exit 1
fi

# Определяем короткое имя хоста (без домена)
HOSTNAME=$(hostname -s | tr '[:upper:]' '[:lower:]')

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=module1_config.sh
source "$SCRIPT_DIR/module1_config.sh"

# Функция настройки ethernet-подключения
configure_nm_connection() {
    local conn_name="$1"
    local iface="$2"
    local ip="$3"
    local gateway="$4"
    local dns="$5"

    # Удаляем предыдущее подключение с таким именем (если есть)
    nmcli connection delete "$conn_name" 2>/dev/null || true

    if [[ "$ip" == "DHCP" ]]; then
        nmcli connection add type ethernet con-name "$conn_name" ifname "$iface" ipv4.method auto
    else
        nmcli connection add type ethernet con-name "$conn_name" ifname "$iface" \
            ipv4.method manual ipv4.addresses "$ip"
        if [[ -n "$gateway" && "$gateway" != "none" ]]; then
            nmcli connection modify "$conn_name" ipv4.gateway "$gateway"
        fi
    fi

    if [[ -n "$dns" ]]; then
        nmcli connection modify "$conn_name" ipv4.dns "$dns"
    fi

    nmcli connection up "$conn_name"
}

# Функция настройки VLAN
configure_vlan() {
    local conn_name="$1"
    local parent_iface="$2"
    local vlan_id="$3"
    local ip="$4"
    local gateway="$5"
    local dns="$6"

    nmcli connection delete "$conn_name" 2>/dev/null || true
    nmcli connection add type vlan con-name "$conn_name" ifname "${parent_iface}.${vlan_id}" \
        dev "$parent_iface" id "$vlan_id" ipv4.method manual ipv4.addresses "$ip"
    if [[ -n "$gateway" && "$gateway" != "none" ]]; then
        nmcli connection modify "$conn_name" ipv4.gateway "$gateway"
    fi
    if [[ -n "$dns" ]]; then
        nmcli connection modify "$conn_name" ipv4.dns "$dns"
    fi
    nmcli connection up "$conn_name"
}

# Функция настройки GRE-туннеля (с TTL 64)
configure_gre() {
    local conn_name="$1"
    local local_ip="$2"
    local remote_ip="$3"
    local tunnel_ip="$4"
    local dns="$5"

    nmcli connection delete "$conn_name" 2>/dev/null || true
    nmcli connection add type ip-tunnel con-name "$conn_name" \
        ifname "$conn_name" mode gre \
        local "$local_ip" remote "$remote_ip" \
        ip-tunnel.ttl 64 \
        ipv4.method manual ipv4.addresses "$tunnel_ip"
    if [[ -n "$dns" ]]; then
        nmcli connection modify "$conn_name" ipv4.dns "$dns"
    fi
    nmcli connection up "$conn_name"
}

# Включение IP-форвардинга
enable_ip_forward() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    if ! grep '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
        echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    fi
}

# Настройка в зависимости от хоста
case "$HOSTNAME" in
    isp)
        # Интерфейс в сторону интернета (DHCP)
        configure_nm_connection "ens18-dhcp" "ens18" "DHCP" "" "$PUBLIC_DNS"

        # К HQ-RTR (ens19)
        configure_nm_connection "ens19-to-hq" "ens19" "${ISP_HQ_ISP_IP}/28" "none" "$PUBLIC_DNS"

        # К BR-RTR (ens20)
        configure_nm_connection "ens20-to-br" "ens20" "${ISP_BR_ISP_IP}/28" "none" "$PUBLIC_DNS"

        enable_ip_forward

        # Маршрутизация и NAT
        iptables -t nat -A POSTROUTING -o ens18 -j MASQUERADE 2>/dev/null || true
        iptables -A FORWARD -i ens18 -o ens19 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
        iptables -A FORWARD -i ens19 -o ens18 -j ACCEPT 2>/dev/null || true
        iptables -A FORWARD -i ens18 -o ens20 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
        iptables -A FORWARD -i ens20 -o ens18 -j ACCEPT 2>/dev/null || true
        ;;

    hq-rtr)
        # Основной интерфейс к ISP (ens18)
        configure_nm_connection "ens18-to-isp" "ens18" "${ISP_HQ_RTR_IP}/28" "$ISP_HQ_ISP_IP" "$PUBLIC_DNS"

        # Настройка транкового интерфейса ens19 (без IP)
        for conn in $(nmcli -t -f NAME connection show | grep ens19 || true); do
            nmcli connection delete "$conn" 2>/dev/null || true
        done
        nmcli device disconnect ens19 2>/dev/null || true
        nmcli connection add type ethernet con-name "ens19-trunk" ifname ens19 \
            ipv4.method disabled ipv6.method ignore
        nmcli connection up "ens19-trunk"
        sleep 2  # небольшая пауза для активации

        # VLAN-интерфейсы
        configure_vlan "vlan${HQ_SRV_VLAN_ID}" "ens19" "$HQ_SRV_VLAN_ID" "${HQ_SRV_GW_IP}/${HQ_SRV_PREFIX}" "none" "$PUBLIC_DNS"
        configure_vlan "vlan${HQ_CLI_VLAN_ID}" "ens19" "$HQ_CLI_VLAN_ID" "${HQ_CLI_GW_IP}/${HQ_CLI_PREFIX}" "none" "$PUBLIC_DNS"
        configure_vlan "vlan${MGMT_VLAN_ID}" "ens19" "$MGMT_VLAN_ID" "${MGMT_GW_IP}/${MGMT_PREFIX}" "none" "$PUBLIC_DNS"

        # GRE-туннель к BR-RTR (с TTL 64)
        configure_gre "gre-tun" "$ISP_HQ_RTR_IP" "$ISP_BR_RTR_IP" "${HQ_GRE_IP}/30" "$PUBLIC_DNS"

        enable_ip_forward

        # NAT для локальных сетей
        iptables -t nat -A POSTROUTING -s "$HQ_SRV_NET_CIDR" -o ens18 -j MASQUERADE 2>/dev/null || true
        iptables -t nat -A POSTROUTING -s "$HQ_CLI_NET_CIDR" -o ens18 -j MASQUERADE 2>/dev/null || true
        iptables -t nat -A POSTROUTING -s "$MGMT_NET_CIDR" -o ens18 -j MASQUERADE 2>/dev/null || true
        ;;

    br-rtr)
        # Основной интерфейс к ISP (ens18)
        configure_nm_connection "ens18-to-isp" "ens18" "${ISP_BR_RTR_IP}/28" "$ISP_BR_ISP_IP" "$PUBLIC_DNS"

        # Локальная сеть (ens19)
        configure_nm_connection "ens19-local" "ens19" "${BR_SRV_GW_IP}/${BR_SRV_PREFIX}" "none" "$PUBLIC_DNS"

        # GRE-туннель к HQ-RTR (с TTL 64)
        configure_gre "gre-tun" "$ISP_BR_RTR_IP" "$ISP_HQ_RTR_IP" "${BR_GRE_IP}/30" "$PUBLIC_DNS"

        enable_ip_forward

        # NAT для локальной сети
        iptables -t nat -A POSTROUTING -s "$BR_SRV_NET_CIDR" -o ens18 -j MASQUERADE 2>/dev/null || true
        ;;

    hq-srv)
        # VLAN-интерфейс для сервера
        nmcli connection delete "ens18-vlan${HQ_SRV_VLAN_ID}" 2>/dev/null || true
        nmcli connection add type vlan con-name "ens18-vlan${HQ_SRV_VLAN_ID}" ifname "ens18.${HQ_SRV_VLAN_ID}" \
            dev "ens18" id "$HQ_SRV_VLAN_ID" ipv4.method manual ipv4.addresses "${HQ_SRV_IP}/${HQ_SRV_PREFIX}" \
            ipv4.gateway "$HQ_SRV_GW_IP" ipv4.dns "$PUBLIC_DNS"
        nmcli connection up "ens18-vlan${HQ_SRV_VLAN_ID}"
        ;;

    br-srv)
        configure_nm_connection "ens18-local" "ens18" "${BR_SRV_IP}/${BR_SRV_PREFIX}" "$BR_SRV_GW_IP" "$PUBLIC_DNS"
        ;;

    *)
        echo "Ошибка: неизвестный хост '$HOSTNAME'" >&2
        echo "Допустимые имена: isp, hq-rtr, br-rtr, hq-srv, br-srv" >&2
        exit 1
        ;;
esac

exit 0

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

# Общие настройки
DNS_SERVER="8.8.8.8"

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
        configure_nm_connection "ens18-dhcp" "ens18" "DHCP" "" "$DNS_SERVER"

        # К HQ-RTR (ens19)
        configure_nm_connection "ens19-to-hq" "ens19" "172.16.1.1/28" "none" "$DNS_SERVER"

        # К BR-RTR (ens20)
        configure_nm_connection "ens20-to-br" "ens20" "172.16.2.1/28" "none" "$DNS_SERVER"

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
        configure_nm_connection "ens18-to-isp" "ens18" "172.16.1.2/28" "172.16.1.1" "$DNS_SERVER"

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
        configure_vlan "vlan100" "ens19" "100" "172.16.10.1/27" "none" "$DNS_SERVER"
        configure_vlan "vlan200" "ens19" "200" "172.16.20.1/24" "none" "$DNS_SERVER"
        configure_vlan "vlan999" "ens19" "999" "172.16.99.1/29" "none" "$DNS_SERVER"

        # GRE-туннель к BR-RTR (с TTL 64)
        configure_gre "gre-tun" "172.16.1.2" "172.16.2.2" "192.168.0.2/30" "$DNS_SERVER"

        enable_ip_forward

        # NAT для локальных сетей
        iptables -t nat -A POSTROUTING -s 172.16.10.0/27 -o ens18 -j MASQUERADE 2>/dev/null || true
        iptables -t nat -A POSTROUTING -s 172.16.20.0/24 -o ens18 -j MASQUERADE 2>/dev/null || true
        iptables -t nat -A POSTROUTING -s 172.16.99.0/29 -o ens18 -j MASQUERADE 2>/dev/null || true
        ;;

    br-rtr)
        # Основной интерфейс к ISP (ens18)
        configure_nm_connection "ens18-to-isp" "ens18" "172.16.2.2/28" "172.16.2.1" "$DNS_SERVER"

        # Локальная сеть (ens19)
        configure_nm_connection "ens19-local" "ens19" "172.16.30.1/28" "none" "$DNS_SERVER"

        # GRE-туннель к HQ-RTR (с TTL 64)
        configure_gre "gre-tun" "172.16.2.2" "172.16.1.2" "192.168.0.1/30" "$DNS_SERVER"

        enable_ip_forward

        # NAT для локальной сети
        iptables -t nat -A POSTROUTING -s 172.16.30.0/28 -o ens18 -j MASQUERADE 2>/dev/null || true
        ;;

    hq-srv)
        # VLAN-интерфейс для сервера
        nmcli connection delete "ens18-vlan100" 2>/dev/null || true
        nmcli connection add type vlan con-name "ens18-vlan100" ifname "ens18.100" \
            dev "ens18" id "100" ipv4.method manual ipv4.addresses "172.16.10.2/27" \
            ipv4.gateway "172.16.10.1" ipv4.dns "$DNS_SERVER"
        nmcli connection up "ens18-vlan100"
        ;;

    *)
        echo "Ошибка: неизвестный хост '$HOSTNAME'" >&2
        echo "Допустимые имена: isp, hq-rtr, br-rtr, hq-srv" >&2
        exit 1
        ;;
esac

exit 0
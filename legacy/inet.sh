#!/bin/bash
# Настройка firewalld на ISP, HQ-RTR, BR-RTR
# Скрипт автоматически определяет хост и применяет соответствующую конфигурацию
# Актуализировано под новые IP-адреса

set -e

# Проверка root
if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: скрипт должен запускаться от root" >&2
    exit 1
fi

# Определяем короткое имя хоста (без домена)
HOSTNAME=$(hostname -s | tr '[:upper:]' '[:lower:]')

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=module1_config.sh
source "$SCRIPT_DIR/module1_config.sh"

# Включение IP forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi

# Установка firewalld (для ALT Linux / Debian)
apt-get update
apt-get install -y firewalld

# Запуск и включение
systemctl start firewalld
systemctl enable firewalld

# Вспомогательные функции для добавления правил (с проверкой)
add_service() {
    local zone=$1
    local service=$2
    if ! firewall-cmd --zone="$zone" --query-service="$service" >/dev/null 2>&1; then
        firewall-cmd --zone="$zone" --add-service="$service" --permanent
    fi
}

add_port() {
    local zone=$1
    local port=$2
    if ! firewall-cmd --zone="$zone" --query-port="$port" >/dev/null 2>&1; then
        firewall-cmd --zone="$zone" --add-port="$port" --permanent
    fi
}

add_source() {
    local zone=$1
    local source=$2
    if ! firewall-cmd --zone="$zone" --query-source="$source" >/dev/null 2>&1; then
        firewall-cmd --zone="$zone" --add-source="$source" --permanent
    fi
}

add_interface() {
    local zone=$1
    local iface=$2
    if ! firewall-cmd --zone="$zone" --query-interface="$iface" >/dev/null 2>&1; then
        firewall-cmd --zone="$zone" --add-interface="$iface" --permanent
    fi
}

case "$HOSTNAME" in
    isp)

        # Назначение интерфейсов зонам
        add_interface external ens18
        add_interface internal ens19
        add_interface internal ens20

        # Маскарад на external
        firewall-cmd --zone=external --add-masquerade --permanent
        firewall-cmd --zone=external --add-forward --permanent
        #TEST
        firewall-cmd --permanent --policy=gateway-lan-to-world --remove-disable

        # Источники внутренних сетей (между ISP и роутерами)
        add_source internal "$ISP_HQ_NET_CIDR"
        add_source internal "$ISP_BR_NET_CIDR"

        # Сервисы на внешнем интерфейсе
        add_service external http
        add_service external https

        # Блокировка ICMP (echo) на внешнем интерфейсе
        firewall-cmd --zone=external --add-icmp-block-inversion --permanent
        firewall-cmd --zone=external --add-icmp-block={echo-request,echo-reply} --permanent

        # Сервисы для внутренних сетей (между роутерами)
        add_service internal ssh
        add_service internal gre
        add_service internal dhcp
        add_service internal dns
        add_service internal samba
        add_service internal ntp
        add_service external ntp
        add_service internal http
        add_port internal 631/tcp
        add_port internal 445/tcp

        firewall-cmd --zone=internal --add-service={ldap,ldaps,kerberos,kpasswd,dns,netbios-ns,netbios-dgm,netbios-ssn,microsoft-ds,rpc-bind} --permanent
        # Применить изменения
        firewall-cmd --reload

        # Вывод информации
        echo "=== External zone ==="
        firewall-cmd --zone=external --list-all
        echo "=== Internal zone ==="
        firewall-cmd --zone=internal --list-all
        ;;

    hq-rtr)

        # Внешний интерфейс к ISP
        add_interface external ens18
        firewall-cmd --zone=external --add-masquerade --permanent

        # Внутренние сети (VLAN) – добавляем как источники в зону internal
        add_source internal "$HQ_SRV_NET_CIDR"
        add_source internal "$HQ_CLI_NET_CIDR"
        add_source internal "$MGMT_NET_CIDR"

        # GRE туннель (между HQ-RTR и BR-RTR) в trusted зону
        add_source trusted "$GRE_NET_CIDR"

        # Разрешить GRE протокол на внешнем интерфейсе
        add_service external gre
        add_service internal ntp
        add_service external ntp

        # Включить форвардинг для internal зоны
        firewall-cmd --zone=internal --add-forward --permanent

        firewall-cmd --zone=trusted --add-protocol=ospf --permanent
        #TEST
        firewall-cmd --permanent --policy=gateway-lan-to-world --remove-disable

        firewall-cmd --zone=internal --add-service={ldap,ldaps,kerberos,kpasswd,dns,netbios-ns,netbios-dgm,netbios-ssn,microsoft-ds,rpc-bind} --permanent
        add_interface trusted gre-tun@NONE

        # Применить изменения
        firewall-cmd --reload

        echo "=== External zone ==="
        firewall-cmd --zone=external --list-all
        echo "=== Internal zone ==="
        firewall-cmd --zone=internal --list-all
        echo "=== Trusted zone ==="
        firewall-cmd --zone=trusted --list-all
        ;;

    br-rtr)

        # Внешний интерфейс к ISP
        add_interface external ens18
        firewall-cmd --zone=external --add-masquerade --permanent

        # Локальная сеть
        add_source internal "$BR_SRV_NET_CIDR"

        # GRE туннель (между BR-RTR и HQ-RTR) в trusted зону
        add_source trusted "$GRE_NET_CIDR"

        # Разрешить GRE протокол на внешнем интерфейсе
        add_service external gre
        add_service internal ntp
        add_service external ntp

        # Включить форвардинг для internal зоны
        firewall-cmd --zone=internal --add-forward --permanent

        firewall-cmd --zone=trusted --add-protocol=ospf --permanent
        #TEST
        firewall-cmd --permanent --policy=gateway-lan-to-world --remove-disable

        add_interface trusted gre-tun@NONE
        
        firewall-cmd --zone=internal --add-service={ldap,ldaps,kerberos,kpasswd,dns,netbios-ns,netbios-dgm,netbios-ssn,microsoft-ds,rpc-bind} --permanent
        # Применить изменения
        firewall-cmd --reload

        echo "=== External zone ==="
        firewall-cmd --zone=external --list-all
        echo "=== Internal zone ==="
        firewall-cmd --zone=internal --list-all
        echo "=== Trusted zone ==="
        firewall-cmd --zone=trusted --list-all
        ;;

    *)
        echo "Ошибка: неподдерживаемый хост '$HOSTNAME'" >&2
        echo "Допустимые имена: isp, hq-rtr, br-rtr" >&2
        exit 1
        ;;
esac

echo "Настройка firewalld на $HOSTNAME успешно завершена."

#!/bin/bash
# Настройка динамической маршрутизации OSPF между HQ-RTR и BR-RTR через GRE-туннель
# Используется FRRouting (FRR) с аутентификацией MD5
# Скрипт автоматически определяет хост и применяет соответствующую конфигурацию

set -e

# Проверка root
if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: скрипт должен запускаться от root" >&2
    exit 1
fi

# Определяем короткое имя хоста
HOSTNAME=$(hostname -s | tr '[:upper:]' '[:lower:]')

# Проверка, что хост поддерживается
if [[ "$HOSTNAME" != "hq-rtr" && "$HOSTNAME" != "br-rtr" ]]; then
    echo "Ошибка: скрипт предназначен только для HQ-RTR и BR-RTR, текущий хост: $HOSTNAME" >&2
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=module1_config.sh
source "$SCRIPT_DIR/module1_config.sh"

# Установка FRR (для ALT/RedOS используем dnf или apt-get в зависимости от системы)
if command -v apt-get &>/dev/null; then
    # Debian/ALT
    apt-get update
    apt-get install -y frr frr-pythontools
elif command -v dnf &>/dev/null; then
    # RedOS/Fedora
    dnf install -y frr frr-pythontools
else
    echo "Неизвестный менеджер пакетов, установите FRR вручную"
    exit 1
fi

# Включаем демон ospfd в /etc/frr/daemons
sed -i 's/^ospfd=.*/ospfd=yes/' /etc/frr/daemons

# Формирование конфигурации в зависимости от хоста
case "$HOSTNAME" in
    hq-rtr)
        cat > /etc/frr/frr.conf << EOF
!
frr version 7.5.1
frr defaults traditional
!
hostname hq-rtr.$DOMAIN
!
router-id $HQ_GRE_IP
!
interface gre-tun
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 $OSPF_PASSWORD
 ip ospf network point-to-point
 ip ospf cost 10
!
router ospf
 ospf router-id $HQ_GRE_IP
 network $GRE_NET_CIDR area 0.0.0.0
 network $HQ_SRV_NET_CIDR area 0.0.0.0
 network $HQ_CLI_NET_CIDR area 0.0.0.0
 network $MGMT_NET_CIDR area 0.0.0.0
 passive-interface default
 no passive-interface gre-tun
!
line vty
!
EOF
        ;;
    br-rtr)
        cat > /etc/frr/frr.conf << EOF
!
frr version 7.5.1
frr defaults traditional
!
hostname br-rtr.$DOMAIN
!
router-id $BR_GRE_IP
!
interface gre-tun
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 $OSPF_PASSWORD
 ip ospf network point-to-point
 ip ospf cost 10
!
router ospf
 ospf router-id $BR_GRE_IP
 network $GRE_NET_CIDR area 0.0.0.0
 network $BR_SRV_NET_CIDR area 0.0.0.0
 passive-interface default
 no passive-interface gre-tun
!
line vty
!
EOF
        ;;
esac

# Устанавливаем правильные права
chown frr:frr /etc/frr/frr.conf
chmod 640 /etc/frr/frr.conf

# Разрешаем OSPF протокол в firewalld (если используется)
if systemctl is-active firewalld &>/dev/null; then
    firewall-cmd --zone=trusted --add-protocol=ospf --permanent
    firewall-cmd --reload
fi

# Перезапускаем FRR
systemctl enable frr
systemctl restart frr

# Проверка статуса
systemctl status frr --no-pager

echo "vtysh -c 'show ip ospf neighbor'"

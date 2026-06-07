#!/bin/bash
# Настройка DHCP сервера на HQ-RTR для сети HQ-CLI
# Скрипт предназначен ТОЛЬКО для хоста hq-rtr (проверка по hostname)

set -e

# Проверка выполнения от root
if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: скрипт должен запускаться от root" >&2
    exit 1
fi

# Определяем короткое имя хоста (без домена)
HOSTNAME=$(hostname -s | tr '[:upper:]' '[:lower:]')

# Проверка, что скрипт запущен на hq-rtr
if [[ "$HOSTNAME" != "hq-rtr" ]]; then
    echo "Ошибка: скрипт предназначен только для хоста hq-rtr, а текущий хост: $HOSTNAME" >&2
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=module1_config.sh
source "$SCRIPT_DIR/module1_config.sh"

# Установка DHCP сервера (для ALT Linux / Debian-совместимых)
apt-get update
apt-get install -y dhcp-server

# Конфигурация DHCP для подсети HQ-CLI

cat > /etc/dhcp/dhcpd.conf << EOF
subnet $HQ_CLI_NET_IP netmask $HQ_CLI_NETMASK {
    range $HQ_CLI_FIRST_DHCP_IP $HQ_CLI_LAST_DHCP_IP;
    option routers $HQ_CLI_GW_IP;
    option domain-name-servers $HQ_SRV_IP;
    option domain-name "$DOMAIN";
    default-lease-time 600;
    max-lease-time 7200;
}
EOF

# Указываем интерфейс, на котором DHCP будет ожидать запросы (VLAN200)
echo "DHCPDARGS=\"ens19.$HQ_CLI_VLAN_ID\"" > /etc/sysconfig/dhcpd

# Включаем и запускаем службу
systemctl enable dhcpd
systemctl restart dhcpd

echo "DHCP start"

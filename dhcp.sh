#!/bin/bash
# Настройка DHCP сервера на HQ-RTR для сети VLAN200 (172.16.20.0/24)
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

# Установка DHCP сервера (для ALT Linux / Debian-совместимых)
apt-get update
apt-get install -y dhcp-server

# Конфигурация DHCP для подсети 172.16.20.0/24
# Маршрутизатор (исключаемый адрес): 172.16.20.1
# Пул для клиентов: 172.16.20.2 – 172.16.20.254
# DNS-сервер: 172.16.10.2 (HQ-SRV)
# Домен: au-team.irpo

cat > /etc/dhcp/dhcpd.conf << 'EOF'
subnet 172.16.20.0 netmask 255.255.255.0 {
    range 172.16.20.2 172.16.20.254;
    option routers 172.16.20.1;
    option domain-name-servers 172.16.10.2;
    option domain-name "au-team.irpo";
    default-lease-time 600;
    max-lease-time 7200;
}
EOF

# Указываем интерфейс, на котором DHCP будет ожидать запросы (VLAN200)
echo 'DHCPDARGS="ens19.200"' > /etc/sysconfig/dhcpd

# Включаем и запускаем службу
systemctl enable dhcpd
systemctl restart dhcpd

echo "DHCP start"
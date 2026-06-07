#!/bin/bash
# Автоматическая настройка BIND DNS сервера на RED OS (HQ-SRV)
# Скрипт предназначен ТОЛЬКО для хоста hq-srv (проверка по hostname)
# IP-адреса и домен берутся из module1_config.sh

set -e

# Проверка выполнения от root
if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: скрипт должен запускаться от root" >&2
    exit 1
fi

# Определяем короткое имя хоста (без домена)
HOSTNAME=$(hostname -s | tr '[:upper:]' '[:lower:]')

# Проверка, что скрипт запущен на hq-srv
if [[ "$HOSTNAME" != "hq-srv" ]]; then
    echo "Ошибка: скрипт предназначен только для хоста hq-srv, а текущий хост: $HOSTNAME" >&2
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=module1_config.sh
source "$SCRIPT_DIR/module1_config.sh"

# 1. Установка пакетов
echo "setup BIND"
dnf install -y bind bind-utils

# 2. Основная конфигурация
echo "setup /etc/named.conf..."
cat > /etc/named.conf << EOF
options {
    listen-on port 53 { any; };
    listen-on-v6 port 53 { none; };
    directory "/var/named";
    
    allow-query { any; };
    allow-recursion { any; };
    
    forwarders {
        $DNS_FORWARDER;
    };
    
    dnssec-validation auto;
};

# Прямая зона
zone "$DOMAIN" IN {
    type master;
    file "$DOMAIN.zone";
    allow-update { none; };
};

# Единая обратная зона для 172.16.0.0/16
zone "16.172.in-addr.arpa" IN {
    type master;
    file "172.16.rev.zone";
    allow-update { none; };
};

include "/etc/named.rfc1912.zones";
include "/etc/named.root.key";
EOF

# 3. Создание файлов зон

# Прямая зона (только актуальные записи)
echo "Создание прямой зоны..."
cat > "/var/named/$DOMAIN.zone" << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. admin.$DOMAIN. (
        2025030801 ; Serial (дата+версия)
        21600      ; Refresh
        3600       ; Retry
        604800     ; Expire
        86400 )    ; Minimum TTL

; NS запись
@          IN  NS  hq-srv.$DOMAIN.

; A записи
hq-rtr     IN  A   $ISP_HQ_RTR_IP
br-rtr     IN  A   $ISP_BR_RTR_IP
hq-srv     IN  A   $HQ_SRV_IP
hq-cli     IN  A   $HQ_CLI_DNS_IP
br-srv     IN  A   $BR_SRV_IP
docker     IN  A   $ISP_HQ_ISP_IP
web        IN  A   $ISP_BR_ISP_IP

; CNAME
moodle     IN  CNAME hq-rtr.$DOMAIN.
wiki       IN  CNAME hq-rtr.$DOMAIN.
EOF

# Единая обратная зона для 172.16.X.X
echo "Создание обратной зоны для 172.16.0.0/16..."
cat > /var/named/172.16.rev.zone << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. admin.$DOMAIN. (
        2025030801 ; Serial
        21600      ; Refresh
        3600       ; Retry
        604800     ; Expire
        86400 )    ; Minimum TTL

@          IN  NS  hq-srv.$DOMAIN.

; PTR записи
$(printf "%s" "$ISP_HQ_RTR_IP" | awk -F. '{print $4"."$3}')        IN  PTR hq-rtr.$DOMAIN.
$(printf "%s" "$HQ_SRV_IP" | awk -F. '{print $4"."$3}')        IN  PTR hq-srv.$DOMAIN.
$(printf "%s" "$HQ_CLI_DNS_IP" | awk -F. '{print $4"."$3}')        IN  PTR hq-cli.$DOMAIN.
EOF

# 5. Установка прав
chown named:named /var/named/*.zone
chmod 640 /var/named/*.zone

# 6. Проверка синтаксиса
echo "Проверка конфигурации..."
named-checkconf
named-checkzone "$DOMAIN" "/var/named/$DOMAIN.zone"
named-checkzone 16.172.in-addr.arpa /var/named/172.16.rev.zone

# 7. Часовой пояс (для Москвы)
echo "Установка часового пояса..."
timedatectl set-timezone "$TIMEZONE"

# 8. Запуск службы
echo "Запуск службы BIND..."
systemctl enable --now named
systemctl status named --no-pager

echo "Настройка DNS завершена."

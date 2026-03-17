#!/bin/bash
# Автоматическая настройка BIND DNS сервера на RED OS (HQ-SRV)
# Скрипт предназначен ТОЛЬКО для хоста hq-srv (проверка по hostname)
# Актуализировано под новые IP-адреса (vlan100: 172.16.10.0/27,
# vlan200: 172.16.20.0/24, локалка BR: 172.16.30.0/28 и т.д.)

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

# 1. Установка пакетов
echo "setup BIND"
dnf install -y bind bind-utils

# 2. Основная конфигурация
echo "setup /etc/named.conf..."
cat > /etc/named.conf << 'EOF'
options {
    listen-on port 53 { any; };
    listen-on-v6 port 53 { none; };
    directory "/var/named";
    
    allow-query { any; };
    allow-recursion { any; };
    
    forwarders {
        8.8.8.8;
        8.8.4.4;
    };
    
    dnssec-validation auto;
};

# Прямая зона
zone "au-team.irpo" IN {
    type master;
    file "au-team.irpo.zone";
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
cat > /var/named/au-team.irpo.zone << 'EOF'
$TTL 86400
@   IN  SOA hq-srv.au-team.irpo. admin.au-team.irpo. (
        2025030801 ; Serial (дата+версия)
        21600      ; Refresh
        3600       ; Retry
        604800     ; Expire
        86400 )    ; Minimum TTL

; NS запись
@          IN  NS  hq-srv.au-team.irpo.

; A записи
hq-rtr     IN  A   172.16.1.2
br-rtr     IN  A   172.16.2.2
hq-srv     IN  A   172.16.10.2
hq-cli     IN  A   172.16.20.2
br-srv     IN  A   172.16.30.2
docker     IN  A   172.16.1.1
web        IN  A   172.16.2.1

; CNAME
moodle     IN  CNAME hq-rtr.au-team.irpo.
wiki       IN  CNAME hq-rtr.au-team.irpo.
EOF

# Единая обратная зона для 172.16.X.X
echo "Создание обратной зоны для 172.16.0.0/16..."
cat > /var/named/172.16.rev.zone << 'EOF'
$TTL 86400
@   IN  SOA hq-srv.au-team.irpo. admin.au-team.irpo. (
        2025030801 ; Serial
        21600      ; Refresh
        3600       ; Retry
        604800     ; Expire
        86400 )    ; Minimum TTL

@          IN  NS  hq-srv.au-team.irpo.

; PTR записи
; hq-rtr (172.16.1.2)
2.1        IN  PTR hq-rtr.au-team.irpo.
; hq-srv (172.16.10.2)
2.10       IN  PTR hq-srv.au-team.irpo.
; hq-cli (172.16.20.3)
2.20       IN  PTR hq-cli.au-team.irpo.
EOF

# 5. Установка прав
chown named:named /var/named/*.zone
chmod 640 /var/named/*.zone

# 6. Проверка синтаксиса
echo "Проверка конфигурации..."
named-checkconf
named-checkzone au-team.irpo /var/named/au-team.irpo.zone
named-checkzone 16.172.in-addr.arpa /var/named/172.16.rev.zone

# 7. Часовой пояс (для Москвы)
echo "Установка часового пояса..."
timedatectl set-timezone Europe/Moscow

# 8. Запуск службы
echo "Запуск службы BIND..."
systemctl enable --now named
systemctl status named --no-pager

echo "Настройка DNS завершена."
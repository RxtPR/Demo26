#!/bin/bash
# Скрипт настройки NTP-сервера на базе chrony для ISP (ALT Server) и клиентов
set -e

# Функция для проверки прав root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Ошибка: Скрипт должен быть запущен от root" >&2
        exit 1
    fi
}

# Функция настройки сервера на ISP (ALT Server)
configure_isp_server() {
    echo "=== Настройка NTP-сервера на ISP (ALT Server) ==="

    # Установка chrony на ALT Server (используем apt-get)
    apt-get update
    apt-get install -y chrony

    # Файл конфигурации для ALT Server: /etc/chrony/chrony.conf
    CONF_FILE="/etc/chrony/chrony.conf"

    # Создаём резервную копию
    cp "$CONF_FILE" "${CONF_FILE}.bak"

    # Очищаем файл и записываем новую конфигурацию
    cat > "$CONF_FILE" << 'EOF'
# Вышестоящий NTP-сервер (можно заменить на любой публичный)
# Используем pool.ntp.org как пример
pool pool.ntp.org iburst

# Стратум сервера - 5 (означает, что сервер находится в 5 шагах от эталонных часов)
local stratum 5

# Разрешаем доступ клиентам из сетей HQ и BR
allow 172.16.1.0/24   # сеть HQ
allow 172.16.2.0/24   # сеть BR

# Записываем скорость дрейфа системных часов
driftfile /var/lib/chrony/drift

# Разрешить ступенчатую коррекцию времени при первом запуске
makestep 1.0 3

# Включаем синхронизацию аппаратных часов
rtcsync

# Файл с ключами для аутентификации
keyfile /etc/chrony/chrony.keys

# Каталог для логов
logdir /var/log/chrony
EOF

    # Включаем и запускаем сервис (для ALT Server сервис называется chrony)
    systemctl enable chrony
    systemctl restart chrony

    # Открываем порт NTP (123/udp) в firewalld (если установлен)
    if command -v firewall-cmd &> /dev/null; then
        firewall-cmd --zone=internal --add-service=ntp --permanent
        firewall-cmd --reload
        echo "Firewall: открыт порт NTP"
    else
        echo "Firewalld не найден, проверьте правила iptables вручную"
    fi

    # Проверка статуса
    echo "Проверка статуса сервера chrony:"
    chronyc tracking
    echo "Проверка источников:"
    chronyc sources -v

    echo "=== Настройка ISP завершена ==="
    echo "!!!Добавь правила ntp на RTR!!!"

}

# Функция настройки клиента (универсальная для RedOS и ALT)
configure_client() {
    local CLIENT_NAME="$1"
    local SERVER_IP="172.16.2.1"  # IP ISP со стороны BR
    local CONF_FILE=""
    local SERVICE_NAME=""

    echo "=== Настройка клиента NTP на $CLIENT_NAME ==="

    # Определяем ОС и соответствующие пути
    if [ -f /etc/redos-release ] || [ -f /etc/redhat-release ]; then
        # RedOS / RHEL-подобные
        echo "Обнаружена RedOS/RHEL-система"
        CONF_FILE="/etc/chrony.conf"
        SERVICE_NAME="chronyd"
        dnf install -y chrony
    elif [ -f /etc/altlinux-release ]; then
        # ALT Server
        echo "Обнаружена ALT Linux"
        CONF_FILE="/etc/chrony/chrony.conf"
        SERVICE_NAME="chrony"
        apt-get install -y chrony
    else
        # По умолчанию как RedOS
        CONF_FILE="/etc/chrony.conf"
        SERVICE_NAME="chronyd"
        dnf install -y chrony 2>/dev/null || apt-get install -y chrony
    fi

    # Создаём резервную копию
    cp "$CONF_FILE" "${CONF_FILE}.bak"

    # Настраиваем конфиг (оставляем только наш сервер)
    cat > "$CONF_FILE" << EOF
# Сервер времени ISP
server $SERVER_IP iburst

# Записываем скорость дрейфа
driftfile /var/lib/chrony/drift

# Разрешить ступенчатую коррекцию времени
makestep 1.0 3

# Включаем синхронизацию аппаратных часов
rtcsync

# Файл с ключами
keyfile /etc/chrony.keys

# Каталог для логов
logdir /var/log/chrony
EOF

    # Включаем и запускаем сервис
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"

    # Проверка
    echo "Проверка синхронизации на $CLIENT_NAME:"
    chronyc sources -v
    chronyc tracking | grep Stratum

    echo "=== Настройка клиента $CLIENT_NAME завершена ==="
}

# ------------------- Основная часть -------------------
check_root

# Определяем полное имя хоста
HOSTNAME=$(hostname -f)

case "$HOSTNAME" in
    isp*|ISP*|router*|Router*)
        # Любой вариант имени ISP (можно уточнить)
        configure_isp_server
        ;;
    hq-srv*|HQ-SRV*)
        configure_client "HQ-SRV"
        ;;
    hq-cli*|HQ-CLI*)
        configure_client "HQ-CLI"
        ;;
    br-rtr*|BR-RTR*)
        configure_client "BR-RTR"
        ;;
    br-srv*|BR-SRV*)
        configure_client "BR-SRV"
        ;;
    *)
        echo "Ошибка: неизвестный хост $HOSTNAME" >&2
        echo "Скрипт предназначен для: ISP, HQ-SRV, HQ-CLI, BR-RTR, BR-SRV" >&2
        exit 1
        ;;
esac

echo "Готово! Проверьте синхронизацию командой: chronyc tracking"
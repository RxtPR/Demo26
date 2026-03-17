#!/bin/bash
# Скрипт создания пользователей и настройки доступа
# Автоматически определяет хост и применяет соответствующую конфигурацию
# Поддерживаемые хосты: hq-rtr, br-rtr (ALT Linux) и hq-srv, br-srv (RED OS)

set -e

# Проверка выполнения от root
if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: скрипт должен запускаться от root" >&2
    exit 1
fi

# Определяем короткое имя хоста (без домена)
HOSTNAME=$(hostname -s | tr '[:upper:]' '[:lower:]')

case "$HOSTNAME" in
    hq-rtr|br-rtr)
        # Настройка для RTR (ALT Linux)
        echo "Настройка пользователя net_admin на $HOSTNAME"

        # Создание пользователя net_admin
        useradd -u 2026 -m net_admin 2>/dev/null || echo "Пользователь net_admin уже существует"

        # Установка пароля с правильным экранированием
        echo 'net_admin:P@ssw0rd' | chpasswd
        if [ $? -eq 0 ]; then
            echo "✓ Пароль для net_admin установлен"
        else
            echo "✗ Ошибка установки пароля для net_admin"
            exit 1
        fi

        # Проверка, что аккаунт не заблокирован
        passwd -S net_admin | grep -q "PS" || echo "⚠ Внимание: аккаунт net_admin может быть заблокирован"

        # Добавление в группу wheel
        if getent group wheel >/dev/null; then
            usermod -aG wheel net_admin
        else
            echo "Группа wheel не найдена, создаю..."
            groupadd wheel
            usermod -aG wheel net_admin
        fi

        # Настройка sudo без пароля
        if ! grep -q "^net_admin ALL=(ALL) NOPASSWD:ALL" /etc/sudoers; then
            echo "net_admin ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
        fi
        ;;

    hq-srv|br-srv)
        # Настройка для SRV (RED OS)
        echo "Настройка пользователя sshuser на $HOSTNAME"

        # Создание пользователя sshuser
        useradd -u 2026 -m sshuser 2>/dev/null || echo "Пользователь sshuser уже существует"

        # Установка пароля с правильным экранированием
        echo 'sshuser:P@ssw0rd' | chpasswd
        if [ $? -eq 0 ]; then
            echo "✓ Пароль для sshuser установлен"
        else
            echo "✗ Ошибка установки пароля для sshuser"
            exit 1
        fi

        # Проверка, что аккаунт не заблокирован
        passwd -S sshuser | grep -q "PS" || echo "⚠ Внимание: аккаунт sshuser может быть заблокирован"

        # Добавление в группу wheel
        usermod -aG wheel sshuser

        # Настройка sudo без пароля
        if ! grep -q "^sshuser ALL=(ALL) NOPASSWD:ALL" /etc/sudoers; then
            echo "sshuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
        fi

        # Создание баннера
        echo "Authorized access only" > /etc/ssh/banner

        # Настройка SSH
        sed -i 's/^#Port 22/Port 2026/' /etc/ssh/sshd_config
        sed -i 's/^#MaxAuthTries 6/MaxAuthTries 2/' /etc/ssh/sshd_config

        # Добавление AllowUsers если еще не добавлено
        if ! grep -q "^AllowUsers sshuser" /etc/ssh/sshd_config; then
            echo "AllowUsers sshuser" >> /etc/ssh/sshd_config
        fi

        # Добавление Banner если еще не добавлено
        if ! grep -q "^Banner /etc/ssh/banner" /etc/ssh/sshd_config; then
            echo "Banner /etc/ssh/banner" >> /etc/ssh/sshd_config
        fi

        # Проверка SELinux
        echo "Проверка статуса SELinux:"
        if command -v sestatus >/dev/null 2>&1; then
            sestatus
            CONFIG_FILE="/etc/selinux/config"
            if [ -f "$CONFIG_FILE" ]; then
                cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
                sed -i 's/^SELINUX=.*/SELINUX=disabled/' "$CONFIG_FILE"
                echo "Reboot"
            fi
        else
            echo "SELinux не установлен или не активен"
        fi

        # Перезапуск SSH
        systemctl restart sshd
        echo "Настройка пользователя sshuser на $HOSTNAME завершена"
        echo "Внимание: SSH теперь слушает порт 2026, используйте: ssh -p 2026 sshuser@<IP>"
        ;;

    *)
        echo "Ошибка: неподдерживаемый хост '$HOSTNAME'" >&2
        echo "Допустимые имена: hq-rtr, br-rtr, hq-srv, br-srv" >&2
        exit 1
        ;;
esac

echo "Complite $HOSTNAME"
exit 0
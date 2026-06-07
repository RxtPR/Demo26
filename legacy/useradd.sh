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

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=module1_config.sh
source "$SCRIPT_DIR/module1_config.sh"

case "$HOSTNAME" in
    hq-rtr|br-rtr)
        # Настройка для RTR (ALT Linux)
        echo "Настройка пользователя $RTR_USER на $HOSTNAME"

        # Создание пользователя маршрутизатора
        useradd -m "$RTR_USER" 2>/dev/null || echo "Пользователь $RTR_USER уже существует"

        # Установка пароля с правильным экранированием
        echo "$RTR_USER:$RTR_PASSWORD" | chpasswd
        if [ $? -eq 0 ]; then
            echo "Пароль для $RTR_USER установлен"
        else
            echo "Ошибка установки пароля для $RTR_USER"
            exit 1
        fi

        # Проверка, что аккаунт не заблокирован
        passwd -S "$RTR_USER" | grep -q "PS" || echo "Внимание: аккаунт $RTR_USER может быть заблокирован"

        # Добавление в группу wheel
        if getent group wheel >/dev/null; then
            usermod -aG wheel "$RTR_USER"
        else
            echo "Группа wheel не найдена, создаю..."
            groupadd wheel
            usermod -aG wheel "$RTR_USER"
        fi

        # Настройка sudo без пароля
        if ! grep -q "^$RTR_USER ALL=(ALL) NOPASSWD:ALL" /etc/sudoers; then
            echo "$RTR_USER ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
        fi
        ;;

    hq-srv|br-srv)
        # Настройка для SRV (RED OS)
        echo "Настройка пользователя $SRV_USER на $HOSTNAME"

        # Создание пользователя сервера
        useradd -u "$SRV_UID" -m "$SRV_USER" 2>/dev/null || echo "Пользователь $SRV_USER уже существует"

        # Установка пароля с правильным экранированием
        echo "$SRV_USER:$SRV_PASSWORD" | chpasswd
        if [ $? -eq 0 ]; then
            echo "Пароль для $SRV_USER установлен"
        else
            echo "Ошибка установки пароля для $SRV_USER"
            exit 1
        fi

        # Проверка, что аккаунт не заблокирован
        passwd -S "$SRV_USER" | grep -q "PS" || echo "Внимание: аккаунт $SRV_USER может быть заблокирован"

        # Добавление в группу wheel
        usermod -aG wheel "$SRV_USER"

        # Настройка sudo без пароля
        if ! grep -q "^$SRV_USER ALL=(ALL) NOPASSWD:ALL" /etc/sudoers; then
            echo "$SRV_USER ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
        fi

        # Создание баннера
        echo "$SSH_BANNER" > /etc/ssh/banner

        # Настройка SSH
        sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
        sed -i "s/^#\?MaxAuthTries .*/MaxAuthTries $SSH_MAX_AUTH_TRIES/" /etc/ssh/sshd_config

        # Добавление AllowUsers если еще не добавлено
        if grep -q "^AllowUsers " /etc/ssh/sshd_config; then
            sed -i "s/^AllowUsers .*/AllowUsers $SRV_USER/" /etc/ssh/sshd_config
        else
            echo "AllowUsers $SRV_USER" >> /etc/ssh/sshd_config
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
        echo "Настройка пользователя $SRV_USER на $HOSTNAME завершена"
        echo "Внимание: SSH теперь слушает порт $SSH_PORT, используйте: ssh -p $SSH_PORT $SRV_USER@<IP>"
        ;;

    *)
        echo "Ошибка: неподдерживаемый хост '$HOSTNAME'" >&2
        echo "Допустимые имена: hq-rtr, br-rtr, hq-srv, br-srv" >&2
        exit 1
        ;;
esac

echo "Complite $HOSTNAME"
exit 0

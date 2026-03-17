#!/bin/bash
# Скрипт настройки sudo для группы hq на HQ-CLI (без ввода в домен)

# Проверка root
if [ "$EUID" -ne 0 ]; then
    echo "Запустите от root" >&2
    exit 1
fi

# Проверка хоста (опционально)
HOSTNAME=$(hostname -s | tr '[:upper:]' '[:lower:]')
if [ "$HOSTNAME" != "hq-cli" ]; then
    echo "Этот скрипт предназначен для hq-cli" >&2
    exit 1
fi

# Параметры
SUDO_GROUP="hq"


# Создание файла sudoers для группы hq
SUDOERS_FILE="/etc/sudoers.d/domain_hq"
cat > $SUDOERS_FILE << EOF
# Разрешить группе $SUDO_GROUP выполнять ограниченный набор команд
%$SUDO_GROUP ALL=(ALL) /bin/cat, /bin/grep, /usr/bin/id
EOF

# Установка правильных прав доступа
chmod 440 $SUDOERS_FILE

# Проверка синтаксиса sudoers
visudo -c -f $SUDOERS_FILE >/dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "Правило sudo успешно добавлено."
else
    echo "шибка в синтаксисе sudoers. Проверьте файл вручную."
    exit 1
fi

echo "compl"
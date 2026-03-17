#!/bin/bash
# Финальный скрипт настройки Samba DC на BR-SRV (без автоматического падения)
# Использует внешний DNS 172.16.10.2

# Проверка root
if [ "$EUID" -ne 0 ]; then
    echo "Запустите от root" >&2
    exit 1
fi

# Проверка хоста
HOSTNAME=$(hostname -s | tr '[:upper:]' '[:lower:]')
if [ "$HOSTNAME" != "br-srv" ]; then
    echo "Этот скрипт только для br-srv" >&2
    exit 1
fi

# Параметры
DOMAIN="au-team.irpo"
REALM="AU-TEAM.IRPO"
ADMIN_PASS="P@ssw0rd"
DNS_FORWARDER="172.16.10.2"
SERVER_IP="172.16.30.2"

# 1. Полная очистка предыдущих установок
echo "=== Очистка предыдущих установок ==="
systemctl stop samba 2>/dev/null || echo "Служба samba не запущена"
systemctl disable samba 2>/dev/null || echo "Служба samba не отключена"
dnf remove -y samba samba-dc samba-client samba-common-tools 2>/dev/null || echo "Пакеты не найдены или уже удалены"
rm -rf /etc/samba /var/lib/samba /var/cache/samba /var/log/samba
echo "Очистка завершена"

# 2. Установка пакетов
echo "=== Установка пакетов Samba DC ==="
dnf install -y samba-dc samba-client samba-common-tools krb5-workstation bind-utils
if [ $? -ne 0 ]; then
    echo "Ошибка при установке пакетов, проверьте подключение к репозиториям"
fi

# 3. Настройка системы
echo "=== Настройка системы ==="
systemctl disable --now systemd-resolved 2>/dev/null || echo "systemd-resolved не отключен"
rm -f /etc/resolv.conf
cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
nameserver $DNS_FORWARDER
search $DOMAIN
EOF
echo "resolv.conf настроен"

hostnamectl set-hostname "br-srv.$DOMAIN" || echo "Не удалось установить hostname"

# 4. Провижинг домена (с внутренним DNS)
echo "=== Провижинг домена $REALM ==="
rm -f /etc/samba/smb.conf

samba-tool domain provision \
    --use-rfc2307 \
    --server-role=dc \
    --realm="$REALM" \
    --domain="${DOMAIN%%.*}" \
    --adminpass="$ADMIN_PASS" \
    --dns-backend=SAMBA_INTERNAL \
    --option="interfaces=lo $SERVER_IP" \
    --option="bind interfaces only=yes"
if [ $? -ne 0 ]; then
    echo "Провижинг завершился с ошибкой! Возможно, Samba не настроится."
else
    echo "Провижинг выполнен."
fi

# Проверка наличия файла конфигурации
if [ ! -f /var/lib/samba/private/smb.conf ]; then
    echo "Ошибка: файл /var/lib/samba/private/smb.conf не создан. Продолжаем, но возможно Samba не работает."
else
    # Создаём ссылку, если её нет
    if [ ! -L /etc/samba/smb.conf ] && [ ! -f /etc/samba/smb.conf ]; then
        ln -s /var/lib/samba/private/smb.conf /etc/samba/smb.conf || echo "Не удалось создать ссылку"
    fi
fi

# 5. Добавление DNS forwarder в конфиг Samba, если файл существует
if [ -f /var/lib/samba/private/smb.conf ]; then
    echo "=== Добавление DNS forwarder ==="
    CONF="/var/lib/samba/private/smb.conf"
    if grep -q "^[[:space:]]*dns forwarder" "$CONF"; then
        sed -i "s/^[[:space:]]*dns forwarder.*/dns forwarder = $DNS_FORWARDER/" "$CONF"
    else
        sed -i "/^\[global\]/a dns forwarder = $DNS_FORWARDER" "$CONF"
    fi
    echo "DNS forwarder добавлен"
else
    echo "Файл конфигурации Samba не найден, DNS forwarder не добавлен"
fi

# 6. Копирование Kerberos конфига (если есть)
if [ -f /var/lib/samba/private/krb5.conf ]; then
    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
    echo "Конфиг Kerberos скопирован"
else
    echo "Конфиг Kerberos не найден"
fi

# 7. Запуск службы
echo "=== Запуск Samba ==="
systemctl unmask samba 2>/dev/null || true
systemctl enable --now samba
sleep 3
systemctl status samba --no-pager || echo "Служба samba не запустилась"

# 8. Настройка firewalld (если установлен)
#if command -v firewall-cmd &>/dev/null; then
#    echo "=== Настройка firewalld ==="
#    systemctl enable --now firewalld || echo "firewalld не включен"
#   firewall-cmd --add-service={ldap,ldaps,kerberos,kpasswd,netbios-ns,netbios-dgm,netbios-ssn,microsoft-ds,rpc-bind} --permanent
#    firewall-cmd --add-port={88/tcp,88/udp,135/tcp,137-138/udp,139/tcp,389/tcp,389/udp,445/tcp,464/tcp,464/udp,636/tcp,3268-3269/tcp,49152-65535/tcp} --permanent
#    firewall-cmd --reload
#else
#    echo "firewalld не установлен, пропускаем настройку"
#fi

# 9. Проверка
echo "=== Проверка ==="
smbclient -L localhost -N && echo "Samba отвечает" || echo "Samba не отвечает"

echo "✅ Скрипт выполнен. вручную поменяй forwarder в /etc/samba/smb.conf на 172.16.10.2 Пароль администратора домена: $ADMIN_PASS"
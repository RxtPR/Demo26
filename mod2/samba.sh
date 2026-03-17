#!/bin/bash
# Финальный скрипт настройки Samba DC на BR-SRV с созданием пользователей HQ

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

# 2. Установка пакетов
dnf install -y samba-dc samba-client samba-common-tools krb5-workstation bind-utils

# 3. Настройка системы
systemctl disable --now systemd-resolved
rm -f /etc/resolv.conf
cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
nameserver $DNS_FORWARDER
search $DOMAIN
EOF

hostnamectl set-hostname "br-srv.$DOMAIN"

# 4. Провижинг домена
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

if [ ! -f /var/lib/samba/private/smb.conf ]; then
    echo "Ошибка: файл конфигурации Samba не создан."
fi

ln -s /var/lib/samba/private/smb.conf /etc/samba/smb.conf

# 5. Копирование Kerberos конфига
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf

# 6. Запуск службы
systemctl unmask samba
systemctl enable --now samba
sleep 3

# 7. Настройка firewalld (только вывод команд)
echo "firewall-cmd --add-service={ldap,ldaps,kerberos,kpasswd,netbios-ns,netbios-dgm,netbios-ssn,microsoft-ds,rpc-bind} --permanent"
echo "firewall-cmd --add-port={88/tcp,88/udp,135/tcp,137-138/udp,139/tcp,389/tcp,389/udp,445/tcp,464/tcp,464/udp,636/tcp,3268-3269/tcp,49152-65535/tcp} --permanent"
echo "firewall-cmd --reload"

# 8. Создание пользователей и группы HQ
USER_PASS="P@ssw0rd"
if ! samba-tool group list | grep -q "^hq$"; then
    samba-tool group add hq
fi

for i in {1..5}; do
    USERNAME="hquser$i"
    if ! samba-tool user list | grep -q "^$USERNAME$"; then
        samba-tool user create "$USERNAME" "$USER_PASS" --given-name="HqUser$i" --surname="User$i"
    fi
    if ! samba-tool group listmembers hq | grep -q "^$USERNAME$"; then
        samba-tool group addmembers hq "$USERNAME"
    fi
done

# 9. Установка DNS forwarder и перезапуск Samba
sed -i 's/^[[:space:]]*dns forwarder.*/dns forwarder = 172.16.10.2/' /etc/samba/smb.conf
systemctl restart samba

echo "pass: $ADMIN_PASS"
echo "user pass: $USER_PASS созданы в группе hq."
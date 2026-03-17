#!/bin/bash
# Универсальный скрипт NFS настройки для RedOS (HQ-SRV и HQ-CLI)
set -e

# Функция для проверки прав root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Ошибка: Скрипт должен быть запущен от root" >&2
        exit 1
    fi
}

# Функция для настройки сервера (HQ-SRV)
configure_server() {
    echo "=== Настройка HQ-SRV (сервер) ==="

    # Установка пакетов
    dnf install -y mdadm nfs-utils

    # Поиск двух дисков размером 1G
    DISKS=($(lsblk -d -o NAME,SIZE,TYPE | grep -E 'disk.*1G' | awk '{print $1}' | head -2))
    if [ ${#DISKS[@]} -ne 2 ]; then
        echo "Ошибка: Не найдено два диска размером 1G" >&2
        exit 1
    fi
    DISK1="/dev/${DISKS[0]}"
    DISK2="/dev/${DISKS[1]}"
    echo "Используются диски: $DISK1 и $DISK2"

    # Создание RAID0
    mdadm --create /dev/md0 --level=0 --raid-devices=2 "$DISK1" "$DISK2" --run --force
    sleep 2

    # Сохранение конфигурации RAID
    mkdir -p /etc/mdadm
    mdadm --detail --scan >> /etc/mdadm.conf
    echo "MDADM_CONF=/etc/mdadm.conf" >> /etc/default/mdadm

    # Создание раздела
    parted /dev/md0 mklabel msdos -s
    parted /dev/md0 mkpart primary ext4 0% 100% -s
    PART="/dev/md0p1"
    sleep 2

    # Форматирование
    mkfs.ext4 -F "$PART"

    # Монтирование
    mkdir -p /raid
    mount "$PART" /raid

    # Добавление в fstab
    echo "$PART /raid ext4 defaults 0 0" >> /etc/fstab

    # Создание каталога NFS и установка прав доступа (чтение и запись для всех)
    mkdir -p /raid/nfs
    chmod 777 /raid/nfs

    # Настройка экспорта (доступ только для сети клиента)
    NFS_CLIENT_NET="172.16.20.0/24"
    echo "/raid/nfs $NFS_CLIENT_NET(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports

    # Включение NFS сервера
    systemctl enable --now nfs-server

    # Настройка firewalld
    firewall-cmd --add-service=nfs --permanent
    firewall-cmd --add-service=rpc-bind --permanent
    firewall-cmd --add-service=mountd --permanent
    firewall-cmd --reload

    # Применение экспортов
    exportfs -ra

    # Проверка
    echo "Проверка RAID:"
    mdadm --detail /dev/md0
    echo "Проверка монтирования:"
    df -h /raid
    echo "Проверка экспортов:"
    exportfs -v
    echo "Права доступа на /raid/nfs:"
    ls -ld /raid/nfs

    echo "=== Настройка HQ-SRV завершена ==="
}

# Функция для настройки клиента (HQ-CLI)
configure_client() {
    echo "=== Настройка HQ-CLI (клиент) ==="

    # Установка пакетов
    dnf install -y nfs-utils

    # Создание точки монтирования
    mkdir -p /mnt/nfs

    # Используем полное доменное имя сервера для монтирования
    SERVER_FQDN="hq-srv.au-team.irpo"
    echo "$SERVER_FQDN:/raid/nfs /mnt/nfs nfs rw,soft,intr,_netdev 0 0" >> /etc/fstab

    # Монтирование
    mount -a

    # Проверка
    echo "Проверка монтирования:"
    df -h /mnt/nfs
    ls -la /mnt/nfs

    echo "=== Настройка HQ-CLI завершена ==="
}

# ------------------- Основная часть -------------------
check_root

# Определяем короткое имя хоста (без домена) и приводим к нижнему регистру
HOSTNAME=$(hostname -s | tr '[:upper:]' '[:lower:]')

case "$HOSTNAME" in
    hq-srv)
        configure_server
        ;;
    hq-cli)
        configure_client
        ;;
    *)
        echo "Ошибка: Скрипт предназначен для хостов HQ-SRV или HQ-CLI, а текущий хост - $HOSTNAME" >&2
        exit 1
        ;;
esac
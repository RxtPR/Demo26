#!/bin/bash
# Настройка Ansible на BR-SRV с автоматическим копированием SSH-ключей

set -e

# 1. Установка Ansible
dnf install -y ansible

# 2. Создание рабочего каталога
mkdir -p /etc/ansible

# 3. Создание inventory файла с актуальными IP и пользователями
cat > /etc/ansible/hosts << 'EOF'
[hq-srv]
172.16.10.2

[hq-cli]
172.16.20.2

[hq-rtr]
172.16.1.2

[br-rtr]
172.16.2.2

[hq-srv:vars]
ansible_port=2026
ansible_user=sshuser

[hq-cli:vars]
ansible_user=user

[hq-rtr:vars]
ansible_user=net_admin

[br-rtr:vars]
ansible_user=net_admin
EOF

# 4. Генерация SSH-ключа (если нет)
if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ''
fi

# 5. Установка sshpass для автоматического ввода пароля
dnf install -y sshpass

# 6. Копирование ключей на все хосты (пароль P@ssw0rd)
PASSWORD="P@ssw0rd"

sshpass -p "$PASSWORD" ssh-copy-id -p 2026 -o StrictHostKeyChecking=no sshuser@hq-srv.au-team.irpo

sshpass -p "$PASSWORD" ssh-copy-id -p 2026 -o StrictHostKeyChecking=no sshuser@br-srv.au-team.irpo

sshpass -p "$PASSWORD" ssh-copy-id -o StrictHostKeyChecking=no net_admin@hq-rtr.au-team.irpo

sshpass -p "$PASSWORD" ssh-copy-id -o StrictHostKeyChecking=no net_admin@br-rtr.au-tema.ipo

# 7. Проверка подключения через Ansible
echo "ansible all -m ping"

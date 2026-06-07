#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Автоматическое развертывание инфраструктуры ===${NC}"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Скрипт должен запускаться от root${NC}"
   exit 1
fi

CURRENT_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
CURRENT_HOSTNAME="${CURRENT_HOSTNAME,,}"
if [[ "$CURRENT_HOSTNAME" != *br-srv* ]]; then
    echo -e "${RED}Защита от ошибочного запуска: hostname должен содержать br-srv${NC}"
    echo -e "${RED}Текущий hostname: $CURRENT_HOSTNAME${NC}"
    exit 1
fi

read -r -p "ТЫ ОБНОВИЛ ISP? [yes/No]: " ISP_UPDATED
ISP_UPDATED="${ISP_UPDATED,,}"
if [[ "$ISP_UPDATED" != "да" && "$ISP_UPDATED" != "yes" && "$ISP_UPDATED" != "y" ]]; then
    echo -e "${RED}НЕОБХОДИМО ОБЯЗАТЕЛЬНО ОБНОВИТЬ ISP!${NC}"
    exit 1
fi

# Переменные
ANSIBLE_DIR="/etc/ansible"
ISO_MOUNT="/mnt/iso"
DEFAULT_DOMAIN="au-team.irpo"
read -r -p "Введите домен задания [${DEFAULT_DOMAIN}]: " DOMAIN_INPUT
DOMAIN="${DOMAIN_INPUT:-$DEFAULT_DOMAIN}"
DOMAIN="${DOMAIN,,}"
if [[ "$DOMAIN" != *.* ]]; then
    DOMAIN="${DOMAIN}.irpo"
fi
if [[ ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    echo -e "${RED}Некорректный домен задания: $DOMAIN${NC}"
    exit 1
fi
echo -e "${GREEN}Домен задания: $DOMAIN${NC}"

ask_var() {
    local var_name=$1
    local prompt=$2
    local default_value=$3
    local value=""
    read -r -p "$prompt [$default_value]: " value
    printf -v "$var_name" '%s' "${value:-$default_value}"
}

yaml_quote() {
    local value=$1
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

ask_var SAMBA_ADMIN_PASS "Пароль Administrator домена Samba" "P@ssw0rd"
ask_var HQ_USER_PASS "Пароль пользователей hquser1..5" "P@ssw0rd"
ask_var WEB_AUTH_USER "Логин web-based аутентификации nginx" "WEB"
ask_var WEB_AUTH_PASS "Пароль web-based аутентификации nginx" "P@ssw0rd"
ask_var DB_USER "Пользователь БД веб-приложения HQ-SRV" "web"
ask_var DB_PASS "Пароль БД веб-приложения HQ-SRV" "P@ssw0rd"
ask_var DB_NAME "Имя БД веб-приложения HQ-SRV" "webdb"
ask_var DOCKER_DB_NAME "Имя БД docker-приложения" "testdb"
ask_var DOCKER_DB_USER "Пользователь БД docker-приложения" "testc"
ask_var DOCKER_DB_PASS "Пароль БД docker-приложения" "P@ssw0rd"
ask_var DOCKER_DB_ROOT_PASS "Root-пароль БД docker-приложения" "P@ssw0rd"
ask_var DOCKER_DB_IMAGE "Docker-образ БД" "mariadb:10.11"
ask_var TESTAPP_IMAGE "Docker-образ приложения" "site:latest"
ask_var DOCKER_DB_CONTAINER "Имя контейнера БД" "db"
ask_var TESTAPP_CONTAINER "Имя контейнера приложения" "tespapp"
ask_var TESTAPP_PORT "Внешний порт docker-приложения" "8080"
ask_var SSH_FORWARD_PORT "Порт проброса SSH" "2026"
ask_var CHRONY_STRATUM "Стратум chrony" "5"
ask_var SSHUSER_PASS "Пароль пользователя sshuser" "P@ssw0rd"
ask_var NET_ADMIN_PASS "Пароль пользователя net_admin" "P@ssw0rd"
ask_var ROOT_PASS "Пароль пользователя root" "toor"

# Пароли для разных пользователей
declare -A USER_PASS
USER_PASS["sshuser"]="$SSHUSER_PASS"
USER_PASS["net_admin"]="$NET_ADMIN_PASS"
USER_PASS["root"]="$ROOT_PASS"

install_package() {
    local pkg=$1
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq "$pkg"
    elif command -v dnf &>/dev/null; then
        dnf install -y -q "$pkg"
    else
        echo -e "${RED}Неизвестный пакетный менеджер${NC}"
        exit 1
    fi
}

setup_ssh_keys() {
    echo -e "${YELLOW}Настройка SSH-ключей для доступа к хостам...${NC}"
    if ! command -v sshpass &>/dev/null; then
        install_package sshpass
    fi
    if [[ ! -f /root/.ssh/id_rsa ]]; then
        ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa
    fi

    local current_host=""
    local current_user=""
    local current_port=""
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ $line =~ ^[[:space:]]+ansible_host:[[:space:]]+(.+)$ ]]; then
            current_host="${BASH_REMATCH[1]}"
        elif [[ $line =~ ^[[:space:]]+ansible_user:[[:space:]]+(.+)$ ]]; then
            current_user="${BASH_REMATCH[1]}"
        elif [[ $line =~ ^[[:space:]]+ansible_port:[[:space:]]+(.+)$ ]]; then
            current_port="${BASH_REMATCH[1]}"
        elif [[ $line =~ ^[[:space:]]+ansible_connection:[[:space:]]+local ]]; then
            current_host=""
            current_user=""
            current_port=""
            continue
        elif [[ $line =~ ^[[:space:]]*[a-zA-Z] ]] && [[ -n "$current_host" ]]; then
            if [[ -n "$current_host" && "$current_host" != "192.168.2.2" ]]; then
                local user="${current_user:-root}"
                local port="${current_port:-22}"
                local pass="${USER_PASS[$user]}"
                if [[ -z "$pass" ]]; then
                    echo -e "${RED}Не задан пароль для пользователя $user на хосте $current_host${NC}"
                    exit 1
                fi
                echo -e "${YELLOW}Копирование ключа на $current_host (пользователь $user, порт $port)...${NC}"
                sshpass -p "$pass" ssh-copy-id -o StrictHostKeyChecking=no -p "$port" "$user@$current_host"
            fi
            current_host=""
            current_user=""
            current_port=""
        fi
    done < "$ANSIBLE_DIR/inventory.yml"
    if [[ -n "$current_host" && "$current_host" != "192.168.2.2" ]]; then
        local user="${current_user:-root}"
        local port="${current_port:-22}"
        local pass="${USER_PASS[$user]}"
        if [[ -z "$pass" ]]; then
            echo -e "${RED}Не задан пароль для пользователя $user на хосте $current_host${NC}"
            exit 1
        fi
        echo -e "${YELLOW}Копирование ключа на $current_host (пользователь $user, порт $port)...${NC}"
        sshpass -p "$pass" ssh-copy-id -o StrictHostKeyChecking=no -p "$port" "$user@$current_host"
    fi
}

# --- Установка Ansible ---
if ! command -v ansible &>/dev/null; then
    echo -e "${YELLOW}Установка Ansible...${NC}"
    install_package ansible
fi

# --- Создание структуры Ansible ---
echo -e "${YELLOW}Создание структуры Ansible в $ANSIBLE_DIR...${NC}"
mkdir -p "$ANSIBLE_DIR"/{group_vars,roles}
cd "$ANSIBLE_DIR"

cat > ansible.cfg << 'EOF'
[defaults]
inventory = /etc/ansible/inventory.yml
host_key_checking = False
stdout_callback = yaml
gathering = smart
EOF

cat > inventory.yml << EOF
all:
  children:
    routers:
      hosts:
        ISP:
          ansible_host: 172.16.1.1
          ansible_user: root
          ansible_port: 22
        HQ-RTR:
          ansible_host: 172.16.1.2
          ansible_user: net_admin
          ansible_port: 22
        BR-RTR:
          ansible_host: 172.16.2.2
          ansible_user: net_admin
          ansible_port: 22
    servers:
      hosts:
        HQ-SRV:
          ansible_host: 192.168.10.2
          ansible_user: sshuser
          ansible_port: $SSH_FORWARD_PORT
        BR-SRV:
          ansible_host: 192.168.2.2
          ansible_user: sshuser
          ansible_port: $SSH_FORWARD_PORT
          ansible_connection: local
    clients:
      hosts:
        HQ-CLI:
          ansible_host: 192.168.20.2
          ansible_user: root
          ansible_port: 22
EOF

cat > group_vars/all.yml << EOF
ansible_python_interpreter: /usr/bin/python3
domain: $(yaml_quote "$DOMAIN")
ntp_server: 172.16.1.1
dns_server: 192.168.10.2
samba_admin_pass: $(yaml_quote "$SAMBA_ADMIN_PASS")
hq_user_pass: $(yaml_quote "$HQ_USER_PASS")
web_auth_user: $(yaml_quote "$WEB_AUTH_USER")
web_auth_pass: $(yaml_quote "$WEB_AUTH_PASS")
db_user: $(yaml_quote "$DB_USER")
db_pass: $(yaml_quote "$DB_PASS")
db_name: $(yaml_quote "$DB_NAME")
docker_db_name: $(yaml_quote "$DOCKER_DB_NAME")
docker_db_user: $(yaml_quote "$DOCKER_DB_USER")
docker_db_pass: $(yaml_quote "$DOCKER_DB_PASS")
docker_db_root_pass: $(yaml_quote "$DOCKER_DB_ROOT_PASS")
docker_db_image: $(yaml_quote "$DOCKER_DB_IMAGE")
testapp_image: $(yaml_quote "$TESTAPP_IMAGE")
docker_db_container: $(yaml_quote "$DOCKER_DB_CONTAINER")
testapp_container: $(yaml_quote "$TESTAPP_CONTAINER")
testapp_port: $(yaml_quote "$TESTAPP_PORT")
ssh_forward_port: $(yaml_quote "$SSH_FORWARD_PORT")
chrony_stratum: $(yaml_quote "$CHRONY_STRATUM")
iso_mount: $(yaml_quote "$ISO_MOUNT")
EOF

cat > site.yml << 'EOF'
- name: Монтирование ISO на серверах
  hosts: BR-SRV, HQ-SRV
  become: yes
  roles:
    - mount_iso

- name: Настройка Samba DC
  hosts: BR-SRV
  become: yes
  roles:
    - samba_dc

- name: Настройка sudo для группы hq на HQ-CLI
  hosts: HQ-CLI
  become: yes
  tasks:
    - name: Создание файла sudoers для группы hq
      copy:
        dest: /etc/sudoers.d/domain_hq
        content: |
          # Разрешить группе hq выполнять ограниченный набор команд
          %hq ALL=(ALL) /bin/cat, /bin/grep, /usr/bin/id
        mode: '0440'
      register: sudoers_file
    - name: Проверка синтаксиса sudoers
      command: visudo -c -f /etc/sudoers.d/domain_hq
      when: sudoers_file is changed
      changed_when: false


- name: RAID0 и NFS на HQ-SRV
  hosts: HQ-SRV
  become: yes
  roles:
    - raid_nfs

- name: Настройка NTP-сервера на ISP
  hosts: ISP
  become: yes
  roles:
    - chrony_server

- name: Настройка клиентов NTP
  hosts: all:!ISP
  become: yes
  roles:
    - chrony_client

- name: Проверка ping (pong)
  hosts: BR-SRV
  become: yes
  tasks:
    - name: Пинг всех хостов
      command: ansible all -i /etc/ansible/inventory.yml -m ping
      register: ping_result
      failed_when: "'pong' not in ping_result.stdout"

- name: Docker-стек на BR-SRV
  hosts: BR-SRV
  become: yes
  roles:
    - docker_stack

- name: Веб-приложение Apache на HQ-SRV
  hosts: HQ-SRV
  become: yes
  roles:
    - apache_app

- name: Проброс портов (firewalld)
  hosts: routers
  become: yes
  roles:
    - port_forwarding

- name: Nginx proxy + auth на ISP
  hosts: ISP
  # ISP использует root, become не требуется
  roles:
    - nginx_proxy_auth

- name: Яндекс Браузер на HQ-CLI
  hosts: HQ-CLI
  become: yes
  roles:
    - yandex_browser
EOF

# --- Функция создания ролей ---
create_role() {
    local role=$1
    local tasks_content=$2
    local handlers_content=$3
    mkdir -p "$ANSIBLE_DIR/roles/$role/tasks"
    mkdir -p "$ANSIBLE_DIR/roles/$role/handlers"
    echo "$tasks_content" > "$ANSIBLE_DIR/roles/$role/tasks/main.yml"
    if [[ -n "$handlers_content" ]]; then
        echo "$handlers_content" > "$ANSIBLE_DIR/roles/$role/handlers/main.yml"
    fi
}

# Роль mount_iso
create_role "mount_iso" '
- name: Проверка существования точки монтирования
  stat:
    path: "{{ iso_mount }}"
  register: mount_point

- name: Создание точки монтирования (если не существует)
  file:
    path: "{{ iso_mount }}"
    state: directory
    mode: "0755"
  when: not mount_point.stat.exists
  become: yes

- name: Монтирование /dev/sr0
  mount:
    path: "{{ iso_mount }}"
    src: /dev/sr0
    fstype: iso9660
    opts: ro,loop
    state: mounted
    fstab: /etc/fstab
  become: yes

- name: Проверка наличия docker и web
  stat:
    path: "{{ iso_mount }}/{{ item }}"
  loop:
    - docker
    - web
  register: iso_check

- name: Убедиться, что оба каталога существуют
  assert:
    that:
      - iso_check.results[0].stat.exists
      - iso_check.results[1].stat.exists
    fail_msg: "В ISO отсутствует необходимый каталог (docker или web)"
' ''

# Роль samba_dc (исправленная на основе рабочего скрипта)
create_role "samba_dc" '
- name: Установка пакетов Samba DC
  dnf:
    name:
      - samba-dc
      - samba-client
      - samba-common-tools
      - krb5-workstation
      - bind-utils
    state: present


- name: Установка hostname
  hostname:
    name: "br-srv.{{ domain }}"

- name: Удаление старого smb.conf
  file:
    path: /etc/samba/smb.conf
    state: absent

- name: Provision домена
  command: |
    samba-tool domain provision \
      --use-rfc2307 \
      --server-role=dc \
      --realm={{ domain | upper }} \
      --domain={{ domain.split(".")[0] | upper }} \
      --adminpass="{{ samba_admin_pass }}" \
      --dns-backend=SAMBA_INTERNAL \
      --option="dns forwarder=192.168.10.2" \
      --option="interfaces=lo {{ ansible_host }}" \
      --option="bind interfaces only=yes"
  args:
    creates: /var/lib/samba/private/smb.conf


- name: Копирование krb5.conf
  copy:
    src: /var/lib/samba/private/krb5.conf
    dest: /etc/krb5.conf
    remote_src: yes

- name: Запуск и включение службы samba
  systemd:
    name: samba
    enabled: yes
    state: started
  ignore_errors: yes

- name: Добавление DNS-записей в Samba
  loop:
    - { name: hq-rtr, ip: 172.16.1.2 }
    - { name: br-rtr, ip: 172.16.2.2 }
    - { name: hq-srv, ip: 192.168.10.2 }
    - { name: hq-cli, ip: 192.168.20.2 }
    - { name: br-srv, ip: 192.168.2.2 }
    - { name: docker, ip: 172.16.1.1 }
    - { name: web, ip: 172.16.1.1 }
  command: samba-tool dns add 127.0.0.1 "{{ domain }}" "{{ item.name }}" A "{{ item.ip }}" -U "Administrator%{{ samba_admin_pass }}"
  register: samba_dns_add
  changed_when: samba_dns_add.rc == 0
  failed_when: >
    samba_dns_add.rc != 0 and
    "already exists" not in samba_dns_add.stderr

- name: Создание группы hq
  command: samba-tool group add hq
  args:
    creates: /var/lib/samba/private/groups/hq
  ignore_errors: yes

- name: Создание пользователей hquser1..5
  loop: "{{ range(1,6)|list }}"
  command: samba-tool user create hquser{{ item }} "{{ hq_user_pass }}" --given-name="HqUser{{ item }}" --surname="User{{ item }}"
  args:
    creates: "/var/lib/samba/private/users/hquser{{ item }}"
  ignore_errors: yes

- name: Добавление пользователей в группу hq
  loop: "{{ range(1,6)|list }}"
  command: samba-tool group addmembers hq hquser{{ item }}
  ignore_errors: yes

- name: Перезапуск samba для применения настроек
  systemd:
    name: samba
    state: restarted
' '
- name: restart samba
  systemd:
    name: samba
    state: restarted
'

# Роль raid_nfs (исправленная)
create_role "raid_nfs" '
- name: Установка mdadm, nfs-utils
  dnf:
    name:
      - mdadm
      - nfs-utils
    state: present

- name: Создание RAID0 из /dev/sdb и /dev/sdc
  command: mdadm --create /dev/md0 --level=0 --raid-devices=2 /dev/sdb /dev/sdc
  args:
    creates: /dev/md0

- name: Сохранение конфигурации mdadm
  shell: mdadm --detail --scan > /etc/mdadm.conf
  args:
    creates: /etc/mdadm.conf

- name: Форматирование ext4
  filesystem:
    fstype: ext4
    dev: /dev/md0

- name: Монтирование в /raid
  mount:
    path: /raid
    src: /dev/md0
    fstype: ext4
    state: mounted
    opts: defaults

- name: Создание папки NFS share
  file:
    path: /raid/nfs
    state: directory
    owner: "1000"          # или имя пользователя, например 'nfsshare'
    group: "1000"          # или имя группы
    mode: "0755"

- name: Экспорт NFS для сети HQ-CLI
  lineinfile:
    path: /etc/exports
    line: "/raid/nfs 192.168.20.0/24(rw,sync,no_root_squash,all_squash,anonuid=1000,anongid=1000)"
    create: yes
  notify: restart nfs

- name: Включение и запуск nfs-server
  systemd:
    name: nfs-server
    enabled: yes
    state: started

- name: Применить изменения экспорта
  command: exportfs -a
  changed_when: false

- name: Автомонтирование на HQ-CLI
  delegate_to: HQ-CLI
  mount:
    path: /mnt/nfs
    src: "{{ ansible_host }}:/raid/nfs"
    fstype: nfs
    opts: _netdev,auto
    state: mounted
' '
- name: restart nfs
  systemd:
    name: nfs-server
    state: restarted
'
# Роль chrony_server (настройка NTP-сервера на ISP)
create_role "chrony_server" '
- name: Установка chrony
  package:
    name: chrony
    state: present

- name: Настройка конфигурации chrony (российский пул и заданный стратум)
  copy:
    dest: /etc/chrony.conf
    content: |
      # Используем российские NTP-серверы
      pool ru.pool.ntp.org iburst

      # Разрешаем синхронизацию с клиентами из локальных сетей (опционально)
      allow 172.16.0.0/16
      allow 192.168.0.0/16

      # Устанавливаем стратум (если сервер не синхронизирован с внешними источниками)
      local stratum {{ chrony_stratum }}

      # Файл с данными о времени
      driftfile /var/lib/chrony/drift
      makestep 1.0 3
      rtcsync
      logdir /var/log/chrony
    mode: "0644"
  notify: restart chrony

- name: Запуск и включение chronyd
  systemd:
    name: chronyd
    enabled: yes
    state: started

- name: Проверка статуса chrony (только для отладки)
  command: systemctl status chronyd --no-pager
  register: chrony_status
  changed_when: false
  ignore_errors: yes

- name: Вывод статуса chrony
  debug:
    msg: "{{ chrony_status.stdout_lines }}"
  when: chrony_status is defined
' '
- name: restart chrony
  systemd:
    name: chronyd
    state: restarted
'

# Роль chrony_client
create_role "chrony_client" '
- name: Установка chrony
  package:
    name: chrony
    state: present

- name: Настройка клиента
  lineinfile:
    path: /etc/chrony.conf
    regexp: "^pool"
    line: "server {{ ntp_server }} iburst"
    state: present
  notify: restart chrony
' '
- name: restart chrony
  systemd:
    name: chronyd
    state: restarted

'

# Роль docker_stack
# Роль docker_stack (исправленная)
create_role "docker_stack" '
- name: Установка Docker и Docker Compose
  dnf:
    name:
      - docker-ce
      - docker-compose
    state: present

- name: Запуск и включение docker
  systemd:
    name: docker
    enabled: yes
    state: started

- name: Загрузка образов из ISO
  command: "docker load -i {{ iso_mount }}/docker/{{ item }}"
  loop:
    - mariadb_latest.tar
    - site_latest.tar
  register: load_result
  failed_when: load_result.rc != 0
  ignore_errors: yes

- name: Создание директории для docker-compose
  file:
    path: /opt/testapp
    state: directory
    mode: "0755"

- name: Создание docker-compose.yml
  copy:
    dest: /opt/testapp/docker-compose.yml
    content: |
      services:
        db:
          image: "{{ docker_db_image }}"
          container_name: "{{ docker_db_container }}"
          restart: unless-stopped
          environment:
            MYSQL_DATABASE: "{{ docker_db_name }}"
            MYSQL_USER: "{{ docker_db_user }}"
            MYSQL_PASSWORD: "{{ docker_db_pass }}"
            MYSQL_ROOT_PASSWORD: "{{ docker_db_root_pass }}"
        testapp:
          image: "{{ testapp_image }}"
          container_name: "{{ testapp_container }}"
          restart: always
          ports:
            - "{{ testapp_port }}:8000"
          environment:
            DB_HOST: db
            DB_PORT: "3306"
            DB_NAME: "{{ docker_db_name }}"
            DB_USER: "{{ docker_db_user }}"
            DB_PASS: "{{ docker_db_pass }}"
            DB_TYPE: maria
          depends_on:
            - db

- name: Запуск стека через docker-compose
  shell: |
    cd /opt/testapp
    docker-compose up -d
  register: compose_up
  changed_when: "'Creating' in compose_up.stderr or 'Started' in compose_up.stderr"
  ignore_errors: yes

- name: Вывод предупреждения о необходимости ручной проверки
  debug:
    msg: |
      ВНИМАНИЕ: При развёртывании Docker-стека возникли проблемы.
      Пожалуйста, вручную проверьте:
        - состояние контейнеров: docker ps -a
        - логи: docker-compose -f /opt/testapp/docker-compose.yml logs
  when: load_result is failed or compose_up is failed
' ''

# Роль apache_app (исправленная, без ошибок синтаксиса)
create_role "apache_app" '
- name: Установка httpd, mariadb-server, php-mysqlnd
  dnf:
    name:
      - httpd
      - mariadb-server
      - php
      - php-mysqlnd
    state: present

- name: Запуск mariadb и httpd
  systemd:
    name: "{{ item }}"
    enabled: yes
    state: started
  loop:
    - mariadb
    - httpd

- name: Копирование файлов приложения из ISO
  copy:
    src: "{{ iso_mount }}/web/{{ item }}"
    dest: "/var/www/html/{{ item }}"
  loop:
    - index.php
    - logo.png
  notify: restart httpd

- name: Создание базы данных webdb
  shell: mysql -e "CREATE DATABASE IF NOT EXISTS {{ db_name }};"

- name: Импорт dump.sql
  shell: mysql {{ db_name }} < {{ iso_mount }}/web/dump.sql

- name: Создание пользователя БД
  shell: |
    mysql -e "CREATE USER IF NOT EXISTS '"'"'{{ db_user }}'"'"'@'"'"'localhost'"'"' IDENTIFIED BY '"'"'{{ db_pass }}'"'"';"
    mysql -e "GRANT ALL PRIVILEGES ON {{ db_name }}.* TO '"'"'{{ db_user }}'"'"'@'"'"'localhost'"'"';"
    mysql -e "FLUSH PRIVILEGES;"

- name: Настройка имени БД в index.php
  replace:
    path: /var/www/html/index.php
    regexp: "(\\$dbname\\s*=\\s*\")[^\"]*(\")"
    replace: "\\1{{ db_name }}\\2"

- name: Настройка пользователя БД в index.php
  replace:
    path: /var/www/html/index.php
    regexp: "(\\$username\\s*=\\s*\")[^\"]*(\")"
    replace: "\\1{{ db_user }}\\2"

- name: Настройка пароля БД в index.php
  replace:
    path: /var/www/html/index.php
    regexp: "(\\$password\\s*=\\s*\")[^\"]*(\")"
    replace: "\\1{{ db_pass }}\\2"
' '
- name: restart httpd
  systemd:
    name: httpd
    state: restarted
'

# Роль port_forwarding
create_role "port_forwarding" '
- name: Включение IP forwarding
  sysctl:
    name: net.ipv4.ip_forward
    value: 1
    sysctl_set: yes
    reload: yes

- name: Включение masquerade для public зоны
  firewalld:
    zone: external
    masquerade: yes
    permanent: yes
    state: enabled
  notify: reload firewalld

- name: Проброс порта 8080 на BR-SRV (BR-RTR)
  when: inventory_hostname == "BR-RTR"
  firewalld:
    zone: external
    port_forward:
    - port: "{{ testapp_port }}"          # исходный порт (source port)
      proto: tcp          # протокол
      toaddr: 192.168.2.2   # адрес назначения (если требуется)
      toport: "{{ testapp_port }}"          # порт назначения
    permanent: yes
    state: enabled
  notify: reload firewalld

- name: Проброс порта 2026 на BR-SRV (BR-RTR)
  when: inventory_hostname == "BR-RTR"
  firewalld:
    zone: external
    port_forward:
    - port: "{{ ssh_forward_port }}"          # исходный порт (source port)
      proto: tcp          # протокол
      toaddr: 192.168.2.2   # адрес назначения (если требуется)
      toport: "{{ ssh_forward_port }}"          # порт назначения
    permanent: yes
    state: enabled
  notify: reload firewalld

- name: Проброс порта 8080 на HQ-SRV (HQ-RTR)
  when: inventory_hostname == "HQ-RTR"
  firewalld:
    zone: external
    port_forward:
    - port: "{{ testapp_port }}"          # исходный порт (source port)
      proto: tcp          # протокол
      toaddr: 192.168.10.2   # адрес назначения (если требуется)
      toport: 80          # порт назначения
    permanent: yes
    state: enabled
  notify: reload firewalld

- name: Проброс порта 2026 на HQ-SRV (HQ-RTR)
  when: inventory_hostname == "HQ-RTR"
  firewalld:
    zone: external
    port_forward:
    - port: "{{ ssh_forward_port }}"          # исходный порт (source port)
      proto: tcp          # протокол
      toaddr: 192.168.10.2   # адрес назначения (если требуется)
      toport: "{{ ssh_forward_port }}"          # порт назначения
    permanent: yes
    state: enabled
  notify: reload firewalld

- name: Открытие внешних портов
  firewalld:
    port: "{{ item }}"
    permanent: yes
    state: enabled
  loop:
    - "{{ testapp_port }}/tcp"
    - "{{ ssh_forward_port }}/tcp"
  notify: reload firewalld
' '
- name: reload firewalld
  systemd:
    name: firewalld
    state: reloaded
'

# Роль nginx_proxy_auth
create_role "nginx_proxy_auth" '
- name: Установка nginx, apache2-utils
  package:
    name:
      - nginx
      - apache2-htpasswd
      - python3-module-passlib
    state: present

- name: Открытие HTTP/HTTPS в firewalld
  firewalld:
    zone: external
    service: "{{ item }}"
    permanent: yes
    state: enabled
  loop:
    - http
    - https
  notify: reload firewalld

- name: Создание .htpasswd
  htpasswd:
    path: /etc/nginx/.htpasswd
    name: "{{ web_auth_user }}"
    password: "{{ web_auth_pass }}"
    mode: "0600"

- name: Установка прав на файл .htpasswd
  file:
    path: /etc/nginx/.htpasswd
    owner: _nginx
    group: _nginx
    mode: '0600'

- name: Создание директории /etc/nginx/conf.d
  file:
    path: /etc/nginx/conf.d
    state: directory
    mode: '0755'

- name: Создание директорий для конфигураций
  file:
    path: "{{ item }}"
    state: directory
    mode: '0755'
  loop:
    - /etc/nginx/sites-available.d
    - /etc/nginx/sites-enabled.d

- name: Размещение конфигурации в sites-available.d
  copy:
    dest: /etc/nginx/sites-available.d/proxy.conf
    content: |
      server {
        listen 80;
        server_name web.{{ domain }};
        location / {
          auth_basic "Restricted";
          auth_basic_user_file /etc/nginx/.htpasswd;
          proxy_pass http://172.16.1.2:{{ testapp_port }};
        }
      }
      server {
        listen 80;
        server_name docker.{{ domain }};
        location / {
          proxy_pass http://172.16.2.2:{{ testapp_port }};
        }
      }
  notify: restart nginx

- name: Активация конфигурации через символическую ссылку
  file:
    src: /etc/nginx/sites-available.d/proxy.conf
    dest: /etc/nginx/sites-enabled.d/proxy.conf
    state: link
  notify: restart nginx
' '
- name: restart nginx
  systemd:
    name: nginx
    state: restarted
- name: reload firewalld
  systemd:
    name: firewalld
    state: reloaded
'

# Роль yandex_browser
create_role "yandex_browser" '
- name: Установка Яндекс Браузера
  dnf:
    name: yandex-browser
    state: present
' ''

# --- Рассылка SSH-ключей ---
setup_ssh_keys

# --- Запуск Ansible ---
echo -e "${GREEN}=== Запуск Ansible плейбука ===${NC}"
ansible-playbook -i "$ANSIBLE_DIR/inventory.yml" "$ANSIBLE_DIR/site.yml"

echo -e "${GREEN}=== Развертывание успешно завершено ===${NC}"

#!/bin/bash
#ZALUPA KOTA
echo "=== Общие параметры ==="
read -p "Домен (например example.org): " DOMAIN
read -p "Введите VLAN ID (3 шт через пробел, пример 100 200 999): " VLAN1_ID VLAN2_ID VLAN3_ID
read -p "Создать пользователя на RTR: " USER_RTR
read -p "Пароль пользователя на RTR: " PASSWORD_RTR
read -p "Создать пользователя на SRV: " USER_SRV
read -p "Пароль пользователя на SRV: " PASSWORD_SRV
read -p "ID пользователя: " USER_ID
read -p "Порт ssh: " PORT
read -p "Максимальное количество попыток входа: " TRIERS
read -p "БАННЕР (фраза по заданию): " BANNER_PHRASE
read -p "Локальная сеть в сторону HQ-SRV должна вмещать: " vlan100
read -p "Локальная сеть в сторону HQ-CLI должна вмещать : " vlan200
read -p "Локальная сеть для управления должна вмещать: " vlan999
read -p "Локальная сеть в сторону BR-SRV должна вмещать: " brsrv
read -p " Интерфейс в сторону HQ-RTR подключен к сети (например, 172.16.1.0/28): " input_HQ
read -p " Интерфейс в сторону BR-RTR подключен к сети (например, 172.16.2.0/28): " input_BR

# == Рассчет сети для ISP и RTR
net_setup_ISP () {
 local input=$1
 local base_ip="${input%/*}"
 local mask="${input#*/}"
 IFS='.' read -r o1 o2 o3 o4 <<< "$base_ip"
 local ip="$o1.$o2.$o3.$((o4 + 1))"
 local full_ip="$ip/$mask"
 echo "$full_ip"
}

# == Вычисляем маски == 
calc_min_prefix() {
    local n=$1
    local p=30 t=4
    while (( t-2 < n && p>0 )); do ((t*=2, p--)); done
    echo "$p"
}

calc_max_prefix() {
    local n=$1
    local p=30 t=4
    while (( t-2 <= n && p>0 )); do ((t*=2, p--)); done
    ((p++, t/=2))
    echo "$p"
}
parse() {
    local input=$1
    local type="${input:0:3}"
    local num="${input:3}"
    if [[ "$type" == "min" ]]; then
       calc_min_prefix "$num"
   elif [[ "$type" == "max" ]]; then
        calc_max_prefix "$num"
    fi
}
echo "Результаты:"
echo "HQ-RTR: $(net_setup_ISP "$input_HQ")"
echo "BR-RTR: $(net_setup_ISP "$input_BR")"
echo "VLAN 100: /$(parse "$vlan100")"
echo "VLAN 200: /$(parse "$vlan200")"
echo "VLAN 999: /$(parse "$vlan999")"
echo "BR-SRV: /$(parse  "$brsrv")"
BR_MASK=$(parse  "$brsrv")
VLAN1_MASK=$(parse "$vlan100")
VLAN2_MASK=$(parse "$vlan200")
VLAN3_MASK=$(parse "$vlan999")
net_setup_RTR () {
 local input=$1
 local base_ip="${input%/*}"
 local mask="${input#*/}"
 IFS='.' read -r o1 o2 o3 o4 <<< "$base_ip"
 local ip="$o1.$o2.$o3.$((o4 + 1))"
 local full_ip="$ip/$mask"
 echo "$full_ip"
}
HQ_ISP_IP=$(net_setup_ISP "$input_HQ")
BR_ISP_IP=$(net_setup_ISP "$input_BR")
HQ_RTR_IP=$(net_setup_RTR "$HQ_ISP_IP")
BR_RTR_IP=$(net_setup_RTR "$BR_ISP_IP")
HQ_RTR_GATEWAY="${HQ_ISP_IP%/*}"
BR_RTR_GATEWAY="${BR_ISP_IP%/*}"
HQ_SRV_GATEWAY="${HQ_RTR_IP%/*}"
BR_SRV_GATEWAY="${BR_RTR_IP%/*}"
VLAN1_SHORT=${VLAN1_ID:0:1}
VLAN1_IP_HQ_RTR="192.168.$VLAN1_SHORT.1"
VLAN1_IP_HQ_SRV="192.168.$VLAN1_SHORT.2"
VLAN2_SHORT=${VLAN2_ID:0:1}
VLAN2_IP="192.168.$VLAN2_SHORT.1"
VLAN3_SHORT=${VLAN3_ID:0:1}
VLAN3_IP="192.168.$VLAN3_SHORT.1"
NET_BR="192.168.0.1/$BR_MASK"

# --- КОМАНДЫ ДЛЯ HQ-SRV ---
cat > hq-srv.sh << HQ_SRV
export HISTFILE=~/.bash_history
set -o history
hostnamectl set-hostname hq-srv.$DOMAIN
systemctl disable --now firewalld
systemctl device set ens18 managed yes
nmcli connection delete ens18 2>/dev/null || true
nmcli connection add type ethernet con-name ens18 ifname ens18 ipv4.method disabled
nmcli connection modify ens18 connection.autoconnect yes
nmcli connection up ens18
nmcli connection add type vlan con-name vlan$VLAN1_ID ifname ens18.$VLAN1_ID dev ens18 id $VLAN1_ID
nmcli connection modify vlan$VLAN1_ID \
    ipv4.method manual \
    ipv4.addresses "$VLAN1_IP_HQ_SRV/$VLAN1_MASK" \
    ipv4.gateway "$VLAN1_IP_HQ_RTR" \
    ipv4.dns "$VLAN1_IP_HQ_SRV" \
    ipv4.dns-search "$DOMAIN" \
    ipv4.ignore-auto-dns yes \
    connection.autoconnect yes
nmcli connection up vlan$VLAN1_ID
systemctl disable --now systemd-resolved
rm -f /etc/resolv.conf
cat > /etc/dnsmasq.d/dns << DNS
port=53
listen-address=$VLAN1_IP_HQ_SRV
bind-dynamic
domain=hq.local
local=/hq.local/
bogus-priv
no-resolv
no-poll
no-hosts
server=77.88.8.7
server=77.88.8.3
host-record=hq-srv.$DOMAIN,$VLAN1_IP_HQ_SRV
host-record=hq-rtr.$DOMAIN,$VLAN2_IP
host-record=hq-rtr.$DOMAIN,$VLAN1_IP_HQ_RTR
host-record=hq-rtr.$DOMAIN,$HQ_SRV_GATEWAY
host-record=hq-cli.$DOMAIN,192.168.$VLAN2_SHORT.2
address=/br-srv.$DOMAIN/192.168.0.2
address=/br-rtr.$DOMAIN/192.168.0.1
address=/br-rtr.$DOMAIN/$BR_SRV_GATEWAY
address=/docker.$DOMAIN/$HQ_RTR_GATEWAY
address=/web.$DOMAIN/$BR_RTR_GATEWAY
DNS
systemctl enable --now dnsmasq
useradd $USER_SRV
echo "$USER_SRV:$PASSWORD_SRV" | chpasswd
usermod -u $USER_ID -a -G wheel $USER_SRV
echo "$USER_SRV ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USER_SRV
cat >> /etc/ssh/sshd_config << EOF
Port $PORT
AllowUsers $USER_SRV
MaxAuthTries  $TRIERS
Banner /etc/ssh/banner
EOF
echo "$BANNER_PHRASE" > /etc/ssh/banner
sed -i '/PermitRootLogin/d' /etc/ssh/sshd_config
setenforce 0
sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
systemctl restart sshd
history -a
set +o history
systemctl restart NetworkManager
sed -i '/PermitRootLogin yes/d' /etc/ssh/sshd_config
rm -f hq-srv.sh
set -o history
reboot
HQ_SRV

# --- КОМАНДЫ ДЛЯ HQ-CLI ---
cat > hq-cli.sh << HQ_CLI
export HISTFILE=~/.bash_history
set -o history
nmcli device set ens18 managed yes
nmcli connection delete ens18 2>/dev/null || true
nmcli connection add type ethernet con-name ens18 ifname ens18 ipv4.method disabled
nmcli connection add type vlan con-name vlan$VLAN2_ID ifname ens18.$VLAN2_ID dev ens18 id $VLAN2_ID
nmcli connection modify vlan$VLAN2_ID ipv4.method auto
history -a
set +o history
echo "=== HQ-CLI: настройка завершена ==="
rm -f hq-cli.sh
sed -i '/PermitRootLogin yes/d' /etc/ssh/sshd_config
set -o history
reboot
HQ_CLI

# --- КОМАНДЫ ДЛЯ HQ-RTR ---
cat > hq-rtr.sh << HQ_RTR
systemctl stop dnsmasq
rm -f /etc/dnsmasq.d/dhcp
export HISTFILE=~/.bash_history
set -o history
hostnamectl set-hostname hq-rtr.$DOMAIN
systemctl disable --now firewalld
systemctl disable  --now NetworkManager
rm -rf /etc/net/ifaces/ens18
mkdir -p /etc/net/ifaces/ens18
cat > /etc/net/ifaces/ens18/options << EOF
TYPE=eth
BOOTPROTO=static
ONBOOT=yes
EOF
echo "$HQ_RTR_IP" > /etc/net/ifaces/ens18/ipv4address
echo "default via $HQ_RTR_GATEWAY" > /etc/net/ifaces/ens18/ipv4route
mkdir -p /etc/net/ifaces/ens19
cat > /etc/net/ifaces/ens19/options << EOF
TYPE=eth
BOOTPROTO=manual
ONBOOT=no
EOF
mkdir -p /etc/net/ifaces/ens19.$VLAN1_ID
cat > /etc/net/ifaces/ens19.$VLAN1_ID/options << EOF
TYPE=vlan
HOST=ens19
VID=$VLAN1_ID
BOOTPROTO=static
ONBOOT=yes
EOF
echo "$VLAN1_IP_HQ_RTR/$VLAN1_MASK" > /etc/net/ifaces/ens19.$VLAN1_ID/ipv4address
mkdir -p /etc/net/ifaces/ens19.$VLAN2_ID
cat > /etc/net/ifaces/ens19.$VLAN2_ID/options << EOF
TYPE=vlan
HOST=ens19
VID=$VLAN2_ID
BOOTPROTO=static
ONBOOT=yes
EOF
echo "$VLAN2_IP/$VLAN2_MASK" > /etc/net/ifaces/ens19.$VLAN2_ID/ipv4address
mkdir -p /etc/net/ifaces/ens19.$VLAN3_ID
cat > /etc/net/ifaces/ens19.$VLAN3_ID/options << EOF
TYPE=vlan
HOST=ens19
VID=$VLAN3_ID
BOOTPROTO=static
ONBOOT=yes
EOF
echo "$VLAN3_IP/$VLAN3_MASK" > /etc/net/ifaces/ens19.$VLAN3_ID/ipv4address
mkdir -p /etc/net/ifaces/gre1
cat > /etc/net/ifaces/gre1/options << EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=$HQ_SRV_GATEWAY
TUNREMOTE=$BR_SRV_GATEWAY
TUNOPTIONS='ttl 64'
BOOTPROTO=static
ONBOOT=yes
EOF
echo "10.10.10.1/30" > /etc/net/ifaces/gre1/ipv4address
mv /etc/bird/bird.conf /etc/bird/bird.conf.bak || true
cat > /etc/bird/bird.conf << EOF
router id 1.1.1.1;
protocol kernel { persist; ipv4 { import all; export all;}; } 
protocol device { scan time 10; }
protocol ospf {
    area 0 {
        interface "gre1" {
            type ptp;
            authentication simple;
            password "P@ssw0rd";
            };
        interface "ens19.*" {
            stub;
        };
      };
}
EOF
birdc configure || true
cat > /etc/dnsmasq.d/dhcp << DHCP
listen-address=$VLAN2_IP
dhcp-range=192.168.$VLAN2_SHORT.2,192.168.$VLAN2_SHORT.4,12h
dhcp-option=option:router,$VLAN2_IP
dhcp-option=option:dns-server,$VLAN1_IP_HQ_SRV
dhcp-option=option:domain-search,$DOMAIN
DHCP
cat > /etc/dnsmasq.d/resolv << RESOLV
server=$VLAN1_IP_HQ_SRV
no-hosts
no-resolv
RESOLV
systemctl enable --now dnsmasq
useradd $USER_RTR
echo "$USER_RTR:$PASSWORD_RTR" | chpasswd
usermod -a -G wheel $USER_RTR
echo "$USER_RTR ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USER_RTR
nft add table nat
nft add chain nat postrouting '{ type nat hook postrouting priority srcnat; }'
nft add rule nat postrouting oifname "ens18" masquerade
nft list ruleset > /etc/nftables/nftables.nft
systemctl enable --now nftables
history -a
set +o history
echo "=== HQ-RTR: настройка завершена ==="
rm -f hq-rtr.sh
sed -i '/PermitRootLogin yes/d' /etc/openssh/sshd_config
set -o history
reboot
HQ_RTR

# --- СЛУЖЕБНЫЙ DHCP ДЛЯ HQ-RTR ---
cat > hq-rtr_dhcp.sh << HQ_RTR_DHCP
set +o history
history -c
systemctl disable --now NetworkManager
systemctl disable --now firewalld
apt-get update 
apt-get install bird -y
systemctl enable --now bird
sed -i 's/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
nft add table nat
nft add chain nat postrouting '{ type nat hook postrouting priority srcnat; }'
nft add rule nat postrouting oifname "ens18" masquerade
nft list ruleset > /etc/nftables/nftables.nft
systemctl enable --now nftables
ip addr add 10.255.3.1/24 dev ens19 || true
ip link set dev ens19 up
cat > /etc/dnsmasq.d/dhcp << DHCP
port=0
listen-address=10.255.3.1
dhcp-range=10.255.3.2,10.255.3.4,12h
dhcp-option=option:router,10.255.3.1
dhcp-option=option:dns-server,77.88.8.8
DHCP
systemctl enable --now dnsmasq
rm -rf hq-rtr_dhcp.sh
HQ_RTR_DHCP
# --- КОМАНДЫ ДЛЯ BR-RTR ---
cat > br-rtr.sh << BR_RTR
systemctl stop dnsmasq 
rm -f /etc/dnsmasq.d/dhcp
export HISTFILE=~/.bash_history
set -o history
hostnamectl set-hostname br-rtr.$DOMAIN
systemctl disable --now firewalld
rm -rf /etc/net/ifaces/ens18
systemctl disable --now NetworkManager
rm -rf /etc/resolv.conf
mkdir -p /etc/net/ifaces/ens18
cat > /etc/net/ifaces/ens18/options << EOF
TYPE=eth
BOOTPROTO=static
ONBOOT=yes
EOF
echo " $BR_RTR_IP" > /etc/net/ifaces/ens18/ipv4address
echo " default via $BR_RTR_GATEWAY" > /etc/net/ifaces/ens18/ipv4route
mkdir -p /etc/net/ifaces/ens19
cat > /etc/net/ifaces/ens19/options << EOF
TYPE=eth
BOOTPROTO=static
ONBOOT=yes
EOF
echo " 192.168.0.1/$BR_MASK" > /etc/net/ifaces/ens19/ipv4address
mkdir -p /etc/net/ifaces/gre1
cat > /etc/net/ifaces/gre1/options << EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=$BR_SRV_GATEWAY
TUNREMOTE=$HQ_SRV_GATEWAY
TUNOPTIONS='ttl 64'
BOOTPROTO=static
ONBOOT=yes
EOF
echo "10.10.10.2/30" > /etc/net/ifaces/gre1/ipv4address
systemctl restart network
apt-get update
apt-get install bird -y
systemctl enable --now bird
mv /etc/bird/bird.conf /etc/bird/bird.conf.bak || true
cat > /etc/bird/bird.conf << EOF
router id 2.2.2.2;
protocol kernel { persist; ipv4 {import all; export all;};}
protocol device { scan time 10;}
protocol ospf {
    area 0 {
        interface "gre1" {
            type ptp;
            authentication simple;
            password "P@ssw0rd";
            };
        interface "ens19" {
            stub;
        };
      };
}
EOF
cat > /etc/dnsmasq.d/resolv << RESOLV
server=$VLAN1_IP_HQ_SRV
no-hosts
no-resolv
RESOLV
systemctl enable --now dnsmasq
useradd $USER_RTR
echo "$USER_RTR:$PASSWORD_RTR" | chpasswd
usermod -a -G wheel $USER_RTR
echo "$USER_RTR ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USER_RTR
nft add table nat
nft add chain nat postrouting '{ type nat hook postrouting priority srcnat; }'
nft add rule nat postrouting oifname "ens18" masquerade
nft list ruleset > /etc/nftables/nftables.nft
systemctl enable --now nftables
history -a 
set +o history
echo "=== BR-RTR: настройка завершена ==="
rm -f br-rtr.sh
sed -i '/PermitRootLogin yes/d' /etc/openssh/sshd_config
set -o history
reboot
BR_RTR

# --- КОМАНДЫ ДЛЯ BR-SRV ---
cat > br-srv.sh << BR_SRV
export HISTFILE=~/.bash_history
set -o history
hostnamectl set-hostname br-srv.$DOMAIN
systemctl disable --now firewalld
systemctl disable --now systemd-resolved
rm -rf /etc/resolv.conf
nmcli connection delete ens18 2>/dev/null || true
nmcli connection add type ethernet con-name ens18 ifname ens18 \
    ipv4.method manual \
    ipv4.addresses "192.168.0.2/$BR_MASK" \
    ipv4.gateway "192.168.0.1" \
    ipv4.dns "$VLAN1_IP_HQ_SRV" \
    ipv4.dns-search "$DOMAIN" \
    ipv4.ignore-auto-dns yes \
    connection.autoconnect yes
nmcli connection up ens18
useradd $USER_SRV
echo "$USER_SRV:$PASSWORD_SRV" | chpasswd
usermod -u $USER_ID -a -G wheel $USER_SRV
echo "$USER_SRV ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USER_SRV
cat >> /etc/ssh/sshd_config << EOF
Port $PORT
AllowUsers $USER_SRV
MaxAuthTries  $TRIERS
Banner /etc/ssh/banner
EOF
echo "$BANNER_PHRASE" > /etc/ssh/banner
sed -i '/PermitRootLogin/d' /etc/ssh/sshd_config
setenforce 0
sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
systemctl restart sshd
history -a 
set +o history
echo "=== BR-SRV: настройка завершена ==="
rm -f br-srv.sh
sed -i '/PermitRootLogin yes/d' /etc/ssh/sshd_config
set -o history
reboot
BR_SRV

# --- СЛУЖЕБНЫЙ DHCP ДЛЯ BR-RTR ---
cat > br-rtr_dhcp.sh << BR_RTR_DHCP
set +o history
history -c 
systemctl disable --now NetworkManager
systemctl disable --now firewalld
apt-get update 
apt-get install bird -y
systemctl enable --now bird
sed -i 's/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
sysctl -p /etc/net/sysctl.conf
nft add table nat
nft add chain nat postrouting '{ type nat hook postrouting priority srcnat; }'
nft add rule nat postrouting oifname "ens18" masquerade
nft list ruleset > /etc/nftables/nftables.nft
systemctl enable --now nftables
ip addr add 10.255.4.1/24 dev ens19 || true
ip link set dev ens19 up
systemctl restart network
cat > /etc/dnsmasq.d/dhcp << DHCP
port=0
listen-address=10.255.4.1
dhcp-range=10.255.4.2,10.255.4.4,12h
dhcp-option=option:router,10.255.4.1
dhcp-option=option:dns-server,77.88.8.8
DHCP
systemctl enable --now dnsmasq
rm -f br-rtr_dhcp.sh
BR_RTR_DHCP

# --- КОМАНДЫ ДЛЯ ISP ---
cat > isp.sh << ISP
export HISTFILE=~/.bash_history
set -o history
hostnamectl set-hostname isp
systemctl disable --now firewalld
rm -rf /etc/net/ifaces/ens18
mkdir -p /etc/net/ifaces/ens18
cat > /etc/net/ifaces/ens18/options << EOF
TYPE=eth
BOOTPROTO=dhcp
ONBOOT=yes
EOF
mkdir -p /etc/net/ifaces/ens19
cat > /etc/net/ifaces/ens19/options << EOF
TYPE=eth
BOOTPROTO=static
ONBOOT=yes
EOF
echo "$HQ_ISP_IP" > /etc/net/ifaces/ens19/ipv4address
mkdir -p /etc/net/ifaces/ens20
cat > /etc/net/ifaces/ens20/options << EOF
TYPE=eth
BOOTPROTO=static
ONBOOT=yes
EOF
echo "$BR_ISP_IP" > /etc/net/ifaces/ens20/ipv4address
systemctl disable --now NetworkManager
rm -rf /etc/resolv.conf
nft add table nat
nft add chain nat postrouting '{ type nat hook postrouting priority srcnat; }'
nft add rule nat postrouting oifname "ens18" masquerade
nft list ruleset > /etc/nftables/nftables.nft
systemctl enable --now nftables
history -a
set +o history
rm -f isp.sh
set -o history
reboot
ISP

#=== Настройка временного DHCP на текущем узле (ISP) ===#
set +o history
history -c 
systemctl disable --now NetworkManager firewalld
sed -i 's/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
sysctl -p /etc/net/sysctl.conf
nft add table nat
nft add chain nat postrouting '{ type nat hook postrouting priority srcnat; }'
nft add rule nat postrouting oifname "ens18" masquerade
nft list ruleset > /etc/nftables/nftables.nft
systemctl enable --now nftables
ip addr add 10.255.1.1/24 dev ens19 || true
ip addr add 10.255.2.1/24 dev ens20 || true
ip link set dev ens19 up
ip link set dev ens20 up
cat > /etc/dnsmasq.d/dhcp << DHCP
port=0
listen-address=10.255.1.1
dhcp-range=10.255.1.2,10.255.1.4,12h
dhcp-option=option:router,10.255.1.1
listen-address=10.255.2.1
dhcp-range=10.255.2.2,10.255.2.4,12h
dhcp-option=option:router,10.255.2.1
dhcp-option=option:dns-server,77.88.8.8
DHCP
systemctl start dnsmasq

# --- АВТОМАТИЗАЦИЯ ПЕРЕСЫЛКИ И ЗАПУСКА СКРИПТОВ (БЕЗ SSHPASS) ---
echo "=== Запуск процесса автоматической отправки и настройки ==="

# 1. Запрашиваем временные IP-адреса, которые роутеры получили от ISP
read -p "Введите временный IP, который HQ-RTR получил от ISP (например 10.255.1.3): " TEMP_HQ_RTR_IP
read -p "Введите временный IP, который BR-RTR получил от ISP (например 10.255.2.3): " TEMP_BR_RTR_IP

echo "Шаг 1: Копирование и АВТОЗАПУСК DHCP на роутерах..."

# Копируем основной скрипт и скрипт DHCP на HQ-RTR
scp -o StrictHostKeyChecking=no hq-rtr.sh hq-rtr_dhcp.sh root@$TEMP_HQ_RTR_IP:/root/
# Удалённо запускаем hq-rtr_dhcp.sh для поднятия временного DHCP на роутере
ssh -o StrictHostKeyChecking=no root@$TEMP_HQ_RTR_IP "chmod +x /root/hq-rtr_dhcp.sh && /root/hq-rtr_dhcp.sh"

# То же самое проделываем для BR-RTR
scp -o StrictHostKeyChecking=no br-rtr.sh br-rtr_dhcp.sh root@$TEMP_BR_RTR_IP:/root/
ssh -o StrictHostKeyChecking=no root@$TEMP_BR_RTR_IP "chmod +x /root/br-rtr_dhcp.sh && /root/br-rtr_dhcp.sh"

echo "---"
echo "DHCP-скрипты на роутерах запущены автоматически."
echo "Пожалуйста, подождите 10 секунд, пока внутренние машины (SRV/CLI) поднимут линки..."
echo "---"
sleep 10

# 2. Запрашиваем адреса внутренних машин, полученные динамически
# 2. Запрашиваем адреса внутренних машин, полученные динамически
read -p "Введите временный IP, который получил HQ-SRV (например 10.255.3.2): " TEMP_HQ_SRV_IP
read -p "Введите временный IP, который получил HQ-CLI (например 10.255.3.3): " TEMP_HQ_CLI_IP
read -p "Введите временный IP, который получил BR-SRV (например 10.255.4.3): " TEMP_BR_SRV_IP

echo "Шаг 2: Отправка конфигураций на внутренние узлы через роутеры (флаг -J)..."

# Пересылка файлов на внутренние узлы через Jump-хосты
scp -o StrictHostKeyChecking=no -J root@$TEMP_HQ_RTR_IP hq-srv.sh root@$TEMP_HQ_SRV_IP:/root/
scp -o StrictHostKeyChecking=no -J root@$TEMP_HQ_RTR_IP hq-cli.sh root@$TEMP_HQ_CLI_IP:/root/
scp -o StrictHostKeyChecking=no -J root@$TEMP_BR_RTR_IP br-srv.sh root@$TEMP_BR_SRV_IP:/root/

echo "Шаг 3: АВТОЗАПУСК конфигураций на внутренних серверах и клиентах..."

# Запуск на HQ-SRV через HQ-RTR (флаг -J в ssh заменяется на опцию -o ProxyJump)
# Используем фоновый запуск, так как скрипты серверов завершаются командой reboot
ssh -o StrictHostKeyChecking=no -o ProxyJump=root@$TEMP_HQ_RTR_IP root@$TEMP_HQ_SRV_IP \
  "chmod +x /root/hq-srv.sh && nohup /root/hq-srv.sh && reboot> /dev/null 2>&1 &"

# Запуск на HQ-CLI через HQ-RTR
ssh -o StrictHostKeyChecking=no -o ProxyJump=root@$TEMP_HQ_RTR_IP root@$TEMP_HQ_CLI_IP \
  "chmod +x /root/hq-cli.sh && nohup /root/hq-cli.sh> /dev/null 2>&1 &"

# Запуск на BR-SRV через BR-RTR
ssh -o StrictHostKeyChecking=no -o ProxyJump=root@$TEMP_BR_RTR_IP root@$TEMP_BR_SRV_IP \
  "chmod +x /root/br-srv.sh && nohup /root/br-srv.sh &&> /dev/null 2>&1 &"

echo "Ожидание 5 секунд для инициализации серверных скриптов..."
sleep 5

# Шаг 4: Даем команду на применение финальных конфигураций роутеров
echo "Шаг 4: Запуск основных конфигураций на роутерах (роутеры уйдут в перезагрузку)..."
ssh -o StrictHostKeyChecking=no root@$TEMP_HQ_RTR_IP "chmod +x /root/hq-rtr.sh && nohup bash /root/hq-rtr.sh && reboot > /dev/null 2>&1 &"
ssh -o StrictHostKeyChecking=no root@$TEMP_BR_RTR_IP "chmod +x /root/br-rtr.sh && nohup bash /root/br-rtr.sh && reboot > /dev/null 2>&1 &"
echo "=== Все файлы успешно доставлены и запущены на исполнение! ==="
rm -rf hq-rtr.sh br-rtr.sh  hq-cli.sh br-srv.sh hq-srv.sh br-rtr_dhcp.sh hq-rtr_dhcp.sh mod1_kluc
bash isp.sh

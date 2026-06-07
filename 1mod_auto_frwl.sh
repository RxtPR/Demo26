#!/bin/bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Модуль 1: базовая инфраструктура через DHCP-bootstrap. ===${NC}"
echo -e "${YELLOW}ПЕРЕД ВЫПОЛНЕНИЕМ ВЕЗДНЕ ОБЯАТЕЛЬНО ВКЛЮЧИТЬ SSH ОТ ROOT${NC}"
echo -e "${YELLOW}КОНФИГ ЛЕЖИТ В  /etc/ssh(openssh)/sshd_config${NC}"
echo -e "${YELLOW}ПОСЛЕ ЭТОГО ПЕРЕЗАГРУЗИ SSH командой systemctl restart sshd${NC}"
echo -e "${YELLOW}Сотри решетку у PermitRootLogin, и приведи к виду PermitRootLogin yes.${NC}"


if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запусти скрипт от root на ISP${NC}"
    exit 1
fi

ask() {
    local var=$1
    local prompt=$2
    local default=$3
    local value=""
    while true; do
        read -r -p "$prompt [$default]: " value
        value="${value:-$default}"
        if [[ -n "$value" ]]; then
            printf -v "$var" '%s' "$value"
            return
        fi
        echo -e "${RED}Значение не может быть пустым${NC}"
    done
}

continue_after_error() {
    local answer=""
    while true; do
        read -r -p "Возникла ошибка. Всё равно продолжить следующий этап? [no]: " answer
        answer="${answer:-no}"
        case "${answer,,}" in
            yes|y|да|д)
                echo -e "${YELLOW}Продолжаю, но этот этап мог остаться недонастроенным.${NC}"
                return 0
                ;;
            no|n|нет|н)
                return 1
                ;;
            *)
                echo "Ответь yes/no или да/нет."
                ;;
        esac
    done
}

is_yes() {
    case "${1,,}" in
        yes|y|да|д) return 0 ;;
        *) return 1 ;;
    esac
}

select_start_stage() {
    local value=""
    cat <<'EOF_STAGES'
С какого этапа начать:
  1) isp       - настройка ISP/bootstrap DHCP/NAT
  2) rtr       - отправка и настройка HQ-RTR/BR-RTR
  3) routes    - временные маршруты ISP до внутренних сетей
  4) endpoints - отправка HQ-SRV, HQ-CLI, BR-SRV
  5) hq-srv    - начать с HQ-SRV
  6) hq-cli    - начать с HQ-CLI
  7) br-srv    - начать с BR-SRV
EOF_STAGES
    read -r -p "Начать с этапа [isp]: " value
    value="${value:-isp}"
    case "${value,,}" in
        1|isp) START_STAGE="isp"; START_ORDER=10 ;;
        2|rtr|routers) START_STAGE="rtr"; START_ORDER=20 ;;
        3|routes|route) START_STAGE="routes"; START_ORDER=30 ;;
        4|endpoints|srv|servers) START_STAGE="endpoints"; START_ORDER=40 ;;
        5|hq-srv|hqsrv) START_STAGE="hq-srv"; START_ORDER=41 ;;
        6|hq-cli|hqcli) START_STAGE="hq-cli"; START_ORDER=42 ;;
        7|br-srv|brsrv) START_STAGE="br-srv"; START_ORDER=43 ;;
        *)
            echo -e "${RED}Неизвестный этап: $value${NC}"
            select_start_stage
            ;;
    esac
}

run_from_stage() {
    local order=$1
    (( START_ORDER <= order ))
}

prefix_to_netmask() {
    local prefix=$1
    if [[ ! "$prefix" =~ ^[0-9]+$ ]] || (( prefix < 0 || prefix > 32 )); then
        echo -e "${RED}Некорректная маска: /$prefix${NC}" >&2
        exit 1
    fi
    local mask=0
    if (( prefix > 0 )); then
        mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
    fi
    echo "$(( (mask >> 24) & 255 )).$(( (mask >> 16) & 255 )).$(( (mask >> 8) & 255 )).$(( mask & 255 ))"
}

is_private_ipv4() {
    local ip=$1
    local a b c d
    IFS=. read -r a b c d <<< "$ip"
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
    (( a >= 0 && a <= 255 && b >= 0 && b <= 255 && c >= 0 && c <= 255 && d >= 0 && d <= 255 )) || return 1
    (( a == 10 )) || (( a == 172 && b >= 16 && b <= 31 )) || (( a == 192 && b == 168 ))
}

cidr_prefix() {
    local cidr=$1
    if [[ "$cidr" != */* ]]; then
        echo -e "${RED}CIDR должен быть в формате адрес/маска, например 192.168.10.0/27: $cidr${NC}" >&2
        exit 1
    fi
    local prefix="${cidr##*/}"
    if [[ ! "$prefix" =~ ^[0-9]+$ ]] || (( prefix < 0 || prefix > 32 )); then
        echo -e "${RED}Некорректная маска в CIDR: $cidr${NC}" >&2
        exit 1
    fi
    echo "$prefix"
}

validate_private_cidr() {
    local name=$1
    local cidr=$2
    local network="${cidr%/*}"
    cidr_prefix "$cidr" >/dev/null
    if ! is_private_ipv4 "$network"; then
        echo -e "${RED}$name должен быть из приватного диапазона RFC1918: $cidr${NC}" >&2
        exit 1
    fi
}

validate_prefix_at_least() {
    local name=$1
    local cidr=$2
    local min_prefix=$3
    local reason=$4
    local prefix
    prefix="$(cidr_prefix "$cidr")"
    if (( prefix < min_prefix )); then
        echo -e "${RED}$name ($cidr) не соответствует условию: $reason${NC}" >&2
        exit 1
    fi
}

validate_prefix_at_most() {
    local name=$1
    local cidr=$2
    local max_prefix=$3
    local reason=$4
    local prefix
    prefix="$(cidr_prefix "$cidr")"
    if (( prefix > max_prefix )); then
        echo -e "${RED}$name ($cidr) не соответствует условию: $reason${NC}" >&2
        exit 1
    fi
}

ipv4_to_int() {
    local ip=$1
    local a b c d
    IFS=. read -r a b c d <<< "$ip"
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
    (( a >= 0 && a <= 255 && b >= 0 && b <= 255 && c >= 0 && c <= 255 && d >= 0 && d <= 255 )) || return 1
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

validate_ip_in_cidr() {
    local name=$1
    local ip=$2
    local cidr=$3
    local network="${cidr%/*}"
    local prefix
    local ip_int net_int mask
    prefix="$(cidr_prefix "$cidr")"
    ip_int="$(ipv4_to_int "$ip")" || { echo -e "${RED}$name имеет некорректный IPv4: $ip${NC}" >&2; exit 1; }
    net_int="$(ipv4_to_int "$network")" || { echo -e "${RED}$name имеет некорректную сеть: $cidr${NC}" >&2; exit 1; }
    if (( prefix == 0 )); then
        mask=0
    else
        mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
    fi
    if (( (ip_int & mask) != (net_int & mask) )); then
        echo -e "${RED}$name=$ip не входит в сеть $cidr${NC}" >&2
        exit 1
    fi
}

reverse_ptr_name() {
    local ip=$1
    local a b c d
    IFS=. read -r a b c d <<< "$ip"
    if [[ -z "${a:-}" || -z "${b:-}" || -z "${c:-}" || -z "${d:-}" ]]; then
        echo -e "${RED}Некорректный IPv4 для PTR: $ip${NC}" >&2
        exit 1
    fi
    echo "$d.$c.$b.$a.in-addr.arpa"
}

reverse_zone_24() {
    local ip=$1
    local a b c d
    IFS=. read -r a b c d <<< "$ip"
    echo "$c.$b.$a.in-addr.arpa"
}

last_octet() {
    local ip=$1
    echo "${ip##*.}"
}

install_pkg() {
    local pkg=$1
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq || true
        case "$pkg" in
            network-manager) apt-get install -y NetworkManager || apt-get install -y network-manager ;;
            isc-dhcp-server) apt-get install -y isc-dhcp-server || apt-get install -y dhcp-server ;;
            bind9) apt-get install -y bind9 bind9utils || apt-get install -y bind bind-utils ;;
            *) apt-get install -y "$pkg" ;;
        esac
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$pkg" || {
            case "$pkg" in
                network-manager) dnf install -y NetworkManager ;;
                isc-dhcp-server) dnf install -y dhcp-server ;;
                bind9) dnf install -y bind bind-utils ;;
                *) return 1 ;;
            esac
        }
    else
        echo -e "${RED}Неизвестный пакетный менеджер, не могу поставить $pkg${NC}"
        exit 1
    fi
}

ensure_cmd() {
    local cmd=$1
    local pkg=$2
    if ! command -v "$cmd" >/dev/null 2>&1; then
        install_pkg "$pkg"
    fi
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}Не найдена команда $cmd. Проверь репозитории или установи пакет $pkg вручную.${NC}"
        exit 1
    fi
}

record_history() {
    local cmd
    mkdir -p /etc/profile.d
    cat > /etc/profile.d/mod1-history.sh <<'EOF_HISTORY_PROFILE'
shopt -s histappend 2>/dev/null || true
export HISTSIZE=5000
export HISTFILESIZE=5000
export HISTCONTROL=
case ";${PROMPT_COMMAND:-};" in
    *";history -a; history -n;"*) ;;
    *) PROMPT_COMMAND="history -a; history -n${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
esac
EOF_HISTORY_PROFILE
    touch /root/.bash_history
    chmod 600 /root/.bash_history 2>/dev/null || true
    for cmd in "$@"; do
        printf '%s\n' "$cmd" >> /root/.bash_history
    done
}

restart_dhcp_service_local() {
    local svc=""
    if systemctl list-unit-files --no-legend dhcpd.service 2>/dev/null | awk '{print $1}' | grep -qx "dhcpd.service"; then
        svc="dhcpd"
    elif systemctl list-unit-files --no-legend isc-dhcp-server.service 2>/dev/null | awk '{print $1}' | grep -qx "isc-dhcp-server.service"; then
        svc="isc-dhcp-server"
    elif systemctl status dhcpd >/dev/null 2>&1; then
        svc="dhcpd"
    elif systemctl status isc-dhcp-server >/dev/null 2>&1; then
        svc="isc-dhcp-server"
    fi

    if [[ -z "$svc" ]]; then
        echo -e "${RED}Не найден systemd unit DHCP-сервера: dhcpd или isc-dhcp-server${NC}"
        exit 1
    fi

    if command -v dhcpd >/dev/null 2>&1 && [[ -f /etc/dhcp/dhcpd.conf ]]; then
        dhcpd -t -cf /etc/dhcp/dhcpd.conf
    fi
    systemctl enable --now "$svc"
    systemctl restart "$svc"
}

persist_ip_forward() {
    mkdir -p /etc/sysctl.d
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-mod1-ip-forward.conf
    sysctl -w net.ipv4.ip_forward=1
}

fw_add_interface() {
    local zone=$1
    local iface=$2
    firewall-cmd --permanent --zone="$zone" --query-interface="$iface" >/dev/null 2>&1 || firewall-cmd --permanent --zone="$zone" --change-interface="$iface" || firewall-cmd --permanent --zone="$zone" --add-interface="$iface"
}

fw_add_source() {
    local zone=$1
    local source=$2
    firewall-cmd --permanent --zone="$zone" --query-source="$source" >/dev/null 2>&1 || firewall-cmd --permanent --zone="$zone" --add-source="$source"
}

fw_add_service() {
    local zone=$1
    local service=$2
    firewall-cmd --permanent --zone="$zone" --query-service="$service" >/dev/null 2>&1 || firewall-cmd --permanent --zone="$zone" --add-service="$service" || true
}

fw_add_protocol() {
    local zone=$1
    local proto=$2
    firewall-cmd --permanent --zone="$zone" --query-protocol="$proto" >/dev/null 2>&1 || firewall-cmd --permanent --zone="$zone" --add-protocol="$proto" || true
}

fw_enable_forward() {
    local zone=$1
    if firewall-cmd --help 2>/dev/null | grep -q -- "--add-forward"; then
        firewall-cmd --permanent --zone="$zone" --add-forward || true
    fi
}

fw_set_target_accept() {
    local zone=$1
    firewall-cmd --permanent --zone="$zone" --set-target=ACCEPT || true
}

fw_add_masquerade() {
    local zone=$1
    firewall-cmd --permanent --zone="$zone" --query-masquerade >/dev/null 2>&1 || firewall-cmd --permanent --zone="$zone" --add-masquerade
}

configure_isp_firewalld() {
    systemctl enable --now firewalld
    systemctl disable --now nftables >/dev/null 2>&1 || true

    fw_add_interface external "$ISP_WAN_IF"
    fw_add_interface internal "$ISP_HQ_IF"
    fw_add_interface internal "$ISP_BR_IF"
    fw_set_target_accept external
    fw_set_target_accept internal
    for net in "$ISP_HQ_NET" "$ISP_BR_NET" "$HQ_SRV_NET" "$HQ_CLI_NET" "$HQ_MGMT_NET" "$BR_SRV_NET"; do
        fw_add_source internal "$net"
    done
    fw_add_masquerade external
    fw_enable_forward external
    fw_enable_forward internal
    for service in ssh dhcp dns ntp http https; do
        fw_add_service internal "$service"
    done
    fw_add_protocol internal gre
    firewall-cmd --reload
    firewall-cmd --zone=external --list-all
    firewall-cmd --zone=internal --list-all
}

nm_static() {
    local con=$1
    local ifname=$2
    local address=$3
    local gateway=${4:-}
    local dns=${5:-}
    nmcli con delete "$con" >/dev/null 2>&1 || true
    nmcli device set "$ifname" managed yes >/dev/null 2>&1 || true
    nmcli con add type ethernet ifname "$ifname" con-name "$con" ipv4.method manual ipv4.addresses "$address" ipv6.method disabled >/dev/null
    if [[ -n "$gateway" ]]; then
        nmcli con mod "$con" ipv4.gateway "$gateway"
    fi
    if [[ -n "$dns" ]]; then
        nmcli con mod "$con" ipv4.dns "$dns" ipv4.ignore-auto-dns yes
    fi
    nmcli con mod "$con" connection.autoconnect yes
    nmcli con up "$con" >/dev/null
}

nm_dhcp() {
    local con=$1
    local ifname=$2
    nmcli con delete "$con" >/dev/null 2>&1 || true
    nmcli device set "$ifname" managed yes >/dev/null 2>&1 || true
    nmcli con add type ethernet ifname "$ifname" con-name "$con" ipv4.method auto ipv6.method disabled >/dev/null
    nmcli con mod "$con" connection.autoconnect yes
    nmcli con up "$con" >/dev/null || true
}

write_remote() {
    local path=$1
    local content=$2
    printf '%s\n' "$content" > "$path"
    if [[ ! -s "$path" ]]; then
        echo -e "${RED}Сгенерирован пустой удалённый скрипт: $path${NC}"
        exit 1
    fi
    chmod +x "$path"
}

push_and_run() {
    local ip=$1
    local user=$2
    local pass=$3
    local local_script=$4
    local final_ip=${5:-$ip}
    local final_port=${6:-22}
    local final_user=${7:-$user}
    local final_pass=${8:-$pass}
    local remote_script="/tmp/$(basename "$local_script")"
    local remote_log="/tmp/$(basename "$local_script").log"
    local remote_done="/tmp/$(basename "$local_script").done"

    if [[ ! -s "$local_script" ]]; then
        echo -e "${RED}Локальный скрипт $local_script пустой, копирование отменено.${NC}"
        if continue_after_error; then
            return
        fi
        exit 1
    fi
    echo -e "${YELLOW}Проверяю доступность $ip перед копированием...${NC}"
    if ! ping -c 2 -W 2 "$ip" >/dev/null 2>&1; then
        echo -e "${RED}$ip не пингуется с ISP. SSH-копирование почти точно упадёт.${NC}"
        echo -e "${YELLOW}Проверь, что это реальный временный DHCP IP машины, а не stock IP по умолчанию.${NC}"
        echo -e "${YELLOW}На ISP: ip route get $ip${NC}"
        echo -e "${YELLOW}На HQ-RTR/BR-RTR: firewall-cmd --list-all-zones; ip route; ip addr${NC}"
        if continue_after_error; then
            return
        fi
        exit 1
    fi
    echo -e "${YELLOW}Копирую $(basename "$local_script") на $user@$ip...${NC}"
    if sshpass -p "$pass" scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$local_script" "$user@$ip:$remote_script" &&
       sshpass -p "$pass" ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$user@$ip" "rm -f $remote_done; nohup sh -c 'bash $remote_script > $remote_log 2>&1; echo \$? > $remote_done' < /dev/null >/dev/null 2>&1 &"; then
        echo -e "${YELLOW}Запустил $(basename "$local_script") на $user@$ip в фоне, лог: $remote_log${NC}"
    elif [[ "$final_user" != "$user" || "$final_port" != "22" || "$final_ip" != "$ip" ]]; then
        echo -e "${YELLOW}Не получилось зайти как $user@$ip:22. Пробую повторный запуск через $final_user@$final_ip:$final_port с sudo...${NC}"
        if sshpass -p "$final_pass" scp -P "$final_port" -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$local_script" "$final_user@$final_ip:$remote_script" &&
           sshpass -p "$final_pass" ssh -n -p "$final_port" -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$final_user@$final_ip" "rm -f $remote_done; nohup sh -c 'sudo -n bash $remote_script > $remote_log 2>&1; echo \$? > $remote_done' < /dev/null >/dev/null 2>&1 &"; then
            echo -e "${YELLOW}Запустил $(basename "$local_script") через sudo на $final_user@$final_ip:$final_port, лог: $remote_log${NC}"
        else
            echo -e "${RED}Повторный запуск через $final_user@$final_ip:$final_port тоже не удался.${NC}"
            if continue_after_error; then
                return
            fi
            exit 1
        fi
    else
        echo -e "${RED}Не удалось скопировать или запустить $(basename "$local_script") на $user@$ip.${NC}"
        if continue_after_error; then
            return
        fi
        exit 1
    fi

    echo -e "${YELLOW}Жду завершения настройки и SSH на $final_ip:$final_port...${NC}"
    for _ in {1..120}; do
        if sshpass -p "$final_pass" ssh -n -p "$final_port" -o StrictHostKeyChecking=no -o ConnectTimeout=4 "$final_user@$final_ip" "test -f $remote_done" >/dev/null 2>&1; then
            local remote_rc
            remote_rc="$(sshpass -p "$final_pass" ssh -n -p "$final_port" -o StrictHostKeyChecking=no -o ConnectTimeout=4 "$final_user@$final_ip" "cat $remote_done" 2>/dev/null || echo 1)"
            echo -e "${GREEN}$final_ip доступен. Последние строки лога:${NC}"
            sshpass -p "$final_pass" ssh -n -p "$final_port" -o StrictHostKeyChecking=no -o ConnectTimeout=4 "$final_user@$final_ip" "tail -n 20 $remote_log" || true
            if [[ "$remote_rc" != "0" ]]; then
                echo -e "${RED}Удалённый скрипт $(basename "$local_script") завершился с кодом $remote_rc.${NC}"
                if continue_after_error; then
                    return
                fi
                exit 1
            fi
            return
        fi
        if sshpass -p "$final_pass" ssh -n -p "$final_port" -o StrictHostKeyChecking=no -o ConnectTimeout=4 "$final_user@$final_ip" "test -f /root/.mod1_reboot_requested && test -f $remote_log" >/dev/null 2>&1; then
            echo -e "${YELLOW}$final_ip доступен после перезагрузки, но marker завершения ещё не создан. Проверяю лог...${NC}"
            sshpass -p "$final_pass" ssh -n -p "$final_port" -o StrictHostKeyChecking=no -o ConnectTimeout=4 "$final_user@$final_ip" "tail -n 40 $remote_log" || true
            echo -e "${GREEN}Перезагрузка была запрошена из-за SELinux/SSH-порта. Продолжаю, SSH на $final_ip:$final_port доступен.${NC}"
            return
        fi
        sleep 3
    done

    echo -e "${RED}Не дождался SSH на $final_ip. Проверь консоль машины и лог $remote_log.${NC}"
    echo -e "${YELLOW}Пробую вытащить последние строки лога через старый адрес $ip:22...${NC}"
    sshpass -p "$pass" ssh -n -p 22 -o StrictHostKeyChecking=no -o ConnectTimeout=6 "$user@$ip" "tail -n 80 $remote_log" || true
    echo -e "${YELLOW}Если IP изменился не на ожидаемый, продолжи вручную или перезапусти с правильным IP.${NC}"
    if continue_after_error; then
        return
    fi
    exit 1
}

ask DOMAIN "Домен" "au-team.irpo"
ask ROOT_PASS "Пароль root на временных DHCP-хостах" "toor"
ask SSHUSER_PASS "Пароль sshuser" "P@ssw0rd"
ask SSH_PORT "Порт SSH для HQ-SRV и BR-SRV" "2026"
ask SSHUSER_UID "UID пользователя sshuser" "2026"
ask NET_ADMIN_PASS "Пароль net_admin" "P@ssw0rd"
ask OSPF_PASS "Пароль защиты OSPF" "P@ssw0rd"
ask TZ_NAME "Часовой пояс" "Europe/Moscow"

if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    echo -e "${RED}Некорректный SSH-порт: $SSH_PORT${NC}" >&2
    exit 1
fi
if [[ ! "$SSHUSER_UID" =~ ^[0-9]+$ ]] || (( SSHUSER_UID < 1 )); then
    echo -e "${RED}Некорректный UID sshuser: $SSHUSER_UID${NC}" >&2
    exit 1
fi

ask ISP_WAN_IF "ISP интерфейс в магистрального провайдера (DHCP)" "ens18"
ask ISP_HQ_IF "ISP интерфейс в сторону HQ-RTR" "ens19"
ask ISP_BR_IF "ISP интерфейс в сторону BR-RTR" "ens20"
ask HQ_WAN_IF "HQ-RTR интерфейс в сторону ISP" "ens18"
ask HQ_TRUNK_IF "HQ-RTR trunk-интерфейс VLAN 100/200/999" "ens19"
ask BR_WAN_IF "BR-RTR интерфейс в сторону ISP" "ens18"
ask BR_LAN_IF "BR-RTR интерфейс в сторону BR-SRV" "ens19"
ask HQ_SRV_IF "HQ-SRV сетевой интерфейс" "ens18"
ask HQ_CLI_IF "HQ-CLI сетевой интерфейс" "ens18"
ask BR_SRV_IF "BR-SRV сетевой интерфейс" "ens18"

ask ISP_HQ_NET "Сеть ISP-HQ CIDR" "172.16.1.0/28"
ask ISP_HQ_IP "IP ISP в сторону HQ-RTR" "172.16.1.1"
ask HQ_RTR_WAN_IP "IP HQ-RTR в сторону ISP" "172.16.1.2"
ask ISP_HQ_DHCP_START "DHCP start для HQ-RTR bootstrap" "172.16.1.2"
ask ISP_HQ_DHCP_END "DHCP end для HQ-RTR bootstrap" "172.16.1.14"

ask ISP_BR_NET "Сеть ISP-BR CIDR" "172.16.2.0/28"
ask ISP_BR_IP "IP ISP в сторону BR-RTR" "172.16.2.1"
ask BR_RTR_WAN_IP "IP BR-RTR в сторону ISP" "172.16.2.2"
ask ISP_BR_DHCP_START "DHCP start для BR-RTR bootstrap" "172.16.2.2"
ask ISP_BR_DHCP_END "DHCP end для BR-RTR bootstrap" "172.16.2.14"

ask HQ_VLAN_SRV "VLAN в сторону HQ-SRV" "100"
ask HQ_SRV_NET "Сеть HQ-SRV CIDR" "192.168.10.0/27"

ask HQ_VLAN_CLI "VLAN в сторону HQ-CLI" "200"
ask HQ_CLI_NET "Сеть HQ-CLI CIDR" "192.168.20.0/27"

ask HQ_VLAN_MGMT "VLAN управления" "999"
ask HQ_MGMT_NET "Сеть управления CIDR" "192.168.99.0/29"

ask TAG_ENDPOINT_VLANS "Тегировать VLAN на HQ-SRV/HQ-CLI? yes/no (обычно no, если порт access)" "yes"
TAG_ENDPOINT_VLANS="${TAG_ENDPOINT_VLANS,,}"

ask BR_SRV_NET "Сеть BR-SRV CIDR" "192.168.2.0/28"

ask GRE_NET "Сеть GRE CIDR" "10.10.10.0/30"
ask PUBLIC_DNS "DNS forwarder" "77.88.8.7"

validate_private_cidr "Сеть ISP-HQ" "$ISP_HQ_NET"
validate_private_cidr "Сеть ISP-BR" "$ISP_BR_NET"
validate_private_cidr "Сеть HQ-SRV VLAN$HQ_VLAN_SRV" "$HQ_SRV_NET"
validate_private_cidr "Сеть HQ-CLI VLAN$HQ_VLAN_CLI" "$HQ_CLI_NET"
validate_private_cidr "Сеть управления VLAN$HQ_VLAN_MGMT" "$HQ_MGMT_NET"
validate_private_cidr "Сеть BR-SRV" "$BR_SRV_NET"
validate_private_cidr "Сеть GRE" "$GRE_NET"
validate_prefix_at_least "Сеть HQ-SRV VLAN$HQ_VLAN_SRV" "$HQ_SRV_NET" 27 "должна вмещать не более 32 адресов (/27 или меньше по размеру)"
validate_prefix_at_most "Сеть HQ-CLI VLAN$HQ_VLAN_CLI" "$HQ_CLI_NET" 28 "должна вмещать не менее 16 адресов (/28 или больше по размеру)"
validate_prefix_at_least "Сеть управления VLAN$HQ_VLAN_MGMT" "$HQ_MGMT_NET" 29 "должна вмещать не более 8 адресов (/29 или меньше по размеру)"
validate_prefix_at_least "Сеть BR-SRV" "$BR_SRV_NET" 28 "должна вмещать не более 16 адресов (/28 или меньше по размеру)"

HQ_RTR_SRV_IP="192.168.10.1"
HQ_SRV_IP="192.168.10.2"
HQ_SRV_DHCP_START="192.168.10.2"
HQ_SRV_DHCP_END="192.168.10.30"
HQ_RTR_CLI_IP="192.168.20.1"
HQ_CLI_IP="192.168.20.2"
HQ_CLI_DHCP_START="192.168.20.2"
HQ_CLI_DHCP_END="192.168.20.30"
HQ_RTR_MGMT_IP="192.168.99.1"
BR_RTR_LAN_IP="192.168.2.1"
BR_SRV_IP="192.168.2.2"
BR_SRV_DHCP_START="192.168.2.2"
BR_SRV_DHCP_END="192.168.2.14"
GRE_HQ_IP="10.10.10.1"
GRE_BR_IP="10.10.10.2"

ask CHANGE_STOCK_IPS "Менять stock IP внутренних устройств/GRE? yes/no" "no"
CHANGE_STOCK_IPS="${CHANGE_STOCK_IPS,,}"
if [[ "$CHANGE_STOCK_IPS" == "yes" || "$CHANGE_STOCK_IPS" == "y" || "$CHANGE_STOCK_IPS" == "да" ]]; then
    ask HQ_RTR_SRV_IP "IP HQ-RTR в VLAN HQ-SRV" "$HQ_RTR_SRV_IP"
    ask HQ_SRV_IP "IP HQ-SRV" "$HQ_SRV_IP"
    ask HQ_SRV_DHCP_START "DHCP start для HQ-SRV bootstrap" "$HQ_SRV_DHCP_START"
    ask HQ_SRV_DHCP_END "DHCP end для HQ-SRV bootstrap" "$HQ_SRV_DHCP_END"
    ask HQ_RTR_CLI_IP "IP HQ-RTR в VLAN HQ-CLI" "$HQ_RTR_CLI_IP"
    ask HQ_CLI_IP "IP HQ-CLI" "$HQ_CLI_IP"
    ask HQ_CLI_DHCP_START "DHCP start для HQ-CLI" "$HQ_CLI_DHCP_START"
    ask HQ_CLI_DHCP_END "DHCP end для HQ-CLI" "$HQ_CLI_DHCP_END"
    ask HQ_RTR_MGMT_IP "IP HQ-RTR в VLAN управления" "$HQ_RTR_MGMT_IP"
    ask BR_RTR_LAN_IP "IP BR-RTR в сторону BR-SRV" "$BR_RTR_LAN_IP"
    ask BR_SRV_IP "IP BR-SRV" "$BR_SRV_IP"
    ask BR_SRV_DHCP_START "DHCP start для BR-SRV bootstrap" "$BR_SRV_DHCP_START"
    ask BR_SRV_DHCP_END "DHCP end для BR-SRV bootstrap" "$BR_SRV_DHCP_END"
    ask GRE_HQ_IP "IP GRE на HQ-RTR" "$GRE_HQ_IP"
    ask GRE_BR_IP "IP GRE на BR-RTR" "$GRE_BR_IP"
else
    echo -e "${GREEN}Внутренние stock IP оставлены по умолчанию.${NC}"
fi

validate_ip_in_cidr "IP ISP в сторону HQ-RTR" "$ISP_HQ_IP" "$ISP_HQ_NET"
validate_ip_in_cidr "IP HQ-RTR в сторону ISP" "$HQ_RTR_WAN_IP" "$ISP_HQ_NET"
validate_ip_in_cidr "DHCP start для HQ-RTR bootstrap" "$ISP_HQ_DHCP_START" "$ISP_HQ_NET"
validate_ip_in_cidr "DHCP end для HQ-RTR bootstrap" "$ISP_HQ_DHCP_END" "$ISP_HQ_NET"
validate_ip_in_cidr "IP ISP в сторону BR-RTR" "$ISP_BR_IP" "$ISP_BR_NET"
validate_ip_in_cidr "IP BR-RTR в сторону ISP" "$BR_RTR_WAN_IP" "$ISP_BR_NET"
validate_ip_in_cidr "DHCP start для BR-RTR bootstrap" "$ISP_BR_DHCP_START" "$ISP_BR_NET"
validate_ip_in_cidr "DHCP end для BR-RTR bootstrap" "$ISP_BR_DHCP_END" "$ISP_BR_NET"
validate_ip_in_cidr "IP HQ-RTR в VLAN HQ-SRV" "$HQ_RTR_SRV_IP" "$HQ_SRV_NET"
validate_ip_in_cidr "IP HQ-SRV" "$HQ_SRV_IP" "$HQ_SRV_NET"
validate_ip_in_cidr "DHCP start для HQ-SRV bootstrap" "$HQ_SRV_DHCP_START" "$HQ_SRV_NET"
validate_ip_in_cidr "DHCP end для HQ-SRV bootstrap" "$HQ_SRV_DHCP_END" "$HQ_SRV_NET"
validate_ip_in_cidr "IP HQ-RTR в VLAN HQ-CLI" "$HQ_RTR_CLI_IP" "$HQ_CLI_NET"
validate_ip_in_cidr "Ожидаемый IP HQ-CLI" "$HQ_CLI_IP" "$HQ_CLI_NET"
validate_ip_in_cidr "DHCP start для HQ-CLI" "$HQ_CLI_DHCP_START" "$HQ_CLI_NET"
validate_ip_in_cidr "DHCP end для HQ-CLI" "$HQ_CLI_DHCP_END" "$HQ_CLI_NET"
validate_ip_in_cidr "IP HQ-RTR в VLAN управления" "$HQ_RTR_MGMT_IP" "$HQ_MGMT_NET"
validate_ip_in_cidr "IP BR-RTR в сторону BR-SRV" "$BR_RTR_LAN_IP" "$BR_SRV_NET"
validate_ip_in_cidr "IP BR-SRV" "$BR_SRV_IP" "$BR_SRV_NET"
validate_ip_in_cidr "DHCP start для BR-SRV bootstrap" "$BR_SRV_DHCP_START" "$BR_SRV_NET"
validate_ip_in_cidr "DHCP end для BR-SRV bootstrap" "$BR_SRV_DHCP_END" "$BR_SRV_NET"
validate_ip_in_cidr "IP GRE на HQ-RTR" "$GRE_HQ_IP" "$GRE_NET"
validate_ip_in_cidr "IP GRE на BR-RTR" "$GRE_BR_IP" "$GRE_NET"

ISP_HQ_PREFIX="$(cidr_prefix "$ISP_HQ_NET")"
ISP_BR_PREFIX="$(cidr_prefix "$ISP_BR_NET")"
HQ_SRV_PREFIX="$(cidr_prefix "$HQ_SRV_NET")"
HQ_CLI_PREFIX="$(cidr_prefix "$HQ_CLI_NET")"
HQ_MGMT_PREFIX="$(cidr_prefix "$HQ_MGMT_NET")"
BR_SRV_PREFIX="$(cidr_prefix "$BR_SRV_NET")"
GRE_PREFIX="$(cidr_prefix "$GRE_NET")"
ISP_HQ_NETMASK="$(prefix_to_netmask "$ISP_HQ_PREFIX")"
ISP_BR_NETMASK="$(prefix_to_netmask "$ISP_BR_PREFIX")"
HQ_SRV_NETMASK="$(prefix_to_netmask "$HQ_SRV_PREFIX")"
HQ_CLI_NETMASK="$(prefix_to_netmask "$HQ_CLI_PREFIX")"
BR_SRV_NETMASK="$(prefix_to_netmask "$BR_SRV_PREFIX")"
PTR_HQ_RTR="$(reverse_ptr_name "$HQ_RTR_SRV_IP")"
PTR_HQ_SRV="$(reverse_ptr_name "$HQ_SRV_IP")"
PTR_HQ_CLI="$(reverse_ptr_name "$HQ_CLI_IP")"
REV_HQ_RTR_ZONE="$(reverse_zone_24 "$HQ_RTR_SRV_IP")"
REV_HQ_SRV_ZONE="$(reverse_zone_24 "$HQ_SRV_IP")"
REV_HQ_CLI_ZONE="$(reverse_zone_24 "$HQ_CLI_IP")"
REV_HQ_RTR_LAST="$(last_octet "$HQ_RTR_SRV_IP")"
REV_HQ_SRV_LAST="$(last_octet "$HQ_SRV_IP")"
REV_HQ_CLI_LAST="$(last_octet "$HQ_CLI_IP")"

ask DEBUG_MODE "Запустить в режиме debug? yes/no" "no"
DEBUG_MODE="${DEBUG_MODE,,}"
START_STAGE="isp"
START_ORDER=10
if is_yes "$DEBUG_MODE"; then
    select_start_stage
else
    echo -e "${YELLOW}Debug выключен, стартую с начала.${NC}"
fi
echo -e "${YELLOW}Debug mode: $DEBUG_MODE; стартовый этап: $START_STAGE${NC}"
echo -e "${YELLOW}Проверь базовую схему:${NC}"
cat << EOF_SUMMARY
Домен: $DOMAIN
ISP-HQ: $ISP_HQ_NET, ISP=$ISP_HQ_IP, HQ-RTR=$HQ_RTR_WAN_IP
ISP-BR: $ISP_BR_NET, ISP=$ISP_BR_IP, BR-RTR=$BR_RTR_WAN_IP
VLAN $HQ_VLAN_SRV HQ-SRV: $HQ_SRV_NET, gateway=$HQ_RTR_SRV_IP, host=$HQ_SRV_IP
VLAN $HQ_VLAN_CLI HQ-CLI: $HQ_CLI_NET, gateway=$HQ_RTR_CLI_IP, DHCP=$HQ_CLI_DHCP_START-$HQ_CLI_DHCP_END, DNS A=$HQ_CLI_IP
VLAN $HQ_VLAN_MGMT MGMT: $HQ_MGMT_NET, gateway=$HQ_RTR_MGMT_IP
Тегирование VLAN на конечных HQ-SRV/HQ-CLI: $TAG_ENDPOINT_VLANS
BR-SRV: $BR_SRV_NET, gateway=$BR_RTR_LAN_IP, host=$BR_SRV_IP
GRE: $GRE_NET, HQ=$GRE_HQ_IP, BR=$GRE_BR_IP
EOF_SUMMARY
echo -e "${YELLOW}Для запуска нужно подтвердить схему.${NC}"
read -r -p "Все выглядит правильно? Напиши YES для продолжения: " CONFIRM_TOPOLOGY
if [[ "$CONFIRM_TOPOLOGY" != "YES" ]]; then
    echo -e "${RED}Остановлено до внесения правильных значений.${NC}"
    exit 1
fi
if is_yes "$DEBUG_MODE"; then
    export PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
    set -x
fi

ensure_cmd nmcli network-manager
ensure_cmd sshpass sshpass

if run_from_stage 10; then
echo -e "${YELLOW}Настраиваю ISP как временный DHCP-bootstrap и NAT...${NC}"
hostnamectl set-hostname "isp.$DOMAIN" || true
timedatectl set-timezone "$TZ_NAME" || true

systemctl enable --now NetworkManager >/dev/null 2>&1 || true
systemctl enable --now NetworkManager-wait-online.service >/dev/null 2>&1 || true
systemctl disable --now nftables >/dev/null 2>&1 || true

nm_dhcp "mod1-isp-wan" "$ISP_WAN_IF"
nm_static "mod1-isp-hq" "$ISP_HQ_IF" "$ISP_HQ_IP/$ISP_HQ_PREFIX"
nm_static "mod1-isp-br" "$ISP_BR_IF" "$ISP_BR_IP/$ISP_BR_PREFIX"

echo -e "${YELLOW}Проверяю интернет на ISP через $ISP_WAN_IF...${NC}"
ip route || true
if ! ping -c 2 -W 3 "$PUBLIC_DNS"; then
    echo -e "${RED}На ISP нет выхода в интернет до $PUBLIC_DNS. Без этого роутеры/серверы не смогут скачать пакеты.${NC}"
    exit 1
fi

ensure_cmd firewall-cmd firewalld
ensure_cmd dhcpd isc-dhcp-server

sysctl -w net.ipv4.ip_forward=1
persist_ip_forward
configure_isp_firewalld

mkdir -p /etc/dhcp
cat > /etc/dhcp/dhcpd.conf << EOF_BOOTSTRAP_DHCP
authoritative;
default-lease-time 1800;
max-lease-time 3600;

subnet ${ISP_HQ_NET%/*} netmask $ISP_HQ_NETMASK {
  range $ISP_HQ_DHCP_START $ISP_HQ_DHCP_END;
  option routers $ISP_HQ_IP;
  option domain-name-servers $PUBLIC_DNS;
}

subnet ${ISP_BR_NET%/*} netmask $ISP_BR_NETMASK {
  range $ISP_BR_DHCP_START $ISP_BR_DHCP_END;
  option routers $ISP_BR_IP;
  option domain-name-servers $PUBLIC_DNS;
}
EOF_BOOTSTRAP_DHCP
if [[ -f /etc/default/isc-dhcp-server ]]; then
    sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"$ISP_HQ_IF $ISP_BR_IF\"/" /etc/default/isc-dhcp-server
fi
if [[ -f /etc/sysconfig/dhcpd ]]; then
    if grep -q "^DHCPDARGS=" /etc/sysconfig/dhcpd; then
        sed -i "s/^DHCPDARGS=.*/DHCPDARGS=\"$ISP_HQ_IF $ISP_BR_IF\"/" /etc/sysconfig/dhcpd
    else
        echo "DHCPDARGS=\"$ISP_HQ_IF $ISP_BR_IF\"" >> /etc/sysconfig/dhcpd
    fi
fi
restart_dhcp_service_local
record_history \
    "hostnamectl set-hostname isp.$DOMAIN" \
    "timedatectl set-timezone $TZ_NAME" \
    "nmcli con add type ethernet ifname $ISP_WAN_IF con-name mod1-isp-wan ipv4.method auto ipv6.method disabled" \
    "nmcli con add type ethernet ifname $ISP_HQ_IF con-name mod1-isp-hq ipv4.method manual ipv4.addresses $ISP_HQ_IP/$ISP_HQ_PREFIX ipv6.method disabled" \
    "nmcli con add type ethernet ifname $ISP_BR_IF con-name mod1-isp-br ipv4.method manual ipv4.addresses $ISP_BR_IP/$ISP_BR_PREFIX ipv6.method disabled" \
    "sysctl -w net.ipv4.ip_forward=1" \
    "firewall-cmd --permanent --zone=external --change-interface=$ISP_WAN_IF" \
    "firewall-cmd --permanent --zone=internal --change-interface=$ISP_HQ_IF" \
    "firewall-cmd --permanent --zone=internal --change-interface=$ISP_BR_IF" \
    "firewall-cmd --permanent --zone=external --add-masquerade" \
    "cat > /etc/dhcp/dhcpd.conf" \
    "systemctl enable --now dhcpd" \
    "systemctl restart dhcpd"
else
    echo -e "${YELLOW}Пропускаю этап ISP, стартовый этап: $START_STAGE.${NC}"
fi

HQ_RTR_DHCP_IP="$HQ_RTR_WAN_IP"
BR_RTR_DHCP_IP="$BR_RTR_WAN_IP"
if run_from_stage 20; then
    echo -e "${GREEN}Подключи HQ-RTR и BR-RTR к ISP, дождись DHCP.${NC}"
    ask HQ_RTR_DHCP_IP "Временный DHCP IP HQ-RTR" "$HQ_RTR_WAN_IP"
    ask BR_RTR_DHCP_IP "Временный DHCP IP BR-RTR" "$BR_RTR_WAN_IP"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

HQ_RTR_SCRIPT="$TMP_DIR/hq-rtr_mod1.sh"
BR_RTR_SCRIPT="$TMP_DIR/br-rtr_mod1.sh"
HQ_SRV_SCRIPT="$TMP_DIR/hq-srv_mod1.sh"
HQ_CLI_SCRIPT="$TMP_DIR/hq-cli_mod1.sh"
BR_SRV_SCRIPT="$TMP_DIR/br-srv_mod1.sh"

nm_remote_functions='
record_history() {
    local cmd
    mkdir -p /etc/profile.d
    cat > /etc/profile.d/mod1-history.sh <<'"'"'EOF_HISTORY_PROFILE'"'"'
shopt -s histappend 2>/dev/null || true
export HISTSIZE=5000
export HISTFILESIZE=5000
export HISTCONTROL=
case ";${PROMPT_COMMAND:-};" in
    *";history -a; history -n;"*) ;;
    *) PROMPT_COMMAND="history -a; history -n${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
esac
EOF_HISTORY_PROFILE
    touch /root/.bash_history
    chmod 600 /root/.bash_history 2>/dev/null || true
    for cmd in "$@"; do
        printf "%s\n" "$cmd" >> /root/.bash_history
    done
}

ensure_wheel_user() {
    local user=$1
    if ! getent group wheel >/dev/null 2>&1; then
        groupadd wheel
    fi
    usermod -aG wheel "$user"
}

install_route_dhcp_packages() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq || true
        apt-get install -y isc-dhcp-server firewalld frr iproute2 || apt-get install -y dhcp-server firewalld frr iproute2
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y dhcp-server firewalld frr iproute
    else
        echo "Неизвестный пакетный менеджер. Нужны DHCP-server, firewalld, FRR, iproute."
        exit 1
    fi
    if ! command -v dhcpd >/dev/null 2>&1; then
        echo "DHCP-server не установлен: нет команды dhcpd. Проверь репозитории/зеркала."
        exit 1
    fi
    if ! systemctl list-unit-files --no-legend frr.service 2>/dev/null | awk "{print \$1}" | grep -qx "frr.service"; then
        echo "FRR не установлен. OSPF не будет настроен, проверь репозитории/зеркала."
        exit 1
    fi
    if ! command -v firewall-cmd >/dev/null 2>&1; then
        echo "firewalld не установлен: нет команды firewall-cmd. Проверь репозитории/зеркала."
        exit 1
    fi
}

check_internet_or_exit() {
    local target=$1
    echo "Проверяю интернет до $target..."
    ip route || true
    if ! ping -c 2 -W 3 "$target"; then
        echo "Нет интернета до $target. Сначала проверь NAT/маршруты на ISP и линк до него."
        exit 1
    fi
}

persist_ip_forward() {
    mkdir -p /etc/sysctl.d
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-mod1-ip-forward.conf
    sysctl -w net.ipv4.ip_forward=1
}

persist_gre_tunnel() {
    local local_ip=$1
    local remote_ip=$2
    local gre_ip=$3
    local gre_prefix=$4
    systemctl disable --now mod1-gre1.timer mod1-gre1.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/mod1-gre1.timer /etc/systemd/system/mod1-gre1.service /usr/local/sbin/mod1-gre1.sh
    systemctl daemon-reload >/dev/null 2>&1 || true

    nmcli con delete mod1-gre1 >/dev/null 2>&1 || true
    ip tunnel del gre1 >/dev/null 2>&1 || true
    nmcli con add type ip-tunnel con-name mod1-gre1 \
        ifname gre1 mode gre \
        local "$local_ip" remote "$remote_ip" \
        ip-tunnel.ttl 255 \
        ipv4.method manual ipv4.addresses "$gre_ip/$gre_prefix" \
        ipv6.method disabled >/dev/null
    nmcli con mod mod1-gre1 connection.autoconnect yes ipv4.never-default yes
    nmcli con up mod1-gre1
}

fw_add_interface() {
    local zone=$1
    local iface=$2
    firewall-cmd --permanent --zone="$zone" --query-interface="$iface" >/dev/null 2>&1 || firewall-cmd --permanent --zone="$zone" --change-interface="$iface" || firewall-cmd --permanent --zone="$zone" --add-interface="$iface"
}

fw_add_source() {
    local zone=$1
    local source=$2
    firewall-cmd --permanent --zone="$zone" --query-source="$source" >/dev/null 2>&1 || firewall-cmd --permanent --zone="$zone" --add-source="$source"
}

fw_add_service() {
    local zone=$1
    local service=$2
    firewall-cmd --permanent --zone="$zone" --query-service="$service" >/dev/null 2>&1 || firewall-cmd --permanent --zone="$zone" --add-service="$service" || true
}

fw_add_protocol() {
    local zone=$1
    local proto=$2
    firewall-cmd --permanent --zone="$zone" --query-protocol="$proto" >/dev/null 2>&1 || firewall-cmd --permanent --zone="$zone" --add-protocol="$proto" || true
}

fw_enable_forward() {
    local zone=$1
    if firewall-cmd --help 2>/dev/null | grep -q -- "--add-forward"; then
        firewall-cmd --permanent --zone="$zone" --add-forward || true
    fi
}

fw_set_target_accept() {
    local zone=$1
    firewall-cmd --permanent --zone="$zone" --set-target=ACCEPT || true
}

fw_add_masquerade() {
    local zone=$1
    firewall-cmd --permanent --zone="$zone" --query-masquerade >/dev/null 2>&1 || firewall-cmd --permanent --zone="$zone" --add-masquerade
}

configure_router_firewalld() {
    local wan_if=$1
    local gre_net=$2
    shift 2

    systemctl enable --now firewalld
    systemctl disable --now nftables >/dev/null 2>&1 || true

    fw_add_interface external "$wan_if"
    fw_set_target_accept external
    fw_set_target_accept internal
    fw_set_target_accept trusted
    fw_add_masquerade external
    fw_enable_forward external
    fw_enable_forward internal
    for net in "$@"; do
        fw_add_source internal "$net"
    done
    fw_add_source trusted "$gre_net"
    fw_add_interface trusted gre1
    fw_add_protocol external gre
    fw_add_protocol internal gre
    fw_add_protocol trusted ospf
    for service in ssh dhcp dns ntp; do
        fw_add_service internal "$service"
    done
    firewall-cmd --reload
    firewall-cmd --zone=external --list-all
    firewall-cmd --zone=internal --list-all
    firewall-cmd --zone=trusted --list-all
}

restart_dhcp_service() {
    local svc=""
    if systemctl list-unit-files --no-legend dhcpd.service 2>/dev/null | awk "{print \$1}" | grep -qx "dhcpd.service"; then
        svc="dhcpd"
    elif systemctl list-unit-files --no-legend isc-dhcp-server.service 2>/dev/null | awk "{print \$1}" | grep -qx "isc-dhcp-server.service"; then
        svc="isc-dhcp-server"
    elif systemctl status dhcpd >/dev/null 2>&1; then
        svc="dhcpd"
    elif systemctl status isc-dhcp-server >/dev/null 2>&1; then
        svc="isc-dhcp-server"
    fi
    if [[ -z "$svc" ]]; then
        echo "Не найден systemd unit DHCP-сервера: dhcpd или isc-dhcp-server"
        exit 1
    fi
    if command -v dhcpd >/dev/null 2>&1 && [[ -f /etc/dhcp/dhcpd.conf ]]; then
        dhcpd -t -cf /etc/dhcp/dhcpd.conf
    fi
    systemctl enable --now "$svc"
    systemctl restart "$svc"
}

configure_frr_ospf() {
    local router_id=$1
    local networks=$2
    local pass=$3
    if [[ -f /etc/frr/daemons ]]; then
        sed -i "s/^zebra=.*/zebra=yes/" /etc/frr/daemons
        sed -i "s/^ospfd=.*/ospfd=yes/" /etc/frr/daemons
    fi
    mkdir -p /etc/frr
    cat > /etc/frr/frr.conf << EOF_FRR
frr version 8.0
frr defaults traditional
hostname $(hostname -s)
service integrated-vtysh-config
!
interface gre1
 ip ospf network point-to-point
 ip ospf message-digest-key 1 md5 $pass
!
router ospf
 ospf router-id $router_id
 passive-interface default
 no passive-interface gre1
 area 0 authentication message-digest
EOF_FRR
    for net in $networks; do
        echo " network $net area 0" >> /etc/frr/frr.conf
    done
    echo "!" >> /etc/frr/frr.conf
    mkdir -p /etc/systemd/system/frr.service.d
    cat > /etc/systemd/system/frr.service.d/10-mod1-gre.conf << EOF_FRR_DROPIN
[Unit]
After=NetworkManager-wait-online.service
Wants=NetworkManager-wait-online.service
EOF_FRR_DROPIN
    systemctl daemon-reload
    systemctl enable --now frr
    systemctl restart frr
}

nm_static() {
    local con=$1
    local ifname=$2
    local address=$3
    local gateway=${4:-}
    local dns=${5:-}
    nmcli con delete "$con" >/dev/null 2>&1 || true
    nmcli device set "$ifname" managed yes >/dev/null 2>&1 || true
    nmcli con add type ethernet ifname "$ifname" con-name "$con" ipv4.method manual ipv4.addresses "$address" ipv6.method disabled >/dev/null
    if [[ -n "$gateway" ]]; then nmcli con mod "$con" ipv4.gateway "$gateway"; fi
    if [[ -n "$dns" ]]; then nmcli con mod "$con" ipv4.dns "$dns" ipv4.ignore-auto-dns yes; fi
    nmcli con mod "$con" connection.autoconnect yes
    nmcli con up "$con" >/dev/null
}

nm_vlan() {
    local con=$1
    local parent=$2
    local vlan_id=$3
    local address=$4
    local ifname="$parent.$vlan_id"
    nmcli con delete "$con" >/dev/null 2>&1 || true
    nmcli con add type vlan con-name "$con" ifname "$ifname" dev "$parent" id "$vlan_id" ipv4.method manual ipv4.addresses "$address" ipv6.method disabled >/dev/null
    nmcli con mod "$con" connection.autoconnect yes
    nmcli con up "$con" >/dev/null
}

nm_parent_no_ip() {
    local con=$1
    local ifname=$2
    nmcli con delete "$con" >/dev/null 2>&1 || true
    nmcli device set "$ifname" managed yes >/dev/null 2>&1 || true
    nmcli con add type ethernet ifname "$ifname" con-name "$con" ipv4.method disabled ipv6.method disabled >/dev/null
    nmcli con mod "$con" connection.autoconnect yes
    nmcli con up "$con" >/dev/null || true
}

nm_endpoint() {
    local con=$1
    local ifname=$2
    local vlan_id=$3
    local address=$4
    local gateway=$5
    local dns=$6
    local tag_vlan=$7
    if [[ "$tag_vlan" == "yes" || "$tag_vlan" == "y" || "$tag_vlan" == "да" ]]; then
        nm_parent_no_ip "$con-parent" "$ifname"
        nm_vlan "$con-vlan$vlan_id" "$ifname" "$vlan_id" "$address"
        nmcli con mod "$con-vlan$vlan_id" ipv4.gateway "$gateway" ipv4.dns "$dns" ipv4.ignore-auto-dns yes
        nmcli con up "$con-vlan$vlan_id" >/dev/null
    else
        nm_static "$con" "$ifname" "$address" "$gateway" "$dns"
    fi
}

nm_endpoint_dhcp() {
    local con=$1
    local ifname=$2
    local vlan_id=$3
    local tag_vlan=$4
    if [[ "$tag_vlan" == "yes" || "$tag_vlan" == "y" || "$tag_vlan" == "да" ]]; then
        nm_parent_no_ip "$con-parent" "$ifname"
        nmcli con delete "$con-vlan$vlan_id" >/dev/null 2>&1 || true
        nmcli con add type vlan con-name "$con-vlan$vlan_id" ifname "$ifname.$vlan_id" dev "$ifname" id "$vlan_id" ipv4.method auto ipv6.method disabled >/dev/null
        nmcli con mod "$con-vlan$vlan_id" connection.autoconnect yes ipv4.route-metric 50
        nmcli con up "$con-vlan$vlan_id" >/dev/null
    else
        nmcli con delete "$con" >/dev/null 2>&1 || true
        nmcli device set "$ifname" managed yes >/dev/null 2>&1 || true
        nmcli con add type ethernet ifname "$ifname" con-name "$con" ipv4.method auto ipv6.method disabled >/dev/null
        nmcli con mod "$con" connection.autoconnect yes ipv4.route-metric 50
        nmcli con up "$con" >/dev/null
    fi
}
'

write_remote "$HQ_RTR_SCRIPT" "$(cat << EOF_HQ_RTR
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH"
$nm_remote_functions
hostnamectl set-hostname hq-rtr.$DOMAIN || true
timedatectl set-timezone $TZ_NAME || true
command -v nmcli >/dev/null 2>&1 || { echo "nmcli не найден. Установи NetworkManager на hq-rtr."; exit 1; }
systemctl enable --now NetworkManager >/dev/null 2>&1 || true
systemctl enable --now NetworkManager-wait-online.service >/dev/null 2>&1 || true
systemctl disable --now nftables >/dev/null 2>&1 || true
useradd -m -s /bin/bash net_admin >/dev/null 2>&1 || true
echo 'net_admin:$NET_ADMIN_PASS' | chpasswd
ensure_wheel_user net_admin
echo 'net_admin ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/net_admin
chmod 0440 /etc/sudoers.d/net_admin
sysctl -w net.ipv4.ip_forward=1
persist_ip_forward
nm_static "mod1-hq-wan" "$HQ_WAN_IF" "$HQ_RTR_WAN_IP/$ISP_HQ_PREFIX" "$ISP_HQ_IP" "$PUBLIC_DNS"
cat > /etc/resolv.conf << EOF_RESOLV
nameserver $PUBLIC_DNS
EOF_RESOLV
check_internet_or_exit "$PUBLIC_DNS"
install_route_dhcp_packages
nm_parent_no_ip "mod1-hq-trunk" "$HQ_TRUNK_IF"
nm_vlan "mod1-vlan-$HQ_VLAN_SRV" "$HQ_TRUNK_IF" "$HQ_VLAN_SRV" "$HQ_RTR_SRV_IP/$HQ_SRV_PREFIX"
nm_vlan "mod1-vlan-$HQ_VLAN_CLI" "$HQ_TRUNK_IF" "$HQ_VLAN_CLI" "$HQ_RTR_CLI_IP/$HQ_CLI_PREFIX"
nm_vlan "mod1-vlan-$HQ_VLAN_MGMT" "$HQ_TRUNK_IF" "$HQ_VLAN_MGMT" "$HQ_RTR_MGMT_IP/$HQ_MGMT_PREFIX"
persist_gre_tunnel "$HQ_RTR_WAN_IP" "$BR_RTR_WAN_IP" "$GRE_HQ_IP" "$GRE_PREFIX"
configure_router_firewalld "$HQ_WAN_IF" "$GRE_NET" "$HQ_SRV_NET" "$HQ_CLI_NET" "$HQ_MGMT_NET"
fw_add_interface internal "$HQ_TRUNK_IF.$HQ_VLAN_SRV"
fw_add_interface internal "$HQ_TRUNK_IF.$HQ_VLAN_CLI"
fw_add_interface internal "$HQ_TRUNK_IF.$HQ_VLAN_MGMT"
firewall-cmd --reload
mkdir -p /etc/dhcp
cat > /etc/dhcp/dhcpd.conf << EOF_DHCP
authoritative;
default-lease-time 1800;
max-lease-time 3600;
option domain-name "$DOMAIN";

subnet ${HQ_SRV_NET%/*} netmask $HQ_SRV_NETMASK {
  range $HQ_SRV_DHCP_START $HQ_SRV_DHCP_END;
  option routers $HQ_RTR_SRV_IP;
  option domain-name-servers $HQ_SRV_IP;
  option domain-search "$DOMAIN";
}

subnet ${HQ_CLI_NET%/*} netmask $HQ_CLI_NETMASK {
  range $HQ_CLI_DHCP_START $HQ_CLI_DHCP_END;
  option routers $HQ_RTR_CLI_IP;
  option domain-name-servers $HQ_SRV_IP;
  option domain-search "$DOMAIN";
}
EOF_DHCP
if [[ -f /etc/default/isc-dhcp-server ]]; then
  sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"$HQ_TRUNK_IF.$HQ_VLAN_SRV $HQ_TRUNK_IF.$HQ_VLAN_CLI\"/" /etc/default/isc-dhcp-server
fi
if [[ -f /etc/sysconfig/dhcpd ]]; then
  if grep -q "^DHCPDARGS=" /etc/sysconfig/dhcpd; then
    sed -i "s/^DHCPDARGS=.*/DHCPDARGS=\"$HQ_TRUNK_IF.$HQ_VLAN_SRV $HQ_TRUNK_IF.$HQ_VLAN_CLI\"/" /etc/sysconfig/dhcpd
  else
    echo "DHCPDARGS=\"$HQ_TRUNK_IF.$HQ_VLAN_SRV $HQ_TRUNK_IF.$HQ_VLAN_CLI\"" >> /etc/sysconfig/dhcpd
  fi
fi
restart_dhcp_service
configure_frr_ospf "$HQ_RTR_WAN_IP" "$HQ_SRV_NET $HQ_CLI_NET $HQ_MGMT_NET $GRE_NET" "$OSPF_PASS"
record_history \
  "hostnamectl set-hostname hq-rtr.$DOMAIN" \
  "timedatectl set-timezone $TZ_NAME" \
  "useradd -m -s /bin/bash net_admin" \
  "echo 'net_admin:$NET_ADMIN_PASS' | chpasswd" \
  "usermod -aG wheel net_admin" \
  "echo 'net_admin ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/net_admin" \
  "sysctl -w net.ipv4.ip_forward=1" \
  "nmcli con add type ethernet ifname $HQ_WAN_IF con-name mod1-hq-wan ipv4.method manual ipv4.addresses $HQ_RTR_WAN_IP/$ISP_HQ_PREFIX ipv4.gateway $ISP_HQ_IP" \
  "nmcli con add type ethernet ifname $HQ_TRUNK_IF con-name mod1-hq-trunk ipv4.method disabled ipv6.method disabled" \
  "nmcli con add type vlan con-name mod1-vlan-$HQ_VLAN_SRV ifname $HQ_TRUNK_IF.$HQ_VLAN_SRV dev $HQ_TRUNK_IF id $HQ_VLAN_SRV ipv4.method manual ipv4.addresses $HQ_RTR_SRV_IP/$HQ_SRV_PREFIX" \
  "nmcli con add type vlan con-name mod1-vlan-$HQ_VLAN_CLI ifname $HQ_TRUNK_IF.$HQ_VLAN_CLI dev $HQ_TRUNK_IF id $HQ_VLAN_CLI ipv4.method manual ipv4.addresses $HQ_RTR_CLI_IP/$HQ_CLI_PREFIX" \
  "nmcli con add type vlan con-name mod1-vlan-$HQ_VLAN_MGMT ifname $HQ_TRUNK_IF.$HQ_VLAN_MGMT dev $HQ_TRUNK_IF id $HQ_VLAN_MGMT ipv4.method manual ipv4.addresses $HQ_RTR_MGMT_IP/$HQ_MGMT_PREFIX" \
  "nmcli con add type ip-tunnel con-name mod1-gre1 ifname gre1 mode gre local $HQ_RTR_WAN_IP remote $BR_RTR_WAN_IP ipv4.addresses $GRE_HQ_IP/$GRE_PREFIX" \
  "firewall-cmd --permanent --zone=external --change-interface=$HQ_WAN_IF" \
  "firewall-cmd --permanent --zone=internal --change-interface=$HQ_TRUNK_IF.$HQ_VLAN_SRV" \
  "firewall-cmd --permanent --zone=internal --change-interface=$HQ_TRUNK_IF.$HQ_VLAN_CLI" \
  "firewall-cmd --permanent --zone=internal --change-interface=$HQ_TRUNK_IF.$HQ_VLAN_MGMT" \
  "firewall-cmd --permanent --zone=external --add-masquerade" \
  "cat > /etc/dhcp/dhcpd.conf" \
  "systemctl enable --now dhcpd" \
  "systemctl restart dhcpd" \
  "cat > /etc/frr/frr.conf" \
  "nano /etc/frr/frr.conf" \
  "systemctl enable --now frr" \
  "vtysh" \
  "systemctl restart frr"
EOF_HQ_RTR
)"

write_remote "$BR_RTR_SCRIPT" "$(cat << EOF_BR_RTR
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH"
$nm_remote_functions
hostnamectl set-hostname br-rtr.$DOMAIN || true
timedatectl set-timezone $TZ_NAME || true
command -v nmcli >/dev/null 2>&1 || { echo "nmcli не найден. Установи NetworkManager на br-rtr."; exit 1; }
systemctl enable --now NetworkManager >/dev/null 2>&1 || true
systemctl enable --now NetworkManager-wait-online.service >/dev/null 2>&1 || true
systemctl disable --now nftables >/dev/null 2>&1 || true
useradd -m -s /bin/bash net_admin >/dev/null 2>&1 || true
echo 'net_admin:$NET_ADMIN_PASS' | chpasswd
ensure_wheel_user net_admin
echo 'net_admin ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/net_admin
chmod 0440 /etc/sudoers.d/net_admin
sysctl -w net.ipv4.ip_forward=1
persist_ip_forward
nm_static "mod1-br-wan" "$BR_WAN_IF" "$BR_RTR_WAN_IP/$ISP_BR_PREFIX" "$ISP_BR_IP" "$PUBLIC_DNS"
cat > /etc/resolv.conf << EOF_RESOLV
nameserver $PUBLIC_DNS
EOF_RESOLV
check_internet_or_exit "$PUBLIC_DNS"
install_route_dhcp_packages
nm_static "mod1-br-lan" "$BR_LAN_IF" "$BR_RTR_LAN_IP/$BR_SRV_PREFIX"
persist_gre_tunnel "$BR_RTR_WAN_IP" "$HQ_RTR_WAN_IP" "$GRE_BR_IP" "$GRE_PREFIX"
configure_router_firewalld "$BR_WAN_IF" "$GRE_NET" "$BR_SRV_NET"
fw_add_interface internal "$BR_LAN_IF"
firewall-cmd --reload
mkdir -p /etc/dhcp
cat > /etc/dhcp/dhcpd.conf << EOF_DHCP
authoritative;
default-lease-time 1800;
max-lease-time 3600;
option domain-name "$DOMAIN";

subnet ${BR_SRV_NET%/*} netmask $BR_SRV_NETMASK {
  range $BR_SRV_DHCP_START $BR_SRV_DHCP_END;
  option routers $BR_RTR_LAN_IP;
  option domain-name-servers $HQ_SRV_IP;
  option domain-search "$DOMAIN";
}
EOF_DHCP
if [[ -f /etc/default/isc-dhcp-server ]]; then
  sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"$BR_LAN_IF\"/" /etc/default/isc-dhcp-server
fi
if [[ -f /etc/sysconfig/dhcpd ]]; then
  if grep -q "^DHCPDARGS=" /etc/sysconfig/dhcpd; then
    sed -i "s/^DHCPDARGS=.*/DHCPDARGS=\"$BR_LAN_IF\"/" /etc/sysconfig/dhcpd
  else
    echo "DHCPDARGS=\"$BR_LAN_IF\"" >> /etc/sysconfig/dhcpd
  fi
fi
restart_dhcp_service
configure_frr_ospf "$BR_RTR_WAN_IP" "$BR_SRV_NET $GRE_NET" "$OSPF_PASS"
record_history \
  "hostnamectl set-hostname br-rtr.$DOMAIN" \
  "timedatectl set-timezone $TZ_NAME" \
  "useradd -m -s /bin/bash net_admin" \
  "echo 'net_admin:$NET_ADMIN_PASS' | chpasswd" \
  "usermod -aG wheel net_admin" \
  "echo 'net_admin ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/net_admin" \
  "sysctl -w net.ipv4.ip_forward=1" \
  "nmcli con add type ethernet ifname $BR_WAN_IF con-name mod1-br-wan ipv4.method manual ipv4.addresses $BR_RTR_WAN_IP/$ISP_BR_PREFIX ipv4.gateway $ISP_BR_IP" \
  "nmcli con add type ethernet ifname $BR_LAN_IF con-name mod1-br-lan ipv4.method manual ipv4.addresses $BR_RTR_LAN_IP/$BR_SRV_PREFIX" \
  "nmcli con add type ip-tunnel con-name mod1-gre1 ifname gre1 mode gre local $BR_RTR_WAN_IP remote $HQ_RTR_WAN_IP ipv4.addresses $GRE_BR_IP/$GRE_PREFIX" \
  "firewall-cmd --permanent --zone=external --change-interface=$BR_WAN_IF" \
  "firewall-cmd --permanent --zone=internal --change-interface=$BR_LAN_IF" \
  "firewall-cmd --permanent --zone=external --add-masquerade" \
  "cat > /etc/frr/frr.conf" \
  "nano /etc/frr/frr.conf" \
  "systemctl enable --now frr" \
  "vtysh" \
  "systemctl restart frr"
EOF_BR_RTR
)"

server_script_common='
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
install_bind_if_needed() {
  if ! command -v named >/dev/null 2>&1 && ! command -v named-checkconf >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq || true
    apt-get install -y bind9 bind9utils || apt-get install -y bind bind-utils
  elif ! command -v named >/dev/null 2>&1 && command -v dnf >/dev/null 2>&1; then
    dnf install -y bind bind-utils
  fi
  if ! command -v named >/dev/null 2>&1 && ! command -v named-checkconf >/dev/null 2>&1; then
    echo "BIND не установлен. Проверь репозитории/зеркала или установи bind вручную."
    exit 1
  fi
}
install_ssh_server_if_needed() {
  if command -v sshd >/dev/null 2>&1; then
    return
  fi
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq || true
    apt-get install -y openssh-server
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y openssh-server
  else
    echo "Неизвестный пакетный менеджер. Нужен openssh-server."
    exit 1
  fi
  command -v sshd >/dev/null 2>&1 || { echo "openssh-server не установлен: нет команды sshd"; exit 1; }
}
create_sshuser() {
  if id sshuser >/dev/null 2>&1; then
    current_uid="$(id -u sshuser)"
    if [[ "$current_uid" != "'"$SSHUSER_UID"'" ]]; then
      if getent passwd '"$SSHUSER_UID"' >/dev/null 2>&1; then
        echo "UID '"$SSHUSER_UID"' уже занят другим пользователем, не могу настроить sshuser."
        exit 1
      fi
      usermod -u '"$SSHUSER_UID"' sshuser
      chown -R sshuser:sshuser /home/sshuser >/dev/null 2>&1 || true
    fi
    usermod -s /bin/bash sshuser
  else
    useradd -m -u '"$SSHUSER_UID"' -s /bin/bash sshuser
  fi
  ensure_wheel_user sshuser
  echo "sshuser:'"$SSHUSER_PASS"'" | chpasswd
  echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser
  chmod 0440 /etc/sudoers.d/sshuser
}
open_ssh_firewall_port() {
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    firewall-cmd --permanent --query-port='"$SSH_PORT"'/tcp >/dev/null 2>&1 || firewall-cmd --permanent --add-port='"$SSH_PORT"'/tcp
    firewall-cmd --reload
  fi
}
prepare_selinux_for_ssh_port() {
  SELINUX_REBOOT_REQUIRED=0
  echo "Проверка статуса SELinux:"
  if command -v sestatus >/dev/null 2>&1; then
    sestatus || true
    if command -v semanage >/dev/null 2>&1; then
      semanage port -a -t ssh_port_t -p tcp '"$SSH_PORT"' >/dev/null 2>&1 || semanage port -m -t ssh_port_t -p tcp '"$SSH_PORT"' >/dev/null 2>&1 || true
    fi
    CONFIG_FILE="/etc/selinux/config"
    if [[ -f "$CONFIG_FILE" ]]; then
      cp "$CONFIG_FILE" "$CONFIG_FILE.bak_mod1" 2>/dev/null || true
      if ! grep -q "^SELINUX=disabled" "$CONFIG_FILE"; then
        sed -i "s/^SELINUX=.*/SELINUX=disabled/" "$CONFIG_FILE"
        SELINUX_REBOOT_REQUIRED=1
        echo "SELinux отключен в $CONFIG_FILE, потребуется reboot"
      fi
    fi
    if command -v setenforce >/dev/null 2>&1; then
      setenforce 0 >/dev/null 2>&1 || true
    fi
  else
    echo "SELinux не установлен или не активен"
  fi
}
secure_ssh() {
  install_ssh_server_if_needed
  prepare_selinux_for_ssh_port
  open_ssh_firewall_port
  mkdir -p /etc/ssh
  echo "Authorized access only" > /etc/issue.net
  touch /etc/ssh/sshd_config
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak_mod1 2>/dev/null || true
  awk "
    BEGIN { inserted=0 }
    /^[[:space:]]*(Port|AllowUsers|MaxAuthTries|Banner|PasswordAuthentication)[[:space:]]/ { next }
    /^[[:space:]]*Match[[:space:]]/ && !inserted {
      print \"Port '"$SSH_PORT"'\"
      print \"PasswordAuthentication yes\"
      print \"AllowUsers sshuser\"
      print \"MaxAuthTries 2\"
      print \"Banner /etc/issue.net\"
      inserted=1
    }
    { print }
    END {
      if (!inserted) {
        print \"Port '"$SSH_PORT"'\"
        print \"PasswordAuthentication yes\"
        print \"AllowUsers sshuser\"
        print \"MaxAuthTries 2\"
        print \"Banner /etc/issue.net\"
      }
    }
  " /etc/ssh/sshd_config > /etc/ssh/sshd_config.mod1
  mv /etc/ssh/sshd_config.mod1 /etc/ssh/sshd_config
  mkdir -p /run/sshd /var/run/sshd
  if ! sshd -t; then
    cp /etc/ssh/sshd_config.bak_mod1 /etc/ssh/sshd_config 2>/dev/null || true
    echo "Ошибка в sshd_config, восстановлен backup. SSH не перенастроен."
    exit 1
  fi
  if command -v restorecon >/dev/null 2>&1; then
    restorecon -v /etc/ssh/sshd_config /etc/issue.net >/dev/null 2>&1 || true
  fi
  if systemctl list-unit-files --no-legend sshd.service 2>/dev/null | awk "{print \$1}" | grep -qx "sshd.service"; then
    systemctl enable sshd
    systemctl restart sshd
  elif systemctl list-unit-files --no-legend ssh.service 2>/dev/null | awk "{print \$1}" | grep -qx "ssh.service"; then
    systemctl enable ssh
    systemctl restart ssh
  else
    echo "Не найден systemd unit SSH: sshd или ssh"
    exit 1
  fi
  if [[ "${SELINUX_REBOOT_REQUIRED:-0}" == "1" ]]; then
    echo "Reboot из-за отключения SELinux для SSH-порта '"$SSH_PORT"'"
    touch /root/.mod1_reboot_requested
    (sleep 20; systemctl reboot || reboot) >/dev/null 2>&1 &
  fi
}
'

write_remote "$HQ_SRV_SCRIPT" "$(cat << EOF_HQ_SRV
#!/bin/bash
$server_script_common
$nm_remote_functions
hostnamectl set-hostname hq-srv.$DOMAIN || true
timedatectl set-timezone $TZ_NAME || true
command -v nmcli >/dev/null 2>&1 || { echo "nmcli не найден. Установи NetworkManager на hq-srv."; exit 1; }
systemctl enable --now NetworkManager >/dev/null 2>&1 || true
create_sshuser
nm_endpoint "mod1-hq-srv" "$HQ_SRV_IF" "$HQ_VLAN_SRV" "$HQ_SRV_IP/$HQ_SRV_PREFIX" "$HQ_RTR_SRV_IP" "127.0.0.1 $PUBLIC_DNS" "$TAG_ENDPOINT_VLANS"
cat > /etc/resolv.conf << EOF_RESOLV
search $DOMAIN
nameserver $PUBLIC_DNS
EOF_RESOLV
echo "Проверяю интернет на HQ-SRV через gateway $HQ_RTR_SRV_IP..."
ip route || true
ping -c 2 -W 2 "$HQ_RTR_SRV_IP"
ping -c 2 -W 3 "$PUBLIC_DNS"
install_bind_if_needed
if [[ -d /etc/bind ]]; then
  BIND_CONF_LOCAL="/etc/bind/named.conf.local"
  BIND_OPTIONS="/etc/bind/named.conf.options"
  ZONE_DIR="/var/cache/bind"
  BIND_SERVICE="bind9"
else
  BIND_CONF_LOCAL="/etc/named.rfc1912.zones"
  BIND_OPTIONS="/etc/named.conf"
  ZONE_DIR="/var/named"
  BIND_SERVICE="named"
fi
mkdir -p "\$ZONE_DIR"
cat > "\$BIND_OPTIONS" << EOF_BIND_OPTIONS
options {
  directory "\$ZONE_DIR";
  recursion yes;
  allow-query { any; };
  forwarders { $PUBLIC_DNS; };
  dnssec-validation no;
  listen-on port 53 { any; };
  listen-on-v6 { none; };
};
EOF_BIND_OPTIONS
if [[ "\$BIND_SERVICE" == "named" ]]; then
  cat >> "\$BIND_OPTIONS" << EOF_NAMED_INCLUDE
include "\$BIND_CONF_LOCAL";
EOF_NAMED_INCLUDE
fi
cat > "\$BIND_CONF_LOCAL" << EOF_BIND_LOCAL
zone "$DOMAIN" {
  type master;
  file "\$ZONE_DIR/db.$DOMAIN";
};
EOF_BIND_LOCAL
add_reverse_zone() {
  local zone=\$1
  local file="\$ZONE_DIR/db.\$zone"
  if ! grep -q "zone \"\$zone\"" "\$BIND_CONF_LOCAL"; then
    cat >> "\$BIND_CONF_LOCAL" << EOF_REV_LOCAL
zone "\$zone" {
  type master;
  file "\$file";
};
EOF_REV_LOCAL
  fi
  if [[ ! -f "\$file" ]]; then
    cat > "\$file" << EOF_REV_BASE
\\\$TTL 86400
@ IN SOA hq-srv.$DOMAIN. admin.$DOMAIN. (
  1 3600 900 604800 86400 )
@ IN NS hq-srv.$DOMAIN.
EOF_REV_BASE
  fi
}
add_ptr() {
  local zone=\$1
  local octet=\$2
  local host=\$3
  local file="\$ZONE_DIR/db.\$zone"
  grep -q "^\$octet " "\$file" 2>/dev/null || echo "\$octet IN PTR \$host.$DOMAIN." >> "\$file"
}
cat > "\$ZONE_DIR/db.$DOMAIN" << EOF_FWD_ZONE
\\\$TTL 86400
@ IN SOA hq-srv.$DOMAIN. admin.$DOMAIN. (
  1 3600 900 604800 86400 )
@ IN NS hq-srv.$DOMAIN.
hq-rtr IN A $HQ_RTR_SRV_IP
br-rtr IN A $BR_RTR_WAN_IP
hq-srv IN A $HQ_SRV_IP
hq-cli IN A $HQ_CLI_IP
br-srv IN A $BR_SRV_IP
docker IN A $ISP_HQ_IP
web IN A $ISP_BR_IP
EOF_FWD_ZONE
add_reverse_zone "$REV_HQ_RTR_ZONE"
add_reverse_zone "$REV_HQ_SRV_ZONE"
add_reverse_zone "$REV_HQ_CLI_ZONE"
add_ptr "$REV_HQ_RTR_ZONE" "$REV_HQ_RTR_LAST" "hq-rtr"
add_ptr "$REV_HQ_SRV_ZONE" "$REV_HQ_SRV_LAST" "hq-srv"
add_ptr "$REV_HQ_CLI_ZONE" "$REV_HQ_CLI_LAST" "hq-cli"
chown -R named:named "\$ZONE_DIR" >/dev/null 2>&1 || chown -R bind:bind "\$ZONE_DIR" >/dev/null 2>&1 || true
if command -v named-checkconf >/dev/null 2>&1; then
  named-checkconf
fi
if command -v named-checkzone >/dev/null 2>&1; then
  named-checkzone "$DOMAIN" "\$ZONE_DIR/db.$DOMAIN"
  named-checkzone "$REV_HQ_RTR_ZONE" "\$ZONE_DIR/db.$REV_HQ_RTR_ZONE"
  named-checkzone "$REV_HQ_SRV_ZONE" "\$ZONE_DIR/db.$REV_HQ_SRV_ZONE"
  named-checkzone "$REV_HQ_CLI_ZONE" "\$ZONE_DIR/db.$REV_HQ_CLI_ZONE"
fi
systemctl enable --now "\$BIND_SERVICE"
systemctl restart "\$BIND_SERVICE"
cat > /etc/resolv.conf << EOF_RESOLV_FINAL
search $DOMAIN
nameserver 127.0.0.1
EOF_RESOLV_FINAL
secure_ssh
record_history \
  "hostnamectl set-hostname hq-srv.$DOMAIN" \
  "timedatectl set-timezone $TZ_NAME" \
  "useradd -m -u $SSHUSER_UID -s /bin/bash sshuser" \
  "echo 'sshuser:$SSHUSER_PASS' | chpasswd" \
  "usermod -aG wheel sshuser" \
  "echo 'sshuser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/sshuser" \
  "nmcli con add type vlan con-name mod1-hq-srv-vlan$HQ_VLAN_SRV ifname $HQ_SRV_IF.$HQ_VLAN_SRV dev $HQ_SRV_IF id $HQ_VLAN_SRV ipv4.method manual ipv4.addresses $HQ_SRV_IP/$HQ_SRV_PREFIX ipv4.gateway $HQ_RTR_SRV_IP" \
  "cat > /etc/named.conf" \
  "nano /etc/named.conf" \
  "cat > /var/named/db.$DOMAIN" \
  "nano > /etc/named/db.$DOMAIN" \
  "named-checkconf" \
  "named-checkzone $DOMAIN /var/named/db.$DOMAIN" \
  "systemctl enable --now named" \
  "systemctl restart named" \
  "echo 'Authorized access only' > /etc/issue.net" \
  "sed -i '/^Port /d;/^AllowUsers /d;/^MaxAuthTries /d;/^Banner /d' /etc/ssh/sshd_config" \
  "echo 'Port $SSH_PORT' >> /etc/ssh/sshd_config" \
  "echo 'AllowUsers sshuser' >> /etc/ssh/sshd_config" \
  "echo 'MaxAuthTries 2' >> /etc/ssh/sshd_config" \
  "echo 'Banner /etc/issue.net' >> /etc/ssh/sshd_config" \
  "sshd -t" \
  "systemctl restart sshd"
EOF_HQ_SRV
)"

write_remote "$HQ_CLI_SCRIPT" "$(cat << EOF_HQ_CLI
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH"
$nm_remote_functions
hostnamectl set-hostname hq-cli.$DOMAIN || true
timedatectl set-timezone $TZ_NAME || true
command -v nmcli >/dev/null 2>&1 || { echo "nmcli не найден. Установи NetworkManager на hq-cli."; exit 1; }
systemctl enable --now NetworkManager >/dev/null 2>&1 || true
nm_endpoint_dhcp "mod1-hq-cli" "$HQ_CLI_IF" "$HQ_VLAN_CLI" "$TAG_ENDPOINT_VLANS"
cat > /etc/resolv.conf << EOF_RESOLV
search $DOMAIN
nameserver $HQ_SRV_IP
EOF_RESOLV
record_history \
  "hostnamectl set-hostname hq-cli.$DOMAIN" \
  "timedatectl set-timezone $TZ_NAME" \
  "nmcli con add type vlan con-name mod1-hq-cli-vlan$HQ_VLAN_CLI ifname $HQ_CLI_IF.$HQ_VLAN_CLI dev $HQ_CLI_IF id $HQ_VLAN_CLI ipv4.method auto ipv6.method disabled" \
  "nmcli con mod mod1-hq-cli-vlan$HQ_VLAN_CLI ipv4.route-metric 50" \
  "cat > /etc/resolv.conf"
EOF_HQ_CLI
)"

write_remote "$BR_SRV_SCRIPT" "$(cat << EOF_BR_SRV
#!/bin/bash
$server_script_common
$nm_remote_functions
hostnamectl set-hostname br-srv.$DOMAIN || true
timedatectl set-timezone $TZ_NAME || true
command -v nmcli >/dev/null 2>&1 || { echo "nmcli не найден. Установи NetworkManager на br-srv."; exit 1; }
systemctl enable --now NetworkManager >/dev/null 2>&1 || true
create_sshuser
nm_static "mod1-br-srv" "$BR_SRV_IF" "$BR_SRV_IP/$BR_SRV_PREFIX" "$BR_RTR_LAN_IP" "$HQ_SRV_IP"
cat > /etc/resolv.conf << EOF_RESOLV
search $DOMAIN
nameserver $HQ_SRV_IP
EOF_RESOLV
secure_ssh
record_history \
  "hostnamectl set-hostname br-srv.$DOMAIN" \
  "timedatectl set-timezone $TZ_NAME" \
  "useradd -m -u $SSHUSER_UID -s /bin/bash sshuser" \
  "echo 'sshuser:$SSHUSER_PASS' | chpasswd" \
  "usermod -aG wheel sshuser" \
  "echo 'sshuser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/sshuser" \
  "nmcli con add type ethernet ifname $BR_SRV_IF con-name mod1-br-srv ipv4.method manual ipv4.addresses $BR_SRV_IP/$BR_SRV_PREFIX ipv4.gateway $BR_RTR_LAN_IP" \
  "echo 'Authorized access only' > /etc/issue.net" \
  "sed -i '/^Port /d;/^AllowUsers /d;/^MaxAuthTries /d;/^Banner /d' /etc/ssh/sshd_config" \
  "echo 'Port $SSH_PORT' >> /etc/ssh/sshd_config" \
  "echo 'AllowUsers sshuser' >> /etc/ssh/sshd_config" \
  "echo 'MaxAuthTries 2' >> /etc/ssh/sshd_config" \
  "echo 'Banner /etc/issue.net' >> /etc/ssh/sshd_config" \
  "sshd -t" \
  "systemctl restart sshd"
EOF_BR_SRV
)"

if run_from_stage 20; then
    push_and_run "$HQ_RTR_DHCP_IP" root "$ROOT_PASS" "$HQ_RTR_SCRIPT" "$HQ_RTR_WAN_IP"
    push_and_run "$BR_RTR_DHCP_IP" root "$ROOT_PASS" "$BR_RTR_SCRIPT" "$BR_RTR_WAN_IP"
else
    echo -e "${YELLOW}Пропускаю этап HQ-RTR/BR-RTR, стартовый этап: $START_STAGE.${NC}"
fi

if run_from_stage 30; then
    ip route replace "$HQ_SRV_NET" via "$HQ_RTR_WAN_IP"
    ip route replace "$HQ_CLI_NET" via "$HQ_RTR_WAN_IP"
    ip route replace "$HQ_MGMT_NET" via "$HQ_RTR_WAN_IP"
    ip route replace "$BR_SRV_NET" via "$BR_RTR_WAN_IP"
    echo -e "${YELLOW}На ISP добавлены временные bootstrap-маршруты до внутренних сетей. После reboot они не сохраняются; постоянную маршрутизацию между офисами делает FRR/OSPF на HQ-RTR и BR-RTR.${NC}"
else
    echo -e "${YELLOW}Пропускаю этап временных маршрутов ISP, стартовый этап: $START_STAGE.${NC}"
fi

HQ_SRV_DHCP_IP="$HQ_SRV_IP"
HQ_CLI_DHCP_IP="$HQ_CLI_IP"
BR_SRV_DHCP_IP="$BR_SRV_IP"
if run_from_stage 43; then
    echo -e "${GREEN}Теперь подключи HQ-SRV в VLAN$HQ_VLAN_SRV, HQ-CLI в VLAN$HQ_VLAN_CLI, BR-SRV к BR-RTR и дождись DHCP.${NC}"
fi
if run_from_stage 41 || run_from_stage 40; then
    ask HQ_SRV_DHCP_IP "Временный DHCP IP HQ-SRV" "$HQ_SRV_IP"
fi
if run_from_stage 42 || run_from_stage 40; then
    ask HQ_CLI_DHCP_IP "Текущий DHCP IP HQ-CLI (может быть .2, .3 и т.д.)" "$HQ_CLI_IP"
fi
if run_from_stage 43 || run_from_stage 40; then
    ask BR_SRV_DHCP_IP "Временный DHCP IP BR-SRV" "$BR_SRV_IP"
fi

if run_from_stage 41 || run_from_stage 40; then
    push_and_run "$HQ_SRV_DHCP_IP" root "$ROOT_PASS" "$HQ_SRV_SCRIPT" "$HQ_SRV_IP" "$SSH_PORT" sshuser "$SSHUSER_PASS"
fi
if run_from_stage 42 || run_from_stage 40; then
    push_and_run "$HQ_CLI_DHCP_IP" root "$ROOT_PASS" "$HQ_CLI_SCRIPT" "$HQ_CLI_DHCP_IP"
fi
if run_from_stage 43 || run_from_stage 40; then
    push_and_run "$BR_SRV_DHCP_IP" root "$ROOT_PASS" "$BR_SRV_SCRIPT" "$BR_SRV_IP" "$SSH_PORT" sshuser "$SSHUSER_PASS"
fi

echo -e "${GREEN}=== Готово. Базовая схема настроена. ===${NC}"
echo "Адреса:"
echo "ISP-HQ: $ISP_HQ_IP/$ISP_HQ_PREFIX, HQ-RTR: $HQ_RTR_WAN_IP/$ISP_HQ_PREFIX"
echo "ISP-BR: $ISP_BR_IP/$ISP_BR_PREFIX, BR-RTR: $BR_RTR_WAN_IP/$ISP_BR_PREFIX"
echo "HQ-SRV VLAN$HQ_VLAN_SRV: $HQ_SRV_IP/$HQ_SRV_PREFIX gateway $HQ_RTR_SRV_IP"
echo "HQ-CLI VLAN$HQ_VLAN_CLI: DHCP-клиент, последний введенный IP $HQ_CLI_DHCP_IP/$HQ_CLI_PREFIX, gateway $HQ_RTR_CLI_IP, DNS A $HQ_CLI_IP"
echo "MGMT VLAN$HQ_VLAN_MGMT: $HQ_RTR_MGMT_IP/$HQ_MGMT_PREFIX"
echo "BR-SRV: $BR_SRV_IP/$BR_SRV_PREFIX gateway $BR_RTR_LAN_IP"

# Demo2026

Скрипты для подготовки лабораторной инфраструктуры Demo2026 по направлению
`09.02.06` - сетевое и системное администрирование.

Проект закрывает автоматическую настройку первого модуля, запуск второго модуля
через web/CLI-мастер и набор резервных ручных скриптов.

> [!WARNING]
> Скрипты рассчитаны на лабораторные ВМ и должны запускаться осознанно.
> Многие файлы требуют `root`, меняют сетевые подключения, firewall, `/etc`,
> службы, пользователей, DNS, Samba, Docker и Ansible. Перед запуском проверьте
> hostname, интерфейсы, адресацию и актуальную топологию задания.

## Основной запуск

| Модуль | Предпочтительный способ | Где запускать |
| --- | --- | --- |
| 1 модуль в.1| `1mod_auto_frwl.sh` | Только на `ISP` |
| 1 модуль в.2 | `module1.sh` | Скрипт Кирюхи |
| 2 модуль | `mod2/deploy_web.py` | Запуск на `BR-SRV`, открывать в браузере с `HQ-CLI` по IP |
| 2 модуль, CLI | `mod2/deploy_inf.sh` | На `BR-SRV`, менее предпочтительный вариант, без графики |
| Удаление логов | `Сlean_bash_history.sh` | Где удобно |
| IP Калькулятор | `ipcalc.sh` | Где удобно |



## 1 Модуль: Автоматически

Основной автоматизатор первого модуля враиант 1 - `1mod_auto_frwl.sh`. Он запускается на
`ISP`, спрашивает параметры топологии, показывает сводку для подтверждения и
дальше раскладывает/запускает удаленные скрипты на остальных узлах.

> [!WARNING]
> ПЕРЕД ВЫПОЛНЕНИЕМ ВЕЗДНЕ ОБЯАТЕЛЬНО ВКЛЮЧИТЬ SSH ОТ ROOT.
> КОНФИГ ЛЕЖИТ В  /etc/openssh/sshd_config - в случае с RTR, ISP и /etc/ssh/sshd_config - на SRV и CLI.
> Сотри решетку у PermitRootLogin, и приведи к виду PermitRootLogin yes.
> ПОСЛЕ ЭТОГО ПЕРЕЗАГРУЗИ SSH командой systemctl restart sshd.

Видео инструкция 1 модуль: [https://www.youtube.com/watch?v=bNH4R_5HLtI](https://www.youtube.com/watch?v=bNH4R_5HLtIm)

Как запустить:
```bash
apt-get install git
git clone https://github.com/RxtPR/Demo26
cd start
chmod +x 1mod_auto_frwl.sh
./1mod_auto_frwl.sh
```
Основной автоматизатор первого модуля враиант 2 - `module1.sh`. 
Что делает автоматизатор в.1:

| Узел | Что настраивается |
| --- | --- |
| `ISP` | DHCP-bootstrap, адресация, firewalld, NAT |
| `HQ-RTR` | NetworkManager, VLAN, GRE, DHCP, firewalld, FRR/OSPF |
| `BR-RTR` | NetworkManager, GRE, firewalld, FRR/OSPF |
| `HQ-SRV` | VLAN, DNS/BIND, SSH-пользователь |
| `HQ-CLI` | DHCP/VLAN endpoint |
| `BR-SRV` | Статическая адресация и SSH-пользователь |

> [!WARNING]
> После выполнения автоматизатора в.1 **ОБЯЗАТЕЛЬНО** почистить логи!
> После удаления логов **ОБЯЗАТЕЛЬННО ПЕРЕЗАПУСТИТЬ ВСЕ МАШИНЫ**, и удалить сам файл скрипта с машин!
> Важно не оставить следов, которые можно найти при проверке!
> Чистит логи скрипт `Сlean_bash_history.sh`
> **ТАК ЖЕ ОБЯЗАТЕЛЬНО** удалить DHCP subnet 192.168.10.0  **ЦЕЛИКОМ** на `HQ-RTR` в файле`/etc/dhcp/dhcpd.config`,

## 2 Модуль: Web

Предпочтительный способ второго модуля - красивый web-мастер
`mod2/deploy_web.py`. Его нужно запускать на `BR-SRV`, а форму открывать с
`HQ-CLI` в браузере по IP-адресу `BR-SRV`.

ПЕРЕД ВЫПОЛЕНИЕМ ОБНОВИТЬ **ISP**.
**ПЕРЕД ВЫПОЛНЕНИЕМ ВЕЗДНЕ ОБЯЗАТЕЛЬНО ВКЛЮЧИТЬ SSH ОТ ROOT.**
КОНФИГ ЛЕЖИТ В  `/etc/openssh/sshd_config` - в случае с RTR, ISP и `/etc/ssh/sshd_config` - на SRV и CLI.
Сотри решетку у PermitRootLogin, и приведи к виду PermitRootLogin yes.
ПОСЛЕ ЭТОГО ПЕРЕЗАГРУЗИ SSH командой `systemctl restart sshd`

Видео инструкция 2 модуль: [https://youtu.be/iBdUqw4EMHw](https://youtu.be/iBdUqw4EMHw)

Как запустить:
```bash
dnf install git
git clone https://github.com/RxtPR/Demo26
cd start
cd mod2
chmod +x deploy_web.py
./deploy_web.py
```

После запуска скрипт поднимет web-интерфейс и покажет адрес. На `HQ-CLI`
откройте его в браузере:
Скачать браузер можно так:
```bash
dnf install firefox
```
В поисковой строке укажи ip `BR-SRV`и порт 8088
```text
http://<IP-BR-SRV>:8088
```

Если порт `8088` занят, web-мастер выберет следующий свободный порт. Используйте
адрес, который он выведет в терминал.

Web-мастер собирает параметры в форме и передает их в `deploy_inf.sh`: домен,
пароли, пользователей, БД, Docker-образы, контейнеры, порт приложения,
SSH-проброс и stratum chrony.

## 2 Модуль: CLI

CLI-вариант `mod2/deploy_inf.sh` менее предпочтителен, но полезен, если web
недоступен, или нет возможности запустить. Запускается на `BR-SRV`.

```bash
dnf install git
git clone https://github.com/RxtPR/Demo26
cd start
cd mod2
chmod +x deploy_inf.sh
./deploy_inf.sh
```

Скрипт защищен от случайного запуска и ожидает, что hostname содержит `br-srv`.
Перед стартом он спрашивает, обновлен ли ISP, затем параметры домена, пароли,
БД, Docker, порт приложения, порт SSH-проброса и chrony.

`deploy_inf.sh` создает в `/etc/ansible`:

| Файл/каталог | Назначение |
| --- | --- |
| `ansible.cfg` | Базовая конфигурация Ansible |
| `inventory.yml` | Узлы ISP, HQ-RTR, BR-RTR, HQ-SRV, BR-SRV, HQ-CLI |
| `group_vars/all.yml` | Общие переменные задания |
| `site.yml` | Главный playbook |
| `roles/*` | Роли для сервисов второго модуля |

Основные роли второго модуля:

| Роль | Что настраивает |
| --- | --- |
| `mount_iso` | Монтирование ISO и проверку каталогов `docker`/`web` |
| `samba_dc` | Samba DC на BR-SRV, DNS-записи, группу `hq`, пользователей `hquser1..5` |
| `raid_nfs` | RAID0 из `/dev/sdb` и `/dev/sdc`, ext4, NFS export |
| `chrony_server` | NTP-сервер на ISP |
| `chrony_client` | NTP-клиенты на остальных узлах |
| `docker_stack` | Docker Compose стек на BR-SRV |
| `apache_app` | Apache, MariaDB и PHP-приложение на HQ-SRV |
| `port_forwarding` | Пробросы портов через firewalld на маршрутизаторах |
| `nginx_proxy_auth` | Nginx reverse proxy и basic-auth на ISP |
| `yandex_browser` | Яндекс Браузер на HQ-CLI |

## Основные файлы

| Файл | Назначение | Где запускать |
| --- | --- | --- |
| `1mod_auto_frwl.sh` | Основной автоматизатор первого модуля. | `isp` |
| `скрипт кирюхи.sh` | Основной пользовательский скрипт, который будет добавлен позже. | По назначению после загрузки |
| `mod2/deploy_web.py` | Предпочтительный web-мастер второго модуля. | `br-srv`, открывать с `hq-cli` |
| `mod2/deploy_inf.sh` | CLI-мастер второго модуля, менее предпочтительный. | `br-srv` |
| `ipcalc.sh` | IP-калькулятор: network, broadcast, hostmin/hostmax, wildcard, binary/hex. | Локально |
| `Сlean_bash_history.sh` | Скрит очищающий логи, в конце **ОБЯЗАТЕЛЬНО** его выполнить | Локально |
## Топология

Скрипты ориентируются на короткое имя хоста. Перед запуском проверьте:

```bash
hostname -s
```

Ожидаемые имена:

| Узел | Роль |
| --- | --- |
| `isp` | Внешний маршрутизатор, NAT, DHCP-bootstrap для автоматизаторов |
| `hq-rtr` | Маршрутизатор HQ, VLAN, GRE, OSPF, DHCP для HQ-CLI |
| `br-rtr` | Маршрутизатор BR, GRE, OSPF |
| `hq-srv` | Сервер HQ, DNS/BIND, SSH-пользователь |
| `hq-cli` | Клиент HQ |
| `br-srv` | Сервер BR, Samba DC и второй модуль |

## Адресация первого модуля

По умолчанию `module1_config.sh` использует такие базовые значения:

| Сегмент | CIDR | Шлюз/первый адрес |
| --- | --- | --- |
| ISP-HQ | `172.16.1.0/28` | ISP `172.16.1.1`, HQ-RTR `172.16.1.2` |
| ISP-BR | `172.16.2.0/28` | ISP `172.16.2.1`, BR-RTR `172.16.2.2` |
| HQ-SRV | `172.16.10.0/27` | HQ-RTR `172.16.10.1`, HQ-SRV `172.16.10.2` |
| HQ-CLI | `172.16.20.0/27` | HQ-RTR `172.16.20.1`, DHCP с `.2` по предпоследний адрес |
| MGMT | `172.16.99.0/29` | HQ-RTR `172.16.99.1` |
| BR-SRV | `172.16.30.0/28` | BR-RTR `172.16.30.1`, BR-SRV `172.16.30.2` |
| GRE | `192.168.0.0/30` | BR `192.168.0.1`, HQ `192.168.0.2` |

VLAN по умолчанию:

| VLAN | Назначение |
| --- | --- |
| `100` | HQ-SRV |
| `200` | HQ-CLI |
| `999` | Management |

## Docker Compose

В каталоге `legacy` лежат два compose-примера:

| Файл | Описание |
| --- | --- |
| `mod2/docker_hq/docker-compose.yaml` | MariaDB `webdb` + `php:apache`, публикация `80:80` |
| `mod2/docker_br/docker-compose.yaml` | `site:latest` + MariaDB `testdb`, публикация `8080:8080` |

В compose-файлах есть жестко заданные имена контейнеров, пароли и пути к данным.
**Это резервный вариант запуска контейнеров для 2 модуля**
Перед реальным запуском проверьте их под свою среду.

## Служебные утилиты

IP-калькулятор:

```bash
./ipcalc.sh
./ipcalc.sh 172.16.20.1/27
./ipcalc.sh 172.16.20.1 255.255.255.224
```

Очистка истории bash:

```bash
./clean_bash_history.sh
```

По умолчанию чистится `~/.bash_history`. Можно передать другой файл:

```bash
./clean_bash_history.sh /tmp/history.txt
```

Удаляются строки, содержащие:

```text
apt-get install git
dnf install git
git clone
./
history -d
chmod +x
```
**После выполнения перезагрузить машины!**

## Проверки после запуска

Сеть и адреса:

```bash
ip -br addr
ip route
nmcli connection show
```

Firewall:

```bash
firewall-cmd --list-all
firewall-cmd --get-active-zones
```

OSPF:

```bash
systemctl status frr --no-pager
vtysh -c 'show ip ospf neighbor'
vtysh -c 'show ip route ospf'
```

DNS:

```bash
named-checkconf
dig @127.0.0.1 hq-srv.au-team.irpo
dig @127.0.0.1 -x 172.16.10.2
```

DHCP:

```bash
systemctl status dhcpd --no-pager
journalctl -u dhcpd -n 50 --no-pager
```

Samba:

```bash
systemctl status samba --no-pager
smbclient -L localhost -N
samba-tool user list
```

Docker:

```bash
docker ps -a
docker compose ps
```

Ansible:

```bash
ansible all -i /etc/ansible/inventory.yml -m ping
ansible-playbook /etc/ansible/site.yml --check
```

## Резервный способ

Резервный способ делает только первый модуль. Он нужен, если автоматический
`1mod_auto_frwl.sh` не подходит или нужно вручную подогнать отдельные части
инфраструктуры.

Перед использованием резервных скриптов сначала подготовьте `module1_config.sh` в папке `legacy`,
чтобы подогнать домен, VLAN, адресацию, пароли, SSH и OSPF под свой вариант.
При первом запуске скрипт создаст `demo2026-module1.conf` рядом с файлами.

Чтобы пересоздать конфиг:

```bash
RESET_MODULE1_CONFIG=1 ./ip.sh
```

Чтобы явно указать путь к конфигу:

```bash
MODULE1_CONFIG=/path/to/demo2026-module1.conf ./ip.sh
```

Резервный порядок запуска:

```bash
chmod +x *.sh
./ip.sh
./inet.sh
./dhcp.sh
./dns.sh
./ospf.sh
./useradd.sh
```

Запускайте только те скрипты, которые подходят текущему хосту. Например,
`dns.sh` сам остановится, если запущен не на `hq-srv`, а `dhcp.sh` - если
запущен не на `hq-rtr`.

Рекомендуемый порядок по узлам:

| Узел | Скрипты |
| --- | --- |
| `isp` | `ip.sh`, `inet.sh` |
| `hq-rtr` | `ip.sh`, `inet.sh`, `dhcp.sh`, `ospf.sh`, `useradd.sh` |
| `br-rtr` | `ip.sh`, `inet.sh`, `ospf.sh`, `useradd.sh` |
| `hq-srv` | `ip.sh`, `dns.sh`, `useradd.sh` |
| `br-srv` | `ip.sh`, `useradd.sh` |

Резервные файлы:

| Файл | Назначение | Где запускать |
| --- | --- | --- |
| `module1_config.sh` | Общий конфиг первого модуля. | Подключается другими скриптами |
| `ip.sh` | Настраивает IP-адреса, VLAN, GRE и NAT через NetworkManager/iptables. | `isp`, `hq-rtr`, `br-rtr`, `hq-srv`, `br-srv` |
| `inet.sh` | Настраивает `firewalld`, зоны, masquerade, GRE/OSPF и доступ к сервисам. | `isp`, `hq-rtr`, `br-rtr` |
| `dhcp.sh` | Поднимает DHCP для сети HQ-CLI. | `hq-rtr` |
| `dns.sh` | Поднимает BIND, прямую и обратную DNS-зоны. | `hq-srv` |
| `ospf.sh` | Настраивает FRR/OSPF через GRE с MD5-аутентификацией. | `hq-rtr`, `br-rtr` |
| `useradd.sh` | Создает пользователей, задает пароли, sudo и SSH-настройки. | `hq-rtr`, `br-rtr`, `hq-srv`, `br-srv` ||
| `clean_bash_history.sh` | Удаляет из `~/.bash_history` строки с заданными служебными командами. | Локально/на нужном хосте |

Если FRR поднялся, но маршруты не появились, проверьте соседство:

```bash
vtysh -c 'show ip ospf neighbor'
```

Иногда помогает перезапуск:

```bash
systemctl restart frr
```

## Важные примечания

- Большинство скриптов нужно запускать от `root`.
- Перед запуском убедитесь, что hostname совпадает с ролью машины.
- Имена интерфейсов в скриптах предполагают конкретную лабораторную схему.
- Web-вариант второго модуля запускается на `BR-SRV`, но открывается с `HQ-CLI`
  по IP-адресу `BR-SRV`.
- `useradd.sh` на серверах меняет порт SSH и может требовать перезагрузку после
  изменения SELinux.
- `deploy_inf.sh` создает и перезаписывает содержимое `/etc/ansible`.
- `raid_nfs` во втором модуле использует `/dev/sdb` и `/dev/sdc`; проверьте
  диски перед запуском.
- Пароли в репозитории учебные. Для реальной среды замените их.

## Статус

Самые актуальные точки входа сейчас: `1mod_auto_frwl.sh` для первого модуля,
`mod2/deploy_web.py` для второго модуля и `ipcalc.sh` как вспомогательная
утилита. Резервные скрипты оставлены внизу документации для ручной настройки
первого модуля и подгонки под вариант.

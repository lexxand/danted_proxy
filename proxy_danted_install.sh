#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="/etc/danted.conf"
SERVICE_NAME="danted"
DEFAULT_PORT="15097"
DEFAULT_USER="spruser"
SYSCTL_IPV6_FILE="/etc/sysctl.d/99-danted-disable-ipv6.conf"

PROXY_USER=""
PROXY_PASS=""
PROXY_PORT=""
EXTERNAL_IFACE=""
ALLOWED_CIDR=""
PUBLIC_IP=""
UFW_CHANGED="no"
SSH_PORTS_OPENED=""
SSH_SOURCE_OPENED=""
BACKUP_FILE=""
CONFIG_EXISTED="no"
CONFIG_WRITTEN="no"
DISABLE_IPV6="yes"
IPV6_DISABLED="no"

die() {
    echo "Ошибка: $*" >&2
    exit 1
}

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "запустите скрипт от root: sudo $0"
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

ask_default() {
    local prompt="$1"
    local default="$2"
    local value

    read -r -p "${prompt} [${default}]: " value
    echo "${value:-$default}"
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local answer suffix

    if [[ "${default}" == "y" ]]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi

    while true; do
        read -r -p "${prompt} ${suffix}: " answer
        answer="${answer:-$default}"
        case "${answer,,}" in
            y|yes|д|да) return 0 ;;
            n|no|н|нет) return 1 ;;
            *) echo "Введите y или n." ;;
        esac
    done
}

validate_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

validate_username() {
    local username="$1"
    [[ "${username}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

is_protected_username() {
    local username="$1"
    local login_user

    login_user="$(logname 2>/dev/null || true)"
    if [[ "${username}" == "root" ]]; then
        return 0
    fi
    if [[ -n "${SUDO_USER:-}" && "${username}" == "${SUDO_USER}" ]]; then
        return 0
    fi
    if [[ -n "${login_user}" && "${username}" == "${login_user}" ]]; then
        return 0
    fi

    case "${username}" in
        admin|administrator|kali|ubuntu|debian|ec2-user|centos|fedora|almalinux|rocky|oracle|azureuser|www-data|nobody|sshd|proxy|danted|systemd-*)
            return 0
            ;;
    esac

    return 1
}

validate_proxy_user_choice() {
    local username="$1"
    local passwd_record uid shell home

    if ! validate_username "${username}"; then
        echo "Имя должно начинаться с латинской буквы или _, длина до 32, символы: a-z 0-9 _ -"
        return 1
    fi

    if is_protected_username "${username}"; then
        echo "Это имя защищено от изменения. Выберите отдельного пользователя только для прокси."
        return 1
    fi

    if ! id "${username}" >/dev/null 2>&1; then
        return 0
    fi

    uid="$(id -u "${username}")"
    passwd_record="$(getent passwd "${username}")"
    IFS=':' read -r _ _ _ _ _ home shell <<<"${passwd_record}"

    if (( uid == 0 || uid < 1000 )); then
        echo "Пользователь ${username} уже существует и выглядит системным (UID=${uid}). Скрипт не будет менять его пароль."
        return 1
    fi

    case "${shell}" in
        /usr/sbin/nologin|/sbin/nologin|/bin/false|/usr/bin/false)
            ;;
        *)
            echo "Пользователь ${username} уже существует и имеет интерактивный shell: ${shell}."
            echo "Скрипт не меняет пароли реальных пользователей. Выберите отдельное имя, например ${DEFAULT_USER}."
            return 1
            ;;
    esac

    echo "Пользователь ${username} уже существует: UID=${uid}, home=${home}, shell=${shell}."
    if ask_yes_no "Обновить пароль только для этого service-only пользователя?" "n"; then
        return 0
    fi

    return 1
}

validate_iface_name() {
    local iface="$1"

    [[ "${iface}" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 1
    if command_exists ip; then
        ip link show dev "${iface}" >/dev/null 2>&1 || return 1
    fi
}

validate_ipv4_cidr() {
    local cidr="$1"
    local ip_addr prefix octet
    local o1 o2 o3 o4

    [[ "${cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
    ip_addr="${cidr%/*}"
    prefix="${cidr#*/}"
    [[ "${prefix}" =~ ^[0-9]+$ ]] || return 1

    IFS='.' read -r o1 o2 o3 o4 <<<"${ip_addr}"
    for octet in "${o1}" "${o2}" "${o3}" "${o4}"; do
        [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
        (( 10#${octet} >= 0 && 10#${octet} <= 255 )) || return 1
    done
}

detect_iface() {
    command_exists ip || return 0
    ip route get 1.1.1.1 2>/dev/null | awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    exit
                }
            }
        }
    ' || true
}

detect_public_ip() {
    if command_exists curl; then
        curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true
    fi
}

generate_password() {
    if command_exists openssl; then
        openssl rand -hex 24
    elif command_exists od; then
        od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
    else
        local password
        set +o pipefail
        password="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)"
        set -o pipefail
        printf '%s' "${password}"
    fi
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y dante-server
}

create_or_update_user() {
    if id "${PROXY_USER}" >/dev/null 2>&1; then
        echo "Пользователь ${PROXY_USER} уже существует и прошёл защитную проверку. Обновляю только пароль."
    else
        useradd -M -s /usr/sbin/nologin -- "${PROXY_USER}"
    fi

    printf '%s:%s\n' "${PROXY_USER}" "${PROXY_PASS}" | chpasswd
}

write_danted_config() {
    local tmp_file
    tmp_file="$(mktemp)"

    if [[ -f "${CONFIG_FILE}" ]]; then
        CONFIG_EXISTED="yes"
        BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "${CONFIG_FILE}" "${BACKUP_FILE}"
        echo "Старая конфигурация сохранена: ${BACKUP_FILE}"
    fi

    cat >"${tmp_file}" <<EOF
logoutput: syslog
user.privileged: root
user.unprivileged: nobody

# IPv4-only listener. IPv6 is disabled by sysctl when selected in the installer.
internal: 0.0.0.0 port = ${PROXY_PORT}
external: ${EXTERNAL_IFACE}

socksmethod: username
clientmethod: none

client pass {
    from: ${ALLOWED_CIDR} to: 0.0.0.0/0
    log: error
}

socks block {
    from: 0.0.0.0/0 to: 127.0.0.0/8
    log: error
}

socks block {
    from: 0.0.0.0/0 to: 10.0.0.0/8
    log: error
}

socks block {
    from: 0.0.0.0/0 to: 172.16.0.0/12
    log: error
}

socks block {
    from: 0.0.0.0/0 to: 192.168.0.0/16
    log: error
}

socks block {
    from: 0.0.0.0/0 to: 169.254.0.0/16
    log: error
}

socks pass {
    from: ${ALLOWED_CIDR} to: 0.0.0.0/0
    command: connect
    socksmethod: username
    log: error
}

socks block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
EOF

    install -o root -g root -m 0644 "${tmp_file}" "${CONFIG_FILE}"
    rm -f "${tmp_file}"
    CONFIG_WRITTEN="yes"
}

detect_ssh_ports() {
    local ports=""
    local files=()

    if command_exists ss; then
        ports="$(ss -H -ltnp 2>/dev/null | awk '
            /sshd/ {
                local_addr = $4
                sub(/^.*:/, "", local_addr)
                if (local_addr ~ /^[0-9]+$/) {
                    print local_addr
                }
            }
        ' | sort -nu)"
    fi

    if [[ -z "${ports}" ]]; then
        files=(/etc/ssh/sshd_config)
        if compgen -G "/etc/ssh/sshd_config.d/*.conf" >/dev/null; then
            files+=(/etc/ssh/sshd_config.d/*.conf)
        fi
        ports="$(awk '
            /^[[:space:]]*#/ { next }
            tolower($1) == "port" && $2 ~ /^[0-9]+$/ { print $2 }
        ' "${files[@]}" 2>/dev/null | sort -nu)"
    fi

    if [[ -n "${ports}" ]]; then
        printf '%s\n' "${ports}"
    else
        printf '%s\n' "22"
    fi
}

detect_ssh_client_cidr() {
    local client_ip=""

    if [[ -n "${SSH_CLIENT:-}" ]]; then
        client_ip="${SSH_CLIENT%% *}"
    elif [[ -n "${SSH_CONNECTION:-}" ]]; then
        client_ip="${SSH_CONNECTION%% *}"
    fi

    if [[ -n "${client_ip}" ]] && validate_ipv4_cidr "${client_ip}/32"; then
        printf '%s/32\n' "${client_ip}"
    fi
}

ssh_session_uses_ipv6() {
    local client_ip=""

    if [[ -n "${SSH_CLIENT:-}" ]]; then
        client_ip="${SSH_CLIENT%% *}"
    elif [[ -n "${SSH_CONNECTION:-}" ]]; then
        client_ip="${SSH_CONNECTION%% *}"
    fi

    [[ "${client_ip}" == *:* ]]
}

disable_ipv6_if_requested() {
    if [[ "${DISABLE_IPV6}" != "yes" ]]; then
        return
    fi

    if ! command_exists sysctl; then
        die "sysctl не найден, не могу отключить IPv6"
    fi

    cat >"${SYSCTL_IPV6_FILE}" <<EOF
# Managed by setup-danted.sh. Remove this file and run "sysctl --system" to enable IPv6 again.
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    sysctl -p "${SYSCTL_IPV6_FILE}" >/dev/null
    IPV6_DISABLED="yes"
}

configure_firewall() {
    local detected_ssh_ports ssh_ports_input ssh_port default_ssh_source ssh_source_cidr ufw_status

    if ! ask_yes_no "Ограничить доступ к порту через UFW? Рекомендуется, если UFW используется на сервере" "y"; then
        return
    fi

    if ! command_exists ufw; then
        if ask_yes_no "UFW не установлен. Установить ufw?" "n"; then
            apt-get install -y ufw
        else
            echo "Пропускаю настройку UFW."
            return
        fi
    fi

    ufw_status="$(LANG=C ufw status 2>/dev/null || true)"

    if echo "${ufw_status}" | grep -qi '^Status: active'; then
        echo "UFW уже активен. SSH-правила не меняю, чтобы не расширить существующие ограничения."
    else
        echo "UFW сейчас не активен. При включении firewall важно заранее разрешить SSH только с нужных IP."
        if ask_yes_no "Добавить SSH-правило перед возможным включением UFW?" "y"; then
            detected_ssh_ports="$(detect_ssh_ports | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
            ssh_ports_input="$(ask_default "SSH-порты через пробел" "${detected_ssh_ports}")"
            default_ssh_source="$(detect_ssh_client_cidr || true)"
            ssh_source_cidr="$(ask_default "CIDR, которому разрешить SSH" "${default_ssh_source}")"

            if [[ -z "${ssh_source_cidr}" ]]; then
                die "CIDR для SSH пустой. Чтобы не закрыть себе доступ, скрипт остановлен."
            fi
            if ! validate_ipv4_cidr "${ssh_source_cidr}"; then
                die "некорректный CIDR для SSH: ${ssh_source_cidr}"
            fi

            for ssh_port in ${ssh_ports_input}; do
                if ! validate_port "${ssh_port}"; then
                    die "некорректный SSH-порт для UFW: ${ssh_port}"
                fi
                ufw allow from "${ssh_source_cidr}" to any port "${ssh_port}" proto tcp
            done

            SSH_PORTS_OPENED="${ssh_ports_input}"
            SSH_SOURCE_OPENED="${ssh_source_cidr}"
        else
            echo "SSH-правила не меняю. Включайте UFW только если уверены, что доступ уже разрешён."
        fi
    fi

    ufw allow from "${ALLOWED_CIDR}" to any port "${PROXY_PORT}" proto tcp

    if LANG=C ufw status | grep -qi '^Status: inactive'; then
        if [[ -n "${SSH_PORTS_OPENED}" ]]; then
            echo "Перед включением UFW разрешены SSH TCP-порты ${SSH_PORTS_OPENED} для ${SSH_SOURCE_OPENED}."
        else
            echo "SSH-правила не добавлялись этим скриптом."
        fi
        if ask_yes_no "UFW сейчас выключен. Включить его?" "n"; then
            ufw --force enable
        fi
    fi

    UFW_CHANGED="yes"
}

rollback_danted_config() {
    if [[ "${CONFIG_WRITTEN}" != "yes" ]]; then
        return
    fi

    echo "Откатываю /etc/danted.conf после неудачного запуска Dante."
    if [[ "${CONFIG_EXISTED}" == "yes" && -n "${BACKUP_FILE}" && -f "${BACKUP_FILE}" ]]; then
        cp -a "${BACKUP_FILE}" "${CONFIG_FILE}"
        echo "Возвращён предыдущий конфиг: ${BACKUP_FILE}"
        systemctl restart "${SERVICE_NAME}" || true
    else
        rm -f "${CONFIG_FILE}"
        echo "Предыдущего конфига не было, новый ${CONFIG_FILE} удалён."
    fi
}

restart_service() {
    if ! systemctl restart "${SERVICE_NAME}"; then
        rollback_danted_config
        die "Dante не запустился с новым конфигом. Изменения /etc/danted.conf откачены."
    fi

    systemctl enable "${SERVICE_NAME}" >/dev/null
    systemctl --no-pager --full status "${SERVICE_NAME}" || true
}

collect_answers() {
    local detected_iface custom_pass pass_confirm

    detected_iface="$(detect_iface)"
    [[ -n "${detected_iface}" ]] || detected_iface="eth0"

    echo "Интерактивная настройка SOCKS5 Dante."
    echo "Важно: отсутствие DNS-утечек зависит от клиента. Используйте socks5h / SOCKS5 remote DNS."
    echo

    while true; do
        PROXY_USER="$(ask_default "Имя системного пользователя для SOCKS-аутентификации" "${DEFAULT_USER}")"
        validate_proxy_user_choice "${PROXY_USER}" && break
    done

    while true; do
        PROXY_PORT="$(ask_default "Порт Dante" "${DEFAULT_PORT}")"
        validate_port "${PROXY_PORT}" && break
        echo "Введите порт от 1 до 65535."
    done

    while true; do
        EXTERNAL_IFACE="$(ask_default "Внешний сетевой интерфейс" "${detected_iface}")"
        validate_iface_name "${EXTERNAL_IFACE}" && break
        echo "Интерфейс ${EXTERNAL_IFACE} не найден или имя некорректно."
    done

    while true; do
        ALLOWED_CIDR="$(ask_default "Кому разрешить подключаться к прокси, IPv4 CIDR" "0.0.0.0/0")"
        validate_ipv4_cidr "${ALLOWED_CIDR}" && break
        echo "Введите IPv4 CIDR, например 0.0.0.0/0 или 203.0.113.10/32."
    done

    if ask_yes_no "Отключить IPv6 на сервере через sysctl? Рекомендуется для IPv4-only прокси" "y"; then
        if ssh_session_uses_ipv6; then
            echo "Похоже, текущая SSH-сессия подключена по IPv6. Отключение IPv6 может оборвать доступ."
            if ask_yes_no "Всё равно отключить IPv6?" "n"; then
                DISABLE_IPV6="yes"
            else
                DISABLE_IPV6="no"
            fi
        else
            DISABLE_IPV6="yes"
        fi
    else
        DISABLE_IPV6="no"
    fi

    if ask_yes_no "Сгенерировать сильный пароль автоматически?" "y"; then
        PROXY_PASS="$(generate_password)"
    else
        while true; do
            read -r -s -p "Введите пароль для ${PROXY_USER}: " custom_pass
            echo
            read -r -s -p "Повторите пароль: " pass_confirm
            echo
            if [[ -z "${custom_pass}" ]]; then
                echo "Пароль не может быть пустым."
            elif [[ "${custom_pass}" != "${pass_confirm}" ]]; then
                echo "Пароли не совпадают."
            else
                PROXY_PASS="${custom_pass}"
                break
            fi
        done
    fi
}

print_summary_once() {
    PUBLIC_IP="$(detect_public_ip)"
    [[ -n "${PUBLIC_IP}" ]] || PUBLIC_IP="<IP_СЕРВЕРА>"

    cat <<EOF

Готово. Данные доступа показаны один раз:

  SOCKS5 host: ${PUBLIC_IP}
  SOCKS5 port: ${PROXY_PORT}
  Username:    ${PROXY_USER}
  Password:    ${PROXY_PASS}

Проверка без DNS-утечки на стороне клиента:

  curl --socks5-hostname 'USERNAME:PASSWORD@${PUBLIC_IP}:${PROXY_PORT}' https://api.ipify.org

Важно:
  - используйте именно socks5h / --socks5-hostname / "Proxy DNS when using SOCKS v5";
  - обычный socks5 может резолвить домены локально и утекать DNS;
  - сервер не может заставить клиент не делать локальный DNS-запрос до подключения к SOCKS;
  - абсолютной "1000% анонимности" не бывает: не используйте личные аккаунты, WebRTC/QUIC без контроля и уникальные браузерные отпечатки.
EOF

    if [[ "${UFW_CHANGED}" == "yes" ]]; then
        echo
        echo "UFW был настроен для TCP-порта ${PROXY_PORT} и CIDR ${ALLOWED_CIDR}."
        if [[ -n "${SSH_PORTS_OPENED}" ]]; then
            echo "SSH-правила добавлены только для портов ${SSH_PORTS_OPENED} и CIDR ${SSH_SOURCE_OPENED}."
        else
            echo "SSH-правила скриптом не менялись."
        fi
    fi

    if [[ "${IPV6_DISABLED}" == "yes" ]]; then
        echo
        echo "IPv6 отключён через ${SYSCTL_IPV6_FILE}."
    fi
}

main() {
    need_root
    collect_answers
    install_packages
    disable_ipv6_if_requested
    create_or_update_user
    write_danted_config
    configure_firewall
    restart_service
    print_summary_once
}

main "$@"

#!/usr/bin/env bash

# ==============================================================
#  Caddy Reverse Proxy for Emby - V6 (Multi-Backend Edition)
#  Original author: AiLi1337
#  V6 repository: https://github.com/Yamada-anna1/install_caddy_emby
# ==============================================================

VERSION="6.4.0"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

SCRIPT_URL="${CADDY_EMBY_SCRIPT_URL:-https://raw.githubusercontent.com/Yamada-anna1/install_caddy_emby/main/install_caddy_emby.sh}"
SCRIPT_DEST="/usr/local/bin/caddy_emby.sh"
SHORTCUT="/usr/local/bin/c"
CADDY_DIR="/etc/caddy"
CADDYFILE="$CADDY_DIR/Caddyfile"

log()   { echo -e "${GREEN}[Info]${PLAIN} $1"; }
warn()  { echo -e "${YELLOW}[Warning]${PLAIN} $1"; }
error() { echo -e "${RED}[Error]${PLAIN} $1"; }

register_shortcut() {
    local src="${BASH_SOURCE[0]}"

    # 普通文件运行时直接保存；进程替换/管道运行时重新下载完整脚本。
    if [[ -f "$src" && "$src" != /proc/* && "$src" != /dev/fd/* && "$src" != /dev/stdin ]]; then
        cp "$src" "$SCRIPT_DEST"
    else
        log "正在保存管理脚本到 $SCRIPT_DEST ..."
        if ! curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_DEST"; then
            error "脚本下载失败，请检查网络或手动保存到 $SCRIPT_DEST"
            return 1
        fi
    fi

    chmod +x "$SCRIPT_DEST"
    printf '#!/usr/bin/env bash\nexec bash "%s"\n' "$SCRIPT_DEST" > "$SHORTCUT"
    chmod +x "$SHORTCUT"

    if ! grep -Fq "alias c='bash $SCRIPT_DEST'" /root/.bashrc 2>/dev/null; then
        printf "\nalias c='bash %s'\n" "$SCRIPT_DEST" >> /root/.bashrc
    fi
    log "已注册快捷命令：c"
}

install_base() {
    log "正在检查基础组件..."
    local packages=(curl wget sudo socat net-tools psmisc sed grep gpg)
    local to_install=()
    local pkg

    if [[ -f /etc/debian_version ]]; then
        for pkg in "${packages[@]}"; do
            if ! dpkg -s "$pkg" 2>/dev/null | grep -q '^Status: install ok installed'; then
                to_install+=("$pkg")
            fi
        done
        if ((${#to_install[@]})); then
            log "正在安装缺失组件: ${to_install[*]}"
            apt-get update -y && apt-get install -y "${to_install[@]}"
        else
            log "所有基础组件已安装"
        fi
    elif [[ -f /etc/redhat-release ]]; then
        for pkg in "${packages[@]}"; do
            rpm -q "$pkg" &>/dev/null || to_install+=("$pkg")
        done
        if ((${#to_install[@]})); then
            log "正在安装缺失组件: ${to_install[*]}"
            yum install -y "${to_install[@]}"
        else
            log "所有基础组件已安装"
        fi
    else
        warn "未检测到支持的 Linux 发行版 (Debian/Ubuntu/CentOS/RHEL)"
        return 1
    fi
}

validate_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]
}

# 设置 NORMALIZED_BACKEND 和 BACKEND_SCHEME。
normalize_backend() {
    local input="$1"
    local scheme="http"
    local address="$input"
    local host port octet

    input="${input%/}"
    if [[ "$input" =~ ^(https?)://(.+)$ ]]; then
        scheme="${BASH_REMATCH[1]}"
        address="${BASH_REMATCH[2]}"
    else
        address="$input"
    fi

    # 支持域名、IPv4 和带方括号的 IPv6；上游地址不能包含路径。
    if [[ "$address" =~ ^(\[[0-9A-Fa-f:]+\]|[a-zA-Z0-9._-]+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        return 1
    fi

    ((10#$port >= 1 && 10#$port <= 65535)) || return 1

    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        IFS='.' read -r -a octets <<< "$host"
        for octet in "${octets[@]}"; do
            [[ "$octet" =~ ^[0-9]+$ ]] && ((10#$octet <= 255)) || return 1
        done
    fi

    BACKEND_SCHEME="$scheme"
    if [[ "$scheme" == "https" ]]; then
        NORMALIZED_BACKEND="https://$host:$port"
    else
        NORMALIZED_BACKEND="$host:$port"
    fi
}

collect_backends() {
    BACKENDS=()
    local expected_scheme=""
    local input duplicate backend index=1

    echo -e "${SKYBLUE}逐个输入后端地址；添加完毕后直接按回车。${PLAIN}"
    echo "同一域名的后端必须全部使用 HTTP，或全部使用 HTTPS。"

    while true; do
        if ((index == 1)); then
            read -r -p "后端 #1（留空默认 127.0.0.1:8096）: " input < /dev/tty
            [[ -z "$input" ]] && input="127.0.0.1:8096"
        else
            read -r -p "后端 #$index（留空结束）: " input < /dev/tty
            [[ -z "$input" ]] && break
        fi

        if ! normalize_backend "$input"; then
            error "地址无效。示例：127.0.0.1:8096、emby.example.com:8096、https://emby.example.com:443"
            continue
        fi

        if [[ -n "$expected_scheme" && "$BACKEND_SCHEME" != "$expected_scheme" ]]; then
            error "不能混用 HTTP 与 HTTPS 后端；请保持和第一个后端一致。"
            continue
        fi
        expected_scheme="${expected_scheme:-$BACKEND_SCHEME}"

        duplicate=false
        for backend in "${BACKENDS[@]}"; do
            if [[ "$backend" == "$NORMALIZED_BACKEND" ]]; then
                duplicate=true
                break
            fi
        done
        if [[ "$duplicate" == true ]]; then
            warn "该后端已存在，未重复添加。"
            continue
        fi

        BACKENDS+=("$NORMALIZED_BACKEND")
        log "已添加：$NORMALIZED_BACKEND"
        ((index++))
    done

    ((${#BACKENDS[@]} > 0))
}

select_load_balance_policy() {
    local policy_choice
    LB_POLICY="first"
    ((${#BACKENDS[@]} > 1)) || return 0

    echo ""
    echo -e "${SKYBLUE}请选择多后端工作模式：${PLAIN}"
    echo " 1. 主备故障切换（推荐；始终优先第一个后端，避免 Emby 登录失效）"
    echo " 2. 按客户端 IP 粘滞（不同客户端可分流，同一客户端固定后端）"
    echo " 3. 轮询负载均衡（仅适合共享用户、令牌和媒体状态的后端）"
    read -r -p "请选择 [1-3]（默认 1）: " policy_choice < /dev/tty

    case "$policy_choice" in
        2) LB_POLICY="client_ip_hash" ;;
        3) LB_POLICY="round_robin" ;;
        *) LB_POLICY="first" ;;
    esac
}

check_port() {
    echo "------------------------------------------------"
    echo -e "${SKYBLUE}正在查询 80 和 443 端口占用情况...${PLAIN}"
    echo "------------------------------------------------"
    if command -v ss &>/dev/null; then
        ss -tulpn | grep -E ':(80|443)([[:space:]]|$)' || true
    elif command -v netstat &>/dev/null; then
        netstat -tunlp | grep -E ':(80|443)([[:space:]]|$)' || true
    fi
    echo "------------------------------------------------"
}

caddy_service_available() {
    systemctl cat caddy.service >/dev/null 2>&1
}

show_caddy_failure_details() {
    echo ""
    echo -e "${YELLOW}================ Caddy 启动诊断 ================${PLAIN}"

    if ! caddy_service_available; then
        error "未找到 caddy.service。机器上可能只有 Caddy 可执行文件，没有 systemd 服务。"
        echo "请重新运行菜单 1，脚本会补装/修复官方 Caddy 服务。"
    else
        echo -e "${SKYBLUE}[systemctl status]${PLAIN}"
        systemctl status caddy --no-pager -l 2>&1 | tail -n 18 || true
        echo ""
        echo -e "${SKYBLUE}[最近的 Caddy 日志]${PLAIN}"
        journalctl -u caddy --no-pager -n 25 2>/dev/null || true
    fi

    echo ""
    echo -e "${SKYBLUE}[80/443 端口占用]${PLAIN}"
    if command -v ss &>/dev/null; then
        ss -tulpn 2>/dev/null | grep -E ':(80|443)([[:space:]]|$)' || echo "未发现监听程序"
    elif command -v netstat &>/dev/null; then
        netstat -tunlp 2>/dev/null | grep -E ':(80|443)([[:space:]]|$)' || echo "未发现监听程序"
    fi
    echo ""
    warn "如果端口被 nginx、apache、httpd 或其他程序占用，请返回主菜单选择 8 后重试。"
    echo -e "${YELLOW}=================================================${PLAIN}"
}

kill_port() {
    local confirm attempt pids pid cgroup_line
    local services=(nginx openresty apache2 httpd)

    echo -e "${RED}此操作会停止并屏蔽占用 Web 端口的 nginx/openresty/apache 服务。${PLAIN}"
    read -r -p "确定继续？[y/N]: " confirm < /dev/tty
    [[ "$confirm" =~ ^[Yy]$ ]] || { log "已取消"; return 0; }

    echo -e "${RED}正在停止常见 Web 服务并清理 80/TCP、443/TCP、443/UDP...${PLAIN}"
    for service in "${services[@]}"; do
        if systemctl cat "$service.service" >/dev/null 2>&1; then
            systemctl disable --now "$service.service" 2>/dev/null || true
            systemctl mask "$service.service" 2>/dev/null || true
        fi
    done

    # 连续处理三次，覆盖服务停止过程中短暂重建的 worker 进程。
    for attempt in 1 2 3; do
        if command -v fuser &>/dev/null; then
            fuser -k 80/tcp 2>/dev/null || true
            fuser -k 443/tcp 2>/dev/null || true
            fuser -k 443/udp 2>/dev/null || true
        fi
        pkill -TERM -x nginx 2>/dev/null || true
        pkill -TERM -x openresty 2>/dev/null || true
        sleep 1
    done
    pkill -KILL -x nginx 2>/dev/null || true
    pkill -KILL -x openresty 2>/dev/null || true
    sleep 2

    pids="$(pgrep -x nginx 2>/dev/null | paste -sd, -)"
    if [[ -n "$pids" ]]; then
        error "nginx 被其他程序自动重新拉起，端口尚未清理完成。"
        echo -e "${SKYBLUE}[nginx 进程来源]${PLAIN}"
        ps -o pid,ppid,user,comm,args -p "$pids" 2>/dev/null || true
        echo ""
        echo -e "${SKYBLUE}[进程所属 cgroup；包含 docker/containerd 时表示来自容器]${PLAIN}"
        IFS=',' read -r -a nginx_pids <<< "$pids"
        for pid in "${nginx_pids[@]}"; do
            echo "PID $pid:"
            while IFS= read -r cgroup_line; do
                echo "  $cgroup_line"
            done < "/proc/$pid/cgroup" 2>/dev/null || true
        done
        if command -v docker &>/dev/null; then
            echo ""
            echo -e "${SKYBLUE}[正在运行的 Docker 容器]${PLAIN}"
            docker ps --no-trunc --format 'table {{.ID}}\t{{.Names}}\t{{.Ports}}' 2>/dev/null || true
        fi
        echo ""
        warn "这通常是宝塔/1Panel/Docker 的守护功能。请把上面的“进程来源”和 cgroup 截图发来。"
        return 1
    fi

    if command -v ss &>/dev/null && ss -tulpn 2>/dev/null | grep -qE ':(80|443)([[:space:]]|$)'; then
        error "仍有其他程序占用 80/443："
        ss -tulpn 2>/dev/null | grep -E ':(80|443)([[:space:]]|$)' || true
        return 1
    fi

    log "80/TCP、443/TCP、443/UDP 已全部释放。"
    log "如需恢复 nginx，可运行：systemctl unmask nginx && systemctl enable --now nginx"
}

install_caddy() {
    if command -v caddy &>/dev/null && caddy_service_available; then
        systemctl unmask caddy >/dev/null 2>&1 || true
        systemctl enable caddy >/dev/null 2>&1 || true
        log "Caddy 和 systemd 服务均已安装。"
        return 0
    fi

    install_base || return 1
    if command -v caddy &>/dev/null; then
        warn "检测到 Caddy 命令，但缺少 caddy.service，正在修复官方安装。"
    else
        log "正在安装 Caddy..."
    fi
    if [[ -f /etc/debian_version ]]; then
        apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
        apt-get update -y
        if dpkg -s caddy &>/dev/null; then
            apt-get install --reinstall -y caddy
        else
            apt-get install -y caddy
        fi
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y yum-plugin-copr
        yum copr enable -y @caddyserver/caddy
        if rpm -q caddy &>/dev/null; then
            yum reinstall -y caddy
        else
            yum install -y caddy
        fi
    fi

    systemctl daemon-reload
    systemctl unmask caddy >/dev/null 2>&1 || true
    if command -v caddy &>/dev/null && caddy_service_available; then
        systemctl enable caddy
        log "Caddy 和 systemd 服务安装完成"
    else
        error "Caddy 安装不完整：未找到 caddy 命令或 caddy.service"
        return 1
    fi
}

backup_caddyfile() {
    LAST_BACKUP=""
    [[ -f "$CADDYFILE" ]] || return 0
    LAST_BACKUP="$CADDYFILE.bak.$(date +%F_%H%M%S)"
    cp "$CADDYFILE" "$LAST_BACKUP"

    local backups=()
    mapfile -t backups < <(find "$CADDY_DIR" -maxdepth 1 -type f -name 'Caddyfile.bak.*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
    if ((${#backups[@]} > 5)); then
        rm -f -- "${backups[@]:5}"
    fi
}

remove_site_block() {
    local domain="$1" source="$2" destination="$3"
    awk -v target="$domain" '
        BEGIN { skipping=0; depth=0 }
        !skipping && $0 == target " {" { skipping=1; depth=1; next }
        skipping {
            line=$0
            opens=gsub(/\{/, "{", line)
            closes=gsub(/\}/, "}", line)
            depth += opens - closes
            if (depth <= 0) skipping=0
            next
        }
        { print }
    ' "$source" > "$destination"
}

write_site_block() {
    local domain="$1" destination="$2" backend
    {
        printf '%s {\n' "$domain"
        printf '    encode zstd gzip\n'
        printf '    header Access-Control-Allow-Origin *\n\n'
        printf '    reverse_proxy'
        for backend in "${BACKENDS[@]}"; do
            printf ' %s' "$backend"
        done
        printf ' {\n'
        if ((${#BACKENDS[@]} > 1)); then
            printf '        lb_policy %s\n' "$LB_POLICY"
            printf '        lb_try_duration 5s\n'
            printf '        lb_try_interval 250ms\n'
            printf '        fail_duration 30s\n'
            printf '        max_fails 2\n'
            printf '        unhealthy_status 5xx\n'
        fi
        printf '        header_up X-Real-IP {remote_host}\n'
        printf '    }\n'
        printf '}\n'
    } >> "$destination"
}

validate_candidate() {
    local candidate="$1"
    if ! command -v caddy &>/dev/null; then
        error "未安装 Caddy，无法验证配置。请先选择菜单 1。"
        return 1
    fi
    caddy fmt --overwrite "$candidate" >/dev/null 2>&1 || return 1
    caddy validate --config "$candidate" --adapter caddyfile >/dev/null 2>&1
}

install_candidate() {
    local candidate="$1"
    if ! validate_candidate "$candidate"; then
        error "新配置验证失败，原配置未被修改。"
        return 1
    fi

    if ! caddy_service_available; then
        error "未找到 caddy.service，无法启动。请先选择菜单 1 修复安装。"
        return 1
    fi

    backup_caddyfile
    install -m 0644 "$candidate" "$CADDYFILE"
    rm -f -- "$candidate"

    systemctl daemon-reload
    systemctl reset-failed caddy >/dev/null 2>&1 || true
    log "配置验证通过，正在重启 Caddy..."
    if systemctl restart caddy && systemctl is-active --quiet caddy; then
        echo -e "${GREEN}配置成功，Caddy 正在运行。${PLAIN}"
        return 0
    fi

    error "Caddy 启动失败。以下是本次失败的真实诊断信息："
    show_caddy_failure_details
    error "正在恢复上一份配置。"
    if [[ -n "$LAST_BACKUP" && -f "$LAST_BACKUP" ]]; then
        cp "$LAST_BACKUP" "$CADDYFILE"
        if systemctl restart caddy 2>/dev/null; then
            log "已恢复上一份配置。"
        else
            error "旧配置也无法启动，请根据上面的端口/服务日志处理。"
        fi
    else
        warn "这是第一份配置，没有可恢复的旧配置；失败配置仍保留在 $CADDYFILE。"
    fi
    return 1
}

configure_caddy() {
    echo "------------------------------------------------"
    echo -e "${SKYBLUE}Caddy 反代配置（单域名支持任意数量后端）${PLAIN}"
    echo "------------------------------------------------"

    local mode="new" config_mode domain candidate stripped
    mkdir -p "$CADDY_DIR"

    if [[ -s "$CADDYFILE" ]]; then
        echo " 1. 覆盖全部配置"
        echo " 2. 添加新域名 / 更新已有域名"
        read -r -p "请选择模式 [1-2]（默认 2）: " config_mode < /dev/tty
        if [[ "$config_mode" == "1" ]]; then
            mode="new"
        else
            mode="append"
        fi
    fi

    read -r -p "请输入域名（例如 emby.example.com）: " domain < /dev/tty
    if ! validate_domain "$domain"; then
        error "域名格式无效"
        return 1
    fi
    collect_backends || return 1
    select_load_balance_policy

    candidate="$(mktemp "$CADDY_DIR/Caddyfile.new.XXXXXX")" || return 1
    if [[ "$mode" == "append" && -s "$CADDYFILE" ]]; then
        stripped="$(mktemp "$CADDY_DIR/Caddyfile.strip.XXXXXX")" || return 1
        remove_site_block "$domain" "$CADDYFILE" "$stripped"
        sed '/^[[:space:]]*$/d' "$stripped" > "$candidate"
        rm -f -- "$stripped"
        [[ -s "$candidate" ]] && printf '\n' >> "$candidate"
    fi
    write_site_block "$domain" "$candidate"

    echo ""
    log "域名：$domain"
    log "后端数量：${#BACKENDS[@]}"
    install_candidate "$candidate" || rm -f -- "$candidate"
}

list_domains() {
    [[ -f "$CADDYFILE" ]] || return 0
    awk '/^[a-zA-Z0-9.-]+[[:space:]]*\{$/ { print $1 }' "$CADDYFILE"
}

delete_config() {
    if [[ ! -s "$CADDYFILE" ]]; then
        error "未找到有效配置文件"
        return 1
    fi

    local domains=() input domain index candidate
    mapfile -t domains < <(list_domains)
    if ((${#domains[@]} == 0)); then
        warn "未找到域名配置"
        return 1
    fi

    echo "当前域名："
    for index in "${!domains[@]}"; do
        printf ' %d. %s\n' "$((index + 1))" "${domains[$index]}"
    done
    read -r -p "请输入编号或完整域名: " input < /dev/tty

    if [[ "$input" =~ ^[0-9]+$ ]]; then
        index=$((10#$input - 1))
        ((index >= 0 && index < ${#domains[@]})) || { error "编号无效"; return 1; }
        domain="${domains[$index]}"
    else
        domain="$input"
    fi

    read -r -p "确定删除 $domain？[y/N]: " input < /dev/tty
    [[ "$input" =~ ^[Yy]$ ]] || { log "已取消"; return 0; }

    candidate="$(mktemp "$CADDY_DIR/Caddyfile.new.XXXXXX")" || return 1
    remove_site_block "$domain" "$CADDYFILE" "$candidate"
    sed -i '/^[[:space:]]*$/d' "$candidate"

    if [[ ! -s "$candidate" ]]; then
        backup_caddyfile
        : > "$CADDYFILE"
        rm -f -- "$candidate"
        systemctl stop caddy
        log "最后一个域名已删除，Caddy 已停止。"
    else
        install_candidate "$candidate"
    fi
}

restart_caddy() {
    if [[ ! -s "$CADDYFILE" ]]; then
        error "Caddyfile 不存在或为空"
        return 1
    fi
    if ! caddy validate --config "$CADDYFILE" --adapter caddyfile; then
        error "配置验证失败，未重启 Caddy。"
        return 1
    fi
    if ! caddy_service_available; then
        error "未找到 caddy.service，请先选择菜单 1 修复安装。"
        return 1
    fi
    systemctl daemon-reload
    systemctl reset-failed caddy >/dev/null 2>&1 || true
    systemctl restart caddy
    if systemctl is-active --quiet caddy; then
        log "Caddy 正在运行"
    else
        error "Caddy 启动失败"
        show_caddy_failure_details
        return 1
    fi
}

uninstall_caddy() {
    read -r -p "将卸载 Caddy 并删除 /etc/caddy，确定继续？[y/N]: " confirm < /dev/tty
    [[ "$confirm" =~ ^[Yy]$ ]] || { log "已取消"; return 0; }
    systemctl stop caddy 2>/dev/null || true
    if [[ -f /etc/debian_version ]]; then
        apt-get remove -y caddy
    elif [[ -f /etc/redhat-release ]]; then
        yum remove -y caddy
    fi
    rm -rf -- "$CADDY_DIR"
    log "Caddy 已卸载，配置目录已删除。"
}

show_menu() {
    clear
    echo "############################################################"
    echo "#  Caddy + Emby 管理脚本 V${VERSION}（多后端负载均衡版）   #"
    echo "############################################################"
    echo " 1. 安装环境和 Caddy"
    echo " 2. 添加/更新反代（一个域名可绑定多个后端）"
    echo " 3. 删除指定域名"
    echo " 4. 查看 Caddy 配置"
    echo "------------------------------------------------------------"
    echo " 5. 停止 Caddy"
    echo " 6. 验证配置并重启 Caddy"
    echo " 7. 查询 80/443 端口占用"
    echo -e " ${RED}8. 停止占用端口的常见 Web 服务${PLAIN}"
    echo -e " ${RED}9. 卸载 Caddy${PLAIN}"
    echo "------------------------------------------------------------"
    echo " 0. 退出"
    echo ""

    local num
    read -r -p "请输入数字 [0-9]: " num < /dev/tty
    case "$num" in
        1) install_caddy ;;
        2) install_caddy && configure_caddy ;;
        3) delete_config ;;
        4) [[ -f "$CADDYFILE" ]] && cat "$CADDYFILE" || warn "配置文件不存在" ;;
        5) systemctl stop caddy && log "Caddy 已停止" ;;
        6) restart_caddy ;;
        7) check_port ;;
        8) kill_port ;;
        9) uninstall_caddy ;;
        0) exit 0 ;;
        *) error "请输入 0-9" ;;
    esac
}

main() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行！\n" && exit 1
    register_shortcut || warn "快捷命令注册失败，但仍可继续使用当前脚本。"
    while true; do
        show_menu
        echo -e "\n${GREEN}按回车返回主菜单...${PLAIN}"
        read -r _ < /dev/tty
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

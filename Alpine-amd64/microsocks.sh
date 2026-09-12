#!/bin/sh
# ============================================================
# microsocks 部署/卸载脚本 v3.0 (Alpine Linux / OpenRC)
#
# 用法:
#   sh microsocks.sh              默认安装
#   sh microsocks.sh install      安装
#   sh microsocks.sh uninstall    完全卸载 (适用于任何安装状态)
#   sh microsocks.sh --help       显示帮助
# ============================================================
set -e

# ---------- 常量 ----------
REPO="ccbkkb/microsocks-release"
BIN_PATH="/usr/local/bin/microsocks"
CONF_FILE="/etc/microsocks.conf"
SERVICE_FILE="/etc/init.d/microsocks"
LOG_FILE="/var/log/microsocks.log"
ERR_FILE="/var/log/microsocks.err"
PID_FILE="/run/microsocks.pid"
PORT=1080
VERSION="3.0"

# ---------- 颜色 (busybox 兼容) ----------
if [ -t 1 ]; then
    RED=$(printf '\033[0;31m')
    GREEN=$(printf '\033[0;32m')
    YELLOW=$(printf '\033[1;33m')
    BLUE=$(printf '\033[0;34m')
    BOLD=$(printf '\033[1m')
    NC=$(printf '\033[0m')
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

info()  { printf "%s[INFO]%s %s\n" "$GREEN" "$NC" "$*"; }
warn()  { printf "%s[WARN]%s %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%s[ERROR]%s %s\n" "$RED" "$NC" "$*" >&2; exit 1; }
step()  { printf "\n%s>>> %s%s\n" "$BLUE$BOLD" "$*" "$NC"; }

# ---------- 工具函数 ----------
check_root() {
    [ "$(id -u)" -eq 0 ] || error "请使用 root 用户运行此脚本"
}

ensure_curl() {
    if ! command -v curl >/dev/null 2>&1; then
        info "安装 curl..."
        apk add --no-cache curl >/dev/null 2>&1 || error "安装 curl 失败"
    fi
}

# 生成随机字符串: 仅 A-Z a-z 0-9 . - _
rand_str() {
    LEN="${1:-12}"
    LC_ALL=C tr -dc 'A-Za-z0-9._-' < /dev/urandom | head -c "$LEN"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7)  echo "armv7" ;;
        armv6l|armv6)  echo "armv6" ;;
        *) error "不支持的架构: $(uname -m)" ;;
    esac
}

# ============================================================
# 卸载
# ============================================================
do_uninstall() {
    QUIET="${1:-}"
    check_root

    [ "$QUIET" = "quiet" ] || step "卸载 microsocks"

    # 1. 停止服务
    if [ -f "$SERVICE_FILE" ]; then
        if rc-service microsocks status >/dev/null 2>&1; then
            info "停止 microsocks 服务..."
            rc-service microsocks stop 2>/dev/null || true
        fi
        info "从启动项移除..."
        rc-update del microsocks default 2>/dev/null || true
        rc-update del microsocks 2>/dev/null || true
    fi

    # 2. 兜底杀进程
    if pgrep -f "$BIN_PATH" >/dev/null 2>&1; then
        info "强制终止残留进程..."
        pkill -f "$BIN_PATH" 2>/dev/null || true
        sleep 1
        pkill -9 -f "$BIN_PATH" 2>/dev/null || true
    fi

    # 3. 删除所有相关文件
    remove_file() {
        if [ -e "$1" ]; then
            rm -rf "$1" && info "已删除: $1"
        fi
    }
    remove_file "$SERVICE_FILE"
    remove_file "$CONF_FILE"
    remove_file "$BIN_PATH"
    remove_file "$PID_FILE"
    remove_file "/var/run/microsocks.pid"
    remove_file "$LOG_FILE"
    remove_file "$ERR_FILE"
    rm -f /tmp/microsocks.* 2>/dev/null || true

    # 4. 刷新 OpenRC 依赖缓存
    rc-update -u 2>/dev/null || true

    # 5. 验证清理结果
    LEFT=$(find /etc/init.d /etc /usr/local/bin /var/log /run /var/run \
        -maxdepth 1 -name 'microsocks*' 2>/dev/null || true)
    if [ -n "$LEFT" ]; then
        warn "以下文件仍存在，请手动检查:"
        printf "  %s\n" "$LEFT"
    else
        info "所有 microsocks 相关文件已清理干净"
    fi

    # 6. 端口检查
    PORT_CHECK=""
    if command -v netstat >/dev/null 2>&1; then
        PORT_CHECK=$(netstat -tlnp 2>/dev/null | grep ":${PORT} " || true)
    elif command -v ss >/dev/null 2>&1; then
        PORT_CHECK=$(ss -tlnp 2>/dev/null | grep ":${PORT} " || true)
    fi
    if [ -n "$PORT_CHECK" ]; then
        warn "端口 ${PORT} 仍被占用:"
        printf "  %s\n" "$PORT_CHECK"
    else
        info "端口 ${PORT} 已释放"
    fi

    if [ "$QUIET" != "quiet" ]; then
        printf "\n%s============================================================\n" "$GREEN"
        printf "  microsocks 卸载完成\n"
        printf "============================================================%s\n" "$NC"
    fi
}

# ============================================================
# 安装
# ============================================================
do_install() {
    check_root
    ensure_curl

    step "部署 microsocks v${VERSION}"

    # 0. 检测旧版本 → 先卸载
    if [ -f "$BIN_PATH" ] || [ -f "$SERVICE_FILE" ] || [ -f "$CONF_FILE" ]; then
        warn "检测到已有安装，先清理旧版本"
        do_uninstall quiet
        printf "\n"
    fi

    # 1. 架构检测
    ARCH=$(detect_arch)
    info "检测到架构: $ARCH"

    # 2. 获取最新 Release
    info "获取最新 Release 信息..."
    API_URL="https://api.github.com/repos/${REPO}/releases/latest"
    RELEASE_JSON=$(curl -fsSL "$API_URL" 2>/dev/null) || error "无法访问 GitHub API，请检查网络"

    TAG=$(echo "$RELEASE_JSON" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"tag_name": *"//;s/"//')
    [ -n "$TAG" ] || error "无法解析最新 tag"
    info "最新版本: $TAG"

    # 3. 拼接下载 URL
    BIN_NAME="microsocks-alpine-${ARCH}"
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${BIN_NAME}"
    ASSET_URL=$(echo "$RELEASE_JSON" | grep -o "\"browser_download_url\": *\"[^\"]*${BIN_NAME}\"" | head -1 | sed 's/.*"browser_download_url": *"//;s/"//')
    [ -n "$ASSET_URL" ] && DOWNLOAD_URL="$ASSET_URL"
    info "下载地址: $DOWNLOAD_URL"

    # 4. 下载二进制
    info "正在下载 microsocks (${ARCH})..."
    TMP_BIN="/tmp/microsocks.$$"
    curl -fsSL -o "$TMP_BIN" "$DOWNLOAD_URL" || error "下载失败"

    # 5. 二进制验证 (三重检查)
    ELF_MAGIC=$(head -c 4 "$TMP_BIN" | od -An -tx1 | tr -d ' \n')
    if [ "$ELF_MAGIC" != "7f454c46" ]; then
        rm -f "$TMP_BIN"
        error "文件不是有效的 ELF 格式 (magic: ${ELF_MAGIC})"
    fi
    FILESIZE=$(stat -c '%s' "$TMP_BIN" 2>/dev/null || echo 0)
    if [ "$FILESIZE" -lt 10240 ]; then
        rm -f "$TMP_BIN"
        error "下载的文件过小 (${FILESIZE} bytes)，可能不完整"
    fi
    info "ELF 格式验证通过，文件大小 ${FILESIZE} bytes"

    chmod +x "$TMP_BIN"
    mv "$TMP_BIN" "$BIN_PATH"
    chmod 755 "$BIN_PATH"
    info "已安装到: $BIN_PATH"

    # 6. 生成随机凭据
    USERNAME="ms_$(rand_str 8)"
    PASSWORD="$(rand_str 16)"
    info "生成随机凭据完成"

    # 7. 写配置文件
    cat > "$CONF_FILE" <<EOF
# microsocks configuration
# 修改后需执行: rc-service microsocks restart
MICROSOCKS_USER="${USERNAME}"
MICROSOCKS_PASS="${PASSWORD}"
MICROSOCKS_PORT="${PORT}"
EOF
    chmod 600 "$CONF_FILE"
    info "配置文件已写入: $CONF_FILE"

    # 8. 创建 OpenRC 服务
    #    关键修复: 使用 <<'EOF' 保留变量不展开，运行时 source 配置文件
    cat > "$SERVICE_FILE" <<'SERVICEEOF'
#!/sbin/openrc-run

name="microsocks"
description="MicroSOCKS5 proxy server"
pidfile="/run/microsocks.pid"
command_background="yes"
output_log="/var/log/microsocks.log"
error_log="/var/log/microsocks.err"

# 从配置文件读取凭据
if [ -f /etc/microsocks.conf ]; then
    . /etc/microsocks.conf
fi

# 校验必需变量
if [ -z "${MICROSOCKS_USER}" ] || [ -z "${MICROSOCKS_PASS}" ] || [ -z "${MICROSOCKS_PORT}" ]; then
    eerror "配置文件 /etc/microsocks.conf 缺少必要变量"
    exit 1
fi

command="/usr/local/bin/microsocks"
command_args="-i 0.0.0.0 -p ${MICROSOCKS_PORT} -u ${MICROSOCKS_USER} -P ${MICROSOCKS_PASS}"

depend() {
    need net
    after firewall
}
SERVICEEOF
    chmod 755 "$SERVICE_FILE"
    info "OpenRC 服务脚本已创建"

    # 9. 启用并启动
    rc-update add microsocks default 2>/dev/null || true
    rc-service microsocks restart 2>/dev/null || rc-service microsocks start
    sleep 2

    if rc-service microsocks status >/dev/null 2>&1; then
        info "microsocks 服务已启动"
    else
        warn "服务可能未正常启动，请检查: $ERR_FILE"
    fi

    # 10. 本地代理连通性测试
    step "本地代理连通性测试"

    info "① 认证代理测试 (通过 127.0.0.1:${PORT})..."
    TEST_OUT=$(curl --socks5 "${USERNAME}:${PASSWORD}@127.0.0.1:${PORT}" \
        -s --connect-timeout 10 --max-time 15 \
        https://api.ipify.org 2>&1) && {
        info "   通过 (出口 IP: ${TEST_OUT})"
    } || {
        warn "   失败: ${TEST_OUT}"
        warn "   请检查日志: $ERR_FILE"
    }

    info "② 无认证访问测试 (预期被拒绝)..."
    TEST_NOAUTH=$(curl --socks5 "127.0.0.1:${PORT}" \
        -s --connect-timeout 5 --max-time 10 \
        https://api.ipify.org 2>&1) && {
        warn "   无认证访问成功——认证可能未生效！"
    } || {
        info "   已拒绝 (认证机制正常)"
    }

    # 11. 获取公网 IP
    PUBLIC_IP=$(curl -fsSL --connect-timeout 5 https://api.ipify.org 2>/dev/null || \
                curl -fsSL --connect-timeout 5 https://ifconfig.me 2>/dev/null || \
                echo "你的服务器IP")

    # 12. 输出结果
    printf "\n"
    printf "%s============================================================\n" "$GREEN"
    printf "  MicroSOCKS 部署完成 (v%s)\n" "$VERSION"
    printf "============================================================%s\n" "$NC"
    printf "\n"
    printf "  版本:       %s\n" "$TAG"
    printf "  架构:       %s\n" "$ARCH"
    printf "  监听端口:   %s\n" "$PORT"
    printf "\n"
    printf "%s--- SOCKS5 连接信息 ---%s\n" "$YELLOW" "$NC"
    printf "  地址:       %s:%s\n" "$PUBLIC_IP" "$PORT"
    printf "  用户名:     %s\n" "$USERNAME"
    printf "  密码:       %s\n" "$PASSWORD"
    printf "\n"
    printf "%s--- 连接示例 ---%s\n" "$YELLOW" "$NC"
    printf "  curl --socks5 %s:%s@%s:%s https://api.ipify.org\n" \
        "$USERNAME" "$PASSWORD" "$PUBLIC_IP" "$PORT"
    printf "\n"
    printf "%s--- 文件位置 ---%s\n" "$YELLOW" "$NC"
    printf "  二进制:     %s\n" "$BIN_PATH"
    printf "  配置文件:   %s\n" "$CONF_FILE"
    printf "  服务脚本:   %s\n" "$SERVICE_FILE"
    printf "  日志:       %s\n" "$LOG_FILE"
    printf "  错误日志:   %s\n" "$ERR_FILE"
    printf "\n"
    printf "%s--- 管理命令 ---%s\n" "$YELLOW" "$NC"
    printf "  rc-service microsocks start     # 启动\n"
    printf "  rc-service microsocks stop      # 停止\n"
    printf "  rc-service microsocks restart   # 重启\n"
    printf "  rc-service microsocks status    # 状态\n"
    printf "  tail -f %s # 查看日志\n" "$LOG_FILE"
    printf "\n"
    printf "%s--- 快速卸载 ---%s\n" "$YELLOW" "$NC"
    printf "  sh %s uninstall\n" "$0"
    printf "\n"
    printf "%s--- 注意事项 ---%s\n" "$YELLOW" "$NC"
    printf "  1. 请确保防火墙开放 %s/tcp 端口\n" "$PORT"
    printf "  2. 凭据保存在 %s，请妥善保管\n" "$CONF_FILE"
    printf "  3. 更改凭据后执行: rc-service microsocks restart\n"
    printf "\n"
    printf "%s============================================================%s\n" "$GREEN" "$NC"
}

# ============================================================
# 帮助
# ============================================================
show_help() {
    cat <<EOF
microsocks 部署脚本 v${VERSION} (Alpine Linux / OpenRC)

用法:
  sh $0              默认执行安装
  sh $0 install      安装 microsocks
  sh $0 uninstall    完全卸载 microsocks
  sh $0 --help       显示此帮助

说明:
  从 GitHub Release (${REPO}) 下载最新的 Alpine 预编译二进制。
  自动生成随机用户名/密码 (字符集 A-Za-z0-9._-)，
  配置为 OpenRC 服务并自动启动，含本地连通性测试。

卸载:
  uninstall 命令会停止服务、移除启动项、删除所有相关文件、
  清理残留进程与 PID 文件，适用于任何安装状态（成功或失败）。
EOF
}

# ============================================================
# 主入口
# ============================================================
main() {
    case "${1:-}" in
        install)          do_install ;;
        uninstall|remove) do_uninstall ;;
        --help|-h|help)   show_help ;;
        "")               do_install ;;
        *)                error "未知参数: $1 (使用 --help 查看用法)" ;;
    esac
}

main "$@"

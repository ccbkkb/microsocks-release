#!/usr/bin/env bash
# microsocks 一键安装脚本
# * 自动识别系统与架构, 从 release 中挑选合适的预编译二进制
# * 生成随机账号/密码
# * 自动配置开机自启 (systemd / OpenRC / SysVinit / launchd)
# 上游源码: https://github.com/rofl0r/microsocks
# 预编译发布: https://github.com/ccbkkb/microsocks-release/releases/tag/v1.0.5
set -e

# ================== 配置区 ==================
VERSION="v1.0.5"
REPO="ccbkkb/microsocks-release"
BIN_PATH="/usr/local/bin/microsocks"
CONF_DIR="/etc/microsocks"
CONF_FILE="${CONF_DIR}/microsocks.conf"
PORT="${PORT:-1080}"        # 可通过环境变量 PORT 覆盖
# ============================================

# 颜色输出
say()  { printf '%s\n' "$*"; }
color(){ [ -t 1 ] && printf '\033[%sm%s\033[0m\n' "$2" "$1" || printf '%s\n' "$1"; }
green(){ color "✓ $1" 32; }
blue() { color "» $1" 34; }
yellow(){ color "! $1" 33; }
red()  { color "✗ $1" 31; }
err()  { red "$1" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 执行(如: sudo bash $0)"
    exit 1
fi

# ============ 检测系统 ============
detect_os() {
    case "$(uname -s)" in
        Linux)  [ -f /etc/alpine-release ] && echo alpine || echo linux ;;
        Darwin) echo darwin ;;
        NetBSD) echo netbsd ;;
        *)      echo linux ;;
    esac
}

# ============ 检测架构, 输出 release 内的标准名 ============
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)         echo amd64 ;;
        aarch64|arm64)        echo arm64 ;;
        armv7l|armv7)         echo armv7 ;;
        armv6l|armv6)         echo armv6 ;;
        mips64)               echo mips64 ;;
        mips64el)             echo mips64el ;;
        mipsel)               echo mipsel ;;
        mips)                 echo mips ;;
        ppc64le|powerpc64le)  echo ppc64le ;;
        powerpc|ppc)          echo powerpc ;;
        powerpc64|ppc64)      echo powerpc64 ;;
        riscv64)              echo riscv64 ;;
        s390x)                echo s390x ;;
        m68k)                 echo m68k ;;
        hppa)                 echo hppa ;;
        sh4)                  echo sh4 ;;
        sparc64)              echo sparc64 ;;
        alpha)                echo alpha ;;
        *)                    uname -m ;;
    esac
}

# ============ 已发布的 assets 清单（来自 v1.0.5 release） ============
RELEASE_ASSETS=(
    alpine-amd64 alpine-armv6 alpine-armv7
    darwin-amd64 darwin-arm64
    linux-alpha linux-amd64 linux-arm64 linux-armv6 linux-armv7
    linux-hppa linux-m68k linux-mips linux-mips64 linux-mips64el linux-mipsel
    linux-powerpc linux-powerpc64 linux-ppc64le linux-riscv64
    linux-s390x linux-sh4 linux-sparc64
    netbsd-amd64 netbsd-arm64
)
asset_exists() {
    local n
    for n in "${RELEASE_ASSETS[@]}"; do
        [ "$n" = "$1" ] && return 0
    done
    return 1
}

# ============ init 系统检测 ============
is_openrc()  { command -v rc-update >/dev/null 2>&1 || [ -x /sbin/openrc-run ]; }
is_systemd() { [ -d /run/systemd/system ] || ps -p 1 -o comm= 2>/dev/null | grep -q '^systemd$'; }

# ============ 生成随机账号密码 ============
rand_string() {
    local chars="$1" n="$2"
    if [ -c /dev/urandom ]; then
        head -c 32 /dev/urandom | tr -dc "$chars" | head -c "$n"
    else
        printf '%s' "$(date +%s%N)$RANDOM" | tr -dc "$chars" | head -c "$n"
    fi
}
gen_user() { rand_string 'abcdefghijklmnopqrstuvwxyz0123456789' 8; }
gen_pass() { rand_string 'A-Za-z0-9' 16; }

# ============ 写 systemd unit ============
write_systemd_unit() {
    local user="$1" pass="$2" port="$3"
    cat > /etc/systemd/system/microsocks.service <<EOF
[Unit]
Description=microsocks - tiny SOCKS5 server
Documentation=https://github.com/rofl0r/microsocks
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -p ${port} -u ${user} -P ${pass}
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    ok "已写入 systemd unit"
    systemctl daemon-reload
    systemctl enable --now microsocks
}

# ============ 写 OpenRC 服务 (Alpine 等) ============
write_openrc_service() {
    local user="$1" pass="$2" port="$3"
    mkdir -p "${CONF_DIR}"
    cat > "${CONF_FILE}" <<EOF
# microsocks 配置文件, 由 OpenRC 服务在启动时 source
MICROSOCKS_PORT=${port}
MICROSOCKS_USER=${user}
MICROSOCKS_PASS=${pass}
EOF
    chmod 600 "${CONF_FILE}"

    cat > /etc/init.d/microsocks <<'EOF'
#!/sbin/openrc-run
# microsocks OpenRC 服务
name="microsocks"
description="microsocks tiny SOCKS5 server"
command="/usr/local/bin/microsocks"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/microsocks.log"
error_log="/var/log/microsocks.log"

depend() {
    need net
    after firewall
}

start_pre() {
    [ -f /etc/microsocks/microsocks.conf ] && . /etc/microsocks/microsocks.conf
    command_args="-p ${MICROSOCKS_PORT} -u ${MICROSOCKS_USER} -P ${MICROSOCKS_PASS}"
}
EOF
    chmod +x /etc/init.d/microsocks
    ok "已写入 OpenRC 服务"
    rc-update add microsocks default
    rc-service microsocks restart
}

# ============ 写 SysVinit 服务 (非 systemd/openrc 的老系统) ============
write_sysvinit_service() {
    local user="$1" pass="$2" port="$3"
    mkdir -p "${CONF_DIR}"
    cat > "${CONF_FILE}" <<EOF
MICROSOCKS_PORT=${port}
MICROSOCKS_USER=${user}
MICROSOCKS_PASS=${pass}
EOF
    chmod 600 "${CONF_FILE}"

    cat > /etc/init.d/microsocks <<'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          microsocks
# Required-Start:    $network $local_fs
# Required-Stop:     $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
### END INIT INFO

DAEMON="/usr/local/bin/microsocks"
NAME="microsocks"
PIDFILE="/var/run/${NAME}.pid"
CONF="/etc/microsocks/microsocks.conf"

[ -f "${CONF}" ] && . "${CONF}"
ARGS="-p ${MICROSOCKS_PORT} -u ${MICROSOCKS_USER} -P ${MICROSOCKS_PASS}"

case "$1" in
    start)   echo "Starting ${NAME}";
             start-stop-daemon -S -b -m -p "${PIDFILE}" -x "${DAEMON}" -- ${ARGS} ;;
    stop)    start-stop-daemon -K -p "${PIDFILE}" ;;
    restart) "$0" stop; sleep 1; "$0" start ;;
    status)  [ -f "${PIDFILE}" ] && echo "${NAME} running ($(cat ${PIDFILE}))" || echo "${NAME} not running" ;;
    *)       echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
exit 0
EOF
    chmod +x /etc/init.d/microsocks
    ok "已写入 SysVinit 服务"
    if command -v update-rc.d >/dev/null 2>&1; then
        update-rc.d microsocks defaults
    elif command -v chkconfig >/dev/null 2>&1; then
        chkconfig --add microsocks
        chkconfig --level 345 microsocks on
    fi
    service microsocks restart
}

# ============ 写 launchd plist (macOS) ============
write_launchd_plist() {
    local user="$1" pass="$2" port="$3"
    local plist="/Library/LaunchDaemons/io.microsocks.plist"
    mkdir -p "$(dirname ${plist})"
    cat > "${plist}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>io.microsocks</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN_PATH}</string>
        <string>-p</string><string>${port}</string>
        <string>-u</string><string>${user}</string>
        <string>-P</string><string>${pass}</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>LimitNumberOfFiles</key><integer>65535</integer>
</dict>
</plist>
EOF
    ok "已写入 launchd plist"
    launchctl unload "${plist}" 2>/dev/null || true
    launchctl load -w "${plist}"
}

# ============ main ============
main() {
    green "============================================"
    blue  " microsocks 一键安装脚本 (${VERSION})"
    blue  " Repo: ${REPO}"
    green "============================================"

    local os arch asset_name
    os="$(detect_os)"
    arch="$(detect_arch)"
    blue "系统: ${os}"
    blue "架构: ${arch} ($(uname -m))"

    # Asset 匹配: Alpine 优先用 alpine-* 静态二进制
    if [ "${os}" = "alpine" ]; then
        if asset_exists "alpine-${arch}"; then
            asset_name="microsocks-alpine-${arch}"
        elif asset_exists "linux-${arch}"; then
            yellow "未发现 alpine-${arch} 静态版, 改用 linux-${arch}"
            asset_name="microsocks-linux-${arch}"
        fi
    else
        if asset_exists "${os}-${arch}"; then
            asset_name="microsocks-${os}-${arch}"
        fi
    fi
    if [ -z "${asset_name}" ]; then
        err "未发布 ${os}/${arch} 版本"
        err "可在 https://github.com/${REPO}/releases/tag/${VERSION} 查看, "
        err "或自行从源码编译: https://github.com/rofl0r/microsocks"
        exit 1
    fi
    ok "选择资产: ${asset_name}"

    # 备份原 binary
    if [ -f "${BIN_PATH}" ]; then
        cp -a "${BIN_PATH}" "${BIN_PATH}.bak.$(date +%s)"
        yellow "已备份旧二进制"
    fi

    # 下载
    mkdir -p "$(dirname "${BIN_PATH}")"
    local url="https://github.com/${REPO}/releases/download/${VERSION}/${asset_name}"
    blue "下载: ${url}"
    if     command -v curl  >/dev/null 2>&1 && curl     -fsSL "${url}" -o "${BIN_PATH}" \
        || command -v wget  >/dev/null 2>&1 && wget    -qO "${BIN_PATH}" "${url}"; then
        :
    else
        err "需 curl 或 wget 完成下载"
        exit 1
    fi
    chmod +x "${BIN_PATH}"
    ok "已安装到 ${BIN_PATH} ($(ls -l ${BIN_PATH} | awk '{print $5}')) bytes"

    # 生成随机账号/密码
    local user pass
    user="$(gen_user)"
    pass="$(gen_pass)"
    blue "随机账号:"
    yellow "  用户: ${user}"
    yellow "  密码: ${pass}"
    blue  "  端口: ${PORT}"

    # 配置开机自启
    case "${os}" in
        darwin)  write_launchd_plist     "${user}" "${pass}" "${PORT}" ;;
        alpine)  write_openrc_service    "${user}" "${pass}" "${PORT}" ;;
        linux)
            if   is_systemd; then write_systemd_unit   "${user}" "${pass}" "${PORT}"
            elif is_openrc;   then write_openrc_service "${user}" "${pass}" "${PORT}"
            elif [ -d /etc/init.d ]; then write_sysvinit_service "${user}" "${pass}" "${PORT}"
            else
                err "未识别到 systemd / OpenRC / SysVinit, 跳过开机自启"
                err "可手动: ${BIN_PATH} -p ${PORT} -u ${user} -P ${pass}"
            fi
            ;;
        netbsd)
            yellow "NetBSD 不自动写 rc 脚本; 可手动启动: ${BIN_PATH} -p ${PORT} -u ${user} -P ${pass}"
            ;;
    esac

    # 输出汇总
    say ""
    green "============================================"
    green " microsocks 安装完成！"
    green "============================================"
    yellow " 用户:  ${user}"
    yellow " 密码:  ${pass}"
    yellow " 端口:  ${PORT}"
    blue  " 二进制: ${BIN_PATH}"
    if   [ -f /etc/systemd/system/microsocks.service ]; then
        blue " systemd 管理: systemctl {status|start|stop|restart} microsocks"
    elif [ -f /etc/init.d/microsocks ]; then
        blue " init 脚本:    service microsocks {start|stop|restart|status}"
        blue "             （Alpine: rc-service microsocks ...）"
    elif [ -f /Library/LaunchDaemons/io.microsocks.plist ]; then
        blue " launchctl:   launchctl load|unload /Library/LaunchDaemons/io.microsocks.plist"
    fi
    blue  " 测试代理:    curl --socks5 ${user}:${pass}@127.0.0.1:${PORT} https://www.google.com -I"
    blue  " 上游源码:    https://github.com/rofl0r/microsocks"
    blue  " 二进制发布:  https://github.com/${REPO}/releases/tag/${VERSION}"
}

main "$@"

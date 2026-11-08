#!/bin/sh
set -eu
umask 077

: "${NAS_DEST:?}" "${NAS_VAR:?}"
binary="$NAS_DEST/bin/mijia-rust"
config="$NAS_VAR/network.conf"
pid_file="$NAS_VAR/bridge.pid"
code_file="$NAS_VAR/setup-code"
log="$NAS_VAR/bridge.log"

running() {
    [ -f "$pid_file" ] || return 1
    IFS= read -r pid < "$pid_file" || return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] && [ "$(readlink "/proc/$pid/exe" 2>/dev/null)" = "$(readlink -f "$binary")" ]
}

configure() {
    if running; then
        echo "请先停止 MijiaLAN，再修改网络设置。"
        return 1
    fi
    ip=${wizard_lan_ip:-}
    port=${wizard_hap_port:-51826}
    code=${wizard_setup_code:-}
    if ! printf '%s\n' "$ip" | awk -F. '
        NF == 4 {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^(0|[1-9][0-9]?[0-9]?)$/ || $i > 255) exit 1
            }
            valid = $1 > 0 && $1 != 127 && $1 < 224
        }
        END { if (!valid) exit 1 }
    '; then
        echo "请输入 NAS 在米家设备所在局域网中的 IPv4 地址。"
        return 1
    fi
    case "$port" in
        ''|*[!0-9]*) echo "HomeKit 端口应为数字。"; return 1 ;;
    esac
    if [ "${#port}" -gt 5 ] || [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ] || [ "$port" -eq 17890 ]; then
        echo "HomeKit 端口须为 1024–65535，且不能使用设置端口 17890。"
        return 1
    fi
    case "$code" in
        ''|*[!a-zA-Z0-9_-]*) echo "设置码须为 12–64 位字母、数字、连字符或下划线。"; return 1 ;;
    esac
    if [ "${#code}" -lt 12 ] || [ "${#code}" -gt 64 ]; then
        echo "设置码须为 12–64 位字母、数字、连字符或下划线。"
        return 1
    fi
    mkdir -p "$NAS_VAR"
    printf '%s %s\n' "$ip" "$port" > "$config.new"
    printf '%s\n' "$code" > "$code_file.new"
    mv "$config.new" "$config"
    mv "$code_file.new" "$code_file"
}

case "${1:-}" in
    install)
        [ -f "$config" ] || configure
        ;;
    configure)
        configure
        ;;
    start)
        if running; then exit 0; fi
        if [ "$(id -u)" -eq 0 ]; then
            echo "MijiaLAN 必须以专用套件用户运行。"
            exit 1
        fi
        if ! IFS=' ' read -r ip port < "$config"; then
            echo "缺少 MijiaLAN 网络配置，请先完成套件设置。"
            exit 1
        fi
        mkdir -p "$NAS_VAR/data" "$NAS_VAR/keys"
        [ ! -f "$log" ] || mv "$log" "$log.previous"
        nohup "$binary" serve --lan-ip "$ip" --hap-port "$port" \
            --data-dir "$NAS_VAR/data" --key-file "$NAS_VAR/keys/master.key" \
            --setup-code-file "$code_file" </dev/null >"$log" 2>&1 &
        child=$!
        if ! printf '%s\n' "$child" > "$pid_file"; then
            kill -TERM "$child" 2>/dev/null || true
            exit 1
        fi
        sleep 1
        if ! running; then
            rm -f "$pid_file"
            echo "MijiaLAN 未能启动，请检查套件日志、局域网地址和端口。"
            exit 1
        fi
        ;;
    stop)
        if running; then
            kill -TERM "$pid" 2>/dev/null || true
            attempts=0
            while running; do
                attempts=$((attempts + 1))
                [ "$attempts" -lt 15 ] || exit 1
                sleep 1
            done
        fi
        rm -f "$pid_file"
        ;;
    status)
        if running; then exit 0; fi
        exit 3
        ;;
    *) exit 1 ;;
esac

#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error when substituting.
# Prevent errors in a pipeline from being masked.
set -euo pipefail

# --- Helper Functions ---
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_warning() {
    echo "[WARNING] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

# --- Function to Start Services ---
start_services() {
    # 获取当前脚本所在目录的绝对路径
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # --- Start Caddy Service ---
    CADDY_CONFIG_PATH="$SCRIPT_DIR/app/caddy/caddy.json"
    CADDY_LOG_FILE="/var/log/caddy.log"
    log_info "正在启动 Caddy 服务... 日志将输出到 $CADDY_LOG_FILE"
    # Create log file and set permissions if it doesn't exist, or ensure it's writable
    # Use root ownership and 640 permissions for better security (readable only by root and group)
    touch "$CADDY_LOG_FILE"
    chown root:adm "$CADDY_LOG_FILE" 2>/dev/null || true  # Set owner to root:adm if possible
    chmod 640 "$CADDY_LOG_FILE"  # More secure permissions - only root can read, group can read, others have no access

    nohup "$SCRIPT_DIR/app/caddy/caddy" run --config "$CADDY_CONFIG_PATH" >> "$CADDY_LOG_FILE" 2>&1 &
    CADDY_PID=$!
    sleep 3 # Give it a moment to start or fail

    if ps -p $CADDY_PID > /dev/null; then
       log_info "Caddy 服务已启动 (PID: $CADDY_PID)。日志文件: $CADDY_LOG_FILE"
    else
       log_error "Caddy 服务启动失败。请检查日志: $CADDY_LOG_FILE"
       log_error "尝试查看 Caddy 日志尾部:"
       tail -n 20 "$CADDY_LOG_FILE" || true
    fi

    # --- Start Xray-core Service ---
    XRAY_CONFIG_PATH="$SCRIPT_DIR/app/xray/config.json"
    XRAY_EXE="$SCRIPT_DIR/app/xray/xray"
    XRAY_LOG_FILE="/var/log/xray.log"
    log_info "正在启动 Xray-core 服务... 日志将输出到 $XRAY_LOG_FILE"
    touch "$XRAY_LOG_FILE"
    chown root:adm "$XRAY_LOG_FILE" 2>/dev/null || true  # Set owner to root:adm if possible
    chmod 640 "$XRAY_LOG_FILE"  # More secure permissions

    nohup "$XRAY_EXE" run -c "$XRAY_CONFIG_PATH" >> "$XRAY_LOG_FILE" 2>&1 &
    XRAY_PID=$!
    sleep 3 # Give it a moment to start or fail

    if ps -p $XRAY_PID > /dev/null; then
       log_info "Xray-core 服务已启动 (PID: $XRAY_PID)。日志文件: $XRAY_LOG_FILE"
    else
       log_error "Xray-core 服务启动失败。请检查日志: $XRAY_LOG_FILE"
       log_error "尝试查看 Xray 日志尾部:"
       tail -n 20 "$XRAY_LOG_FILE" || true
    fi

    # --- Show service status summary ---
    log_info "---------------------------------------------------------------------"
    log_info "服务启动完成!"
    log_info "---------------------------------------------------------------------"
    if ps -p $CADDY_PID > /dev/null && ps -p $XRAY_PID > /dev/null; then
        log_info "Caddy 和 Xray-core 服务正在后台运行。"
    elif ps -p $CADDY_PID > /dev/null; then
        log_warning "Caddy 服务正在运行 (PID: $CADDY_PID)，但 Xray-core 可能启动失败。"
    elif ps -p $XRAY_PID > /dev/null; then
        log_warning "Xray-core 服务正在运行 (PID: $XRAY_PID)，但 Caddy 可能启动失败。"
    else
        log_error "Caddy 和 Xray-core 服务似乎都启动失败了。请检查上面的日志。"
    fi

    # 将PID保存到文件中，便于后续管理
    echo "$CADDY_PID" > "$SCRIPT_DIR/app/caddy/caddy.pid"
    echo "$XRAY_PID" > "$SCRIPT_DIR/app/xray/xray.pid"
    
    log_info ""
    log_info "服务日志:"
    log_info "  Caddy: $CADDY_LOG_FILE"
    log_info "  Xray:  $XRAY_LOG_FILE"
    log_info ""
    log_info "管理服务 (示例):"
    log_info "  要停止服务: bash service.sh stop"
    log_info "  要重启服务: bash service.sh restart"
    log_info "  要查看状态: bash service.sh status"
    log_info "  为确保服务稳定运行和开机自启，强烈建议将它们配置为 systemd 服务。"
    log_info "---------------------------------------------------------------------"
}

# --- Function to Stop Services ---
stop_services() {
    # 获取当前脚本所在目录的绝对路径
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    log_info "正在停止 Caddy 和 Xray-core 服务..."

    # 尝试从PID文件读取
    if [ -f "$SCRIPT_DIR/app/caddy/caddy.pid" ]; then
        CADDY_PID=$(cat "$SCRIPT_DIR/app/caddy/caddy.pid")
        if ps -p $CADDY_PID > /dev/null; then
            kill $CADDY_PID
            log_info "已停止 Caddy 服务 (PID: $CADDY_PID)。"
        else
            log_warning "Caddy 服务未运行或PID已改变。"
        fi
    else
        # 尝试通过进程查找
        CADDY_PID=$(ps aux | grep "[c]addy run" | awk '{print $2}')
        if [ -n "$CADDY_PID" ]; then
            kill $CADDY_PID
            log_info "已停止 Caddy 服务 (PID: $CADDY_PID)。"
        else
            log_warning "未找到运行中的 Caddy 服务。"
        fi
    fi

    if [ -f "$SCRIPT_DIR/app/xray/xray.pid" ]; then
        XRAY_PID=$(cat "$SCRIPT_DIR/app/xray/xray.pid")
        if ps -p $XRAY_PID > /dev/null; then
            kill $XRAY_PID
            log_info "已停止 Xray-core 服务 (PID: $XRAY_PID)。"
        else
            log_warning "Xray-core 服务未运行或PID已改变。"
        fi
    else
        # 尝试通过进程查找
        XRAY_PID=$(ps aux | grep "[x]ray run" | awk '{print $2}')
        if [ -n "$XRAY_PID" ]; then
            kill $XRAY_PID
            log_info "已停止 Xray-core 服务 (PID: $XRAY_PID)。"
        else
            log_warning "未找到运行中的 Xray-core 服务。"
        fi
    fi

    log_info "服务停止操作完成。"
}

# --- Function to Restart Services ---
restart_services() {
    log_info "正在重启服务..."
    stop_services
    sleep 2
    start_services
}

# --- Function to Check Services Status ---
check_status() {
    # 获取当前脚本所在目录的绝对路径
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    log_info "正在检查服务状态..."

    # 检查Caddy状态
    CADDY_STATUS="未运行"
    CADDY_PID=""
    if [ -f "$SCRIPT_DIR/app/caddy/caddy.pid" ]; then
        CADDY_PID=$(cat "$SCRIPT_DIR/app/caddy/caddy.pid")
        if ps -p "$CADDY_PID" > /dev/null 2>&1; then
            CADDY_STATUS="运行中"
            log_info "Caddy 服务正在运行 (PID: $CADDY_PID)。"
        else
            log_warning "Caddy 服务未运行 (PID文件存在但进程不存在: $CADDY_PID)。"
        fi
    else
        # 尝试通过进程查找
        CADDY_PID=$(pgrep -f "[c]addy run" || true)
        if [ -n "$CADDY_PID" ]; then
            log_info "Caddy 服务正在运行 (PID: $CADDY_PID)，但无PID文件。"
            CADDY_STATUS="运行中"
        else
            log_warning "Caddy 服务未运行。"
        fi
    fi

    # 检查Xray状态
    XRAY_STATUS="未运行"
    XRAY_PID=""
    if [ -f "$SCRIPT_DIR/app/xray/xray.pid" ]; then
        XRAY_PID=$(cat "$SCRIPT_DIR/app/xray/xray.pid")
        if ps -p "$XRAY_PID" > /dev/null 2>&1; then
            XRAY_STATUS="运行中"
            log_info "Xray-core 服务正在运行 (PID: $XRAY_PID)。"
        else
            log_warning "Xray-core 服务未运行 (PID文件存在但进程不存在: $XRAY_PID)。"
        fi
    else
        # 尝试通过进程查找
        XRAY_PID=$(pgrep -f "[x]ray run" || true)
        if [ -n "$XRAY_PID" ]; then
            log_info "Xray-core 服务正在运行 (PID: $XRAY_PID)，但无PID文件。"
            XRAY_STATUS="运行中"
        else
            log_warning "Xray-core 服务未运行。"
        fi
    fi

    # 显示汇总信息
    log_info ""
    log_info "服务汇总:"
    log_info "  Caddy: $CADDY_STATUS"
    log_info "  Xray:  $XRAY_STATUS"

    # 显示日志文件位置
    log_info ""
    log_info "服务日志位置:"
    log_info "  Caddy: /var/log/caddy.log"
    log_info "  Xray:  /var/log/xray.log"

    # 显示最近的日志条目（如果服务正在运行）
    if [ "$CADDY_STATUS" = "运行中" ]; then
        log_info ""
        log_info "Caddy 最近日志 (最后5行):"
        tail -n 5 /var/log/caddy.log 2>/dev/null || echo "  (无法读取日志文件)"
    fi

    if [ "$XRAY_STATUS" = "运行中" ]; then
        log_info ""
        log_info "Xray 最近日志 (最后5行):"
        tail -n 5 /var/log/xray.log 2>/dev/null || echo "  (无法读取日志文件)"
    fi
}

# --- Main script logic ---
if [ $# -eq 0 ]; then
    # 默认操作是启动服务
    start_services
else
    # 根据命令行参数执行不同操作
    case "$1" in
        start)
            start_services
            ;;
        stop)
            stop_services
            ;;
        restart)
            restart_services
            ;;
        status)
            check_status
            ;;
        *)
            echo "用法: $0 [start|stop|restart|status]"
            echo "  默认 (无参数): 启动服务"
            echo "  start:   启动 Caddy 和 Xray-core 服务"
            echo "  stop:    停止 Caddy 和 Xray-core 服务"
            echo "  restart: 重启 Caddy 和 Xray-core 服务"
            echo "  status:  显示 Caddy 和 Xray-core 服务的状态"
            exit 1
            ;;
    esac
fi

exit 0

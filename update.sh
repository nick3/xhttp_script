#!/bin/bash

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# --- Backup Functions ---
create_backup() {
    local component="$1"
    local backup_timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_dir="./backups"

    log_info "为 $component 创建备份..."

    # 创建备份目录
    mkdir -p "$backup_dir"

    case "$component" in
        caddy)
            if [ -f "./app/caddy/caddy" ]; then
                local backup_path="$backup_dir/caddy_${backup_timestamp}"
                cp "./app/caddy/caddy" "$backup_path"
                log_info "Caddy 备份已创建: $backup_path"
                echo "$backup_path"
            else
                log_error "找不到 Caddy 可执行文件: ./app/caddy/caddy"
                return 1
            fi
            ;;
        xray)
            if [ -f "./app/xray/xray" ]; then
                local backup_path="$backup_dir/xray_${backup_timestamp}"
                cp "./app/xray/xray" "$backup_path"
                log_info "Xray 备份已创建: $backup_path"
                echo "$backup_path"
            else
                log_error "找不到 Xray 可执行文件: ./app/xray/xray"
                return 1
            fi
            ;;
        all)
            create_backup "caddy"
            create_backup "xray"
            ;;
        *)
            log_error "未知组件: $component"
            return 1
            ;;
    esac
}

# --- List Available Backups ---
list_backups() {
    local backup_dir="./backups"

    if [ ! -d "$backup_dir" ] || [ -z "$(ls -A "$backup_dir" 2>/dev/null)" ]; then
        log_info "没有找到备份文件。"
        return 0
    fi

    log_info "可用的备份文件:"
    echo "----------------------------------------"
    echo "Caddy 备份:"
    ls -la "$backup_dir"/caddy_* 2>/dev/null || echo "  无 Caddy 备份"
    echo

    echo "Xray 备份:"
    ls -la "$backup_dir"/xray_* 2>/dev/null || echo "  无 Xray 备份"
    echo "----------------------------------------"
}

# --- Restore Function ---
restore_backup() {
    local component="$1"
    local backup_file="$2"

    if [ ! -f "$backup_file" ]; then
        log_error "备份文件不存在: $backup_file"
        return 1
    fi

    log_info "正在恢复 $component 从备份: $backup_file"

    case "$component" in
        caddy)
            cp "$backup_file" "./app/caddy/caddy"
            chmod +x "./app/caddy/caddy"
            log_info "Caddy 已恢复到备份版本。"
            ;;
        xray)
            cp "$backup_file" "./app/xray/xray"
            chmod +x "./app/xray/xray"
            log_info "Xray 已恢复到备份版本。"
            ;;
        *)
            log_error "未知组件: $component"
            return 1
            ;;
    esac
}

# --- Update Function ---
update_component() {
    local component="$1"
    local create_backup_flag="${2:-true}"

    log_info "开始更新 $component..."

    # 检查必要文件是否存在
    if [ ! -f "./download.sh" ]; then
        log_error "找不到 download.sh 脚本。"
        return 1
    fi

    # 创建备份（如果需要）
    if [ "$create_backup_flag" = "true" ]; then
        if ! create_backup "$component"; then
            log_error "创建备份失败，更新已取消。"
            return 1
        fi
    fi

    # 停止服务
    log_info "停止服务以进行更新..."
    bash "$SCRIPT_DIR/service.sh" stop || log_warning "停止服务时出现警告，继续更新..."

    # 下载最新版本
    log_info "下载最新版本的 $component..."
    if bash "$SCRIPT_DIR/download.sh" --force "$component"; then
        log_info "$component 更新成功！"
    else
        log_error "$component 更新失败！"

        # 如果创建了备份，询问是否恢复
        if [ "$create_backup_flag" = "true" ]; then
            read -r -p "更新失败，是否恢复到备份版本？ [Y/n]: " restore_confirm
            restore_confirm=${restore_confirm:-Y}
            if [[ $restore_confirm =~ ^[Yy]$ ]]; then
                # 查找最新的备份文件
                backup_dir="./backups"
                latest_backup=$(ls -t "$backup_dir"/${component}_* 2>/dev/null | head -n 1)
                if [ -n "$latest_backup" ]; then
                    restore_backup "$component" "$latest_backup"
                else
                    log_error "找不到 $component 的备份文件。"
                fi
            fi
        fi
        return 1
    fi

    # 重启服务
    log_info "重启服务..."
    bash "$SCRIPT_DIR/service.sh" start

    log_info "$component 更新完成！"
    return 0
}

# --- Interactive Restore Menu ---
interactive_restore() {
    local backup_dir="./backups"

    if [ ! -d "$backup_dir" ] || [ -z "$(ls -A "$backup_dir" 2>/dev/null)" ]; then
        log_info "没有找到备份文件。"
        return 0
    fi

    echo "选择要恢复的组件:"
    echo "1. Caddy"
    echo "2. Xray"
    echo "3. 返回"

    read -r -p "请输入选项 [1-3]: " choice

    case $choice in
        1)
            # 列出 Caddy 备份
            caddy_backups=($(ls "$backup_dir"/caddy_* 2>/dev/null))
            if [ ${#caddy_backups[@]} -eq 0 ]; then
                log_info "没有找到 Caddy 备份文件。"
                return 0
            fi

            echo "可用的 Caddy 备份:"
            for i in "${!caddy_backups[@]}"; do
                echo "$((i+1)). $(basename "${caddy_backups[i]}")"
            done

            read -r -p "请选择要恢复的备份 [1-${#caddy_backups[@]}]: " backup_choice
            if [[ $backup_choice =~ ^[0-9]+$ ]] && [ $backup_choice -ge 1 ] && [ $backup_choice -le ${#caddy_backups[@]} ]; then
                selected_backup="${caddy_backups[$((backup_choice-1))]}"
                read -r -p "确认恢复 Caddy 到 $(basename "$selected_backup")？ [Y/n]: " confirm
                confirm=${confirm:-Y}
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    bash "$SCRIPT_DIR/service.sh" stop
                    restore_backup "caddy" "$selected_backup"
                    bash "$SCRIPT_DIR/service.sh" start
                fi
            fi
            ;;
        2)
            # 列出 Xray 备份
            xray_backups=($(ls "$backup_dir"/xray_* 2>/dev/null))
            if [ ${#xray_backups[@]} -eq 0 ]; then
                log_info "没有找到 Xray 备份文件。"
                return 0
            fi

            echo "可用的 Xray 备份:"
            for i in "${!xray_backups[@]}"; do
                echo "$((i+1)). $(basename "${xray_backups[i]}")"
            done

            read -r -p "请选择要恢复的备份 [1-${#xray_backups[@]}]: " backup_choice
            if [[ $backup_choice =~ ^[0-9]+$ ]] && [ $backup_choice -ge 1 ] && [ $backup_choice -le ${#xray_backups[@]} ]; then
                selected_backup="${xray_backups[$((backup_choice-1))]}"
                read -r -p "确认恢复 Xray 到 $(basename "$selected_backup")？ [Y/n]: " confirm
                confirm=${confirm:-Y}
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    bash "$SCRIPT_DIR/service.sh" stop
                    restore_backup "xray" "$selected_backup"
                    bash "$SCRIPT_DIR/service.sh" start
                fi
            fi
            ;;
        3)
            return 0
            ;;
        *)
            echo "无效选项。"
            ;;
    esac
}

# --- Main Script Logic ---
case "${1:-help}" in
    update)
        component="${2:-all}"
        if [ "$component" = "all" ]; then
            log_info "更新 Caddy 和 Xray 到最新版本..."
            read -r -p "这将更新 Caddy 和 Xray 到最新版本。继续？ [Y/n]: " confirm
            confirm=${confirm:-Y}
            if [[ $confirm =~ ^[Yy]$ ]]; then
                update_component "caddy"
                update_component "xray"
                log_info "所有组件更新完成！"
            else
                log_info "更新已取消。"
            fi
        else
            update_component "$component"
        fi
        ;;
    backup)
        component="${2:-all}"
        create_backup "$component"
        ;;
    list-backups)
        list_backups
        ;;
    restore)
        if [ $# -ge 3 ]; then
            # 命令行方式恢复
            component="$2"
            backup_file="$3"
            bash "$SCRIPT_DIR/service.sh" stop
            restore_backup "$component" "$backup_file"
            bash "$SCRIPT_DIR/service.sh" start
        else
            # 交互式恢复
            interactive_restore
        fi
        ;;
    help|*)
        echo "用法: $0 [命令] [选项]"
        echo ""
        echo "命令:"
        echo "  update [component]    更新组件到最新版本"
        echo "                        component: caddy, xray, all (默认: all)"
        echo "  backup [component]    创建组件备份"
        echo "                        component: caddy, xray, all (默认: all)"
        echo "  list-backups          列出所有可用备份"
        echo "  restore [component] [backup_file]"
        echo "                        恢复组件到指定备份版本"
        echo "                        如果不指定参数，将进入交互模式"
        echo "  help                  显示此帮助信息"
        echo ""
        echo "示例:"
        echo "  $0 update             # 更新所有组件"
        echo "  $0 update caddy       # 只更新 Caddy"
        echo "  $0 backup             # 备份所有组件"
        echo "  $0 list-backups       # 列出备份"
        echo "  $0 restore            # 交互式恢复"
        exit 1
        ;;
esac

exit 0
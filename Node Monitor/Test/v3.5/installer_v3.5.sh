#!/bin/bash
# Универсальный инсталлятор и конфигуратор для системы мониторинга нод v3.5

# --- ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ И НАСТРОЙКИ ---
INSTALL_DIR="$HOME/nod_monitor/v3.5"
MONITOR_SCRIPT_NAME="health_monitor_v3.5.sh" # Имя основного скрипта
CONFIG_FILE_NAME="config.json"
INSTALL_STATE_FILE=".install_state"

# Полные пути
MONITOR_SCRIPT_PATH="$INSTALL_DIR/$MONITOR_SCRIPT_NAME"
CONFIG_FILE_PATH="$INSTALL_DIR/$CONFIG_FILE_NAME"

# Цвета для вывода
C_HEADER='\033[95m'
C_OKGREEN='\033[92m'
C_WARNING='\033[93m'
C_FAIL='\033[91m'
C_ENDC='\033[0m'
C_BOLD='\033[1m'

# --- УТИЛИТЫ ВЫВОДА ---
print_header() { echo -e "\n${C_HEADER}${C_BOLD}--- $1 ---${C_ENDC}"; }
print_success() { echo -e "${C_OKGREEN}✔ $1${C_ENDC}"; }
print_warning() { echo -e "${C_WARNING}⚠ $1${C_ENDC}"; }
print_error() { echo -e "${C_FAIL}✖ $1${C_ENDC}"; }

# --- УТИЛИТЫ КОНФИГУРАЦИИ ---

# Проверка и создание файла конфигурации, если он отсутствует
ensure_config_exists() {
    if [ ! -f "$CONFIG_FILE_PATH" ]; then
        print_warning "Файл конфигурации не найден. Создание нового..."
        # Создаем базовую структуру JSON со всеми новыми полями
        echo '{
    "global": {
        "cosmos_directory_url": "https://rest.cosmos.directory",
        "missed_blocks_threshold": 10,
        "cron_interval_minutes": 15,
        "max_retries": 5,
        "retry_delay_seconds": 10,
        "delay_between_networks_seconds": 5
    },
    "telegram": {
        "bot_token": "",
        "alert_chat_ids": [],
        "report_chat_ids": [],
        "info_chat_ids": []
    },
    "networks": []
}' > "$CONFIG_FILE_PATH"
        print_success "Создан новый файл конфигурации: $CONFIG_FILE_PATH"
    fi
}

# --- ФУНКЦИИ УСТАНОВКИ ---

check_and_install_dependencies() {
    print_header "1. Проверка зависимостей"
    local needs_install=false
    local missing_packages=""
    for cmd in jq curl; do
        if ! command -v $cmd &> /dev/null; then
            print_warning "Команда '$cmd' не найдена."
            missing_packages+="$cmd "
            needs_install=true
        else
            print_success "'$cmd' уже установлен."
        fi
    done
    if [ "$needs_install" = true ]; then
        echo "Попытка установить недостающие пакеты..."
        if command -v apt-get &> /dev/null; then sudo apt-get update && sudo apt-get install -y $missing_packages
        elif command -v yum &> /dev/null; then sudo yum install -y $missing_packages
        elif command -v pacman &> /dev/null; then sudo pacman -S --noconfirm $missing_packages
        else
            print_error "Не удалось определить менеджер пакетов. Пожалуйста, установите ($missing_packages) вручную."
            exit 1
        fi
        print_success "Зависимости успешно установлены."
    fi
}

install_monitor() {
    print_header "2. Установка скриптов и конфигурации"
    if [ ! -f "$MONITOR_SCRIPT_NAME" ]; then
        print_error "Ошибка: Файл скрипта '$MONITOR_SCRIPT_NAME' не найден."
        echo "Пожалуйста, убедитесь, что инсталлятор находится в той же папке, что и скрипт мониторинга."
        exit 1
    fi
    echo "Целевая директория: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    echo "Копирование скрипта мониторинга..."
    cp "$MONITOR_SCRIPT_NAME" "$MONITOR_SCRIPT_PATH"
    ensure_config_exists
    echo "Установка прав на выполнение..."
    chmod +x "$MONITOR_SCRIPT_PATH"
    mkdir -p "$INSTALL_DIR/states"
    print_success "Скрипт мониторинга успешно установлен в $INSTALL_DIR"
    touch "$INSTALL_DIR/$INSTALL_STATE_FILE"
}

setup_cron_job() {
    print_header "3. Настройка Cron"
    if [ ! -f "$MONITOR_SCRIPT_PATH" ]; then
        print_error "Скрипт мониторинга не найден. Сначала выполните установку."
        return
    fi
    ensure_config_exists
    local interval
    if jq -e '.global.cron_interval_minutes' "$CONFIG_FILE_PATH" > /dev/null; then
        interval=$(jq -r '.global.cron_interval_minutes' "$CONFIG_FILE_PATH")
        print_success "Интервал ${interval} минут взят из файла конфигурации."
    else
        read -p "Введите интервал запуска в минутах (например, 10): " interval
    fi
    if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
        print_error "Неверный формат интервала. Введите число."
        return
    fi
    local cron_command="*/$interval * * * * cd $INSTALL_DIR && ./$MONITOR_SCRIPT_NAME >> cron.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT_NAME") | crontab -
    (crontab -l 2>/dev/null; echo "$cron_command") | crontab -
    print_success "Задача Cron успешно настроена! Скрипт будет выполняться каждые $interval минут."
    echo "Логи выполнения будут записываться в файл: $INSTALL_DIR/cron.log"
}

# --- ФУНКЦИИ КОНФИГУРАЦИИ ---

select_network() {
    print_header "Выбор сети"
    mapfile -t networks < <(jq -r '.networks[].name' "$CONFIG_FILE_PATH")
    if [ ${#networks[@]} -eq 0 ]; then
        print_warning "В конфигурации нет сетей для выбора."
        return 1
    fi
    echo "Доступные сети:"
    for i in "${!networks[@]}"; do echo "  $((i+1))) ${networks[$i]}"; done
    echo "  q) Отмена"
    local choice
    read -p "Выберите номер сети: " choice
    if [[ "$choice" =~ ^[qQ]$ ]]; then return 1; fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#networks[@]}" ]; then
        print_error "Неверный выбор."
        return 1
    fi
    REPLY=$((choice-1))
    return 0
}

configure_telegram() {
    print_header "Настройка Telegram"
    ensure_config_exists
    read -p "Введите TELEGRAM_BOT_TOKEN: " token
    read -p "Введите ID чатов для ALERT (через пробел): " alert_ids
    read -p "Введите ID чатов для REPORT (через пробел): " report_ids
    read -p "Введите ID чатов для INFO (через пробел): " info_ids
    local temp_json=$(mktemp)
    jq \
        --arg token "$token" \
        --argjson alert "[$(echo "$alert_ids" | sed 's/ /","/g;s/^/"/;s/$/"/')]" \
        --argjson report "[$(echo "$report_ids" | sed 's/ /","/g;s/^/"/;s/$/"/')]" \
        --argjson info "[$(echo "$info_ids" | sed 's/ /","/g;s/^/"/;s/$/"/')]" \
        '.telegram = {bot_token: $token, alert_chat_ids: $alert, report_chat_ids: $report, info_chat_ids: $info}' \
        "$CONFIG_FILE_PATH" > "$temp_json" && mv "$temp_json" "$CONFIG_FILE_PATH"
    print_success "Telegram сконфигурирован."
}

# ⭐ НОВАЯ ФУНКЦИЯ
configure_global_settings() {
    print_header "🔧 Настройка глобальных параметров"
    ensure_config_exists
    local current_threshold=$(jq -r '.global.missed_blocks_threshold' "$CONFIG_FILE_PATH")
    local current_retries=$(jq -r '.global.max_retries' "$CONFIG_FILE_PATH")
    local current_retry_delay=$(jq -r '.global.retry_delay_seconds' "$CONFIG_FILE_PATH")
    local current_net_delay=$(jq -r '.global.delay_between_networks_seconds' "$CONFIG_FILE_PATH")
    echo "Нажмите Enter, чтобы оставить текущее значение."
    read -p "Порог пропущенных блоков [${current_threshold}]: " threshold
    read -p "Макс. количество попыток при ошибках [${current_retries}]: " retries
    read -p "Задержка между попытками (сек) [${current_retry_delay}]: " retry_delay
    read -p "Задержка между проверкой сетей (сек) [${current_net_delay}]: " net_delay
    threshold=${threshold:-$current_threshold}
    retries=${retries:-$current_retries}
    retry_delay=${retry_delay:-$current_retry_delay}
    net_delay=${net_delay:-$current_net_delay}
    local temp_json=$(mktemp)
    jq \
        --argjson threshold "$threshold" \
        --argjson retries "$retries" \
        --argjson retry_delay "$retry_delay" \
        --argjson net_delay "$net_delay" \
        '.global.missed_blocks_threshold = $threshold |
         .global.max_retries = $retries |
         .global.retry_delay_seconds = $retry_delay |
         .global.delay_between_networks_seconds = $net_delay' \
        "$CONFIG_FILE_PATH" > "$temp_json" && mv "$temp_json" "$CONFIG_FILE_PATH"
    print_success "Глобальные параметры обновлены."
}

# ⭐ ОБНОВЛЕННАЯ ФУНКЦИЯ
add_network() {
    print_header "➕ Добавление сети"
    ensure_config_exists
    read -p "Имя сети (например, Nolus): " name
    read -p "VALOPER адрес: " valoper
    read -p "VALCONS адрес: " valcons
    read -p "Тег пользователя для оповещений (@username): " tag
    read -p "REST URL (опционально, оставьте пустым для автоопределения): " rest_url
    read -p "RPC URL (опционально, оставьте пустым для автоопределения): " rpc_url
    local temp_json=$(mktemp)
    jq \
        --arg name "$name" --arg valoper "$valoper" --arg valcons "$valcons" --arg tag "$tag" --arg rest "$rest_url" --arg rpc "$rpc_url" \
        '.networks += [ { name: $name, valoper_address: $valoper, valcons_address: $valcons, user_tag: $tag } | if $rest != "" then . + {rest_url: $rest} else . end | if $rpc != "" then . + {rpc_url: $rpc} else . end ]' \
        "$CONFIG_FILE_PATH" > "$temp_json" && mv "$temp_json" "$CONFIG_FILE_PATH"
    print_success "Сеть '$name' добавлена."
}

# ⭐ ОБНОВЛЕННАЯ ФУНКЦИЯ
edit_network() {
    print_header "✍️ Редактирование сети"
    ensure_config_exists
    local index
    select_network || return
    index=$REPLY
    local current_name=$(jq -r ".networks[$index].name" "$CONFIG_FILE_PATH")
    local current_valoper=$(jq -r ".networks[$index].valoper_address" "$CONFIG_FILE_PATH")
    local current_valcons=$(jq -r ".networks[$index].valcons_address" "$CONFIG_FILE_PATH")
    local current_tag=$(jq -r ".networks[$index].user_tag" "$CONFIG_FILE_PATH")
    local current_rest=$(jq -r ".networks[$index].rest_url // \"\"" "$CONFIG_FILE_PATH")
    local current_rpc=$(jq -r ".networks[$index].rpc_url // \"\"" "$CONFIG_FILE_PATH")
    echo "Редактирование сети '$current_name'. Нажмите Enter, чтобы оставить текущее значение."
    read -p "Новое имя сети [${current_name}]: " name
    read -p "Новый VALOPER адрес [${current_valoper}]: " valoper
    read -p "Новый VALCONS адрес [${current_valcons}]: " valcons
    read -p "Новый тег пользователя [${current_tag}]: " tag
    read -p "Новый REST URL [${current_rest:-не задан}]: " rest_url
    read -p "Новый RPC URL [${current_rpc:-не задан}]: " rpc_url
    name=${name:-$current_name}
    valoper=${valoper:-$current_valoper}
    valcons=${valcons:-$current_valcons}
    tag=${tag:-$current_tag}
    rest_url=${rest_url:-$current_rest}
    rpc_url=${rpc_url:-$current_rpc}
    local temp_json=$(mktemp)
    jq \
      --argjson index "$index" --arg name "$name" --arg valoper "$valoper" --arg valcons "$valcons" --arg tag "$tag" --arg rest "$rest_url" --arg rpc "$rpc_url" \
      '.networks[$index] = ( { name: $name, valoper_address: $valoper, valcons_address: $valcons, user_tag: $tag } | if $rest != "" then . + {rest_url: $rest} else . end | if $rpc != "" then . + {rpc_url: $rpc} else . end )' \
      "$CONFIG_FILE_PATH" > "$temp_json" && mv "$temp_json" "$CONFIG_FILE_PATH"
    print_success "Сеть '$name' обновлена."
}

delete_network() {
    print_header "➖ Удаление сети"
    ensure_config_exists
    local index
    select_network || return
    index=$REPLY
    local network_name=$(jq -r ".networks[$index].name" "$CONFIG_FILE_PATH")
    read -p "Вы уверены, что хотите удалить сеть '$network_name'? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Удаление отменено."
        return
    fi
    local temp_json=$(mktemp)
    jq --argjson index "$index" 'del(.networks[$index])' "$CONFIG_FILE_PATH" > "$temp_json" && mv "$temp_json" "$CONFIG_FILE_PATH"
    print_success "Сеть '$network_name' удалена."
}

list_config() {
    print_header "📄 Текущая конфигурация ($CONFIG_FILE_PATH)"
    ensure_config_exists
    jq '.' "$CONFIG_FILE_PATH"
}

uninstall_monitor() {
    print_header "❌ Удаление системы мониторинга"
    read -p "Вы уверены, что хотите удалить все файлы ($INSTALL_DIR) и задачу cron? (y/n): " choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        echo "Удаление задачи из cron..."
        (crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT_NAME") | crontab -
        print_success "Задача cron удалена."
        echo "Удаление директории установки..."
        rm -rf "$INSTALL_DIR"
        print_success "Директория $INSTALL_DIR удалена."
        print_success "Удаление завершено."
    else
        echo "Удаление отменено."
    fi
}

# --- ГЛАВНОЕ МЕНЮ ---
main_menu() {
    while true; do
        if [ ! -f "$INSTALL_DIR/$INSTALL_STATE_FILE" ]; then
            print_header "Меню первоначальной установки"
            echo "1) 🚀 Установить систему мониторинга (шаги 1-3)"
            echo "q) Выход"
        else
            print_header "Главное меню управления мониторингом"
            echo "--- Установка и Обновление ---"
            echo "1) Проверить зависимости"
            echo "2) Переустановить скрипты (обновить)"
            echo "3) Настроить/обновить задачу Cron"
            echo "--- Конфигурация ---"
            echo "4) 💬 Настроить Telegram"
            echo "5) 🔧 Настроить глобальные параметры"
            echo "6) ➕ Добавить сеть"
            echo "7) ✍️ Редактировать сеть"
            echo "8) ➖ Удалить сеть"
            echo "9) 📄 Показать текущий конфиг"
            echo "--- Обслуживание ---"
            echo "10) ❌ Удалить систему мониторинга"
            echo "q) Выход"
        fi

        read -p "Ваш выбор: " choice

        if [ ! -f "$INSTALL_DIR/$INSTALL_STATE_FILE" ]; then
            case $choice in
                1) check_and_install_dependencies; install_monitor; setup_cron_job; print_success "Базовая установка завершена! Теперь можно настроить сети.";;
                q|Q) echo "Выход."; break ;;
                *) print_warning "Неверный выбор." ;;
            esac
        else
            case $choice in
                1) check_and_install_dependencies ;;
                2) install_monitor ;;
                3) setup_cron_job ;;
                4) configure_telegram ;;
                5) configure_global_settings ;;
                6) add_network ;;
                7) edit_network ;;
                8) delete_network ;;
                9) list_config ;;
                10) uninstall_monitor; break ;;
                q|Q) echo "Выход."; break ;;
                *) print_warning "Неверный выбор." ;;
            esac
        fi
    done
}

# --- ЗАПУСК ---
main_menu

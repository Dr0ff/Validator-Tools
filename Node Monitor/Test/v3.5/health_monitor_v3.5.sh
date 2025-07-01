#!/usr/bin/env bash

# скрипт мониторинга v3.5 (для bash v4+)
# Зависимости: jq, curl
# Для запуска нужен установшик! installer*.sh
# Запускать с флагом --debug для получения подробного режима.

set -eo pipefail

# --- ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"
STATE_DIR="${SCRIPT_DIR}/states"

# --- ОБРАБОТКА АРГУМЕНТОВ И ЛОГИРОВАНИЕ ---
GLOBAL_DEBUG=false
if [[ "${1:-}" == "--debug" ]]; then
    GLOBAL_DEBUG=true
fi

log_debug() {
    if [ "$GLOBAL_DEBUG" = true ]; then
        echo "[DEBUG] $(date -u -R): $1" >&2
    fi
}

# --- ПРОВЕРКА ЗАВИСИМОСТЕЙ ---
command -v jq >/dev/null 2>&1 || { echo >&2 "ОШИБКА: jq не установлен."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo >&2 "ОШИБКА: curl не установлен."; exit 1; }

# --- ЗАГРУЗКА КОНФИГУРАЦИИ ---
if [ ! -f "$CONFIG_FILE" ]; then
    echo >&2 "ОШИБКА: Файл конфигурации не найден: ${CONFIG_FILE}"
    exit 1
fi

# --- УТИЛИТЫ ---

read_config() {
    jq -r "$1" "$CONFIG_FILE"
}

convert_to_timestamp() {
    local date_string="$1"
    if [[ -z "$date_string" || "$date_string" == "null" || "$date_string" == "0001-01-01T00:00:00Z" ]]; then
        echo ""
        return
    fi
    # Эта конструкция универсальна для GNU/Linux и macOS (с coreutils)
    date -d "$date_string" "+%s" 2>/dev/null
}

send_telegram() {
    local message_body="$1"
    local network_user_tag="$2"
    shift 2
    local types=("$@")
    local full_message="$message_body"

    if [[ " ${types[*]} " =~ " ALERT " ]] && [[ -n "$network_user_tag" ]]; then
        full_message="${full_message} ${network_user_tag}"
    fi

    for type in "${types[@]}"; do
        local chat_ids_json
        chat_ids_json=$(read_config ".telegram.${type,,}_chat_ids")

        if [[ -z "$chat_ids_json" || "$chat_ids_json" == "[]" ]]; then
            log_debug "Массив чатов для '${type}' пуст. Пропускаем отправку."
            continue
        fi

        echo "$chat_ids_json" | jq -r '.[]' | while read -r chat_id; do
            if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$chat_id" ]; then
                log_debug "WARN: TELEGRAM_BOT_TOKEN или CHAT_ID для типа '${type}' не настроен."
                continue
         	fi
            log_debug "Отправка сообщения типа '${type}' в чат ID: ${chat_id}"
            curl -s --show-error -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                -d chat_id="$chat_id" \
                -d text="$full_message" >/dev/null
        done
    done
}

curl_with_retry() {
    local -n output_var="$1" # Nameref для переменной результата
    local url="$2"
    local jq_path="$3"
    local context="$4"
    local last_error_message=""

    for (( attempt=1; attempt<=$MAX_RETRIES; attempt++ )); do
        log_debug "Попытка ${attempt}/${MAX_RETRIES} для ${context} (URL: ${url})."
        if response=$(curl -s --fail --max-time 15 "$url" 2>&1); then
            if echo "$response" | jq -e "$jq_path" >/dev/null 2>&1; then
                log_debug "Успешный ответ для ${context}."
                output_var="$response"
                return 0 # Success
            else
                last_error_message="JSON ответ не содержит '${jq_path}' или невалиден: ${response}"
                log_debug "JSON валидация для ${context} провалена (попытка ${attempt}). Ошибка: '${last_error_message}'"
            fi
        else
            last_error_message="$response"
            log_debug "Попытка ${attempt} для ${context} провалена. Ошибка: '${last_error_message}'"
        fi
        if [ "$attempt" -lt "$MAX_RETRIES" ]; then
            sleep "$RETRY_DELAY_SECONDS"
        fi
    done
    output_var="$last_error_message"
    return 1 # Failure
}

# --- ОСНОВНЫЕ ФУНКЦИИ ПРОВЕРКИ ---

check_rest_api() {
    local node_name="$1"
    local rest_api_base_url="$2"
    local current_user_tag="$3"
    local health_check_url="${rest_api_base_url}/cosmos/staking/v1beta1/params"
    local health_check_output

    if ! curl_with_retry health_check_output "$health_check_url" '.params' "${node_name} Health Check"; then
        send_telegram "⛔️ НОДА НЕДОСТУПНА!%0A%0AСеть: ${node_name^^}%0AURL REST API: ${rest_api_base_url}%0AПричина: Не отвечает или ответ невалиден после ${MAX_RETRIES} попыток.%0AПоследняя ошибка: ${health_check_output}" "${current_user_tag}" "ALERT"
        return 1
    fi
    return 0
}

check_validator_jailed() {
    local node_name="$1"
    local rest_api_base_url="$2"
    local valoper_address="$3"
    local current_user_tag="$4"
    local -n moniker_ref="$5" # Nameref для моникера
    local validator_status_url="${rest_api_base_url}/cosmos/staking/v1beta1/validators/${valoper_address}"
    local validator_info_output

    if ! curl_with_retry validator_info_output "$validator_status_url" '.validator' "${node_name} Staking Status"; then
        send_telegram "❌ ОШИБКА ЗАПРОСА СТАТУСА ВАЛИДАТОРА (Staking)!%0A%0AСеть: ${node_name^^}%0AПричина: Не удалось получить статус валидатора после ${MAX_RETRIES} попыток.%0AПоследняя ошибка: ${validator_info_output}%0AПроверьте REST API или VALOPER_ADDRESS." "${current_user_tag}" "ALERT"
        return 1
    fi

    moniker_ref=$(echo "$validator_info_output" | jq -r '(.validator.description.moniker // .description.moniker // "Неизвестный моникер")')
    log_debug "Моникер валидатора ${node_name}: '${moniker_ref}'"

    if [[ $(echo "$validator_info_output" | jq -r '(.validator.jailed // .jailed // "false") | tostring') == "true" ]]; then
        local unbonding_or_jailed_until_raw
        unbonding_or_jailed_until_raw=$(echo "$validator_info_output" | jq -r '(.validator.unbonding_time // .validator.jailed_until // empty)')

        local jailed_until_date_formatted="неизвестна"
        local jailed_until_timestamp
        jailed_until_timestamp=$(convert_to_timestamp "$unbonding_or_jailed_until_raw")

        if [[ -n "$jailed_until_timestamp" ]] && (( jailed_until_timestamp > $(date +%s) )); then
            jailed_until_date_formatted="ожидается до: $(date -d "@${jailed_until_timestamp}" "+%Y-%m-%d %H:%M:%S %Z")"
        fi
        send_telegram "🚨 ВНИМАНИЕ: ВАЛИДАТОР В ТЮРЬМЕ!%0A%0AСеть: ${node_name^^}%0AВалидатор: ${moniker_ref}%0AСрок: ${jailed_until_date_formatted}" "${current_user_tag}" "ALERT"
        return 1 # Jailed
    fi
    return 0 # Not jailed
}

get_missed_block_count() {
    local node_name="$1"
    local rest_api_base_url="$2"
    local valcons_address="$3"
    local current_user_tag="$4"
    local moniker="$5"
    local api_version="$6"
    local -n count_ref="$7" # Nameref для счетчика
    local signing_info_url="${rest_api_base_url}/cosmos/slashing/${api_version}/signing_infos/${valcons_address}"
    local signing_info_output

    if ! curl_with_retry signing_info_output "$signing_info_url" '.val_signing_info' "${node_name} Signing Info (${api_version})"; then
        send_telegram "❌ ОШИБКА ЗАПРОСА SIGNING-INFO!%0A%0AСеть: ${node_name^^}%0AВалидатор: ${moniker}%0AVALCONS: ${valcons_address}%0AПричина: Не удалось получить signing-info (API: ${api_version}) после ${MAX_RETRIES} попыток.%0AПоследняя ошибка: ${signing_info_output}%0AПроверьте REST API, VALCONS_ADDRESS или версию API в config.json." "${current_user_tag}" "ALERT"
        return 1
    fi
    count_ref=$(echo "$signing_info_output" | jq -r '.val_signing_info.missed_blocks_counter | tonumber? // "0"')
    log_debug "Текущий счетчик пропущенных блоков для ${node_name} (${moniker}): ${count_ref}."
    return 0
}

process_daily_report() {
    local node_name="$1"
    local moniker="$2"
    local current_user_tag="$3"
    local current_missed_blocks="$4"
    local daily_report_file="$5"
    local daily_counter_file="${daily_report_file}.counter"
    local current_day
    current_day=$(date +%j)
    local last_reported_day=0

    if [ -f "$daily_report_file" ]; then
        last_reported_day=$(cat "$daily_report_file")
    fi

    if [ "$current_day" -ne "$last_reported_day" ]; then
        log_debug "Наступил новый день для ${node_name}. Формирование ежедневного отчета."
        local yesterday_counter=0
        if [ -f "$daily_counter_file" ]; then
            yesterday_counter=$(cat "$daily_counter_file")
        fi

        echo "$current_day" > "$daily_report_file"
        echo "$current_missed_blocks" > "$daily_counter_file"

        if [ "$yesterday_counter" -ne 0 ]; then
            local missed_for_24h=$((current_missed_blocks - yesterday_counter))
            if (( missed_for_24h < 0 )); then
                missed_for_24h=0
            fi
            send_telegram "📊 Ежедневный отчёт%0A%0AСеть: ${node_name^^}%0AВалидатор: ${moniker}%0AЗа сутки пропущено: ${missed_for_24h} блоков.%0AТекущий счетчик: ${current_missed_blocks}." "${current_user_tag}" "REPORT" "INFO"
        else
            log_debug "Счетчик за предыдущий день для ${node_name} равен 0. Ежедневный отчет не отправлен."
        fi
    fi
}

check_missed_blocks() {
    local node_name="$1"
    local rest_api_base_url="$2"
    local valoper_address="$3"
    local valcons_address="$4"
    local current_user_tag="$5"
    local state_file="$6"
    local daily_report_file="$7"
    local api_version="$8"
    local moniker

    if [ -z "$valoper_address" ] || [ -z "$valcons_address" ]; then
        log_debug "VALOPER или VALCONS адрес для ${node_name} не указан. Пропускаем."
        return
    fi

    if ! check_validator_jailed "$node_name" "$rest_api_base_url" "$valoper_address" "$current_user_tag" moniker; then
        log_debug "Валидатор ${node_name} в тюрьме. Пропускаем проверку пропущенных блоков."
        return
    fi

    local current_missed_blocks=0
    if ! get_missed_block_count "$node_name" "$rest_api_base_url" "$valcons_address" "$current_user_tag" "$moniker" "$api_version" current_missed_blocks; then
        return
    fi

    local last_missed_blocks=0
    if [ -f "$state_file" ]; then
        last_missed_blocks=$(cat "$state_file")
    fi

    local newly_missed_blocks=$((current_missed_blocks - last_missed_blocks))
    log_debug "Проверка ${node_name} (${moniker}): новых пропущенных блоков за ${CRON_INTERVAL_MINUTES} минут: ${newly_missed_blocks}. Общий: ${current_missed_blocks}."

    if [ "$newly_missed_blocks" -ge "$MISSED_BLOCKS_THRESHOLD" ]; then
        send_telegram "🚨 ТРЕВОГА: Пропущены блоки!%0A%0AСеть: ${node_name^^}%0AВалидатор: ${moniker}%0AНовых пропусков: ${newly_missed_blocks} за ${CRON_INTERVAL_MINUTES} мин.%0AОбщий счетчик: ${current_missed_blocks}." "${current_user_tag}" "ALERT"
    fi

    echo "$current_missed_blocks" > "$state_file"

    process_daily_report "$node_name" "$moniker" "$current_user_tag" "$current_missed_blocks" "$daily_report_file"
}

# --- ГЛАВНЫЙ ЦИКЛ ВЫПОЛНЕНИЯ ---
main() {
    log_debug "----------------------------------------------------------------------------"
    log_debug "Запуск скрипта мониторинга. Время: $(date -u -R)"
    log_debug "----------------------------------------------------------------------------"

    # Загрузка глобальных настроек
    TELEGRAM_BOT_TOKEN=$(read_config ".telegram.bot_token")
    DEFAULT_COSMOS_DIRECTORY_URL=$(read_config ".global.cosmos_directory_url")
    MISSED_BLOCKS_THRESHOLD=$(read_config ".global.missed_blocks_threshold")
    CRON_INTERVAL_MINUTES=$(read_config ".global.cron_interval_minutes")
    MAX_RETRIES=$(read_config ".global.max_retries")
    RETRY_DELAY_SECONDS=$(read_config ".global.retry_delay_seconds")
    DELAY_BETWEEN_NETWORKS_SECONDS=$(read_config ".global.delay_between_networks_seconds")

    mkdir -p "$STATE_DIR"

    local network_count
    network_count=$(read_config ".networks | length")

    for (( i=0; i<network_count; i++ )); do
        local node_name valoper_address valcons_address current_user_tag
        node_name=$(read_config ".networks[${i}].name")
        valoper_address=$(read_config ".networks[${i}].valoper_address")
        valcons_address=$(read_config ".networks[${i}].valcons_address")
        current_user_tag=$(read_config ".networks[${i}].user_tag")

        log_debug "--- Начинаем проверку для сети: ${node_name} ---"

        local rest_api_base_url="${DEFAULT_COSMOS_DIRECTORY_URL}/${node_name,,}"

        if ! check_rest_api "$node_name" "$rest_api_base_url" "$current_user_tag"; then
            log_debug "Проверка доступности REST API для ${node_name} провалена."
            continue
        fi

        local state_file="${STATE_DIR}/missed_blocks_state_${node_name}.txt"
        local daily_report_file="${STATE_DIR}/daily_report_state_${node_name}.txt"
        local slashing_api_version
        slashing_api_version=$(read_config ".networks[${i}].slashing_api_version // \"v1beta1\"")

        check_missed_blocks "$node_name" "$rest_api_base_url" "$valoper_address" "$valcons_address" "$current_user_tag" "$state_file" "$daily_report_file" "$slashing_api_version"

        if [ "$GLOBAL_DEBUG" = true ]; then
            send_telegram "✅ DEBUG: Все проверки для сети ${node_name^^} пройдены." "" "INFO"
        fi

        log_debug "--- Проверка для сети: ${node_name} завершена ---"

        if (( i < network_count - 1 )); then
            log_debug "Пауза ${DELAY_BETWEEN_NETWORKS_SECONDS} секунд."
            sleep "$DELAY_BETWEEN_NETWORKS_SECONDS"
        fi
    done

    log_debug "----------------------------------------------------------------------------"
    log_debug "Завершение скрипта. Время: $(date -u -R)"
    log_debug "----------------------------------------------------------------------------"
    echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] Скрипт мониторинга здоровья нод полностью отработал."
}

main

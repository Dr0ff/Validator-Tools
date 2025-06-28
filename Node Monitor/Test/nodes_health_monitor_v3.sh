#!/bin/bash

# health_monitor_v2_remote_api.sh
# Запускать с флагом --debug для получения подробного режима. Пример: bash health_monitor_v2_remote_api.sh --debug

# --- ОБЩИЕ НАСТРОЙКИ УВЕДОМЛЕНИЙ TELEGRAM (ОБЯЗАТЕЛЬНО ЗАПОЛНИТЬ ВРУЧНУЮ!) ---
TELEGRAM_BOT_TOKEN="7742907053:AAEBXUpVX272V2bIQ" # ЗАПОЛНИТЬ! Вставьте токен вашего Telegram-бота
TELEGRAM_ALERT_CHAT_IDS=( "-47676" ) # ЗАПОЛНИТЬ! Метка ALERT
TELEGRAM_REPORT_CHAT_IDS=( "-47676" ) # ЗАПОЛНИТЬ при желании, канал для отчётов. Метка REPORTS
TELEGRAM_INFO_CHAT_IDS=( "" ) # ЗАПОЛНИТЬ при желании, канал для информации. Метка INFO

# Пользователь для тега в Telegram. Оставьте пустым (""), если не хотите никого тегать.
USER_TO_PING="" # ЗАПОЛНИТЬ ПРИ ЖЕЛАНИИ!

# --- Настройка сетей ---

# ВНИМАНИЕ: Теперь мы используем ТОЛЬКО REST_API_BASE_URL для удаленного мониторинга.

# Настройки для первой сети
NET_1="Nolus" # Имя сети для отображения и использования в массивах (например, "Nolus")
# Обязательно заполните поля для VALOPER адреса и PUBKEY_JSON
# Они находятся чуть ниже, в блоке "МАССИВ" в секции: "Пример для Nolus"

# Настройки для второй сети.
# Если используете вторую ноду то заполните параметры в этом блоке
NET_2="Sommelier" # Имя сети для отображения и использования в массивах (например, "Sommelier")
# Обязательно заполните поля для VALOPER адреса и PUBKEY_JSON
# Они находятся чуть ниже, в блоке "МАССИВ" в секции: "Пример для Sommelier"

MISSED_BLOCKS_THRESHOLD=10
CRON_INTERVAL=10 # Интервал, как часто этот скрипт будет запускаться (в минутах)

# Базовая директория для файлов состояния скрипта.
CURRENT_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_STATE_DIR="${CURRENT_SCRIPT_DIR}"

# Файл для логов отладки. Он будет находиться в той же директории, что и сам скрипт.
DEBUG_LOG_FILE="${CURRENT_SCRIPT_DIR}/health_debug.log"

# --- ОБРАБОТКА АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ И НАСТРОЙКА ЛОГИРОВАНИЯ ---
GLOBAL_DEBUG=false # По умолчанию режим отладки выключен.
if [[ "$1" == "--debug" ]]; then
    GLOBAL_DEBUG=true # Если передан --debug, всегда включаем отладку.
fi

# --- ФУНКЦИЯ ЛОГИРОВАНИЯ ОТЛАДКИ ---
log_debug() {
    if [ "$GLOBAL_DEBUG" = true ]; then
        echo " [DEBUG] $1" >> "$DEBUG_LOG_FILE"
    fi
}

# Добавляем разделитель в начале лога, если включен дебаг
if [ "$GLOBAL_DEBUG" = true ]; then
    log_debug "----------------------------------------------------------------------------"
    log_debug "Запуск скрипта мониторинга здоровья нод (удаленный). Время: $(date -u -R)"
    log_debug "----------------------------------------------------------------------------"
fi


# --- КОНФИГУРАЦИИ СЕТЕЙ ---
declare -A NETWORKS

#    ⚠️        !!!-----  МАССИВ  -----!!!      ⚠️

#        === ОБЯЗАТЕЛЬНО ЗАПОЛНИТЕ ЭТОТ МАССИВ! ===
# Это список уникальных имен ваших сетей.
# Добавьте в команду все имена сетей, которые вы хотите мониторить
# Пример для трёх сетей: "declare -a NETWORK_NAMES=( "$NET_1" "$NET_2" "$NET_3" )".
declare -a NETWORK_NAMES=( "$NET_1" "$NET_2" ) # Используем переменные для имен сетей

# ⚠️  Пример для Nolus (использует переменную NET_1)
NETWORKS[${NET_1},REST_API_BASE_URL]="https://rest.cosmos.directory/${NET_1,,}" # cosmos.directory REST API для Nolus
NETWORKS[${NET_1},VALOPER_ADDRESS]="nolusvaloper1..."  # Не забудьте вставить адрес валидатора!
NETWORKS[${NET_1},PUBKEY_JSON]='{"@type":"/cosmos.crypto.ed25519.PubKey","key":"YOUR_NOLUS_PUBKEY_BASE64"}' # Не забудьте вставить PUBKEY!


# ⚠️  Пример для Sommelier (использует переменную NET_2)
NETWORKS[${NET_2},REST_API_BASE_URL]="https://rest.cosmos.directory/${NET_2,,}" # cosmos.directory REST API для Sommelier
NETWORKS[${NET_2},VALOPER_ADDRESS]="sommvaloper1..." # Не забудьте вставить адрес валидатора!
NETWORKS[${NET_2},PUBKEY_JSON]='{"@type":"/cosmos.crypto.ed25519.PubKey","key":"YOUR_SOMMELIER_PUBKEY_BASE64"}' # Не забудьте вставить PUBKEY!

# Добавьте NET_3, NET_4 и т.д. по аналогии, если требуется
# NET_3="Juno"
# NETWORKS[${NET_3},REST_API_BASE_URL]="https://rest.cosmos.directory/${NET_3,,}"
# NETWORKS[${NET_3},VALOPER_ADDRESS]="junovaloper1..."
# NETWORKS[${NET_3},PUBKEY_JSON]='{"@type":"/cosmos.crypto.ed25519.PubKey","key":"YOUR_JUNO_PUBKEY_BASE64"}'


# Проверка наличия jq
command -v jq >/dev/null 2>&1 || { echo >&2 "jq не установлен. Установите его командой sudo apt install jq"; exit 1; }
# Проверка наличия curl
command -v curl >/dev/null 2>&1 || { echo >&2 "curl не установлен. Установите его командой sudo apt install curl"; exit 1; }


# --- ОТПРАВКА СООБЩЕНИЙ В TELEGRAM ---
send_telegram() {
    local message="$1"
    shift
    local types=("$@") # Массив типов: ALERT, REPORT, INFO
    local full_message="$message"

    if [[ " ${types[@]} " =~ " ALERT " ]] && [[ -n "$USER_TO_PING" ]]; then
        full_message="${full_message} ${USER_TO_PING}"
    fi

    for type in "${types[@]}"; do
        local chat_array_name="TELEGRAM_${type}_CHAT_IDS[@]"
        # Используем косвенную ссылку для получения массива
        local -n chat_ids_ref="$chat_array_name" # Requires bash 4.3+

        if [ ${#chat_ids_ref[@]} -eq 0 ]; then
            log_debug "Массив чат-ID для типа '${type}' пуст. Пропускаем отправку."
            continue
        fi

        for CHAT_ID in "${chat_ids_ref[@]}"; do
            if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
                log_debug "WARN: TELEGRAM_BOT_TOKEN или CHAT_ID для типа '${type}' не настроен. Пропускаем Telegram-уведомление."
                continue
            fi
            log_debug "Отправка сообщения типа '${type}' в чат ID: ${CHAT_ID}"
            curl -s --show-error -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                -d chat_id="$CHAT_ID" -d text="$full_message" > /dev/null
            if [ $? -ne 0 ]; then
                log_debug "ERROR: Не удалось отправить Telegram-сообщение типа '${type}' в чат ID: ${CHAT_ID}."
            fi
        done
    done
}

# --- ПРОВЕРКА REST API И СИНХРОНИЗАЦИИ ---
check_node_health() {
    local node_name="$1"
    local rest_api_base_url="$2"
    # local debug_enabled="$3" # Не используется напрямую, log_debug сам проверяет GLOBAL_DEBUG

    if [ -z "$rest_api_base_url" ]; then
        send_telegram "⚠️  ОШИБКА КОНФИГУРАЦИИ: %0AБазовый URL REST API для ${node_name^^} не указан. %0AПроверьте настройки." "ALERT"
        log_debug "Базовый URL REST API для ${node_name} не указан. Проверка здоровья ноды пропущена."
        return 1
    fi

    log_debug "Начинаем проверку доступности REST API для ${node_name} по URL: ${rest_api_base_url}"

    local node_info_url="${rest_api_base_url}/node_info"
    local status_url="${rest_api_base_url}/status"
    local sync_info_url="${rest_api_base_url}/cosmos/base/tendermint/v1beta1/sync_info"

    local success_health_check=false
    local last_error_message=""

    # --- Логика повторных попыток для проверки доступности REST API ---
    for (( attempt=1; attempt<=$MAX_RETRIES; attempt++ )); do
        log_debug "Попытка ${attempt}/${MAX_RETRIES} проверки доступности REST API для ${node_name}."
        local current_health_output=""
        if current_health_output=$(curl -s --fail --max-time 10 "${node_info_url}" 2>&1); then
            success_health_check=true
            break # Успех, выходим из цикла попыток
        elif current_health_output=$(curl -s --fail --max-time 10 "${status_url}" 2>&1); then
            success_health_check=true
            break # Успех, выходим из цикла попыток
        else
            last_error_message="$current_health_output"
            log_debug "Попытка ${attempt} провалена для ${node_name}. Ошибка: '${last_error_message}'"
            if [ "$attempt" -lt "$MAX_RETRIES" ]; then
                sleep "$RETRY_DELAY_SECONDS"
            fi
        fi
    done

    if [ "$success_health_check" = false ]; then
        send_telegram "⛔️  НОДА НЕДОСТУПНА: %0A${node_name^^} не отвечает на REST API (${rest_api_base_url}) после ${MAX_RETRIES} попыток.%0AПоследняя ошибка: '${last_error_message}'" "ALERT"
        log_debug "REST API для ${node_name} недоступен после ${MAX_RETRIES} попыток. Ошибка: '${last_error_message}'"
        return 1
    fi
    log_debug "REST API для ${node_name} доступен после ${attempt} попыток. Проверка синхронизации."


    # --- Логика повторных попыток для проверки синхронизации ---
    local sync_status_output=""
    local success_sync_check=false
    local last_sync_error_message=""

    for (( attempt=1; attempt<=$MAX_RETRIES; attempt++ )); do
        log_debug "Попытка ${attempt}/${MAX_RETRIES} проверки синхронизации для ${node_name}."
        if sync_status_output=$(curl -s --fail --max-time 15 "${sync_info_url}" 2>&1); then
            success_sync_check=true
            break # Успех, выходим из цикла попыток
        else
            last_sync_error_message="$sync_status_output"
            log_debug "Попытка ${attempt} проверки синхронизации провалена для ${node_name}. Ошибка: '${last_sync_error_message}'"
            if [ "$attempt" -lt "$MAX_RETRIES" ]; then
                sleep "$RETRY_DELAY_SECONDS"
            fi
        fi
    done

    if [ "$success_sync_check" = false ]; then
        send_telegram "⚠️  Ошибка при получении sync_info от ${node_name^^} после ${MAX_RETRIES} попыток.%0AПроверьте REST API и формат ответа. %0AПоследняя ошибка: '${last_sync_error_message}'" "ALERT"
        log_debug "Ошибка при получении sync_info для ${node_name} после ${MAX_RETRIES} попыток. Ошибка: '${last_sync_error_message}'"
        return 1
    fi

    local parsed_sync_status=$(echo "$sync_status_output" | jq -r '.sync_info.catching_up // ""')

    if [[ "$parsed_sync_status" == "true" ]]; then
        send_telegram "⚠️  ${node_name^^} в режиме синхронизации. %0AВозможны пропуски." "ALERT" "INFO"
        log_debug "${node_name} в режиме синхронизации."
    elif [[ "$parsed_sync_status" == "false" ]]; then
        log_debug "${node_name} синхронизирован."
    else
        send_telegram "⚠️  Не удалось определить статус синхронизации для ${node_name^^}.%0A Неожиданный ответ: '${sync_status_output}'" "ALERT" "INFO"
        log_debug "Не удалось определить статус синхронизации для ${node_name}. Неожиданный ответ."
    fi
    return 0
}

# --- ПРОВЕРКА ПРОПУЩЕННЫХ БЛОКОВ И JAIL СТАТУСА ---
check_missed_blocks() {
    local node_name="$1"
    local rest_api_base_url="$2"
    local valoper_address="$3"
    local pubkey_json="$4" # Используется для сопоставления signing-info
    # local debug_enabled="$5" # Не используется напрямую, log_debug сам проверяет GLOBAL_DEBUG
    local state_file="$6"
    local daily_report_file="$7"
    local daily_counter_file="${daily_report_file}.counter"

    if [ -z "$valoper_address" ] || [ -z "$pubkey_json" ]; then
        log_debug "VALOPER_ADDRESS или PUBKEY_JSON для ${node_name} не указаны. Проверка пропущенных блоков и jailed статуса пропущена."
        return 1
    fi

    # 1. Получаем статус валидатора и jailed-статус через Staking REST API
    local validator_status_url="${rest_api_base_url}/cosmos/staking/v1beta1/validators/${valoper_address}"
    local validator_info_output=""
    local success_validator_info=false
    local last_validator_error_message=""

    for (( attempt=1; attempt<=$MAX_RETRIES; attempt++ )); do
        log_debug "Попытка ${attempt}/${MAX_RETRIES} получения статуса валидатора (staking) для ${node_name}."
        if validator_info_output=$(curl -s --fail --max-time 15 "$validator_status_url" 2>&1); then
            success_validator_info=true
            break
        else
            last_validator_error_message="$validator_info_output"
            log_debug "Попытка ${attempt} получения статуса валидатора провалена для ${node_name}. Ошибка: '${last_validator_error_message}'"
            if [ "$attempt" -lt "$MAX_RETRIES" ]; then
                sleep "$RETRY_DELAY_SECONDS"
            fi
        fi
    done

    if [ "$success_validator_info" = false ]; then
        send_telegram "❌ Ошибка при запросе статуса валидатора (staking) для ${node_name^^} после ${MAX_RETRIES} попыток.%0AПроверьте REST API или VALOPER_ADDRESS. %0AПоследняя ошибка: '${last_validator_error_message}'" "ALERT"
        log_debug "Ошибка запроса staking validator для ${node_name} после ${MAX_RETRIES} попыток. Пропускаем дальнейшие проверки. Ошибка: '${last_validator_error_message}'"
        return 1
    fi
    log_debug "Получены данные staking validator для ${node_name}:\n${validator_info_output}"

    # Извлекаем моникер валидатора
    local MONIKER=$(echo "$validator_info_output" | jq -r '(.validator.description.moniker // .description.moniker // "Неизвестный моникер")')
    log_debug "Моникер валидатора ${node_name}: '${MONIKER}'"

    local IS_JAILED="false"
    local jailed_until_time=""

    # Универсальная обработка jailed статуса
    local jailed_raw=$(echo "$validator_info_output" | jq -r '(.validator.jailed // .jailed // "false") | tostring')
    if [[ "$jailed_raw" == "true" ]]; then
        IS_JAILED="true"
        log_debug "Валидатор ${node_name} (${MONIKER}) помечен как 'jailed: true' в Staking API."
    else
        log_debug "Валидатор ${node_name} (${MONIKER}) не помечен как 'jailed: true' в Staking API (raw value: ${jailed_raw})."
    fi

    # Универсальная обработка unbonding_time / jailed_until
    local unbonding_or_jailed_until_raw=$(echo "$validator_info_output" | jq -r '(.validator.unbonding_time // .validator.jailed_until // empty)')
    log_debug "Raw unbonding_time / jailed_until from staking validator for ${node_name} (${MONIKER}): '${unbonding_or_jailed_until_raw}'"

    if [[ "$IS_JAILED" == "true" ]]; then
        local jailed_until_date_formatted="неизвестна"
        local current_timestamp=$(date +%s)

        if [[ -n "$unbonding_or_jailed_until_raw" && "$unbonding_or_jailed_until_raw" != "null" && \
              "$unbonding_or_jailed_until_raw" != "0001-01-01T00:00:00Z" && "$unbonding_or_jailed_until_raw" != "1970-01-01T00:00:00Z" ]]; then
            # Используем gdate если доступен (для macOS) или date (для Linux)
            local jailed_until_timestamp
            if command -v gdate &> /dev/null; then
                jailed_until_timestamp=$(gdate -d "$unbonding_or_jailed_until_raw" +%s 2>/dev/null)
            else
                jailed_until_timestamp=$(date -d "$unbonding_or_jailed_until_raw" +%s 2>/dev/null)
            fi

            if [[ -n "$jailed_until_timestamp" ]]; then
                if (( jailed_until_timestamp > current_timestamp )); then
                    jailed_until_date_formatted="ожидается до: $(date -d @${jailed_until_timestamp} +"%Y-%m-%d %H:%M:%S %Z" 2>/dev/null)"
                    log_debug "Дата освобождения ${node_name} (${MONIKER}) в будущем: ${jailed_until_date_formatted}"
                else
                    jailed_until_date_formatted="срок истек: $(date -d @${jailed_until_timestamp} +"%Y-%m-%d %H:%M:%S %Z" 2>/dev/null)"
                    log_debug "Дата освобождения ${node_name} (${MONIKER}) истекла: ${jailed_until_date_formatted}"
                fi
            else
                log_debug "Не удалось распарсить метку времени jailed_until для ${node_name} (${MONIKER}) из '${unbonding_or_jailed_until_raw}'."
            fi
        else
            log_debug "jailed_until для ${node_name} (${MONIKER}) является пустой, null, 0001-01-01Z или 1970-01-01Z: '${unbonding_or_jailed_until_raw}'."
        fi

        send_telegram "🚨 ВНИМАНИЕ: %0AВалидатор ${node_name^^} (${MONIKER}) В ТЮРЬМЕ! %0AСрок: ${jailed_until_date_formatted}" "ALERT"
        log_debug "Валидатор ${node_name} (${MONIKER}) в тюрьме. Пропускаем дальнейшие проверки пропущенных блоков."
        return 1 # Если валидатор в тюрьме, нет смысла проверять пропущенные блоки.
    fi

    # 2. Получаем missed_blocks_counter через Slashing Signing-Infos REST API
    # Нам нужен consensus_pubkey.key из PUBKEY_JSON
    local target_pubkey_base64=$(echo "$pubkey_json" | jq -r '.key // ""')
    if [ -z "$target_pubkey_base64" ]; then
        send_telegram "❌ ОШИБКА КОНФИГУРАЦИИ: %0AНе удалось извлечь base64-ключ из PUBKEY_JSON для ${node_name^^}.%0AПроверьте PUBKEY_JSON." "ALERT"
        log_debug "Не удалось извлечь base64-ключ из PUBKEY_JSON для ${node_name}. Проверка missed_blocks_counter пропущена."
        return 1
    fi
    log_debug "Целевой PUBKEY (base64) для ${node_name} (${MONIKER}): ${target_pubkey_base64}"


    local signing_infos_url="${rest_api_base_url}/cosmos/slashing/v1beta1/signing_infos"
    local signing_infos_output=""
    local success_signing_infos=false
    local last_signing_infos_error_message=""

    for (( attempt=1; attempt<=$MAX_RETRIES; attempt++ )); do
        log_debug "Попытка ${attempt}/${MAX_RETRIES} получения signing-infos для ${node_name} (${MONIKER})."
        if signing_infos_output=$(curl -s --fail --max-time 20 "$signing_infos_url" 2>&1); then
            success_signing_infos=true
            break
        else
            last_signing_infos_error_message="$signing_infos_output"
            log_debug "Попытка ${attempt} получения signing-infos провалена для ${node_name} (${MONIKER}). Ошибка: '${last_signing_infos_error_message}'"
            if [ "$attempt" -lt "$MAX_RETRIES" ]; then
                sleep "$RETRY_DELAY_SECONDS"
            fi
        fi
    done

    if [ "$success_signing_infos" = false ]; then
        send_telegram "❌ Ошибка при получении signing-infos для ${node_name^^} (${MONIKER}) после ${MAX_RETRIES} попыток. %0AПроверьте REST API. %0AПоследняя ошибка: '${last_signing_infos_error_message}'" "ALERT"
        log_debug "Ошибка при получении signing-infos для ${node_name} (${MONIKER}) после ${MAX_RETRIES} попыток. Пропускаем проверку missed_blocks. Ошибка: '${last_signing_infos_error_message}'"
        return 1
    fi
    log_debug "Получены данные signing-infos для ${node_name} (${MONIKER}) (начало):\n${signing_infos_output:0:500}..." # Ограничиваем вывод


    local CURRENT_MISSED_BLOCKS=0
    local found_signing_info=false

    # Ищем наш валидатор в списке signing_infos по его pubkey
    local matching_info=$(echo "$signing_infos_output" | jq -c ".info[] | select(.pub_key.key == \"$target_pubkey_base64\")")

    if [[ -n "$matching_info" ]]; then
        found_signing_info=true
        CURRENT_MISSED_BLOCKS=$(echo "$matching_info" | jq -r '.missed_blocks_counter | tonumber? // "0"')
        log_debug "Successfully parsed missed_blocks_counter for ${node_name} (${MONIKER}): ${CURRENT_MISSED_BLOCKS}."
    else
        log_debug "Не удалось найти signing-info для ${node_name} (${MONIKER}) с PUBKEY ${target_pubkey_base64}. Предполагаем 0 пропущенных блоков."
    fi

    if [ "$found_signing_info" = false ]; then
        send_telegram "⚠️  Не удалось найти signing-info для ${node_name^^} (${MONIKER}) по предоставленному PUBKEY. %0AУбедитесь, что PUBKEY_JSON верен и валидатор активен." "ALERT" "INFO"
        return 1
    fi


    local LAST_MISSED_BLOCKS=0
    if [ -f "$state_file" ] && [[ "$(cat "$state_file")" =~ ^[0-9]+$ ]]; then
        LAST_MISSED_BLOCKS=$(cat "$state_file")
    else
        log_debug "Предыдущее значение missed_blocks для ${node_name} (${MONIKER}) не числовое или файл отсутствует, сброс до 0."
    fi

    local NEWLY_MISSED_BLOCKS=$((CURRENT_MISSED_BLOCKS - LAST_MISSED_BLOCKS))
    log_debug "Проверка ${node_name} (${MONIKER}): новых пропущенных блоков за ${CRON_INTERVAL} минут: ${NEWLY_MISSED_BLOCKS}. Общий: ${CURRENT_MISSED_BLOCKS}."

    if [ "$NEWLY_MISSED_BLOCKS" -ge "$MISSED_BLOCKS_THRESHOLD" ] && [ "$NEWLY_MISSED_BLOCKS" -gt 0 ]; then
        send_telegram "🚨 ТРЕВОГА: %0A${node_name^^} (${MONIKER}) пропустил ${NEWLY_MISSED_BLOCKS} блоков за ${CRON_INTERVAL} минут! %0AОбщий счетчик: ${CURRENT_MISSED_BLOCKS}." "ALERT"
    fi

    mkdir -p "$(dirname "$state_file")"
    echo "$CURRENT_MISSED_BLOCKS" > "$state_file"

    local CURRENT_DAY=$(date +%j)
    local LAST_REPORTED_DAY=0 # Переименовал LAST_DAY для ясности

    if [ -f "$daily_report_file" ] && [[ "$(cat "$daily_report_file")" =~ ^[0-9]+$ ]]; then
        LAST_REPORTED_DAY=$(cat "$daily_report_file")
    else
        log_debug "Файл последнего отчета (${daily_report_file}) для ${node_name} (${MONIKER}) не числовой или отсутствует, сброс LAST_REPORTED_DAY до 0."
    fi

    # Если текущий день отличается от дня последнего отчета
    if [ "$CURRENT_DAY" -ne "$LAST_REPORTED_DAY" ]; then
        log_debug "Обнаружен новый день для ${node_name} (${MONIKER}). Текущий день: ${CURRENT_DAY}, Последний день отчета: ${LAST_REPORTED_DAY}."

        # *** ВАЖНОЕ ИЗМЕНЕНИЕ: Сначала обновляем файлы состояния для текущего дня ***
        # Это предотвратит отправку дублирующих отчетов, если скрипт запустится несколько раз в один и тот же новый день.
        echo "$CURRENT_DAY" > "$daily_report_file"
        echo "$CURRENT_MISSED_BLOCKS" > "$daily_counter_file"
        log_debug "Суточный счетчик и отметка дня для ${node_name} (${MONIKER}) обновлены до CURRENT_MISSED_BLOCKS: ${CURRENT_MISSED_BLOCKS} и CURRENT_DAY: ${CURRENT_DAY}."

        local YESTERDAY_COUNTER=0
        # Теперь читаем YESTERDAY_COUNTER. Он может быть равен CURRENT_MISSED_BLOCKS,
        # если это первый запуск в новом дне и предыдущего счетчика не было,
        # или если мы только что его обновили.
        # В данном случае, YESTERDAY_COUNTER фактически становится счетчиком на момент начала нового дня.
        if [ -f "$daily_counter_file" ] && [[ "$(cat "$daily_counter_file")" =~ ^[0-9]+$ ]]; then
            YESTERDAY_COUNTER=$(cat "$daily_counter_file")
        else
            log_debug "Файл счетчика ежедневного отчета (${daily_counter_file}) для ${node_name} (${MONIKER}) не числовой или отсутствует, сброс YESTERDAY_COUNTER до 0."
        fi

        # Отправляем отчет только если YESTERDAY_COUNTER (который теперь отражает счетчик на начало этого дня)
        # не равен 0, чтобы избежать отправки отчетов для только что запущенных нод.
        if [ "$YESTERDAY_COUNTER" -ne 0 ]; then
            local MISSED_FOR_24H=$((CURRENT_MISSED_BLOCKS - YESTERDAY_COUNTER))
            if (( MISSED_FOR_24H < 0 )); then
                MISSED_FOR_24H=0 # На случай сброса счетчика или ошибки
            fi
            log_debug "ОТПРАВКА_СУТОЧНОГО_ОТЧЕТА_ВЫЗВАНА_ДЛЯ: ${node_name^^} (${MONIKER})"
            send_telegram "📊 Ежедневный отчёт для ${node_name^^} (${MONIKER}):%0AЗа сутки пропущено: ${MISSED_FOR_24H} блоков.%0AТекущий счетчик: ${CURRENT_MISSED_BLOCKS}." "REPORT" "INFO"
        else
            log_debug "YESTERDAY_COUNTER для ${node_name} (${MONIKER}) равен 0 или не удалось прочитать после обновления. Ежедневный отчет не отправлен."
        fi
    else
        log_debug "Текущий день (${CURRENT_DAY}) равен LAST_REPORTED_DAY (${LAST_REPORTED_DAY}) для ${node_name} (${MONIKER}). Ежедневный отчет не требуется."
    fi
}

# --- ЗАПУСК ОСНОВНОЙ ЛОГИКИ ДЛЯ ВСЕХ СЕТЕЙ ---
for NODE_NAME_KEY in "${NETWORK_NAMES[@]}"; do
    NODE_NAME=${NODE_NAME_KEY}

    log_debug "--- Начинаем проверку для сети: ${NODE_NAME} ---"

    if [[ -z "${NETWORKS[${NODE_NAME},REST_API_BASE_URL]}" ]]; then
        send_telegram "⚠️  ОШИБКА КОНФИГУРАЦИИ:%0A Отсутствует REST_API_BASE_URL для сети ${NODE_NAME^^}.%0A Пропускаю мониторинг этой сети." "ALERT"
        log_debug "Отсутствует REST_API_BASE_URL для ${NODE_NAME}. Пропускаю мониторинг этой сети."
        continue
    fi

    # REST_API_BASE_URL для текущей сети
    REST_API_BASE_URL=${NETWORKS[${NODE_NAME},REST_API_BASE_URL]}
    VALOPER_ADDRESS=${NETWORKS[${NODE_NAME},VALOPER_ADDRESS]}
    PUBKEY_JSON=${NETWORKS[${NODE_NAME},PUBKEY_JSON]}

    STATE_FILE="${BASE_STATE_DIR}/missed_blocks_state_${NODE_NAME}.txt"
    DAILY_REPORT_FILE="${BASE_STATE_DIR}/daily_report_state_${NODE_NAME}.txt"

    # Проверка здоровья ноды через REST API
    if ! check_node_health "$NODE_NAME" "$REST_API_BASE_URL" "$GLOBAL_DEBUG"; then
        log_debug "Проверка здоровья ноды ${NODE_NAME} провалена. Пропускаем дальнейшие проверки для этой сети."
        continue
    fi

    # Проверки, зависящие от настроек валидатора (если VALOPER_ADDRESS и PUBKEY_JSON указаны)
    # Теперь check_missed_blocks также проверяет jailed статус
    if ! check_missed_blocks "$NODE_NAME" "$REST_API_BASE_URL" "$VALOPER_ADDRESS" "$PUBKEY_JSON" "$GLOBAL_DEBUG" "$STATE_FILE" "$DAILY_REPORT_FILE"; then
        log_debug "Проверка пропущенных блоков/jailed статуса для ${NODE_NAME} провалена или валидатор в тюрьме. Пропускаем дальнейшие проверки."
        continue
    fi

    log_debug "--- Проверка для сети: ${NODE_NAME} завершена ---"
    log_debug "" # Для пустой строки

    # Небольшая пауза между проверками разных сетей
    if [[ "$NODE_NAME_KEY" != "${NETWORK_NAMES[${#NETWORK_NAMES[@]}-1]}" ]]; then # Если это не последняя сеть
        log_debug "Пауза ${DELAY_BETWEEN_NETWORKS_SECONDS} секунд перед следующей сетью."
        sleep "$DELAY_BETWEEN_NETWORKS_SECONDS"
    fi
done

# --- Завершающий разделитель для дебаг-лога ---
if [ "$GLOBAL_DEBUG" = true ]; then
    log_debug "----------------------------------------------------------------------------"
    log_debug "Завершение скрипта мониторинга здоровья нод (удаленный). Время: $(date -u -R)"
    log_debug "----------------------------------------------------------------------------"
    log_debug "" # Пустая строка для дополнительного разделения между запусками
fi

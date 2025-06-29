#!/bin/bash

# health_monitor_v2_remote_api.sh
# Запускать с флагом --debug для получения подробного режима. Пример: bash health_monitor_v2_remote_api.sh --debug

# --- ОБЩИЕ НАСТРОЙКИ УВЕДОМЛЕНИЙ TELEGRAM (ОБЯЗАТЕЛЬНО ЗАПОЛНИТЬ ВРУЧНУЮ!) ---
TELEGRAM_BOT_TOKEN="7742907053:AAEBXUpVX272V2bIQ" # ЗАПОЛНИТЬ! Вставьте токен вашего Telegram-бота
TELEGRAM_ALERT_CHAT_IDS=( "-47676" ) # ЗАПОЛНИТЬ! Метка ALERT
TELEGRAM_REPORT_CHAT_IDS=("-47676" ) # ЗАПОЛНИТЬ при желании, канал для отчётов. Метка REPORTS
TELEGRAM_INFO_CHAT_IDS=() # ЗАПОЛНИТЬ при желании, канал для информации. Метка INFO

# --- ГЛОБАЛЬНЫЕ НАСТРОЙКИ URL ---
# Базовый URL для REST API прокси от cosmos.directory.
DEFAULT_COSMOS_DIRECTORY_URL="https://rest.cosmos.directory"


# --- НАСТРОЙКИ СЕТЕЙ (ОБЯЗАТЕЛЬНО ЗАПОЛНИТЬ ВРУЧНУЮ ДЛЯ КАЖДОЙ НОДЫ!) ---

# ВНИМАНИЕ: Теперь все переменные для каждой сети находятся здесь, в одном месте.
# REST_API_BASE_URL будет формироваться из DEFAULT_COSMOS_DIRECTORY_URL и имени сети.

# --- НАСТРОЙКИ ДЛЯ СЕТИ Nolus (NET_1) ---
NET_1="Nolus" # Имя сети для отображения
NET_1_VALOPER_ADDRESS="nolusvaloper1...." # ВАШ VALOPER АДРЕС
NET_1_VALCONS_ADDRESS="nolusvalcons1...." # ВАШ КОНСЕНСУСНЫЙ АДРЕС ВАЛИДАТОРА
NET_1_USER_TAG="@Dry" # Тег пользователя для оповещений по Nolus. Оставьте пустым ("") если не нужен.

# --- НАСТРОЙКИ ДЛЯ СЕТИ Sommelier (NET_2) ---
NET_2="Sommelier" # Имя сети для отображения
NET_2_VALOPER_ADDRESS="sommvaloper1...." # ВАШ VALOPER АДРЕС
NET_2_VALCONS_ADDRESS="sommvalcons1...." # ВАШ КОНСЕНСУСНЫЙ АДРЕС ВАЛИДАТОРА
NET_2_USER_TAG="@Dry" # Тег пользователя для оповещений по Sommelier. Оставьте пустым ("") если не нужен.
# Примечание: Для работы тегов пользователей в Telegram обычно требуется префикс '@'.
# Убедитесь, что пользовательские теги начинаются с '@' (например, "@Mr.D0B").

# --- Пример для NET_3 (если требуется) ---
# NET_3="Juno"
# NET_3_VALOPER_ADDRESS="junovaloper1...."
# NET_3_VALCONS_ADDRESS="junovalcons1...."
# NET_3_USER_TAG="@Ksu"

# NET_4="Sentinel"
# NET_4_VALOPER_ADDRESS="sentvaloper1...."
# NET_4_VALCONS_ADDRESS="sentvalcons1...."
# NET_4_USER_TAG="@Ksu"

# NET_5="Stargaze"
# NET_5_VALOPER_ADDRESS="starsvaloper...."
# NET_5_VALCONS_ADDRESS="starsvalcons1..."
# NET_5_USER_TAG="@Aki"

# NET_6="Persistence"
# NET_6_VALOPER_ADDRESS="persistencevaloper1...."
# NET_6_VALCONS_ADDRESS="persistencevalcons1...."
# NET_6_USER_TAG="@Aki"

# NET_7="Lava"
# NET_7_VALOPER_ADDRESS="lava@valoper1...."
# NET_7_VALCONS_ADDRESS="lava@valcons1...."
# NET_7_USER_TAG="@Mih"


MISSED_BLOCKS_THRESHOLD=10
CRON_INTERVAL=10 # Интервал, как часто этот скрипт будет запускаться (в минутах)

# Базовая директория для файлов состояния скрипта.
CURRENT_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_STATE_DIR="${CURRENT_SCRIPT_DIR}"

# Файл для логов отладки. Он будет находиться в той же директории, что и сам скрипт.
DEBUG_LOG_FILE="${CURRENT_SCRIPT_DIR}/health_debug.log"

# --- ОБРАБОТКА АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ И НАСТРОЙКА ЛОГИРОВАНИЯ ---
GLOBAL_DEBUG=false # По умолчанию режим отладки выключен.
# Безопасная проверка $1, чтобы избежать "unbound variable"
if [[ "${1:-}" == "--debug" ]]; then # Проверяем, если $1 существует и равен "--debug"
    GLOBAL_DEBUG=true # Если передан --debug, всегда включаем отладку.
fi

# --- ФУНКЦИЯ ЛОГИРОВАНИЯ ОТЛАДКИ ---
log_debug() {
    # Восстановлен полный формат даты и времени для логов отладки
    if [ "$GLOBAL_DEBUG" = true ]; then
#        echo "[DEBUG] $1" >> "$DEBUG_LOG_FILE"
	echo "[DEBUG] $1" >&2
    fi
}

# Добавляем разделитель в начале лога, если включен дебаг
if [ "$GLOBAL_DEBUG" = true ]; then
    log_debug "----------------------------------------------------------------------------"
    log_debug "Запуск скрипта мониторинга здоровья нод (удаленный). Время: $(date -u -R)"
    log_debug "----------------------------------------------------------------------------"
fi


# --- КОНФИГУРАЦИИ СЕТЕЙ (Сборка из верхних переменных) ---
declare -A NETWORKS

# Список имен сетей для итерации (порядок важен)
declare -a NETWORK_NAMES=( "$NET_1" "$NET_2" ) # "$NET_3" "$NET_4" "$NET_5" "$NET_6" "$NET_7"  Добавьте в этот массив больше сетей, если используете.


# Nolus
NETWORKS[${NET_1},REST_API_BASE_URL]="${DEFAULT_COSMOS_DIRECTORY_URL}/${NET_1,,}"
NETWORKS[${NET_1},VALOPER_ADDRESS]="${NET_1_VALOPER_ADDRESS:-}"
NETWORKS[${NET_1},VALCONS_ADDRESS]="${NET_1_VALCONS_ADDRESS:-}"
NETWORKS[${NET_1},USER_TAG]="${NET_1_USER_TAG:-}"

Sommelier
NETWORKS[${NET_2},REST_API_BASE_URL]="${DEFAULT_COSMOS_DIRECTORY_URL}/${NET_2,,}"
NETWORKS[${NET_2},VALOPER_ADDRESS]="${NET_2_VALOPER_ADDRESS:-}"
NETWORKS[${NET_2},VALCONS_ADDRESS]="${NET_2_VALCONS_ADDRESS:-}"
NETWORKS[${NET_2},USER_TAG]="${NET_2_USER_TAG:-}"

# Juno (пример)
# NETWORKS[${NET_3},REST_API_BASE_URL]="${DEFAULT_COSMOS_DIRECTORY_URL}/${NET_3,,}"
# NETWORKS[${NET_3},VALOPER_ADDRESS]="${NET_3_VALOPER_ADDRESS:-}"
# NETWORKS[${NET_3},VALCONS_ADDRESS]="${NET_3_VALCONS_ADDRESS:-}"
# NETWORKS[${NET_3},USER_TAG]="${NET_3_USER_TAG:-}"

# NETWORKS[${NET_4},REST_API_BASE_URL]="${DEFAULT_COSMOS_DIRECTORY_URL}/${NET_4,,}"
# NETWORKS[${NET_4},VALOPER_ADDRESS]="${NET_4_VALOPER_ADDRESS:-}"
# NETWORKS[${NET_4},VALCONS_ADDRESS]="${NET_4_VALCONS_ADDRESS:-}"
# NETWORKS[${NET_4},USER_TAG]="${NET_4_USER_TAG:-}"

# NETWORKS[${NET_5},REST_API_BASE_URL]="${DEFAULT_COSMOS_DIRECTORY_URL}/${NET_5,,}"
# NETWORKS[${NET_5},VALOPER_ADDRESS]="${NET_5_VALOPER_ADDRESS:-}"
# NETWORKS[${NET_5},VALCONS_ADDRESS]="${NET_5_VALCONS_ADDRESS:-}"
# NETWORKS[${NET_5},USER_TAG]="${NET_5_USER_TAG:-}"

# NETWORKS[${NET_6},REST_API_BASE_URL]="${DEFAULT_COSMOS_DIRECTORY_URL}/${NET_6,,}"
# NETWORKS[${NET_6},VALOPER_ADDRESS]="${NET_6_VALOPER_ADDRESS:-}"
# NETWORKS[${NET_6},VALCONS_ADDRESS]="${NET_6_VALCONS_ADDRESS:-}"
# NETWORKS[${NET_6},USER_TAG]="${NET_6_USER_TAG:-}"


# NETWORKS[${NET_7},REST_API_BASE_URL]="${DEFAULT_COSMOS_DIRECTORY_URL}/${NET_7,,}"
# NETWORKS[${NET_7},VALOPER_ADDRESS]="${NET_7_VALOPER_ADDRESS:-}"
# NETWORKS[${NET_7},VALCONS_ADDRESS]="${NET_7_VALCONS_ADDRESS:-}"
# NETWORKS[${NET_7},USER_TAG]="${NET_7_USER_TAG:-}"

# Проверка наличия jq
command -v jq >/dev/null 2>&1 || { echo >&2 "jq не установлен. Установите его командой sudo apt install jq"; exit 1; }
# Проверка наличия curl
command -v curl >/dev/null 2>&1 || { echo >&2 "curl не установлен. Установите его командой sudo apt install curl"; exit 1; }

# --- ОБЪЯВЛЕНИЕ ЧИСЛОВЫХ ПЕРЕМЕННЫХ ---
# Явное объявление числового типа для надежности
declare -i MAX_RETRIES=6        # Максимальное количество попыток получить данные (1 = одна попытка без повторов)
declare -i RETRY_DELAY_SECONDS=15 # Задержка между попытками в секундах
declare -i DELAY_BETWEEN_NETWORKS_SECONDS=10 # Пауза между проверками сетей (по умолчанию 10 секунд)


# --- ОТПРАВКА СООБЩЕНИЙ В TELEGRAM ---
# send_telegram "message_body" "опциональный_тег_пользователя" "тип1" "тип2" ...
send_telegram() {
    local message_body="$1" # Ожидается сообщение без Markdown форматирования
    local network_user_tag="$2" # Новый параметр для специфического тега пользователя
    shift 2 # Смещаем параметры, чтобы message_body и network_user_tag были обработаны
    local types=("$@") # Остальные параметры - это типы сообщений (ALERT, REPORT, INFO)
    local full_message="$message_body"

    # Применяем network_user_tag для типов ALERT, если он предоставлен
    if [[ " ${types[@]} " =~ " ALERT " ]] && [[ -n "$network_user_tag" ]]; then
        full_message="${full_message} ${network_user_tag}"
    fi

    for type in "${types[@]}"; do
        local chat_array_name="TELEGRAM_${type}_CHAT_IDS[@]" # Имя переменной массива с @[]

        # Безопасно получаем содержимое массива по имени, используя eval
        local -a chat_ids_to_send
        # eval "chat_ids_to_send=(\"\${${chat_array_name}}\")"
        # Более простой и прямой способ:
        local -n ref_chat_ids="TELEGRAM_${type}_CHAT_IDS" # Создаем nameref для прямого доступа к массиву

        # Проверяем, существует ли массив (уже делается выше, но здесь для надежности) И есть ли в нем элементы
        if [ "${#ref_chat_ids[@]}" -eq 0 ]; then
            log_debug "send_telegram: Массив чатов 'TELEGRAM_${type}_CHAT_IDS' пуст или не существует. Пропускаем отправку для типа '${type}'."
            continue
        fi

        for CHAT_ID in "${ref_chat_ids[@]}"; do # Итерируем напрямую по элементам массива через nameref
            # Финальная проверка на пустоту перед отправкой curl
            if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
                log_debug "WARN: TELEGRAM_BOT_TOKEN или CHAT_ID для типа '${type}' не настроен. Пропускаем Telegram-уведомление."
                continue # Переходим к следующему CHAT_ID, если текущий пуст
            fi

            log_debug "Отправка сообщения типа '${type}' в чат ID: ${CHAT_ID}"

            # Захватываем ответ от Telegram API для отладки
            local curl_response=$(curl -s --show-error -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                -d chat_id="$CHAT_ID" \
                -d text="$full_message")

            local curl_exit_code=$? # Захватываем код выхода curl

            if [ "$GLOBAL_DEBUG" = true ]; then
                # Логируем полный ответ от Telegram API
                log_debug "Telegram API response for chat ID '${CHAT_ID}': ${curl_response}"
            fi

            if [ "$curl_exit_code" -ne 0 ]; then
                # Логируем ошибку, если curl не смог отправить запрос (например, проблемы с сетью)
                log_debug "ERROR: Не удалось отправить Telegram-сообщение типа '${type}' в чат ID: ${CHAT_ID}. Код выхода curl: ${curl_exit_code}. Ответ: '${curl_response}'"
            fi
        done
    done
}

# --- ПРОВЕРКА REST API И СИНХРОНИЗАЦИИ ---
check_node_health() {
    local node_name="$1"
    local rest_api_base_url="$2"
    local current_user_tag="$3" # Получаем тег пользователя

    if [ -z "$rest_api_base_url" ]; then
        send_telegram "⚠️    ОШИБКА КОНФИГУРАЦИИ: REST API URL не указан!%0AСеть: ${node_name^^}%0AПричина: Базовый URL REST API не указан в конфиге.%0AПроверьте настройки." "${current_user_tag}" "ALERT"
        log_debug "Базовый URL REST API для ${node_name} не указан. Проверка здоровья ноды пропущена."
        return 1
    fi

    log_debug "Начинаем проверку доступности REST API для ${node_name} по URL: ${rest_api_base_url} (запрос /cosmos/staking/v1beta1/params)."

    # Используем /cosmos/staking/v1beta1/params как общий индикатор доступности REST API прокси.
    local health_check_url="${rest_api_base_url}/cosmos/staking/v1beta1/params"

    local health_check_output=""
    local success_health_check=false
    local last_error_message=""

    # --- Логика повторных попыток для проверки доступности REST API ---
    if ! [[ "$MAX_RETRIES" =~ ^[0-9]+$ ]]; then
        log_debug "WARN: MAX_RETRIES не является числом (${MAX_RETRIES}). Устанавливаю значение по умолчанию: 3."
        MAX_RETRIES=3
    fi
    for (( attempt=1; attempt<=$MAX_RETRIES; attempt++ )); do
        log_debug "Попытка ${attempt}/${MAX_RETRIES} проверки доступности REST API для ${node_name} (URL: ${health_check_url})."
        if health_check_output=$(curl -s --fail --max-time 15 "$health_check_url" 2>&1); then
            # Проверяем, что ответ - валидный JSON и содержит .params
            if echo "$health_check_output" | jq -e '.params' >/dev/null 2>&1; then
                success_health_check=true
                break # Успех, выходим из цикла попыток
            else
                last_error_message="JSON ответ не содержит 'params' или невалиден: ${health_check_output}"
                log_debug "JSON валидация health_check провалена для ${node_name} (попытка ${attempt}). Ошибка: '${last_error_message}'"
            fi
        else
            last_error_message="$health_check_output"
            log_debug "Попытка ${attempt} проверки health_check провалена для ${node_name}. Ошибка: '${last_error_message}'"
        fi

        if [ "$attempt" -lt "$MAX_RETRIES" ]; then
            sleep "$RETRY_DELAY_SECONDS"
        fi
    done

    if [ "$success_health_check" = false ]; then
        send_telegram "⛔️ НОДА НЕДОСТУПНА!%0AСеть: ${node_name^^}%0AURL REST API: ${rest_api_base_url}%0AПричина: Не отвечает или ответ невалиден после ${MAX_RETRIES} попыток.%0AПоследняя ошибка: ${last_error_message}" "${current_user_tag}" "ALERT"
        log_debug "REST API для ${node_name} недоступен/невалиден после ${MAX_RETRIES} попыток. Ошибка: '${last_error_message}'"
        return 1
    fi
    log_debug "REST API для ${node_name} доступен после 1 попыток."

    log_debug "Проверка синхронизации через '/cosmos/base/tendermint/v1beta1/sync_info' на cosmos.directory/chain_name недоступна (HTTP 501)."
    log_debug "Для целей данного скрипта, если '/cosmos/staking/v1beta1/params' отвечает, считаем ноду условно живой."

    return 0
}

# --- ПРОВЕРКА ПРОПУЩЕННЫХ БЛОКОВ И JAIL СТАТУСА ---
check_missed_blocks() {
    local node_name="$1"
    local rest_api_base_url="$2"
    local valoper_address="$3"
    local valcons_address="$4" # Консенсусный адрес валидатора
    local current_user_tag="$5" # Получаем тег пользователя
    local state_file="$6"
    local daily_report_file="$7"
    local daily_counter_file="${daily_report_file}.counter"

    if [ -z "$valoper_address" ] || [ -z "$valcons_address" ]; then
        send_telegram "⚠️ ОШИБКА КОНФИГУРАЦИИ: Неполные данные валидатора!%0AСеть: ${node_name^^}%0AПричина: VALOPER_ADDRESS или VALCONS_ADDRESS не указаны.%0AПроверка пропущена." "${current_user_tag}" "ALERT"
        log_debug "VALOPER_ADDRESS или VALCONS_ADDRESS для ${node_name} не указаны. Проверка пропущенных блоков и jailed статуса пропущена."
        return 1
    fi

    # 1. Получаем статус валидатора и jailed-статус через Staking REST API
    local validator_status_url="${rest_api_base_url}/cosmos/staking/v1beta1/validators/${valoper_address}"
    local validator_info_output=""
    local success_validator_info=false
    local last_validator_error_message=""

    if ! [[ "$MAX_RETRIES" =~ ^[0-9]+$ ]]; then
        log_debug "WARN: MAX_RETRIES не является числом (${MAX_RETRIES}). Устанавливаю значение по умолчанию: 3."
        MAX_RETRIES=3
    fi
    for (( attempt=1; attempt<=$MAX_RETRIES; attempt++ )); do
        log_debug "Попытка ${attempt}/${MAX_RETRIES} получения статуса валидатора (staking) для ${node_name}."
        if validator_info_output=$(curl -s --fail --max-time 15 "$validator_status_url" 2>&1); then
            # Проверяем, что ответ - валидный JSON и содержит .validator
            if echo "$validator_info_output" | jq -e '.validator' >/dev/null 2>&1; then
                success_validator_info=true
                break
            else
                last_validator_error_message="JSON ответ не содержит 'validator' или невалиден: ${validator_info_output}"
                log_debug "JSON валидация статуса валидатора провалена для ${node_name} (попытка ${attempt}). Ошибка: '${last_validator_error_message}'"
            fi
        else
            last_validator_error_message="$validator_info_output"
            log_debug "Попытка ${attempt} получения статуса валидатора провалена для ${node_name}. Ошибка: '${last_validator_error_message}'"
        fi
        if [ "$attempt" -lt "$MAX_RETRIES" ]; then
            sleep "$RETRY_DELAY_SECONDS"
        fi
    done

    # Извлекаем моникер валидатора
    local MONIKER_RAW=$(echo "$validator_info_output" | jq -r '(.validator.description.moniker // .description.moniker // "Неизвестный моникер")')
    local MONIKER="$MONIKER_RAW"
    log_debug "Моникер валидатора ${node_name}: '${MONIKER_RAW}'"

    if [ "$success_validator_info" = false ]; then
        send_telegram "❌ ОШИБКА ЗАПРОСА СТАТУСА ВАЛИДАТОРА (Staking)!%0AСеть: ${node_name^^}%0AВалидатор: ${MONIKER}%0AПричина: Не удалось получить статус валидатора после ${MAX_RETRIES} попыток.%0AПоследняя ошибка: ${last_validator_error_message}%0AПроверьте REST API или VALOPER_ADDRESS." "${current_user_tag}" "ALERT"
        log_debug "Ошибка запроса staking validator для ${node_name} после ${MAX_RETRIES} попыток. Пропускаем дальнейшие проверки. Ошибка: '${last_validator_error_message}'"
#       echo "Ошибка запроса staking validator для ${node_name} после ${MAX_RETRIES} попыток. Пропускаем дальнейшие проверки. Ошибка: '${last_validator_error_message}'"
	return 1
	
    fi
    log_debug "Получены данные staking validator для ${node_name}:\n${validator_info_output}"

    local IS_JAILED="false"
    local jailed_until_time=""

    # Универсальная обработка jailed статуса
    local jailed_raw=$(echo "$validator_info_output" | jq -r '(.validator.jailed // .jailed // "false") | tostring')
    if [[ "$jailed_raw" == "true" ]]; then
        IS_JAILED="true"
        log_debug "Валидатор ${node_name} (${MONIKER_RAW}) помечен как 'jailed: true' в Staking API."
    else
        log_debug "Валидатор ${node_name} (${MONIKER_RAW}) не помечен как 'jailed: true' в Staking API (raw value: ${jailed_raw})."
    fi

    # Универсальная обработка unbonding_time / jailed_until
    local unbonding_or_jailed_until_raw=$(echo "$validator_info_output" | jq -r '(.validator.unbonding_time // .validator.jailed_until // empty)')
    log_debug "Raw unbonding_time / jailed_until from staking validator for ${node_name} (${MONIKER_RAW}): '${unbonding_or_jailed_until_raw}'"

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
                    log_debug "Дата освобождения ${node_name} (${MONIKER_RAW}) в будущем: ${jailed_until_date_formatted}"
                else
                    jailed_until_date_formatted="срок истек: $(date -d @${jailed_until_timestamp} +"%Y-%m-%d %H:%M:%S %Z" 2>/dev/null)"
                    log_debug "Дата освобождения ${node_name} (${MONIKER_RAW}) истекла: ${jailed_until_date_formatted}"
                fi
            else
                log_debug "Не удалось распарсить метку времени jailed_until для ${node_name} (${MONIKER_RAW}) из '${unbonding_or_jailed_until_raw}'."
            fi
        else
            log_debug "jailed_until для ${node_name} (${MONIKER_RAW}) является пустой, null, 0001-01-01Z или 1970-01-01Z: '${unbonding_or_jailed_until_raw}'."
        fi

        send_telegram "🚨 ВНИМАНИЕ: ВАЛИДАТОР В ТЮРЬМЕ!%0AСеть: ${node_name^^}%0AВалидатор: ${MONIKER}%0AСрок: ${jailed_until_date_formatted}" "${current_user_tag}" "ALERT"
        log_debug "Валидатор ${node_name} (${MONIKER_RAW}) в тюрьме. Пропускаем дальнейшие проверки пропущенных блоков."
        return 1 # Если валидатор в тюрьме, нет смысла проверять пропущенные блоки.
    fi

    # 2. Получаем missed_blocks_counter через Slashing Signing-Info (для конкретного VALCONS_ADDRESS) REST API
    local signing_info_url="${rest_api_base_url}/cosmos/slashing/v1beta1/signing_infos/${valcons_address}"
    local signing_info_output=""
    local success_signing_info=false
    local last_signing_info_error_message=""

    if ! [[ "$MAX_RETRIES" =~ ^[0-9]+$ ]]; then
        log_debug "WARN: MAX_RETRIES не является числом (${MAX_RETRIES}). Устанавливаю значение по умолчанию: 3."
        MAX_RETRIES=3
    fi
    for (( attempt=1; attempt<=$MAX_RETRIES; attempt++ )); do
        log_debug "Попытка ${attempt}/${MAX_RETRIES} получения signing-info для ${node_name} (${MONIKER_RAW}) по VALCONS_ADDRESS: ${valcons_address}."
        if signing_info_output=$(curl -s --fail --max-time 20 "$signing_info_url" 2>&1); then
            if echo "$signing_info_output" | jq -e '.val_signing_info' >/dev/null 2>&1; then
                success_signing_info=true
                break
            else
                last_signing_info_error_message="JSON ответ не содержит 'val_signing_info' или невалиден: ${signing_info_output}"
                log_debug "JSON валидация signing-info провалена для ${node_name} (попытка ${attempt}). Ошибка: '${last_signing_info_error_message}'"
            fi
        else
            last_signing_info_error_message="$signing_info_output"
            log_debug "Попытка ${attempt} получения signing-info провалена для ${node_name}. Ошибка: '${last_signing_info_error_message}'"
        fi
        if [ "$attempt" -lt "$MAX_RETRIES" ]; then
            sleep "$RETRY_DELAY_SECONDS"
        fi
    done

    if [ "$success_signing_info" = false ]; then
        send_telegram "❌ ОШИБКА ЗАПРОСА SIGNING-INFO!%0AСеть: ${node_name^^}%0AВалидатор: ${MONIKER}%0AVALCONS: ${valcons_address}%0AПричина: Не удалось получить signing-info после ${MAX_RETRIES} попыток.%0AПоследняя ошибка: ${last_signing_info_error_message}%0AПроверьте REST API или VALCONS_ADDRESS." "${current_user_tag}" "ALERT"
        log_debug "Ошибка при получении signing-info для ${node_name} (${MONIKER_RAW}) после ${MAX_RETRIES} попыток. Пропускаем проверку missed_blocks. Ошибка: '${last_signing_info_error_message}'"
        return 1
    fi
    log_debug "Получены данные signing-info для ${node_name} (${MONIKER_RAW}):\n${signing_info_output}"


    local CURRENT_MISSED_BLOCKS=0
    CURRENT_MISSED_BLOCKS=$(echo "$signing_info_output" | jq -r '.val_signing_info.missed_blocks_counter | tonumber? // "0"')
    log_debug "Successfully parsed missed_blocks_counter for ${node_name} (${MONIKER_RAW}): ${CURRENT_MISSED_BLOCKS}."


    local LAST_MISSED_BLOCKS=0
    if [ -f "$state_file" ] && [[ "$(cat "$state_file")" =~ ^[0-9]+$ ]]; then
        LAST_MISSED_BLOCKS=$(cat "$state_file")
    else
        log_debug "Предыдущее значение missed_blocks для ${node_name} (${MONIKER_RAW}) не числовое или файл отсутствует, сброс до 0."
    fi

    local NEWLY_MISSED_BLOCKS=$((CURRENT_MISSED_BLOCKS - LAST_MISSED_BLOCKS))
    log_debug "Проверка ${node_name} (${MONIKER_RAW}): новых пропущенных блоков за ${CRON_INTERVAL} минут: ${NEWLY_MISSED_BLOCKS}. Общий: ${CURRENT_MISSED_BLOCKS}."

    if [ "$NEWLY_MISSED_BLOCKS" -ge "$MISSED_BLOCKS_THRESHOLD" ] && [ "$NEWLY_MISSED_BLOCKS" -gt 0 ]; then
        send_telegram "🚨 ТРЕВОГА: Пропущены блоки!%0AСеть: ${node_name^^}%0AВалидатор: ${MONIKER}%0AНовых пропусков: ${NEWLY_MISSED_BLOCKS} за ${CRON_INTERVAL} мин.%0AОбщий счетчик: ${CURRENT_MISSED_BLOCKS}." "${current_user_tag}" "ALERT"
    fi

    mkdir -p "$(dirname "$state_file")"
    echo "$CURRENT_MISSED_BLOCKS" > "$state_file"

    local CURRENT_DAY=$(date +%j)
    local LAST_REPORTED_DAY=0

    if [ -f "$daily_report_file" ] && [[ "$(cat "$daily_report_file")" =~ ^[0-9]+$ ]]; then
        LAST_REPORTED_DAY=$(cat "$daily_report_file")
    else
        log_debug "Файл последнего отчета (${daily_report_file}) для ${node_name} (${MONIKER_RAW}) не числовой или отсутствует, сброс LAST_REPORTED_DAY до 0."
    fi

    # Если текущий день отличается от дня последнего отчета
    if [ "$CURRENT_DAY" -ne "$LAST_REPORTED_DAY" ]; then
        log_debug "Обнаружен новый день для ${node_name} (${MONIKER_RAW}). Текущий день: ${CURRENT_DAY}, Последний день отчета: ${LAST_REPORTED_DAY}."

        # *** ВАЖНОЕ ИЗМЕНЕНИЕ: Сначала обновляем файлы состояния для текущего дня ***
        # Это предотвратит отправку дублирующих отчетов, если скрипт запустится несколько раз в один и тот же новый день.
        echo "$CURRENT_DAY" > "$daily_report_file"
        echo "$CURRENT_MISSED_BLOCKS" > "$daily_counter_file"
        log_debug "Суточный счетчик и отметка дня для ${node_name} (${MONIKER_RAW}) обновлены до CURRENT_MISSED_BLOCKS: ${CURRENT_MISSED_BLOCKS} и CURRENT_DAY: ${CURRENT_DAY}."

        local YESTERDAY_COUNTER=0
        if [ -f "$daily_counter_file" ] && [[ "$(cat "$daily_counter_file")" =~ ^[0-9]+$ ]]; then
            YESTERDAY_COUNTER=$(cat "$daily_counter_file")
        else
            log_debug "Файл счетчика ежедневного отчета (${daily_counter_file}) для ${node_name} (${MONIKER_RAW}) не числовой или отсутствует, сброс YESTERDAY_COUNTER до 0."
        fi

        # Отправляем отчет только если YESTERDAY_COUNTER (который теперь отражает счетчик на начало этого дня)
        # не равен 0, чтобы избежать отправки отчетов для только что запущенных нод.
        if [ "$YESTERDAY_COUNTER" -ne 0 ]; then
            local MISSED_FOR_24H=$((CURRENT_MISSED_BLOCKS - YESTERDAY_COUNTER))
            if (( MISSED_FOR_24H < 0 )); then
                MISSED_FOR_24H=0 # На случай сброса счетчика или ошибки
            fi
            log_debug "ОТПРАВКА_СУТОЧНОГО_ОТЧЕТА_ВЫЗВАНА_ДЛЯ: ${node_name^^} (${MONIKER_RAW})"
            send_telegram "📊 Ежедневный отчёт%0A%0AСеть: ${node_name^^}%0AВалидатор: ${MONIKER}%0AЗа сутки пропущено: ${MISSED_FOR_24H} блоков.%0AТекущий счетчик: ${CURRENT_MISSED_BLOCKS}." "${current_user_tag}" "REPORT" "INFO"
        else
            log_debug "YESTERDAY_COUNTER для ${node_name} (${MONIKER_RAW}) равен 0 или не удалось прочитать после обновления. Ежедневный отчет не отправлен."
        fi
    else
        log_debug "Текущий день (${CURRENT_DAY}) равен LAST_REPORTED_DAY (${LAST_REPORTED_DAY}) для ${node_name} (${MONIKER_RAW}). Ежедневный отчет не требуется."
    fi
    # Возвращаем неэкранированный моникер для использования в дебаг-сообщении
    echo "$MONIKER_RAW" # Это "возвращает" значение
    return 0
}

# Объявляем переменные глобально, чтобы избежать ошибок "local: can only be used in a function"
# и чтобы они были доступны для send_telegram в конце цикла.
MONIKER_OUTPUT=""
CHECK_MISSED_BLOCKS_STATUS=0
MONIKER_FOR_DEBUG_MSG=""
MONIKER_DISPLAY_PART=""

# --- ЗАПУСК ОСНОВНОЙ ЛОГИКИ ДЛЯ ВСЕХ СЕТЕЙ ---
# Объявляем CURRENT_USER_TAG глобально или без 'local' в цикле
CURRENT_USER_TAG=""
for NODE_NAME_KEY in "${NETWORK_NAMES[@]}"; do
    NODE_NAME=${NODE_NAME_KEY}

# --- СООБЩЕНИЕ О НАЧАЛЕ ПРОВЕРКИ СЕТИ (ВСЕГДА В ЛОГ) ---
#    echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] Начинаем проверку для сети: ${NODE_NAME}..."

    log_debug "--- Начинаем проверку для сети: ${NODE_NAME} ---"

    # Получаем тег пользователя для текущей сети. Если не задан, будет пустой строкой.
    CURRENT_USER_TAG="${NETWORKS[${NODE_NAME},USER_TAG]:-}"

    # Добавляем :- для безопасного извлечения значений из массива NETWORKS
    REST_API_BASE_URL="${NETWORKS[${NODE_NAME},REST_API_BASE_URL]:-}"
    VALOPER_ADDRESS="${NETWORKS[${NODE_NAME},VALOPER_ADDRESS]:-}"
    VALCONS_ADDRESS="${NETWORKS[${NODE_NAME},VALCONS_ADDRESS]:-}"

    if [[ -z "$REST_API_BASE_URL" ]]; then # Проверяем здесь уже безопасную переменную
        send_telegram "⚠️ ОШИБКА КОНФИГУРАЦИИ: REST API URL не указан!%0A%0AСеть: ${NODE_NAME^^}%0AПричина: Базовый URL REST API не указан в конфиге.%0AПропускаю мониторинг этой сети." "${CURRENT_USER_TAG}" "ALERT"
        log_debug "Отсутствует REST_API_BASE_URL для ${NODE_NAME}. Пропускаю мониторинг этой сети."
        continue
    fi

    STATE_FILE="${BASE_STATE_DIR}/missed_blocks_state_${NODE_NAME}.txt"
    DAILY_REPORT_FILE="${BASE_STATE_DIR}/daily_report_state_${NODE_NAME}.txt"

    # Проверка здоровья ноды через REST API
    if ! check_node_health "$NODE_NAME" "$REST_API_BASE_URL" "$CURRENT_USER_TAG"; then
        log_debug "Проверка здоровья ноды ${NODE_NAME} провалена. Пропускаем дальнейшие проверки для этой сети."
        continue
    fi

    # Проверки, зависящие от настроек валидатора (если VALOPER_ADDRESS и VALCONS_ADDRESS указаны)
    # Теперь check_missed_blocks также проверяет jailed статус
    # Захватываем вывод MONIKER (неэкранированный) из check_missed_blocks
    MONIKER_OUTPUT=$(check_missed_blocks "$NODE_NAME" "$REST_API_BASE_URL" "$VALOPER_ADDRESS" "$VALCONS_ADDRESS" "$CURRENT_USER_TAG" "$STATE_FILE" "$DAILY_REPORT_FILE")
    CHECK_MISSED_BLOCKS_STATUS=$? # Захватываем статус выхода функции

    if [ "$CHECK_MISSED_BLOCKS_STATUS" -ne 0 ]; then
        log_debug "Проверка пропущенных блоков/jailed статуса для ${NODE_NAME} провалена или валидатор в тюрьме. Пропускаем дальнейшие проверки."
        continue
    fi

    # Если все проверки для данной сети успешно прошли и включен режим отладки
    if [ "$GLOBAL_DEBUG" = true ]; then
        MONIKER_FOR_DEBUG_MSG=$(echo "$MONIKER_OUTPUT" | tail -n 1) # Получаем неэкранированный моникер

        MONIKER_DISPLAY_PART=""
        if [ -n "$MONIKER_FOR_DEBUG_MSG" ]; then
            MONIKER_DISPLAY_PART="${MONIKER_FOR_DEBUG_MSG}" # Больше не добавляем скобки
        fi
        send_telegram "✅ DEBUG: Все проверки пройдены!%0A%0AСеть: ${NODE_NAME^^}%0AВалидатор: ${MONIKER_DISPLAY_PART}" "${CURRENT_USER_TAG}" "INFO"
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
# --- СООБЩЕНИЕ О ПОЛНОМ ЗАВЕРШЕНИИ СКРИПТА ---
echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] Скрипт мониторинга здоровья нод полностью отработал."

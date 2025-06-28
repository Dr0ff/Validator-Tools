#!/bin/bash

# health_monitor_v3.sh
# Запускать с флагом --debug для получения подробного режима. Пример: bash health_monitor.sh --debug

# --- ОБЩИЕ НАСТРОЙКИ УВЕДОМЛЕНИЙ TELEGRAM (ОБЯЗАТЕЛЬНО ЗАПОЛНИТЬ) ---
TELEGRAM_BOT_TOKEN="77429053:AAEBMu-_ZfyTEOUpVV2bIQ" # ЗАПОЛНИТЬ! Вставьте токен вашего Telegram-бота

# ID чатов для уведомлений о предложениях.
TELEGRAM_PROPOSAL_CHAT_IDS=( "-1008302" ) # ЗАПОЛНИТЬ! Вставьте ID вашего Telegram-чата (или несколько, разделяя пробелом)

# Пользователь для тега в Telegram. Оставьте пустым (""), если не хотите никого тегать.
# Если хотите добавить больше пользователей, раскомментируйте их и можете создать новых в этом блоке и добавить их в команду
# в строке под номером #85 (этот комментарий оставлен для контекста, но строка #85 отсутствует в данном скрипте).
USER_TO_PING="" # ЗАПОЛНИТЬ ПРИ ЖЕЛАНИИ!
# USER2_TO_PING=""
# USER3_TO_PING=""


# Количество последних предложений для получения от REST API.
# Для мониторинга достаточно небольшого числа (5-10).
PROPOSALS_FETCH_LIMIT=4

# --- НАСТРОЙКИ ПОВТОРНЫХ ПОПЫТОК (ЛОГИКА ПОВТОРА ЕСЛИ НОДА НЕ ОТВЕТИЛА) ---
MAX_RETRIES=3        # Максимальное количество попыток получить данные (1 = одна попытка без повторов)
RETRY_DELAY_SECONDS=10 # Задержка между попытками в секундах
DELAY_BETWEEN_NETWORKS_SECONDS=15 # Пауза между проверками сетей (по умолчанию 5 секунд)

# Базовая директория для файлов состояния скрипта (чтобы хранить их рядом со скриптом).
CURRENT_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_STATE_DIR="${CURRENT_SCRIPT_DIR}"

# Файл для логов отладки. Он будет находиться в той же директории, что и сам скрипт.
DEBUG_LOG_FILE="${CURRENT_SCRIPT_DIR}/proposals_debug.log"

# Интервал для напоминаний о голосовании (например, 24 часа до окончания)
REMINDER_HOURS_THRESHOLD=24

# Статусы предложений, которые нужно мониторить.
# По умолчанию: предложения на стадии депозита или голосования.
PROPOSAL_STATUSES_TO_MONITOR=( "PROPOSAL_STATUS_VOTING_PERIOD" "PROPOSAL_STATUS_DEPOSIT_PERIOD" )

# --- ОБРАБОТКА АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ И НАСТРОЙКА ЛОГИРОВАНИЯ ---
GLOBAL_DEBUG=false # По умолчанию режим отладки выключен.
if [[ "$1" == "--debug" ]]; then
    GLOBAL_DEBUG=true # Если передан --debug, всегда включаем отладку.
fi

# --- ФУНКЦИЯ ЛОГИРОВАНИЯ ОТЛАДКИ ---
log_debug() {
    if [ "$GLOBAL_DEBUG" = true ]; then
        echo "[DEBUG] $1" >> "$DEBUG_LOG_FILE"
    fi
}

# Добавляем разделитель в начале лога, если включен дебаг
if [ "$GLOBAL_DEBUG" = true ]; then
    log_debug "----------------------------------------------------------------------------"
    log_debug "Запуск скрипта мониторинга предложений: proposal_monitor.sh. Время: $(date -u -R)"
    log_debug "----------------------------------------------------------------------------"
fi


# --- ОПРЕДЕЛЕНИЕ ИМЕН СЕТЕЙ И КОНФИГУРАЦИЙ ---
# Объявляем индексированный массив для хранения имен сетей.
# ВЫ МОЖЕТЕ ИЗМЕНИТЬ НАЗВАНИЯ СЕТЕЙ, УДАЛИТЬ, ДОБАВИТЬ...
declare -a NETWORK_NAMES=(
    "nolus"
    "sommelier"
    "juno"
    "stargaze"
    "persistence"
    "sentinel"
    "lava"
)

# Объявляем ассоциативный массив для хранения конфигураций сетей.
declare -A NETWORKS

# Проходим по каждому имени сети и автоматически заполняем REST_API_BASE_URL.
# Для каждой сети будет указан базовый URL REST Proxy от cosmos.directory.
# ВЕРСИЯ GOV МОДУЛЯ БУДЕТ ОПРЕДЕЛЯТЬСЯ АВТОМАТИЧЕСКИ (v1 -> v1beta1 fallback).
# Если вы хотите УСТАНОВИТЬ КОНКРЕТНУЮ ВЕРСИЮ для сети, раскомментируйте и укажите ее здесь.
for CHAIN in "${NETWORK_NAMES[@]}"; do
  # Используем имя сети в качестве ключа для REST_API_BASE_URL.
  NETWORKS[${CHAIN},REST_API_BASE_URL]="https://rest.cosmos.directory/${CHAIN}"
  # Пример: чтобы принудительно установить версию Gov для Nolus:
  # if [[ "$CHAIN" == "nolus" ]]; then
  #    NETWORKS[${CHAIN},GOV_MODULE_VERSION]="v1beta1"
  # fi
  # Пример: чтобы принудительно установить версию Gov для Sentinel (как было в оригинале):
  # if [[ "$CHAIN" == "sentinel" ]]; then
  #    NETWORKS[${CHAIN},GOV_MODULE_VERSION]="v1beta1" # !!! УБЕРИТЕ ЭТУ СТРОКУ, ЧТОБЫ ТЕСТИРОВАТЬ АВТООПРЕДЕЛЕНИЕ !!!
  # fi
done


# --- ПРОВЕРКА ЗАВИСИМОСТЕЙ ---
command -v jq >/dev/null 2>&1 || { echo >&2 "Ошибка: jq не установлен. Пожалуйста, установите его."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo >&2 "Ошибка: curl не установлен. Пожалуйста, установите его."; exit 1; }

# --- ФУНКЦИЯ ОТПРАВКИ СООБЩЕНИЙ В TELEGRAM ---
send_telegram() {
    local message="$1"
    local full_message="$message"

    if [[ -n "$USER_TO_PING" ]]; then
        full_message="${full_message} ${USER_TO_PING}"
    fi

    # Сообщения отправляются в виде обычного текста. Для новых строк используйте %0A.
    # Опция parse_mode удалена, чтобы сообщения были чистым текстом.
    for CHAT_ID in "${TELEGRAM_PROPOSAL_CHAT_IDS[@]}"; do
        log_debug "Отправка Telegram-сообщения в чат ID: ${CHAT_ID}"
        curl -s --show-error -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="$CHAT_ID" \
            -d text="$full_message" > /dev/null
        if [ $? -ne 0 ]; then
            log_debug "Ошибка при отправке Telegram-сообщения в чат ID: ${CHAT_ID}."
        fi
    done
}


# --- ОСНОВНАЯ ЛОГИКА МОНИТОРИНГА ПРЕДЛОЖЕНИЙ ДЛЯ ОДНОЙ СЕТИ ---
monitor_proposals_for_network() {
    local node_name="$1"
    local rest_api_base_url="$2"
    local debug_enabled="$3" # Эта переменная теперь может быть проигнорирована внутри функции, т.к. log_debug сам проверяет GLOBAL_DEBUG
    local state_file="$4"
    local -a statuses_to_monitor=("${@:5}")

# Преобразуем имя сети в верхний регистр для использования во всех сообщениях
    local display_node_name="${node_name^^}"

    local current_gov_version=""
    local query_output=""
    local success=false
    local curl_error_message=""

    # Проверяем, если версия Gov явно установлена
    if [[ -n "${NETWORKS[${node_name},GOV_MODULE_VERSION]}" ]]; then
        current_gov_version="${NETWORKS[${node_name},GOV_MODULE_VERSION]}"
        log_debug "Для ${node_name} версия Gov явно установлена на: ${current_gov_version}"

        local query_url="${rest_api_base_url}/cosmos/gov/${current_gov_version}/proposals?pagination.limit=${PROPOSALS_FETCH_LIMIT}&pagination.reverse=true"
        local attempt=0
        while [ "$attempt" -lt "$MAX_RETRIES" ]; do
            attempt=$((attempt + 1))
            log_debug "Попытка ${attempt}/${MAX_RETRIES} для ${node_name} с версией Gov ${current_gov_version} URL: ${query_url}"
            if query_output=$(curl -sS --fail -m 15 "$query_url" 2>&1); then
                # Проверяем, что JSON содержит массив 'proposals'
                if echo "$query_output" | jq -e '.proposals | type == "array"' >/dev/null 2>&1; then
                    success=true
                    break
                else
                    curl_error_message="JSON ответ не содержит массив 'proposals' или невалиден."
                    log_debug "JSON валидация не пройдена для ${node_name} (попытка ${attempt}): ${curl_error_message}"
                fi
            else
                curl_error_message="$query_output"
                log_debug "Ошибка curl для ${node_name} (попытка ${attempt}): ${curl_error_message}"
            fi

            if [ "$attempt" -lt "$MAX_RETRIES" ]; then
                sleep "$RETRY_DELAY_SECONDS"
            fi
        done
    else # Автоматическое определение версии Gov
        local potential_versions=( "v1" "v1beta1" ) # Порядок важен: v1, затем v1beta1
        for version_attempt in "${potential_versions[@]}"; do
            log_debug "Пробуем версию Gov: ${version_attempt} для ${node_name}"

            local query_url="${rest_api_base_url}/cosmos/gov/${version_attempt}/proposals?pagination.limit=${PROPOSALS_FETCH_LIMIT}&pagination.reverse=true"
            local attempt=0
            while [ "$attempt" -lt "$MAX_RETRIES" ]; do
                attempt=$((attempt + 1))
                log_debug "Попытка ${attempt}/${MAX_RETRIES} для ${node_name} с версией Gov ${version_attempt} URL: ${query_url}"
                if query_output=$(curl -sS --fail -m 15 "$query_url" 2>&1); then
                    # КЛЮЧЕВОЕ ИЗМЕНЕНИЕ: Проверяем, что JSON содержит массив 'proposals'
                    if echo "$query_output" | jq -e '.proposals | type == "array"' >/dev/null 2>&1; then
                        success=true
                        current_gov_version="$version_attempt"
                        break 2 # Выход из обоих циклов (из while и из for)
                    else
                        curl_error_message="JSON ответ не содержит массив 'proposals' или невалиден."
                        log_debug "JSON валидация не пройдена для ${node_name} (попытка ${attempt}): ${curl_error_message}"
                    fi
                else
                    curl_error_message="$query_output"
                    log_debug "Ошибка curl для ${node_name} (попытка ${attempt}): ${curl_error_message}"
                fi

                if [ "$attempt" -lt "$MAX_RETRIES" ]; then
                    sleep "$RETRY_DELAY_SECONDS"
                fi
            done
        done
    fi

    if [ "$success" = false ]; then
        send_telegram "❌  Ошибка при получении списка предложений:%0A Ошибка в сети ${display_node_name} через REST Proxy ${rest_api_base_url}. %0AВсе ${MAX_RETRIES} попыток (для каждой версии) провалились. %0AПоследняя ошибка: '${curl_error_message}'"
        log_debug "Все попытки получить данные для ${node_name} провалились. Пропускаем проверку предложений."
        return 1
    fi

    log_debug "Успешно получены данные для ${node_name} с версией Gov: ${current_gov_version}"

    # Полный JSON-отчет теперь записывается только в дебаг-лог
    if [ "$GLOBAL_DEBUG" = true ]; then # Явная проверка для вывода больших данных
        log_debug "Полный JSON-отчет от ${node_name} (с Gov ${current_gov_version}):"
        # Перенаправляем вывод jq напрямую в debug-лог, чтобы избежать ошибок с экранированием
        echo "${query_output}" | jq . >> "$DEBUG_LOG_FILE"
        log_debug "Конец полного JSON-ответа для ${node_name}."
    fi

    local JQ_STATUS_CONDITION=""
    # Проверяем, какую версию Gov модуля мы используем, чтобы выбрать правильные статусы
    if [[ "$current_gov_version" == "v1beta1" ]]; then
        # v1beta1 использует короткие статусы (например, 'PROPOSAL_STATUS_VOTING_PERIOD')
        for status in "${statuses_to_monitor[@]}"; do
            if [[ -n "$JQ_STATUS_CONDITION" ]]; then
                JQ_STATUS_CONDITION+=" or "
            fi
            JQ_STATUS_CONDITION+=".status == \"$status\""
        done
    elif [[ "$current_gov_version" == "v1" ]]; then
        # v1 использует короткие статусы (например, 'PROPOSAL_STATUS_VOTING_PERIOD')
        # Пока оставляем как есть, так как REST API часто нормализует.
        for status in "${statuses_to_monitor[@]}"; do
            if [[ -n "$JQ_STATUS_CONDITION" ]]; then
                JQ_STATUS_CONDITION+=" or "
            fi
            JQ_STATUS_CONDITION+=".status == \"$status\""
        done
    else
        log_debug "Неизвестная версия Gov модуля '${current_gov_version}'. Применяем фильтрацию статусов как есть."
        for status in "${statuses_to_monitor[@]}"; do
            if [[ -n "$JQ_STATUS_CONDITION" ]]; then
                JQ_STATUS_CONDITION+=" or "
            F_JQ_STATUS_CONDITION+=".status == \"$status\""
            fi
        done
    fi


    local current_proposals_json
    local jq_proposals_path=".proposals[]" # Путь к массиву предложений

    if [[ -z "$JQ_STATUS_CONDITION" ]]; then
        current_proposals_json=$(echo "${query_output}" | jq -c "${jq_proposals_path}")
        log_debug "Отсутствуют статусы для фильтрации. Обработка всех предложений."
    else
        current_proposals_json=$(echo "${query_output}" | jq -c "${jq_proposals_path} | select(${JQ_STATUS_CONDITION})")
    fi

    # Отфильтрованный JSON-отчет теперь записывается только в дебаг-лог
    if [ "$GLOBAL_DEBUG" = true ]; then # Явная проверка для вывода больших данных
        log_debug "JSON-отчет после фильтрации статусов для ${node_name}:"
        if [ -n "$current_proposals_json" ]; then
            echo "$current_proposals_json" | jq . >> "$DEBUG_LOG_FILE"
        else
            log_debug "Отфильтрованный JSON пуст."
        fi
        log_debug "Конец отфильтрованного JSON-ответа для ${node_name}."
    fi

    if [ -z "$current_proposals_json" ]; then
        log_debug "Нет предложений с выбранными статусами для ${node_name}."
        echo "" > "$state_file"
        log_debug "Файл состояния ${state_file} очищен, так как нет активных предложений."
        return 0
    fi

    local known_proposal_ids=()
    if [ -f "$state_file" ]; then
        mapfile -t known_proposal_ids < "$state_file"
    fi
    log_debug "Известные ID предложений для ${node_name} (до обработки): ${known_proposal_ids[*]}"

    local temp_active_proposals_file="${BASE_STATE_DIR}/temp_active_proposals_${node_name}.txt"
    > "$temp_active_proposals_file"

    echo "$current_proposals_json" | while IFS= read -r proposal_data; do
        # Удаляем символы возврата каретки \r из вывода jq
        local proposal_id=$(echo "$proposal_data" | jq -r '.id // .proposal_id' | tr -d '\r')

        local proposal_title=""
        # Выбираем правильный путь для заголовка в зависимости от версии Gov
        if [[ "$current_gov_version" == "v1" ]]; then
            proposal_title=$(echo "$proposal_data" | jq -r '.title // (.messages[0].content.title // "Нет заголовка")' | tr -d '\r')
        elif [[ "$current_gov_version" == "v1beta1" ]]; then
            proposal_title=$(echo "$proposal_data" | jq -r '.content.title // "Нет заголовка"' | tr -d '\r')
        else
            proposal_title=$(echo "$proposal_data" | jq -r '.title // .content.title // "Нет заголовка - неизвестная версия gov"' | tr -d '\r')
        fi

        local proposal_status=$(echo "$proposal_data" | jq -r '.status' | tr -d '\r')
        local voting_end_time=$(echo "$proposal_data" | jq -r '.voting_end_time // ""' | tr -d '\r')
        local deposit_end_time=$(echo "$proposal_data" | jq -r '.deposit_end_time // ""' | tr -d '\r')



        local already_known=false
        for known_id in "${known_proposal_ids[@]}"; do
            if [[ "$known_id" == "$proposal_id" ]]; then
                already_known=true
                break
            fi
        done

        echo "$proposal_id" >> "$temp_active_proposals_file"

        if [ "$already_known" = false ]; then
            # Здесь нет необходимости в экранировании Markdown, так как parse_mode не используется.
            local message_text="📢  Новое голосование в сети ${display_node_name}:%0A" # Используем %0A для новых строк
            message_text+="ID: ${proposal_id}%0A"
            message_text+="Заголовок: ${proposal_title}%0A"
            message_text+="Статус: ${proposal_status}%0A"

            local end_time_display=""
            if [[ "$proposal_status" == "PROPOSAL_STATUS_VOTING_PERIOD" && -n "$voting_end_time" ]]; then
                end_time_display="Окончание голосования: $(date -d "$voting_end_time" +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null)"
            elif [[ "$proposal_status" == "PROPOSAL_STATUS_DEPOSIT_PERIOD" && -n "$deposit_end_time" ]]; then
                end_time_display="Окончание депозита: $(date -d "$deposit_end_time" +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null)"
            fi

            if [[ -n "$end_time_display" ]]; then
                message_text+="${end_time_display}%0A"
            fi

            send_telegram "$message_text"
            log_debug "Отправлено уведомление о новом предложении ID ${proposal_id} для ${node_name}."
        else
            log_debug "Предложение ID ${proposal_id} для ${node_name} уже известно. Уведомление о новом не отправлено."
        fi

        # Логика напоминаний
        if [[ "$proposal_status" == "PROPOSAL_STATUS_VOTING_PERIOD" && -n "$voting_end_time" && "$voting_end_time" != "0001-01-01T00:00:00Z" ]]; then
            local end_timestamp=$(date -d "$voting_end_time" +%s 2>/dev/null)
            local current_timestamp=$(date +%s)
            local time_diff_seconds=$((end_timestamp - current_timestamp))
            local time_diff_hours=$((time_diff_seconds / 3600))

            if (( time_diff_hours > 0 && time_diff_hours <= REMINDER_HOURS_THRESHOLD )); then
                # Здесь нет необходимости в экранировании Markdown.
                local reminder_message="⏰ Напоминание:%0A Голосование по предложению ${proposal_id} в сети ${display_node_name}%0A"
                reminder_message+="'${proposal_title}' - скоро закончится!%0A"
                reminder_message+="Осталось примерно ${time_diff_hours} часов.%0A"
                reminder_message+="Окончание: $(date -d "$voting_end_time" +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null)"

                send_telegram "$reminder_message"
                log_debug "Отправлено напоминание о голосовании для ID ${proposal_id} (${time_diff_hours}ч осталось)."
            fi
        fi

    done < <(echo "$current_proposals_json") # Здесь мы явно передаем JSON в цикл while

    mapfile -t new_known_proposal_ids < "$temp_active_proposals_file"
    rm "$temp_active_proposals_file"

    printf "%s\n" "${new_known_proposal_ids[@]}" > "$state_file"
    log_debug "Обновлен файл состояния ${state_file} для ${node_name} с ID: ${new_known_proposal_ids[*]}."

    return 0
}

# --- ЗАПУСК ОСНОВНОЙ ЛОГИКИ ДЛЯ ВСЕХ СЕТЕЙ ---
for NODE_NAME_KEY in "${NETWORK_NAMES[@]}"; do
    NODE_NAME=${NODE_NAME_KEY}

    log_debug "--- Начинаем проверку предложений для сети: ${NODE_NAME} ---"

    if [[ -z "${NETWORKS[${NODE_NAME},REST_API_BASE_URL]}" ]]; then
        send_telegram "⚠️    ОШИБКА КОНФИГУРАЦИИ:%0A Отсутствует REST_API_BASE_URL для сети ${NODE_NAME^^} для мониторинга предложений.%0A Пропускаю...."
        log_debug "Отсутствует REST_API_BASE_URL для ${NODE_NAME}. Пропускаю."
        continue
    fi

    monitor_proposals_for_network "$NODE_NAME" "${NETWORKS[${NODE_NAME},REST_API_BASE_URL]}" "$GLOBAL_DEBUG" "${BASE_STATE_DIR}/proposals_state_${NODE_NAME}.txt" "${PROPOSAL_STATUSES_TO_MONITOR[@]}"

    log_debug "--- Проверка предложений для сети: ${NODE_NAME} завершена ---"
    log_debug "" # Для пустой строки
done

# --- Завершающий разделитель для дебаг-лога ---
if [ "$GLOBAL_DEBUG" = true ]; then
    log_debug "----------------------------------------------------------------------------"
    log_debug "Завершение скрипта мониторинга предложений: proposal_monitor.sh. Время: $(date -u -R)"
    log_debug "----------------------------------------------------------------------------"
    log_debug "" # Пустая строка для дополнительного разделения между запусками
fi

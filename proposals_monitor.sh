#!/bin/bash

# --- ОБЩИЕ НАСТРОЙКИ (КОТОРЫЕ НУЖНО ЗАПОЛНИТЬ ВРУЧНУЮ!) ---
TELEGRAM_BOT_TOKEN="774290nNjMu-_ZfyX29272V2bIQ" # ЗАПОЛНИТЬ! Вставьте сюда токен вашего Telegram-бота
# ID чатов для уведомлений о пропозалах. Можно использовать те же, что и для алертов, или создать новые.
TELEGRAM_PROPOSAL_CHAT_IDS=( "-478676" ) # ЗАПОЛНИТЬ! Вставьте сюда ID вашего Telegram-чата (или нескольких, разделяя пробелом)

# Пользователи для тега в Telegram. Оставьте пустым (""), если не хотите никого тегать.
# Если хотите добавить больше пользователей, раскоментируйте их и можете создать новых в этом блоке и добавить их в команду
# в строке под номером #102
USER1_TO_PING="" # ЗАПОЛНИТЬ ПРИ ЖЕЛАНИИ!
# USER2_TO_PING=""
# USER3_TO_PING=""


# Базовая директория для файлов состояния скрипта (чтобы хранить их рядом со скриптом).
CURRENT_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_STATE_DIR="${CURRENT_SCRIPT_DIR}"

# Интервал для напоминаний о голосовании (например, 24 часа до окончания)
REMINDER_HOURS_THRESHOLD=24

# Статусы предложений, которые нужно мониторить.
# По умолчанию: предложения на стадии депозита или голосования.
PROPOSAL_STATUSES_TO_MONITOR=( "PROPOSAL_STATUS_VOTING_PERIOD" "PROPOSAL_STATUS_DEPOSIT_PERIOD" )

# Количество последних предложений для получения от REST API.
# Для мониторинга достаточно небольшого числа (5-10).
PROPOSALS_FETCH_LIMIT=5

# --- НАСТРОЙКИ ПОВТОРНЫХ ПОПЫТОК (RETRY LOGIC) ---
MAX_RETRIES=5        # Максимальное количество попыток получить данные (1 = одна попытка без повторов)
RETRY_DELAY_SECONDS=5 # Задержка между попытками в секунда
DELAY_BETWEEN_NETWORKS_SECONDS=5 # Пауза между проверками сетей (5 секунд по умолчанию)

# --- ОБРАБОТКА АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ ---
GLOBAL_DEBUG=false # По умолчанию режим отладки выключен.
if [[ "$1" == "--debug" ]]; then
    GLOBAL_DEBUG=true # Если передан --debug, всегда включаем отладку.
    echo "Глобальный режим отладки включен."
fi

# --- ОПРЕДЕЛЕНИЕ ИМЕН СЕТЕЙ КАК ПЕРЕМЕННЫХ ---
CHAIN1="nolus"
CHAIN2="sommelier"
CHAIN3="juno"
CHAIN4="sentinel"
CHAIN5="stargaze"
CHAIN6="persistence"

# --- КОНФИГУРАЦИИ СЕТЕЙ ---
declare -A NETWORKS

declare -a NETWORK_NAMES=(
    "${CHAIN1}"
    "${CHAIN2}"
    "${CHAIN3}"
    "${CHAIN4}"
    "${CHAIN5}"
    "${CHAIN6}"
)

# Для каждой сети укажите базовый URL REST Proxy от cosmos.directory.
# ВЕРСИЯ GOV МОДУЛЯ БУДЕТ ОПРЕДЕЛЯТЬСЯ АВТОМАТИЧЕСКИ (v1 -> v1beta1 fallback).
# Если вы хотите УСТАНОВИТЬ КОНКРЕТНУЮ ВЕРСИЮ для сети, раскомментируйте и укажите ее.

# Nolus
NETWORKS[${CHAIN1},REST_API_BASE_URL]="https://rest.cosmos.directory/${CHAIN1}"
# NETWORKS[${CHAIN1},GOV_MODULE_VERSION]="v1beta1"

# Sommelier
NETWORKS[${CHAIN2},REST_API_BASE_URL]="https://rest.cosmos.directory/${CHAIN2}"
# NETWORKS[${CHAIN2},GOV_MODULE_VERSION]="v1"

# Juno
NETWORKS[${CHAIN3},REST_API_BASE_URL]="https://rest.cosmos.directory/${CHAIN3}"
# NETWORKS[${CHAIN3},GOV_MODULE_VERSION]="v1"

# Sentinel
NETWORKS[${CHAIN4},REST_API_BASE_URL]="https://rest.cosmos.directory/${CHAIN4}"

# NETWORKS[${CHAIN4},GOV_MODULE_VERSION]="v1beta1"

# Stargaze
NETWORKS[${CHAIN5},REST_API_BASE_URL]="https://rest.cosmos.directory/${CHAIN5}"
# NETWORKS[${CHAIN5},GOV_MODULE_VERSION]="v1"

# Persistence
NETWORKS[${CHAIN6},REST_API_BASE_URL]="https://rest.cosmos.directory/${CHAIN6}"
# NETWORKS[${CHAIN5},GOV_MODULE_VERSION]="v1"

# --- ПРОВЕРКА ЗАВИСИМОСТЕЙ ---
command -v jq >/dev/null 2>&1 || { echo >&2 "Ошибка: jq не установлен. Установите его."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo >&2 "Ошибка: curl не установлен. Установите его."; exit 1; }

# --- ФУНКЦИЯ ОТПРАВКИ СООБЩЕНИЙ В TELEGRAM ---
send_telegram() {
    local message="$1"
    local full_message="$message"

    if [[ -n "$USER_TO_PING" ]]; then
        full_message="${full_message} ${USER1_TO_PING}"
    fi

    for CHAT_ID in "${TELEGRAM_PROPOSAL_CHAT_IDS[@]}"; do
        curl -s --show-error -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="$CHAT_ID" -d text="$full_message" > /dev/null
    done
}

# --- ОСНОВНАЯ ЛОГИКА МОНИТОРИНГА ПРОПОЗАЛОВ ДЛЯ ОДНОЙ СЕТИ ---
monitor_proposals_for_network() {
    local node_name="$1"
    local rest_api_base_url="$2"
    local debug_enabled="$3"
    local state_file="$4"
    local -a statuses_to_monitor=("${@:5}")

    local current_gov_version=""
    local query_output=""
    local success=false
    local curl_error_message=""

    # Проверяем, если Gov Version принудительно установлена
    if [[ -n "${NETWORKS[${node_name},GOV_MODULE_VERSION]}" ]]; then
        current_gov_version="${NETWORKS[${node_name},GOV_MODULE_VERSION]}"
        [ "$debug_enabled" = true ] && echo "DEBUG: Для ${node_name} принудительно установлена Gov Version: ${current_gov_version}"

        local query_url="${rest_api_base_url}/cosmos/gov/${current_gov_version}/proposals?pagination.limit=${PROPOSALS_FETCH_LIMIT}&pagination.reverse=true"
        local attempt=0
        while [ "$attempt" -lt "$MAX_RETRIES" ]; do
            attempt=$((attempt + 1))
            [ "$debug_enabled" = true ] && echo "DEBUG: Попытка ${attempt}/${MAX_RETRIES} для ${node_name} с Gov Version ${current_gov_version} URL: ${query_url}"
            if query_output=$(curl -sS --fail -m 15 "$query_url" 2>&1); then
                # Проверяем, что JSON содержит массив proposals
                if echo "$query_output" | jq -e '.proposals | type == "array"' >/dev/null 2>&1; then
                    success=true
                    break
                else
                    curl_error_message="JSON ответ не содержит массив 'proposals' или невалиден."
                    [ "$debug_enabled" = true ] && echo "DEBUG: JSON-валидация не пройдена для ${node_name} (попытка ${attempt}): ${curl_error_message}"
                fi
            else
                curl_error_message="$query_output"
                [ "$debug_enabled" = true ] && echo "DEBUG: Ошибка curl для ${node_name} (попытка ${attempt}): ${curl_error_message}"
            fi

            if [ "$attempt" -lt "$MAX_RETRIES" ]; then
                sleep "$RETRY_DELAY_SECONDS"
            fi
        done
    else # Автоматическое определение Gov Version
        local potential_versions=( "v1" "v1beta1" ) # Порядок важен: v1, затем v1beta1
        for version_attempt in "${potential_versions[@]}"; do
            [ "$debug_enabled" = true ] && echo "DEBUG: Пробуем Gov Version: ${version_attempt} для ${node_name}"
            local query_url="${rest_api_base_url}/cosmos/gov/${version_attempt}/proposals?pagination.limit=${PROPOSALS_FETCH_LIMIT}&pagination.reverse=true"
            local attempt=0
            while [ "$attempt" -lt "$MAX_RETRIES" ]; do
                attempt=$((attempt + 1))
                [ "$debug_enabled" = true ] && echo "DEBUG: Попытка ${attempt}/${MAX_RETRIES} для ${node_name} с Gov Version ${version_attempt} URL: ${query_url}"
                if query_output=$(curl -sS --fail -m 15 "$query_url" 2>&1); then
                    #  Проверяем, что JSON содержит массив proposals
                    if echo "$query_output" | jq -e '.proposals | type == "array"' >/dev/null 2>&1; then
                        success=true
                        current_gov_version="$version_attempt"
                        break 2 # Выход из обоих циклов
                    else
                        curl_error_message="JSON ответ не содержит массив 'proposals' или невалиден."
                        [ "$debug_enabled" = true ] && echo "DEBUG: JSON-валидация не пройдена для ${node_name} (попытка ${attempt}): ${curl_error_message}"
                    fi
                else
                    curl_error_message="$query_output"
                    [ "$debug_enabled" = true ] && echo "DEBUG: Ошибка curl для ${node_name} (попытка ${attempt}): ${curl_error_message}"
                fi

                if [ "$attempt" -lt "$MAX_RETRIES" ]; then
                    sleep "$RETRY_DELAY_SECONDS"
                fi
            done
        done
    fi

    if [ "$success" = false ]; then
        send_telegram "❌ Ошибка при получении списка предложений для *${node_name}* через REST Proxy ${rest_api_base_url}. Все ${MAX_RETRIES} попыток (для каждой версии) провалились. Последняя ошибка: '${curl_error_message}'"
        [ "$debug_enabled" = true ] && echo "DEBUG: Все попытки получить данные для ${node_name} провалились. Пропускаем проверку предложений."
        return 1
    fi

    [ "$debug_enabled" = true ] && echo "DEBUG: Успешно получены данные для ${node_name} с Gov Version: ${current_gov_version}"

    if [ "$debug_enabled" = true ]; then
        echo "DEBUG: Полный JSON-отчет от ${node_name} (с Gov ${current_gov_version}):"
        echo "${query_output}" | jq .
        echo "DEBUG: Конец полного JSON-ответа для ${node_name}."
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
        # Здесь нет явного преобразования, так как cosmos.directory уже может возвращать их
        # Если в будущем v1 будет использовать другие статусы (типа 'voting_period'), то это нужно будет здесь адаптировать.
        # Пока оставляем как есть, так как REST API часто нормализует.
        for status in "${statuses_to_monitor[@]}"; do
            if [[ -n "$JQ_STATUS_CONDITION" ]]; then
                JQ_STATUS_CONDITION+=" or "
            fi
            JQ_STATUS_CONDITION+=".status == \"$status\""
        done
    else
        [ "$debug_enabled" = true ] && echo "DEBUG: Неизвестная версия Gov модуля '${current_gov_version}'. Применяем фильтрацию статусов как есть."
        for status in "${statuses_to_monitor[@]}"; do
            if [[ -n "$JQ_STATUS_CONDITION" ]]; then
                JQ_STATUS_CONDITION+=" or "
            fi
            JQ_STATUS_CONDITION+=".status == \"$status\""
        done
    fi


    local current_proposals_json
    local jq_proposals_path=".proposals[]" # Путь к массиву предложений

    if [[ -z "$JQ_STATUS_CONDITION" ]]; then
        current_proposals_json=$(echo "${query_output}" | jq -c "${jq_proposals_path}")
        [ "$debug_enabled" = true ] && echo "DEBUG: Отсутствуют статусы для фильтрации. Обработка всех предложений."
    else
        current_proposals_json=$(echo "${query_output}" | jq -c "${jq_proposals_path} | select(${JQ_STATUS_CONDITION})")
    fi

    if [ "$debug_enabled" = true ]; then
        echo "DEBUG: JSON-отчет после фильтрации статусов для ${node_name}:"
        if [ -n "$current_proposals_json" ]; then
            echo "$current_proposals_json" | jq .
        else
            echo "DEBUG: Фильтрованный JSON пуст."
        fi
        echo "DEBUG: Конец фильтрованного JSON-ответа для ${node_name}."
    fi

    if [ -z "$current_proposals_json" ]; then
        [ "$debug_enabled" = true ] && echo "DEBUG: Нет предложений с выбранными статусами для ${node_name}."
        echo "" > "$state_file"
        [ "$debug_enabled" = true ] && echo "DEBUG: Файл состояния ${state_file} очищен, так как нет активных предложений."
        return 0
    fi

    local known_proposal_ids=()
    if [ -f "$state_file" ]; then
        mapfile -t known_proposal_ids < "$state_file"
    fi
    [ "$debug_enabled" = true ] && echo "DEBUG: Известные ID предложений для ${node_name} (до обработки): ${known_proposal_ids[*]}"

    local temp_active_proposals_file="${BASE_STATE_DIR}/temp_active_proposals_${node_name}.txt"
    > "$temp_active_proposals_file"

    echo "$current_proposals_json" | while IFS= read -r proposal_data; do
        local proposal_id=$(echo "$proposal_data" | jq -r '.id // .proposal_id')

        local proposal_title=""
        # Выбираем правильный путь для заголовка в зависимости от версии Gov
        if [[ "$current_gov_version" == "v1" ]]; then
            proposal_title=$(echo "$proposal_data" | jq -r '.title // (.messages[0].content.title // "Нет заголовка")')
        elif [[ "$current_gov_version" == "v1beta1" ]]; then
            proposal_title=$(echo "$proposal_data" | jq -r '.content.title // "Нет заголовка"')
        else
            proposal_title=$(echo "$proposal_data" | jq -r '.title // .content.title // "Нет заголовка - неизвестная версия gov"')
        fi

        local proposal_status=$(echo "$proposal_data" | jq -r '.status')
        local voting_end_time=$(echo "$proposal_data" | jq -r '.voting_end_time // ""')
        local deposit_end_time=$(echo "$proposal_data" | jq -r '.deposit_end_time // ""')

        local already_known=false
        for known_id in "${known_proposal_ids[@]}"; do
            if [[ "$known_id" == "$proposal_id" ]]; then
                already_known=true
                break
            fi
        done

        echo "$proposal_id" >> "$temp_active_proposals_file"

        if [ "$already_known" = false ]; then
            local message_text="📢 *Новое Голосование в сети ${node_name}*:%0A"
            message_text+="ID: {proposal_id}%0A"
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
            [ "$debug_enabled" = true ] && echo "DEBUG: Отправлено уведомление о новом предложении ID ${proposal_id} для ${node_name}."
        else
            [ "$debug_enabled" = true ] && echo "DEBUG: Предложение ID ${proposal_id} для ${node_name} уже известно. Уведомление о новом не отправлено."
        fi

        # Логика напоминаний
        if [[ "$proposal_status" == "PROPOSAL_STATUS_VOTING_PERIOD" && -n "$voting_end_time" && "$voting_end_time" != "0001-01-01T00:00:00Z" ]]; then
            local end_timestamp=$(date -d "$voting_end_time" +%s 2>/dev/null)
            local current_timestamp=$(date +%s)
            local time_diff_seconds=$((end_timestamp - current_timestamp))
            local time_diff_hours=$((time_diff_seconds / 3600))

            if (( time_diff_hours > 0 && time_diff_hours <= REMINDER_HOURS_THRESHOLD )); then
                local reminder_message="⏰ *НАПОМИНАНИЕ*: Голосование по предложению ${node_name} ID ${proposal_id} '${proposal_title}' скоро закончится!%0AОсталось примерно ${time_diff_hours} часов.%0AОкончание: $(date -d "$voting_end_time" +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null)"
                send_telegram "$reminder_message"
                [ "$debug_enabled" = true ] && echo "DEBUG: Отправлено напоминание о голосовании для ID ${proposal_id} (${time_diff_hours}ч осталось)."
            fi
        fi

    done < <(echo "$current_proposals_json") # Здесь мы явно передаем JSON в цикл while

    mapfile -t new_known_proposal_ids < "$temp_active_proposals_file"
    rm "$temp_active_proposals_file"

    printf "%s\n" "${new_known_proposal_ids[@]}" > "$state_file"
    [ "$debug_enabled" = true ] && echo "DEBUG: Обновлен файл состояния ${state_file} для ${node_name} с ID: ${new_known_proposal_ids[*]}."

    return 0
}

# --- ЗАПУСК ОСНОВНОЙ ЛОГИКИ ДЛЯ ВСЕХ СЕТЕЙ ---
for NODE_NAME_KEY in "${NETWORK_NAMES[@]}"; do
    NODE_NAME=${NODE_NAME_KEY}

    [ "$GLOBAL_DEBUG" = true ] && echo "--- Начинаем проверку предложений для сети: ${NODE_NAME} ---"

    if [[ -z "${NETWORKS[${NODE_NAME},REST_API_BASE_URL]}" ]]; then
        send_telegram "⚠️ ОШИБКА КОНФИГУРАЦИИ: Отсутствует REST_API_BASE_URL для сети ${NODE_NAME} для мониторинга предложений. Пропускаю."
        [ "$GLOBAL_DEBUG" = true ] && echo "DEBUG: Отсутствует REST_API_BASE_URL для ${NODE_NAME}. Пропускаю."
        continue
    fi

    monitor_proposals_for_network "$NODE_NAME" "${NETWORKS[${NODE_NAME},REST_API_BASE_URL]}" "$GLOBAL_DEBUG" "${BASE_STATE_DIR}/proposals_state_${NODE_NAME}.txt" "${PROPOSAL_STATUSES_TO_MONITOR[@]}"

    [ "$GLOBAL_DEBUG" = true ] && echo "--- Проверка предложений для сети: ${NODE_NAME} завершена ---"
    [ "$GLOBAL_DEBUG" = true ] && echo ""
done

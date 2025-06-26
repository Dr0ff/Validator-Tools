#!/bin/bash

# health_monitor.sh
# run with --debug flag to get verbose mode. Example: bash health_monitor.sh --debug

# --- ОБЩИЕ НАСТРОЙКИ (КОТОРЫЕ НУЖНО ЗАПОЛНИТЬ ВРУЧНУЮ!) ---
TELEGRAM_BOT_TOKEN="7742907053:AAEBXUpVX272V2bIQ" # ЗАПОЛНИТЬ!
TELEGRAM_ALERT_CHAT_IDS=( "-47676" ) # ЗАПОЛНИТЬ!
TELEGRAM_REPORT_CHAT_IDS=( "-4776" ) # ЗАПОЛНИТЬ!
TELEGRAM_INFO_CHAT_IDS=( "-4776" ) # ЗАПОЛНИТЬ!

# Пользователь для тега в Telegram. Оставьте пустым (""), если не хотите никого тегать.
# Пример: USER_TO_PING="@Bob_the_Builder"
USER_TO_PING="" # ЗАПОЛНИТЬ ПРИ ЖЕЛАНИИ!

# --- Настройка сетей ---

# Чтобы получить PUBKEY_JSON, используйте один из способов:
# 1) Для любого валидатора: DAEMON query staking validator $VALOPER_ADDRESS --output json | jq ->
# 2) Для вашей локальной ноды: DAEMON tendermint show-validator
# 3) Посмотрите на странице валидатора, например на https://ping.pub/juno/staking

# Настройки для первой сети
NET_1="Network name"         # Имя сети. Например: Juno
NET_1_DAEMON="DAEMON"        # Назвение демона (бинарника). Например: junod
NET_1_DIR=".node"            # Название директории в которой находится нода. Например .juno
NET_1_PORT="26657"           # Порт с которым работает нода. *Сейчас прописан стандартный порт ноды
# Обязательно заполните поля для VALOPER адреса и PUBKEY
# Они находятся чуть ниже,в блоке "MAССИВ" в секции: "Пример для NET_1"

# Настройки для второй сети.
# Если используете вторую ноду то заполните параметры в этом блоке и 
# обязательно пропишите параметр "NET_2" в команде (найдёте ниже, в секции МАССИВ) declare -a NETWORK_NAMES=( "NET_1" )
NET_2="Sentinel"
NET_2_DAEMON="sentinelhub"
NET_2_DIR=".sentinelhub"
NET_2_PORT="36657"
# Обязательно заполните поля для VALOPER адреса и PUBKEY
# Они находятся чуть ниже,в блоке "MAССИВ" в секции: "Пример для NET_2"

# Настройки для ещё одной сети
# NET_3="Sommelier"
# .....

MISSED_BLOCKS_THRESHOLD=10
CRON_INTERVAL=10 # Интервал, как часто этот скрипт будет запускаться (в минутах)

BASE_USER_HOME="$HOME" # Домашняя директория находится автоматически, но можно заполнить вручную (Например: /home/lilfox)

# Базовая директория для файлов состояния скрипта.
# Мы будем хранить их рядом с самим скриптом, который установлен в ~/node_monitor.
CURRENT_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_STATE_DIR="${CURRENT_SCRIPT_DIR}"

# --- ОБРАБОТКА АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ ---
GLOBAL_DEBUG=false # По умолчанию режим отладки выключен.
if [[ "$1" == "--debug" ]]; then
    GLOBAL_DEBUG=true # Если передан --debug, всегда включаем отладку.
    echo "Глобальный режим отладки включен."
fi

# --- КОНФИГУРАЦИИ СЕТЕЙ ---
declare -A NETWORKS

#    ⚠️           !!!-----  МАССИВ  -----!!!          ⚠️

#        === ОБЯЗАТЕЛЬНО ЗАПОЛНИТЕ ЭТОТ МАССИВ! ===
# Это список уникальных имен ваших сетей.
# Добавьте в команду все имена сетей, которые вы хотите мониторить 
# Пример для трёх сетей: "declare -a NETWORK_NAMES=( "$NET_1" "$NET_2" "$NET_3" )".
declare -a NETWORK_NAMES=( "$NET_1" )

# ⚠️   Пример для NET_1
NETWORKS[${NET_1},NODE_BINARY]="${BASE_USER_HOME}/go/bin/$NET_1_DAEMON"
NETWORKS[${NET_1},NODE_HOME]="${BASE_USER_HOME}/$NET_1_DIR"
NETWORKS[${NET_1},NODE_RPC_PORT]="$NET_1_PORT"
NETWORKS[${NET_1},VALOPER_ADDRESS]="nolusvaloper1....."   # Не забудьте вставить адрес валидатора!
NETWORKS[${NET_1},PUBKEY_JSON]='{"@type":"/cosmos.crypto.ed25519.PubKey","key":"Zj1ux6DSNskMu......"}'  # Не забудьте вставить PUBKEY!

# ⚠️    Пример для NET_2
NETWORKS[${NET_2},NODE_BINARY]="${BASE_USER_HOME}/go/bin/$NET_2_DAEMON"
NETWORKS[${NET_2},NODE_HOME]="${BASE_USER_HOME}/$NET_2_DIR"
NETWORKS[${NET_2},NODE_RPC_PORT]="$NET_2_PORT"
NETWORKS[${NET_2},VALOPER_ADDRESS]="sommvaloper1...."    # Не забудьте вставить адрес валидатора!
NETWORKS[${NET_2},PUBKEY_JSON]='{"@type":"/cosmos.crypto.ed25519.PubKey","key":"MlQWKox2Rb....."}'      # Не забудьте вставить PUBKEY!


# Проверка наличия jq
command -v jq >/dev/null 2>&1 || { echo >&2 "jq не установлен. Установите его командой sudo apt install jq"; exit 1; }

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
        for CHAT_ID in "${!chat_array_name}"; do
            curl -s --show-error -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                -d chat_id="$CHAT_ID" -d text="$full_message" > /dev/null
        done
    done
}

# --- ПРОВЕРКА RPC И СИНХРОНИЗАЦИИ ---
check_node_health() {
    local node_name="$1"
    local rpc_port="$2"
    local debug_enabled="$3"

    if [ -z "$rpc_port" ]; then
        send_telegram "⚠️ ОШИБКА КОНФИГУРАЦИИ: Порт RPC для ${node_name} не указан. Проверьте настройки." "ALERT"
        return 1
    fi

    local rpc_url="http://localhost:${rpc_port}"

    [ "$debug_enabled" = true ] && echo "DEBUG: Проверка RPC для ${node_name} на ${rpc_url}"

    if ! curl -s --fail --max-time 10 "${rpc_url}/health" | grep -q 'result'; then
        send_telegram "⛔️ НОДА НЕДОСТУПНА: ${node_name} не отвечает на RPC (порт ${rpc_port})." "ALERT"
        return 1
    fi

    local sync_status
    if ! sync_status=$(curl -s --fail --max-time 10 "${rpc_url}/status" | jq -r '.result.sync_info.catching_up' 2>/dev/null); then
        send_telegram "⚠️ Ошибка при получении sync_info от ${node_name}. Проверьте RPC и формат ответа." "ALERT"
        return 1
    fi

    if [[ "$sync_status" != "false" ]]; then
        send_telegram "⚠️ ${node_name} в режиме синхронизации. Возможны пропуски." "ALERT" "INFO"
    fi
    return 0
}

# --- ПРОВЕРКА ПРОПУЩЕННЫХ БЛОКОВ ---
check_missed_blocks() {
    local node_name="$1"
    local node_binary="$2"
    local node_home="$3"
    local rpc_port="$4"
    local pubkey_json="$5"
    local debug_enabled="$6"
    local state_file="$7"
    local daily_report_file="$8"

    if [ -z "$node_binary" ] || [ -z "$node_home" ] || [ -z "$rpc_port" ] || [ -z "$pubkey_json" ]; then
        [ "$debug_enabled" = true ] && echo "DEBUG: Не все параметры (NODE_BINARY, NODE_HOME, RPC_PORT, PUBKEY_JSON) для проверки пропущенных блоков для ${node_name} указаны. Проверка пропущена."
        return 1
    fi

    local QUERY_OUTPUT
    if ! QUERY_OUTPUT=$("$node_binary" query slashing signing-info "$pubkey_json" \
        --node "tcp://localhost:$rpc_port" \
        --home "$node_home" \
        --output json 2>&1); then
        send_telegram "❌ Ошибка при получении signing-info для ${node_name}. Проверьте бинарник и параметры. Вывод ошибки: '${QUERY_OUTPUT}'" "ALERT"
        return 1
    fi

    [ "$debug_enabled" = true ] && echo -e "DEBUG: signing-info for ${node_name}:\n$QUERY_OUTPUT"

    local CURRENT_MISSED_BLOCKS=0
    local parsed_value
    # Попытаться найти missed_blocks_counter либо в val_signing_info, либо на верхнем уровне
    parsed_value=$(echo "$QUERY_OUTPUT" | jq -r '(.val_signing_info.missed_blocks_counter // .missed_blocks_counter) | tonumber? // ""')

    if [[ -n "$parsed_value" ]]; then
        CURRENT_MISSED_BLOCKS="$parsed_value"
        [ "$debug_enabled" = true ] && echo "DEBUG: Successfully parsed missed_blocks_counter for ${node_name}: ${CURRENT_MISSED_BLOCKS}."
    else
        [ "$debug_enabled" = true ] && echo "DEBUG: missed_blocks_counter for ${node_name} is null/empty, not found, or not a valid number. Assuming 0."
    fi

    local LAST_MISSED_BLOCKS=0
    if [ -f "$state_file" ] && [[ "$(cat "$state_file")" =~ ^[0-9]+$ ]]; then
        LAST_MISSED_BLOCKS=$(cat "$state_file")
    else
        [ "$debug_enabled" = true ] && echo "DEBUG: Предыдущее значение missed_blocks для ${node_name} не числовое или файл отсутствует, сброс до 0."
    fi

    local NEWLY_MISSED_BLOCKS=$((CURRENT_MISSED_BLOCKS - LAST_MISSED_BLOCKS))
    [ "$debug_enabled" = true ] && echo "DEBUG: Проверка ${node_name}: новых пропущенных блоков за ${CRON_INTERVAL} минут: ${NEWLY_MISSED_BLOCKS}. Общий: ${CURRENT_MISSED_BLOCKS}."

    if [ "$NEWLY_MISSED_BLOCKS" -ge "$MISSED_BLOCKS_THRESHOLD" ] && [ "$NEWLY_MISSED_BLOCKS" -gt 0 ]; then
        send_telegram "🚨 ТРЕВОГА: ${node_name} пропустил ${NEWLY_MISSED_BLOCKS} блоков за ${CRON_INTERVAL} минут! Общий счетчик: ${CURRENT_MISSED_BLOCKS}." "ALERT"
    fi

    mkdir -p "$(dirname "$state_file")"
    echo "$CURRENT_MISSED_BLOCKS" > "$state_file"

    local CURRENT_DAY=$(date +%j)
    local LAST_DAY=0
    local daily_counter_file="${daily_report_file}.counter"

    if [ -f "$daily_report_file" ] && [[ "$(cat "$daily_report_file")" =~ ^[0-9]+$ ]]; then
        LAST_DAY=$(cat "$daily_report_file")
    else
        [ "$debug_enabled" = true ] && echo "DEBUG: Файл ежедневного отчета для ${node_name} не числовой или отсутствует, сброс до 0."
    fi

    if [ "$CURRENT_DAY" -ne "$LAST_DAY" ]; then
        local YESTERDAY_COUNTER=0
        if [ -f "$daily_counter_file" ] && [[ "$(cat "$daily_counter_file")" =~ ^[0-9]+$ ]]; then
            YESTERDAY_COUNTER=$(cat "$daily_counter_file")
        else
            [ "$debug_enabled" = true ] && echo "DEBUG: Файл счетчика ежедневного отчета для ${node_name} не числовой или отсутствует, сброс до 0."
        fi

        if [ "$YESTERDAY_COUNTER" -ne 0 ]; then
            local MISSED_FOR_24H=$((CURRENT_MISSED_BLOCKS - YESTERDAY_COUNTER))
            if (( MISSED_FOR_24H < 0 )); then
                MISSED_FOR_24H=0
            fi
            send_telegram "📊 Ежедневный отчет для ${node_name}:%0AЗа сутки пропущено: ${MISSED_FOR_24H} блоков.%0AТекущий счетчик: ${CURRENT_MISSED_BLOCKS}." "REPORT" "INFO"
        fi
        echo "$CURRENT_DAY" > "$daily_report_file"
        echo "$CURRENT_MISSED_BLOCKS" > "$daily_counter_file"
        [ "$debug_enabled" = true ] && echo "DEBUG: Суточный счетчик для ${node_name} сброшен."
    fi
}

# --- ЗАПУСК ОСНОВНОЙ ЛОГИКИ ДЛЯ ВСЕХ СЕТЕЙ ---
for NODE_NAME_KEY in "${NETWORK_NAMES[@]}"; do
    NODE_NAME=${NODE_NAME_KEY}

    [ "$GLOBAL_DEBUG" = true ] && echo "--- Начинаем проверку для сети: ${NODE_NAME} ---"

    if [[ -z "${NETWORKS[${NODE_NAME},NODE_BINARY]}" || \
          -z "${NETWORKS[${NODE_NAME},NODE_HOME]}" || \
          -z "${NETWORKS[${NODE_NAME},NODE_RPC_PORT]}" ]]; then
        send_telegram "⚠️ ОШИБКА КОНФИГУРАЦИИ: Отсутствуют обязательные параметры (NODE_BINARY, NODE_HOME, NODE_RPC_PORT) для сети ${NODE_NAME}. Пропускаю мониторинг этой сети." "ALERT"
        [ "$GLOBAL_DEBUG" = true ] && echo "DEBUG: Отсутствуют обязательные параметры (NODE_BINARY, NODE_HOME, NODE_RPC_PORT) для сети ${NODE_NAME}. Пропускаю мониторинг этой сети."
        continue
    fi

    NODE_BINARY=${NETWORKS[${NODE_NAME},NODE_BINARY]}
    NODE_HOME=${NETWORKS[${NODE_NAME},NODE_HOME]}
    NODE_RPC_PORT=${NETWORKS[${NODE_NAME},NODE_RPC_PORT]}
    VALOPER_ADDRESS=${NETWORKS[${NODE_NAME},VALOPER_ADDRESS]}
    PUBKEY_JSON=${NETWORKS[${NODE_NAME},PUBKEY_JSON]}

    STATE_FILE="${BASE_STATE_DIR}/missed_blocks_state_${NODE_NAME}.txt"
    DAILY_REPORT_FILE="${BASE_STATE_DIR}/daily_report_state_${NODE_NAME}.txt"

    # Проверка здоровья ноды
    if ! check_node_health "$NODE_NAME" "$NODE_RPC_PORT" "$GLOBAL_DEBUG"; then
        [ "$GLOBAL_DEBUG" = true ] && echo "Проверка здоровья ноды ${NODE_NAME} провалена. Пропускаем дальнейшие проверки для этой сети."
        continue
    fi

    # Проверки, зависящие от настроек валидатора (если VALOPER_ADDRESS и PUBKEY_JSON указаны)
    if [[ -n "$VALOPER_ADDRESS" && -n "$PUBKEY_JSON" ]]; then
        STAKING_VALIDATOR_OUTPUT=""
        if ! STAKING_VALIDATOR_OUTPUT=$("$NODE_BINARY" query staking validator "$VALOPER_ADDRESS" --node "tcp://localhost:$NODE_RPC_PORT" --home "$NODE_HOME" --output json 2>&1); then
            send_telegram "❌ Ошибка при запросе статуса валидатора (staking) для ${NODE_NAME}. Проверьте бинарник, RPC, HOME или VALOPER_ADDRESS. Вывод ошибки: '${STAKING_VALIDATOR_OUTPUT}'" "ALERT"
            [ "$GLOBAL_DEBUG" = true ] && echo "DEBUG: Ошибка запроса staking validator для ${NODE_NAME}. Пропускаем дальнейшие проверки для этой сети."
            continue
        fi

        [ "$GLOBAL_DEBUG" = true ] && echo -e "DEBUG: staking validator output for ${NODE_NAME}:\n$STAKING_VALIDATOR_OUTPUT"

        IS_JAILED_FROM_STAKING="false"
        jailed_until_from_staking=""

        # УНИВЕРСАЛЬНАЯ КОРРЕКЦИЯ: Используем .validator.jailed или .jailed
        JAILED_STATUS_RAW=$(echo "$STAKING_VALIDATOR_OUTPUT" | jq -r '(.validator.jailed // .jailed // "false")')
        if [[ "$JAILED_STATUS_RAW" == "true" ]]; then
            IS_JAILED_FROM_STAKING="true"
            [ "$GLOBAL_DEBUG" = true ] && echo "DEBUG: Валидатор ${NODE_NAME} помечен как 'jailed: true' в query staking validator."
        else
            [ "$GLOBAL_DEBUG" = true ] && echo "DEBUG: Валидатор ${NODE_NAME} не помечен как 'jailed: true' в query staking validator (raw value: ${JAILED_STATUS_RAW})."
        fi

        # УНИВЕРСАЛЬНАЯ КОРРЕКЦИЯ: Используем .validator.unbonding_time или .validator.jailed_until или .unbonding_time или .jailed_until
        jailed_until_from_staking=$(echo "$STAKING_VALIDATOR_OUTPUT" | jq -r '(.validator.unbonding_time // .validator.jailed_until // .unbonding_time // .jailed_until // empty)')
        [ "$GLOBAL_DEBUG" = true ] && echo "DEBUG: Raw jailed_until (or unbonding_time) from staking validator for ${NODE_NAME}: '${jailed_until_from_staking}'"

        if [[ "$IS_JAILED_FROM_STAKING" == "true" ]]; then
            jailed_until_date_formatted="неизвестна"
            current_timestamp=$(date +%s)

            if [[ -n "$jailed_until_from_staking" && "$jailed_until_from_staking" != "null" && "$jailed_until_from_staking" != "0001-01-01T00:00:00Z" && "$jailed_until_from_staking" != "1970-01-01T00:00:00Z" ]]; then
                # Используем gdate если доступен (для macOS) или date (для Linux)
                if command -v gdate &> /dev/null; then
                    jailed_until_timestamp=$(gdate -d "$jailed_until_from_staking" +%s 2>/dev/null)
                else
                    jailed_until_timestamp=$(date -d "$jailed_until_from_staking" +%s 2>/dev/null)
                fi

                if [[ -n "$jailed_until_timestamp" ]]; then
                    if (( jailed_until_timestamp > current_timestamp )); then
                        jailed_until_date_formatted="ожидается до: $(date -d @${jailed_until_timestamp} +"%Y-%m-%d %H:%M:%S %Z" 2>/dev/null)"
                        [ "$GLOBAL_DEBUG" = true ] && echo "DEBUG: Дата освобождения ${NODE_NAME} в будущем: ${jailed_until_date_formatted}"
                    else
                        jailed_until_date_formatted="срок истек: $(date -d @${jailed_until_timestamp} +"%Y-%m-%d %H:%M:%S %Z" 2>/dev/null)"
                        [ "$GLOBAL_DEBUG" = true ] && echo "DEBUG: Дата освобождения ${NODE_NAME} истекла: ${jailed_until_date_formatted}"
                    fi
                else
                    [ "$GLOBAL_DEBUG" = true ] && echo "DEBUG: Не удалось распарсить метку времени jailed_until для ${NODE_NAME} из '${jailed_until_from_staking}'."
                fi
            else
                [ "$GLOBAL_DEBUG" = true ] && echo "DEBUG: jailed_until для ${NODE_NAME} является пустой, null, 0001-01-01Z или 1970-01-01Z: '${jailed_until_from_staking}'."
            fi

            send_telegram "🚨 ВНИМАНИЕ: ${NODE_NAME} сообщает, что валидатор В ТЮРЬМЕ! Срок: ${jailed_until_date_formatted}" "ALERT"
            [ "$GLOBAL_DEBUG" = true ] && echo "Валидатор ${NODE_NAME} в тюрьме. Пропускаем дальнейшие проверки пропущенных блоков, так как он уже jailed."
            continue # Если валидатор в тюрьме, нет смысла проверять пропущенные блоки.
        fi

        # Если валидатор НЕ в тюрьме, тогда проверяем пропущенные блоки
        check_missed_blocks "$NODE_NAME" "$NODE_BINARY" "$NODE_HOME" "$NODE_RPC_PORT" "$PUBKEY_JSON" "$GLOBAL_DEBUG" "$STATE_FILE" "$DAILY_REPORT_FILE"
    else
        [ "$GLOBAL_DEBUG" = true ] && echo "DEBUG: VALOPER_ADDRESS или PUBKEY_JSON не указаны для ${NODE_NAME}. Пропускаю проверку на jailed и пропущенные блоки."
    fi

    [ "$GLOBAL_DEBUG" = true ] && echo "--- Проверка для сети: ${NODE_NAME} завершена ---"
    [ "$GLOBAL_DEBUG" = true ] && echo " "
        
    [ "$GLOBAL_DEBUG" = true ] && echo "Проверка завершена $(date -u -R)"
    [ "$GLOBAL_DEBUG" = true ] && echo " "
done

#!/bin/bash

# --- ОБЩИЕ НАСТРОЙКИ (КОТОРЫЕ НУЖНО ЗАПОЛНИТЬ ВРУЧНУЮ!) ---
TELEGRAM_BOT_TOKEN="ВАШ_БОТ_ТОКЕН" # ЗАПОЛНИТЬ!
TELEGRAM_ALERT_CHAT_IDS=( "ВАШ_ЧАТ_ID" ) # ЗАПОЛНИТЬ!
TELEGRAM_REPORT_CHAT_IDS=( "ВАШ_ЧАТ_ID" ) # ЗАПОЛНИТЬ!
TELEGRAM_INFO_CHAT_IDS=( "ВАШ_ЧАТ_ID" ) # ЗАПОЛНИТЬ!

# Пользователь для тега в Telegram. Оставьте пустым (""), если не хотите никого тегать.
# Пример: "@Bob_the_Builder"
USER_TO_PING="" # ЗАПОЛНИТЬ ПРИ ЖЕЛАНИИ!

# Базовая директория пользователя, где обычно находятся .go/bin и .<node_name> директории нод.
# Пример: "/home/lilfox" или "/home/ubuntu"
# ЭТО КРАЙНЕ ВАЖНО ЗАПОЛНИТЬ ПРАВИЛЬНО!
BASE_USER_HOME="/home/YOUR_USER_NAME" # ЗАПОЛНИТЬ! (Например, если вы lilfox, это будет /home/lilfox)

MISSED_BLOCKS_THRESHOLD=10
CRON_INTERVAL=10
PROPOSALS_CHECK_INTERVAL=$((12 * 60 * 60))

# Базовая директория для файлов состояния скрипта.
# Мы будем хранить их рядом с самим скриптом, который установлен в ~/node_monitor.
CURRENT_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_STATE_DIR="${CURRENT_SCRIPT_DIR}"

# --- ОБРАБОТКА АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ ---
GLOBAL_DEBUG=false
if [[ "$1" == "--debug" ]]; then
    GLOBAL_DEBUG=true
    echo "Глобальный режим отладки включен."
fi

# --- КОНФИГУРАЦИИ СЕТЕЙ (НУЖНО ЗАПОЛНИТЬ ВРУЧНУЮ!) ---
declare -A NETWORKS

# Пример для Juno
 NETWORKS[Juno,NODE_BINARY]="${BASE_USER_HOME}/go/bin/junod"
 NETWORKS[Juno,NODE_HOME]="${BASE_USER_HOME}/.juno"
 NETWORKS[Juno,NODE_RPC_PORT]="26657"
 NETWORKS[Juno,VALOPER_ADDRESS]="junovaloper1......"
 NETWORKS[Juno,PUBKEY_JSON]='{"@type":"/cosmos.crypto.ed25519.PubKey","key":"4p1GAuF7....."}'

# Пример для Osmosis
# NETWORKS[Osmosis,NODE_BINARY]="${BASE_USER_HOME}/go/bin/osmosisd"
# NETWORKS[Osmosis,NODE_HOME]="${BASE_USER_HOME}/.osmosisd"
# NETWORKS[Osmosis,NODE_RPC_PORT]="26657"
# NETWORKS[Osmosis,VALOPER_ADDRESS]="osmovaloper1..."
# NETWORKS[Osmosis,PUBKEY_JSON]='{"@type":"/cosmos.crypto.ed25519.PubKey","key":"..."}'

# Проверка наличия jq
command -v jq >/dev/null 2>&1 || { echo >&2 "jq не установлен. Установите его."; exit 1; }

# --- ОТПРАВКА СООБЩЕНИЙ В TELEGRAM ---
send_telegram() {
    local message="$1"
    shift
    local types=("$@")
    local full_message="$message"

    if [[ " ${types[@]} " =~ " ALERT " ]] && [[ -n "$USER_TO_PING" ]]; then
        full_message="${full_message} ${USER_TO_PING}"
    fi

    for type in "${types[@]}"; do
        local chat_array_name="TELEGRAM_${type}_CHAT_IDS[@]"
        for CHAT_ID in "${!chat_array_name}"; do
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                -d chat_id="$CHAT_ID" -d text="$full_message" > /dev/null
        done
    done
}

# --- ПРОВЕРКА RPC И СИНХРОНИЗАЦИИ ---
check_node_health() {
    local node_name="$1"
    local rpc_port="$2"
    local debug_enabled="$3"

    local rpc_url="http://localhost:${rpc_port}"

    [ "$debug_enabled" = true ] && echo "DEBUG: Проверка RPC для ${node_name} на ${rpc_url}"

    if ! curl -s --max-time 10 "${rpc_url}/health" | grep -q 'result'; then
        send_telegram "⛔️ НОДА НЕДОСТУПНА: ${node_name} не отвечает на RPC (порт ${rpc_port})" "ALERT"
        return 1
    fi

    local sync_status
    if ! sync_status=$(curl -s "${rpc_url}/status" | jq -r '.result.sync_info.catching_up'); then
        send_telegram "⚠️ Ошибка при получении sync_info от ${node_name}" "ALERT"
        return 1
    fi

    if [[ "$sync_status" != "false" ]]; then
        send_telegram "⚠️ ${node_name} в режиме синхронизации. Возможны пропуски." "ALERT" "INFO"
    fi
    return 0
}

# --- ПРОВЕРКА ЗАКЛЮЧЕНИЯ В ТЮРЬМУ ---
check_validator_jailed() {
    local node_name="$1"
    local node_binary="$2"
    local node_home="$3"
    local rpc_port="$4"
    local valoper_address="$5"
    local pubkey_json="$6"
    local debug_enabled="$7"

    local jailed
    jailed=$("$node_binary" query staking validator "$valoper_address" --node "tcp://localhost:$rpc_port" --home "$node_home" --output json 2>/dev/null | jq -r '.validator.jailed // empty')

    if [ -z "$jailed" ]; then
        local jailed_until
        jailed_until=$("$node_binary" query slashing signing-info "$pubkey_json" --node "tcp://localhost:$rpc_port" --home "$node_home" --output json 2>/dev/null | jq -r '.jailed_until // empty')
        if [[ -n "$jailed_until" && "$jailed_until" != "0001-01-01T00:00:00Z" ]]; then
            jailed="true"
        else
            jailed="false"
        fi
    fi

    echo "$jailed"
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

    local QUERY_OUTPUT
    if ! QUERY_OUTPUT=$("$node_binary" query slashing signing-info "$pubkey_json" \
        --node "tcp://localhost:$rpc_port" \
        --home "$node_home" \
        --output json 2>&1); then
        send_telegram "❌ Ошибка при получении signing-info ${node_name}" "ALERT"
        return 1
    fi

    [ "$debug_enabled" = true ] && echo -e "DEBUG: signing-info for ${node_name}:\n$QUERY_OUTPUT"

    local CURRENT_MISSED_BLOCKS=0
    if echo "$QUERY_OUTPUT" | jq -e '.missed_blocks_counter' >/dev/null 2>&1; then
        CURRENT_MISSED_BLOCKS=$(echo "$QUERY_OUTPUT" | jq -r '.missed_blocks_counter')
    elif [ "$debug_enabled" = true ]; then
        echo "DEBUG: missed_blocks_counter not found for ${node_name}. Assuming 0."
    fi

    local LAST_MISSED_BLOCKS=0
    [ -f "$state_file" ] && LAST_MISSED_BLOCKS=$(cat "$state_file")
    local NEWLY_MISSED_BLOCKS=$((CURRENT_MISSED_BLOCKS - LAST_MISSED_BLOCKS))
    [ "$debug_enabled" = true ] && echo "DEBUG: Проверка ${node_name}: новых пропущенных блоков за ${CRON_INTERVAL} минут: ${NEWLY_MISSED_BLOCKS}. Общий: ${CURRENT_MISSED_BLOCKS}."

    if [ "$NEWLY_MISSED_BLOCKS" -ge "$MISSED_BLOCKS_THRESHOLD" ] && [ "$NEWLY_MISSED_BLOCKS" -gt 0 ]; then
        send_telegram "🚨 ТРЕВОГА: ${node_name} пропустил ${NEWLY_MISSED_BLOCKS} блоков за ${CRON_INTERVAL} минут! Общий счетчик: ${CURRENT_MISSED_BLOCKS}." "ALERT"
    fi

    echo "$CURRENT_MISSED_BLOCKS" > "$state_file"

    local CURRENT_DAY=$(date +%j)
    local LAST_DAY=0
    [ -f "$daily_report_file" ] && LAST_DAY=$(cat "$daily_report_file")

    if [ "$CURRENT_DAY" -ne "$LAST_DAY" ]; then
        local YESTERDAY_COUNTER=0
        [ -f "$daily_report_file.counter" ] && YESTERDAY_COUNTER=$(cat "$daily_report_file.counter")
        if [ "$YESTERDAY_COUNTER" -ne 0 ]; then
            local MISSED_FOR_24H=$((LAST_MISSED_BLOCKS - YESTERDAY_COUNTER))
            send_telegram "📊 Ежедневный отчет для ${node_name}:%0AЗа сутки пропущено: ${MISSED_FOR_24H} блоков.%0AТекущий счетчик: ${CURRENT_MISSED_BLOCKS}." "REPORT" "INFO"
        fi
        echo "$CURRENT_DAY" > "$daily_report_file"
        echo "$CURRENT_MISSED_BLOCKS" > "$daily_report_file.counter"
        [ "$debug_enabled" = true ] && echo "DEBUG: Суточный счетчик для ${node_name} сброшен."
    fi
}

# --- ПРОВЕРКА НОВЫХ ПРОПОЗАЛОВ ---
check_new_proposals() {
    local node_name="$1"
    local node_binary="$2"
    local node_home="$3"
    local rpc_port="$4"
    local debug_enabled="$5"
    local proposals_last_check_file="$6"
    local seen_proposals_file="$7"

    local now=$(date +%s)
    local last_check=0
    [ -f "$proposals_last_check_file" ] && last_check=$(cat "$proposals_last_check_file")

    if (( now - last_check < PROPOSALS_CHECK_INTERVAL )); then
        [ "$debug_enabled" = true ] && echo "INFO: Проверка пропозалов для ${node_name} пропущена. Прошло $(( now - last_check )) сек., нужно $PROPOSALS_CHECK_INTERVAL."
        return
    fi

    local ACTIVE_PROPOSALS_JSON
    if ! ACTIVE_PROPOSALS_JSON=$("$node_binary" query gov proposals --proposal-status voting-period --node "tcp://localhost:$rpc_port" --output json); then
        send_telegram "❌ Ошибка при получении активных пропозалов ${node_name}" "ALERT"
        return
    fi

    local ACTIVE_IDS
    ACTIVE_IDS=$(echo "$ACTIVE_PROPOSALS_JSON" | jq -r '.proposals[].proposal_id' 2>/dev/null)
    touch "$seen_proposals_file"

    local NEW_IDS=()
    for ID in $ACTIVE_IDS; do
        if ! grep -q "^$ID$" "$seen_proposals_file"; then
            NEW_IDS+=("$ID")
        fi
    done

    if [ "${#NEW_IDS[@]}" -gt 0 ]; then
        local MESSAGE="🗳️ Новые активные голосования в сети ${node_name}:%0AID: ${NEW_IDS[*]}"
        send_telegram "$MESSAGE" "INFO"
        for ID in "${NEW_IDS[@]}"; do
            echo "$ID" >> "$seen_proposals_file"
        done
    elif [ "$debug_enabled" = true ]; then
        echo "INFO: Новых активных пропозалов для ${node_name} нет."
    fi

    echo "$now" > "$proposals_last_check_file"
}

# --- ЗАПУСК ОСНОВНОЙ ЛОГИКИ ДЛЯ ВСЕХ СЕТЕЙ ---
for NET_NAME in "${!NETWORKS[@]}"; do
    NODE_NAME=${NET_NAME}
    NODE_BINARY=${NETWORKS[${NET_NAME},NODE_BINARY]}
    NODE_HOME=${NETWORKS[${NET_NAME},NODE_HOME]}
    NODE_RPC_PORT=${NETWORKS[${NET_NAME},NODE_RPC_PORT]}
    VALOPER_ADDRESS=${NETWORKS[${NET_NAME},VALOPER_ADDRESS]}
    PUBKEY_JSON=${NETWORKS[${NET_NAME},PUBKEY_JSON]}

    # Пути к файлам состояния будут в той же папке, что и скрипт
    STATE_FILE="${BASE_STATE_DIR}/missed_blocks_state_${NODE_NAME}.txt"
    DAILY_REPORT_FILE="${BASE_STATE_DIR}/daily_report_state_${NODE_NAME}.txt"
    PROPOSALS_LAST_CHECK_FILE="${BASE_STATE_DIR}/proposals_last_check_${NODE_NAME}.txt"
    SEEN_PROPOSALS_FILE="${BASE_STATE_DIR}/seen_proposals_${NODE_NAME}.txt"

    [ "$GLOBAL_DEBUG" = true ] && echo "--- Начинаем проверку для сети: ${NODE_NAME} ---"
    
    if ! check_node_health "$NODE_NAME" "$NODE_RPC_PORT" "$GLOBAL_DEBUG"; then
        [ "$GLOBAL_DEBUG" = true ] && echo "Проверка здоровья ноды ${NODE_NAME} провалена. Пропускаем дальнейшие проверки для этой сети."
        continue
    fi

    local IS_JAILED=$(check_validator_jailed "$NODE_NAME" "$NODE_BINARY" "$NODE_HOME" "$NODE_RPC_PORT" "$VALOPER_ADDRESS" "$PUBKEY_JSON" "$GLOBAL_DEBUG")
    if [[ "$IS_JAILED" == "true" ]]; then
        local jailed_until_date=$("$NODE_BINARY" query slashing signing-info "$PUBKEY_JSON" --node "tcp://localhost:$NODE_RPC_PORT" --home "$NODE_HOME" --output json 2>/dev/null | jq -r '.jailed_until' | cut -d'.' -f1)
        send_telegram "🚨 ВНИМАНИЕ: ${NODE_NAME} сообщает, что валидатор В ТЮРЬМЕ! Возможно до: ${jailed_until_date}" "ALERT"
        [ "$GLOBAL_DEBUG" = true ] && echo "Валидатор ${NODE_NAME} в тюрьме. Пропускаем дальнейшие проверки пропущенных блоков."
    fi

    check_missed_blocks "$NODE_NAME" "$NODE_BINARY" "$NODE_HOME" "$NODE_RPC_PORT" "$PUBKEY_JSON" "$GLOBAL_DEBUG" "$STATE_FILE" "$DAILY_REPORT_FILE"

    check_new_proposals "$NODE_NAME" "$NODE_BINARY" "$NODE_HOME" "$NODE_RPC_PORT" "$GLOBAL_DEBUG" "$PROPOSALS_LAST_CHECK_FILE" "$SEEN_PROPOSALS_FILE"
    
    [ "$GLOBAL_DEBUG" = true ] && echo "--- Проверка для сети: ${NODE_NAME} завершена ---"
    [ "$GLOBAL_DEBUG" = true ] && echo ""
done

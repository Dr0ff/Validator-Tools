#!/bin/bash

# --- НАСТРОЙКИ ---
NODE_NAME="NAME"                       # Название сети
NODE_BINARY="/home/USER/go/bin/DAEMON" # Нужно изменить имя пользователя и назавние бинарника
NODE_HOME="/home/USER/.NODE_DIR"       # Нужно изменить имя пользователя и назавние бинарника
NODE_RPC_PORT="26657"                  # По умолчанию указан стандартный, нужно изменить на свой, если он отличается?
USER_TO_PING=" "                       # Пользователь кому адресовано сообщение в телеграмме. Пример: @Bob_the_bulider
TELEGRAM_BOT_TOKEN="TG BOT TOKEN"
TELEGRAM_CHAT_ID="CHAT ID"
MISSED_BLOCKS_THRESHOLD=10
CRON_INTERVAL=10
VALOPER_ADDRESS="***valoper"

# Чтобы получить PUBKEY_JSON, используйте один из способов:
# 1) Для любого валидатора: DAEMON query staking validator $VALOPER_ADDRESS --output json | jq -c '.consensus_pubkey'
# 2) Для вашей локальной ноды: DAEMON tendermint show-validator
PUBKEY_JSON='{"@type":"/cosmos.crypto.ed25519.PubKey","key":"REPLACE_WITH_YOUR_BASE64_PUBKEY=="}'

# Нужно создать директорию для файлов монитора mkdir ~/monitor
STATE_FILE="/home/USER/monitor/missed_blocks_state_${NODE_NAME}.txt"
DAILY_REPORT_FILE="/home/USER/monitor/daily_report_state_${NODE_NAME}.txt"
RPC_URL="http://localhost:${NODE_RPC_PORT}"

# Debug true / false
DEBUG=false

# --- ОТПРАВКА TELEGRAM ---
send_telegram() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" -d text="${message}" > /dev/null
}

# --- ПРОВЕРКА RPC И СИНХРОНИЗАЦИИ ---
check_node_health() {
    if ! curl -s --max-time 10 "${RPC_URL}/health" | grep -q 'result'; then
        send_telegram "⛔️ НОДА НЕДОСТУПНА: ${NODE_NAME} не отвечает на RPC (порт ${NODE_RPC_PORT}) ${USER_TO_PING}"
        exit 1
    fi

    local sync_status=$(curl -s "${RPC_URL}/status" | jq -r '.result.sync_info.catching_up')
    if [[ "$sync_status" != "false" ]]; then
        send_telegram "⚠️ ВНИМАНИЕ: ${NODE_NAME} в режиме синхронизации. Возможны пропуски. ${USER_TO_PING}"
    fi
}

# --- НАЧАЛО ---
check_node_health

# Проверка jailed статуса
VALIDATOR_STATUS_OUTPUT=$($NODE_BINARY query staking validator "$VALOPER_ADDRESS" --node "tcp://localhost:$NODE_RPC_PORT" --home "$NODE_HOME" 2>&1)
if echo "$VALIDATOR_STATUS_OUTPUT" | grep -q "jailed: true"; then
    QUERY_OUTPUT=$($NODE_BINARY query slashing signing-info "$PUBKEY_JSON" --node "tcp://localhost:$NODE_RPC_PORT" --home "$NODE_HOME" 2>&1)
    JAIL_DATE=$(echo "$QUERY_OUTPUT" | grep "jailed_until:" | sed 's/.*jailed_until: \"\(.*\)\"/\1/' | cut -d'.' -f1)
    send_telegram "🚨 ВНИМАНИЕ: ${NODE_NAME} сообщает, что валидатор В ТЮРЬМЕ!  Возможно до: ${JAIL_DATE} ${USER_TO_PING}"
    exit 0
fi

# Получение и парсинг signing-info через JSON pubkey
QUERY_OUTPUT=$($NODE_BINARY query slashing signing-info "$PUBKEY_JSON" --node "tcp://localhost:$NODE_RPC_PORT" --home "$NODE_HOME" 2>&1)
if [ "$DEBUG" = true ]; then
    echo -e "DEBUG: signing-info:\n$QUERY_OUTPUT"
fi

CURRENT_MISSED_BLOCKS=0
if echo "$QUERY_OUTPUT" | grep -q "missed_blocks_counter:"; then
    CURRENT_MISSED_BLOCKS=$(echo "$QUERY_OUTPUT" | grep "missed_blocks_counter:" | awk '{print $2}' | tr -d '"')
elif [ "$DEBUG" = true ]; then
    echo "DEBUG: missed_blocks_counter not found. Assuming 0."
fi

LAST_MISSED_BLOCKS=0
[ -f "$STATE_FILE" ] && LAST_MISSED_BLOCKS=$(cat "$STATE_FILE")
NEWLY_MISSED_BLOCKS=$((CURRENT_MISSED_BLOCKS - LAST_MISSED_BLOCKS))
echo "Проверка ${NODE_NAME}: новых пропущенных блоков за ${CRON_INTERVAL} минут: ${NEWLY_MISSED_BLOCKS}."

if [ "$NEWLY_MISSED_BLOCKS" -ge "$MISSED_BLOCKS_THRESHOLD" ] && [ "$NEWLY_MISSED_BLOCKS" -gt 0 ]; then
    send_telegram "🚨 ТРЕВОГА: ${NODE_NAME} пропустил ${NEWLY_MISSED_BLOCKS} блоков за ${CRON_INTERVAL} минут! Общий счетчик: ${CURRENT_MISSED_BLOCKS}. ${USER_TO_PING} "
fi

echo "$CURRENT_MISSED_BLOCKS" > "$STATE_FILE"

# Ежедневный отчет
CURRENT_DAY=$(date +%j)
LAST_DAY=0
[ -f "$DAILY_REPORT_FILE" ] && LAST_DAY=$(cat "$DAILY_REPORT_FILE")

if [ "$CURRENT_DAY" -ne "$LAST_DAY" ]; then
    YESTERDAY_COUNTER=0
    [ -f "$DAILY_REPORT_FILE.counter" ] && YESTERDAY_COUNTER=$(cat "$DAILY_REPORT_FILE.counter")
    
    if [ "$YESTERDAY_COUNTER" -ne 0 ]; then
        MISSED_FOR_24H=$((LAST_MISSED_BLOCKS - YESTERDAY_COUNTER))
        send_telegram "📊 Ежедневный отчет для ${NODE_NAME}:%0AЗа сутки пропущено: ${MISSED_FOR_24H} блоков.%0AТекущий счетчик: ${CURRENT_MISSED_BLOCKS}. ${USER_TO_PING}"
    fi

    echo "$CURRENT_DAY" > "$DAILY_REPORT_FILE"
    echo "$CURRENT_MISSED_BLOCKS" > "$DAILY_REPORT_FILE.counter"
    echo "DEBUG: Суточный счетчик сброшен."
fi

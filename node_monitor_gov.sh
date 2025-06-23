#!/bin/bash

# --- НАСТРОЙКИ ---
NODE_NAME="Juno"
NODE_BINARY="/home/littlefox/go/bin/junod"
NODE_HOME="/home/littlefox/.juno"
NODE_RPC_PORT="56657"
TELEGRAM_BOT_TOKEN="7742907053:AAEBXW1QnEOUpVX29272V2bIQ"
# Отдельные чаты для тревог, отчётов и информационных сообщений:
TELEGRAM_ALERT_CHAT_IDS=(
    "-4785908676"
)
TELEGRAM_REPORT_CHAT_IDS=(
    "-4785908676"
)
TELEGRAM_INFO_CHAT_IDS=(
    "-4785908676"
)

MISSED_BLOCKS_THRESHOLD=10
CRON_INTERVAL=10
VALOPER_ADDRESS="junovaloper1tx2u0nvjwregdv6a5t5k7zl6hgq4z"

# Чтобы получить PUBKEY_JSON, используйте один из способов:
# junod query staking validator $VALOPER_ADDRESS --output json | jq -c '.consensus_pubkey'
# junod tendermint show-validator
PUBKEY_JSON='{"@type":"/cosmos.crypto.ed25519.PubKey","key":"REPLACE_WITH_YOUR_BASE64_PUBKEY=="}'

PROPOSAL_TRACK_FILE="/home/littlefox/monitor/last_checked_proposal_${NODE_NAME}.txt"
STATE_FILE="/home/littlefox/monitor/missed_blocks_state_${NODE_NAME}.txt"
DAILY_REPORT_FILE="/home/littlefox/monitor/daily_report_state_${NODE_NAME}.txt"
RPC_URL="http://localhost:${NODE_RPC_PORT}"

PROPOSAL_CHECK_INTERVAL_SECONDS=$((12 * 60 * 60))  # 12 часов
PROPOSAL_LAST_CHECK_FILE="/home/littlefox/monitor/last_proposal_check_time_${NODE_NAME}.txt"

DEBUG=false

send_telegram() {
    local message="$1"
    shift
    local types=("$@")
    for type in "${types[@]}"; do
        local chat_array_name="TELEGRAM_${type}_CHAT_IDS[@]"
        for CHAT_ID in "${!chat_array_name}"; do
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                -d chat_id="$CHAT_ID" -d text="$message" > /dev/null
        done
    done
}

check_node_health() {
    if ! curl -s --max-time 10 "${RPC_URL}/health" | grep -q 'result'; then
        send_telegram "⛔️ НОДА НЕДОСТУПНА: ${NODE_NAME} не отвечает на RPC (порт ${NODE_RPC_PORT})" "ALERT"
        exit 1
    fi

    local sync_status=$(curl -s "${RPC_URL}/status" | jq -r '.result.sync_info.catching_up')
    if [[ "$sync_status" != "false" ]]; then
        send_telegram "⚠️ ВНИМАНИЕ: ${NODE_NAME} в режиме синхронизации. Возможны пропуски." "ALERT" "INFO"
    fi
}

check_node_health

VALIDATOR_STATUS_OUTPUT=$($NODE_BINARY query staking validator "$VALOPER_ADDRESS" --node "tcp://localhost:$NODE_RPC_PORT" --home "$NODE_HOME" 2>&1)
if echo "$VALIDATOR_STATUS_OUTPUT" | grep -q "jailed: true"; then
    QUERY_OUTPUT=$($NODE_BINARY query slashing signing-info "$PUBKEY_JSON" --node "tcp://localhost:$NODE_RPC_PORT" --home "$NODE_HOME" 2>&1)
    JAIL_DATE=$(echo "$QUERY_OUTPUT" | grep "jailed_until:" | sed 's/.*jailed_until: \"\(.*\)\"/\1/' | cut -d'.' -f1)
    send_telegram "🚨 ВНИМАНИЕ: ${NODE_NAME} сообщает, что валидатор В ТЮРЬМЕ! @Ksushenka1985 Возможно до: ${JAIL_DATE}" "ALERT"
    exit 0
fi

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
    send_telegram "🚨 ТРЕВОГА: ${NODE_NAME} пропустил ${NEWLY_MISSED_BLOCKS} блоков за ${CRON_INTERVAL} минут! Общий счетчик: ${CURRENT_MISSED_BLOCKS}. @Ksushenka1985" "ALERT"
fi

echo "$CURRENT_MISSED_BLOCKS" > "$STATE_FILE"

CURRENT_DAY=$(date +%j)
LAST_DAY=0
[ -f "$DAILY_REPORT_FILE" ] && LAST_DAY=$(cat "$DAILY_REPORT_FILE")

if [ "$CURRENT_DAY" -ne "$LAST_DAY" ]; then
    YESTERDAY_COUNTER=0
    [ -f "$DAILY_REPORT_FILE.counter" ] && YESTERDAY_COUNTER=$(cat "$DAILY_REPORT_FILE.counter")

    if [ "$YESTERDAY_COUNTER" -ne 0 ]; then
        MISSED_FOR_24H=$((LAST_MISSED_BLOCKS - YESTERDAY_COUNTER))
        send_telegram "📊 Ежедневный отчет для ${NODE_NAME}:%0AЗа сутки пропущено: ${MISSED_FOR_24H} блоков.%0AТекущий счетчик: ${CURRENT_MISSED_BLOCKS}." "REPORT" "INFO"
    fi

    echo "$CURRENT_DAY" > "$DAILY_REPORT_FILE"
    echo "$CURRENT_MISSED_BLOCKS" > "$DAILY_REPORT_FILE.counter"
    echo "DEBUG: Суточный счетчик сброшен."
fi

# --- ПРОВЕРКА НОВЫХ ПРОПОЗАЛОВ ---

CURRENT_TIME=$(date +%s)
LAST_CHECK_TIME=0
if [ -f "$PROPOSAL_LAST_CHECK_FILE" ]; then
    LAST_CHECK_TIME=$(cat "$PROPOSAL_LAST_CHECK_FILE")
fi

TIME_DIFF=$((CURRENT_TIME - LAST_CHECK_TIME))

if [ "$TIME_DIFF" -ge "$PROPOSAL_CHECK_INTERVAL_SECONDS" ]; then
    # Время для проверки прошло — выполняем проверку

    LATEST_PROPOSAL=$($NODE_BINARY query gov proposals --output json | jq -r '.proposals | map(.id | tonumber) | max // 0')
    LAST_PROPOSAL=0
    [ -f "$PROPOSAL_TRACK_FILE" ] && LAST_PROPOSAL=$(cat "$PROPOSAL_TRACK_FILE")

    if [ "$LATEST_PROPOSAL" -gt "$LAST_PROPOSAL" ]; then
        NEW_COUNT=$((LATEST_PROPOSAL - LAST_PROPOSAL))
        send_telegram "🗳 Обнаружено ${NEW_COUNT} новых голосований в сети ${NODE_NAME}! Последнее ID: ${LATEST_PROPOSAL}." "INFO" "ALERT"
        echo "$LATEST_PROPOSAL" > "$PROPOSAL_TRACK_FILE"
    fi

    echo "$CURRENT_TIME" > "$PROPOSAL_LAST_CHECK_FILE"
else
    if [ "$DEBUG" = true ]; then
        echo "DEBUG: Проверка новых пропозалов пропущена. Прошло $TIME_DIFF секунд, надо $PROPOSAL_CHECK_INTERVAL_SECONDS."
    fi
fi


LATEST_PROPOSAL=$($NODE_BINARY query gov proposals --output json | jq -r '.proposals | map(.id | tonumber) | max')
LAST_PROPOSAL=0
[ -f "$PROPOSAL_TRACK_FILE" ] && LAST_PROPOSAL=$(cat "$PROPOSAL_TRACK_FILE")

if [ "$LATEST_PROPOSAL" -gt "$LAST_PROPOSAL" ]; then
    NEW_COUNT=$((LATEST_PROPOSAL - LAST_PROPOSAL))
    send_telegram "🗳 Обнаружено ${NEW_COUNT} новых голосований в сети ${NODE_NAME}! Последнее ID: ${LATEST_PROPOSAL}." "INFO" "ALERT"
    echo "$LATEST_PROPOSAL" > "$PROPOSAL_TRACK_FILE"
fi

#!/bin/bash

# --- НАСТРОЙКИ ДЛЯ ОТЛАДКИ (можно изменить) ---
NETWORK_NAME="persistence" # Сеть для отладки
#REST_API_BASE_URL="https://sentinel-rest.publicnode.com"
REST_API_BASE_URL="https://rest.cosmos.directory/${NETWORK_NAME}"
GOV_MODULE_VERSION="v1" # v1 v1beta1
PROPOSAL_STATUSES_TO_MONITOR=( "PROPOSAL_STATUS_VOTING_PERIOD" "PROPOSAL_STATUS_DEPOSIT_PERIOD" )
MAX_RETRIES=3        # Максимальное количество попыток получить данные
RETRY_DELAY_SECONDS=3 # Задержка между попытками в секундах

# --- ПРОВЕРКА ЗАВИСИМОСТЕЙ ---
command -v jq >/dev/null 2>&1 || { echo >&2 "Ошибка: jq не установлен. Установите его."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo >&2 "Ошибка: curl не установлен. Установите его."; exit 1; }

echo "--- Начинаем отладку получения предложений для ${NETWORK_NAME} ---"
echo "REST API URL: ${REST_API_BASE_URL}"
echo "Gov Module Version: ${GOV_MODULE_VERSION}"
echo "Мониторируемые статусы: ${PROPOSAL_STATUSES_TO_MONITOR[*]}"

# Формируем URL с параметром pagination.reverse=true для получения последних предложений
query_url="${REST_API_BASE_URL}/cosmos/gov/${GOV_MODULE_VERSION}/proposals?pagination.reverse=true"
query_output=""
success=false
attempt=0
curl_error_message=""

# Цикл с повторными попытками для curl-запроса
while [ "$attempt" -lt "$MAX_RETRIES" ]; do
    attempt=$((attempt + 1))
    echo "DEBUG: Попытка ${attempt}/${MAX_RETRIES} для ${NETWORK_NAME} URL: ${query_url}"

    # -m 15 - таймаут для curl 15 секунд
    if query_output=$(curl -sS --fail -m 15 "$query_url" 2>&1); then
        success=true
        break
    else
        curl_error_message="$query_output"
        echo "DEBUG: Ошибка curl для ${NETWORK_NAME} (попытка ${attempt}): ${curl_error_message}"
        if [ "$attempt" -lt "$MAX_RETRIES" ]; then
            echo "DEBUG: Ожидание ${RETRY_DELAY_SECONDS} секунд перед повторной попыткой."
            sleep "$RETRY_DELAY_SECONDS"
        fi
    fi
done

if [ "$success" = false ]; then
    echo "ОШИБКА: Не удалось получить данные для ${NETWORK_NAME} после ${MAX_RETRIES} попыток. Последняя ошибка: '${curl_error_message}'"
    exit 1
fi

echo "--- Полный JSON-ответ от ${NETWORK_NAME} (последние предложения): ---"
# Выводим полный JSON-ответ, форматированный jq
echo "${query_output}" | jq .
echo "--- Конец полного JSON-ответа для ${NETWORK_NAME}. ---"
echo ""

# Формируем строку условия для jq на основе переменной PROPOSAL_STATUSES_TO_MONITOR
JQ_STATUS_CONDITION=""
for status in "${PROPOSAL_STATUSES_TO_MONITOR[@]}"; do
    if [[ -n "$JQ_STATUS_CONDITION" ]]; then
        JQ_STATUS_CONDITION+=" or "
    fi
    JQ_STATUS_CONDITION+=".status == \"$status\""
done

echo "DEBUG: JQ условие для фильтрации статусов: '${JQ_STATUS_CONDITION}'"

filtered_proposals_json=""
jq_proposals_path=".proposals[]" # Путь к массиву предложений одинаков для обеих версий

if [[ -z "$JQ_STATUS_CONDITION" ]]; then
    # Если статусы не указаны, обрабатываем все предложения
    filtered_proposals_json=$(echo "${query_output}" | jq -c "${jq_proposals_path}")
else
    filtered_proposals_json=$(echo "${query_output}" | jq -c "${jq_proposals_path} | select(${JQ_STATUS_CONDITION})")
fi

echo "--- JSON-ответ после фильтрации статусов для ${NETWORK_NAME}: ---"
if [ -n "$filtered_proposals_json" ]; then
    # Используем jq . для красивого вывода каждого объекта в отдельной строке
    echo "$filtered_proposals_json" | jq .
else
    echo "Нет предложений с выбранными статусами после фильтрации."
fi
echo "--- Конец фильтрованного JSON-ответа для ${NETWORK_NAME}. ---"
echo ""

echo "--- Отладка завершена ---"

#!/bin/bash

clear

show_logo() {
    echo -e "\e[92m"
    curl -s https://raw.githubusercontent.com/Dr0ff/Useful-scripts/refs/heads/main/tt.logo.txt
    echo -e "\e[0m"
}

show_logo


# --- НАСТРОЙКИ УСТАНОВКИ ---
# Директория, куда будет установлен монитор.
# Используем ~ для домашней директории текущего пользователя.
MONITOR_INSTALL_DIR="$HOME/node_monitor" 

# URL основного скрипта монитора
# Замените на реальную ссылку, где будет храниться node_monitor.sh
MONITOR_SCRIPT_URL="https://raw.githubusercontent.com/Dr0ff/Validator-Tools/refs/heads/main/Node%20Monitor/multi_node_monitor.sh" 
MONITOR_SCRIPT_NAME="node_monitor.sh"

echo -e "Начинаем установку монитора нод.....\n"

# 1. Проверяем и создаем директорию
if [ ! -d "$MONITOR_INSTALL_DIR" ]; then
    echo "Директория ${MONITOR_INSTALL_DIR} не найдена. Создаю..."
    mkdir -p "$MONITOR_INSTALL_DIR" || { echo "Ошибка: Не удалось создать директорию ${MONITOR_INSTALL_DIR}. Проверьте права."; exit 1; }
    echo "Директория ${MONITOR_INSTALL_DIR} успешно создана."
else
    echo "Директория ${MONITOR_INSTALL_DIR} уже существует."
fi

# 2. Переходим в директорию установки
cd "$MONITOR_INSTALL_DIR" || { echo "Ошибка: Не удалось перейти в директорию ${MONITOR_INSTALL_DIR}."; exit 1; }

# 3. Скачиваем основной скрипт монитора
echo "Скачиваем основной скрипт монитора с github..."
curl -sL "$MONITOR_SCRIPT_URL" -o "$MONITOR_SCRIPT_NAME" || { echo "Ошибка: Не удалось скачать скрипт монитора."; exit 1; }
chmod +x "$MONITOR_SCRIPT_NAME" # Делаем его исполняемым
echo "Скрипт ${MONITOR_SCRIPT_NAME} успешно скачан и настроен."

echo ""
echo "Установка завершена! Теперь вам необходимо выполнить следующие шаги:"
echo -e "\n1. Откройте скачанный скрипт: nano ${MONITOR_INSTALL_DIR}/${MONITOR_SCRIPT_NAME}"
echo -e "\n2. Измените в нем следующие переменные вручную:"
echo "   - TELEGRAM_BOT_TOKEN"
echo "   - TELEGRAM_ALERT_CHAT_IDS"
echo "   - TELEGRAM_REPORT_CHAT_IDS"
echo "   - TELEGRAM_INFO_CHAT_IDS"
echo "   - USER_TO_PING (для тегов в Telegram, например, @YourUsername)"
echo "   - BASE_USER_HOME (абсолютный путь к домашнему каталогу пользователя, где лежат бинарники нод\n и .home директории, например, /home/Your_User_Name)"
echo "     В данном случае, если вы запускаете скрипт от пользователя 'lilfox', то значением будет /home/lilfox."
echo -e "\n3. Добавьте конфигурации для ваших сетей в ассоциативный массив NETWORKS."
echo -e "\n4. Добавьте задание в cron для пользователя, от которого хотите запускать монитор (обычно это ваш текущий пользователь):"
echo "   crontab -e"
echo "   Добавьте строку (например, для запуска каждые 10 минут):"
echo "   */10 * * * * ${MONITOR_INSTALL_DIR}/${MONITOR_SCRIPT_NAME}"
echo ""
echo "Для тестирования вручную: ${MONITOR_INSTALL_DIR}/${MONITOR_SCRIPT_NAME} --debug"

echo -e "\n\e[93mВнимательно изучите краткую инструкцию приведённую выше!\n\e[0m"

exit 0

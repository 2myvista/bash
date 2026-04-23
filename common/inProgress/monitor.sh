#!/bin/bash

# Функция для мониторинга лога
monitor_log() {
    local log_file="/home/pbk/pim/backend/var/log/dev-error-2025-08-26.log"
    
    # Используем tail с флагом -F для автоматического отслеживания ротации
    tail -F "$log_file" | while read -r line; do
        # Выводим каждую новую строку
        data=$(echo "$line" | sed -E 's/.*\[([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}:[0-9]{2}):[0-9]{2}\..*\].*/\3-\2-\1 \4/' )
        messageEerror=$(echo "$line" | grep -oE '[a-zA-Z]+\.[a-zA-Z]+:' | head -1)

        if echo "$line" | grep -qiE "app\."; then
            #echo "2 Найдено app."
            textError=$(echo "$line")
            atError=""
            #echo textError********************"$textError"
            #echo "$line"
        elif echo "$line" | grep -qiE "console\."; then
            #echo "2 Найдено console."
            textError=$(echo "$line" | grep -oP '(?<=Message: ").*?(?=\s*{"exception":)')
            atError=$(echo "$line" | grep -oP 'at /home.*?(?=","command":)')
            #echo atError********************"$atError"
            #echo
            #echo "$line"

        else
            #echo "вывод ошибки"
            #echo "**************"
            #echo "$(date '+%Y-%m-%d %H:%M:%S') - $line"
            textError=$(echo "$line" | grep -oP "(?<=$messageEerror)[^{]*")
            atError=$(echo "$line" | grep -o 'at [^"]*)"}' | tail -1 | sed 's/)"}$//') 

            #echo textError********************"$textError"
            #echo atError********************"$atError"

        fi
        echo "$data" "*" "$messageEerror" "*" "$textError" "$atError" 
        echo 
         #echo "$line"
        #echo 
        #echo 
    done
}

# Основной цикл скрипта
while true; do
    echo "--- Запуск мониторинга error.log ---"
    clear
    # Запускаем мониторинг
    monitor_log
    
    # Если tail завершился (что маловероятно при -F), ждем и перезапускаем
    echo "Мониторинг завершен, перезапуск через 5 секунд..."
    sleep 5
done

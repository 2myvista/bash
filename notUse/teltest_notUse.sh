#!/bin/sh

BOT_TOKEN="7407954714:AAGw9N24zbLTPiNRCgMCd_rotWA-sgYzKLM"
CHAT_ID="519543345"
LOG_DIR="/home/pbk/pim/backend/var/log"
DEBUG_LOG="/tmp/telegram_bot_debug.log"
ENABLE_DEBUG=true
MIN_DELAY=1
HOST_NAME="pim22"
FILE_PROD="dev"

log() {
    [ "$ENABLE_DEBUG" = "true" ] && echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$DEBUG_LOG"
}

send_alert() {
    local message="$1"
    local response

    response=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d "chat_id=$CHAT_ID" \
        -d "text=$message")

    if echo "$response" | grep -q '"retry_after"'; then
        retry_after=$(echo "$response" | grep -o '"retry_after":[0-9]*' | cut -d: -f2)
        log "Превышен лимит. Ждем $retry_after секунд..."
        sleep "$retry_after"
        response=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d "chat_id=$CHAT_ID" \
            -d "text=$message")
    fi

    [ "$ENABLE_DEBUG" = "true" ] && echo "Ответ API: $response" >> "$DEBUG_LOG"
    sleep "$MIN_DELAY"
}

get_log_file() {
    today=$(date +%Y-%m-%d)
    echo "$LOG_DIR/$FILE_PROD-error-$today.log"
}

while true; do
    LOG_FILE=$(get_log_file)
    
    if [ ! -f "$LOG_FILE" ]; then
        log "Файл лога $LOG_FILE не найден"
        sleep 60
        continue
    fi

    log "Мониторинг лога: $LOG_FILE"
    tail -n 0 -F "$LOG_FILE" | while read -r line; do
        case "$line" in
            *==*==*) continue ;;
        esac

        if echo "$line" | grep -qiE "error|warning|exception|critical"; then
            if echo "$line" | grep -qE '\[([0-9-]+)T([0-9:]+)\.'; then
                error_msg=$(echo "$line" | sed 's/^\[[^]]*\] *//; s/"/\\"/g')
                send_alert "$HOST_NAME ❌ Ошибка: $error_msg"
            else
                send_alert "$HOST_NAME ❌ Ошибка: $line"
            fi
        fi
        
        current_log_file=$(get_log_file)
        if [ "$current_log_file" != "$LOG_FILE" ]; then
            log "Обнаружена смена даты. Переключаемся на новый файл: $current_log_file"
            pkill -P $$ tail
            break
        fi
    done
    
    sleep 1
done
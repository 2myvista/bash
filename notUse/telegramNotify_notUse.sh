#!/bin/bash

BOT_TOKEN="7407954714:AAGw9N24zbLTPiNRCgMCd_rotWA-sgYzKLM"
CHAT_ID="519543345"
LOG_DIR="/home/pbk/pim/backend/var/log"
DEBUG_LOG="/tmp/telegram_bot_debug.log"
ENABLE_DEBUG=true
MIN_DELAY=1
HOST_NAME="pim22"
FILE_PROD="dev"

log() {
    if [ "$ENABLE_DEBUG" = "true" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$DEBUG_LOG"
    fi
}

send_alert() {
    local message="$1"
    local response
    
    response=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d "chat_id=$CHAT_ID" \
        -d "text=$message")
    
    if echo "$response" | grep -q '"retry_after"'; then
        retry_after=$(echo "$response" | grep -o '"retry_after":[0-9]*' | cut -d: -f2)
        log "Rate limit hit. Waiting $retry_after seconds..."
        sleep "$retry_after"
        response=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d "chat_id=$CHAT_ID" \
            -d "text=$message")
    fi
    
    if [ "$ENABLE_DEBUG" = "true" ]; then
        echo "API Response: $response" >> "$DEBUG_LOG"
    fi
    sleep "$MIN_DELAY"
}

monitor_log() {
    local log_file="$1"
    log "Monitoring log file: $log_file"
    
    tail -n 0 -F "$log_file" | while read -r line; do
        # Skip tail status messages
        if echo "$line" | grep -q '^==>.*<==$'; then
            continue
        fi
        
        # Check for date change
        current_date=$(date +%Y-%m-%d)
        if [ "$current_date" != "$TODAY" ]; then
            log "Date changed from $TODAY to $current_date"
            TODAY="$current_date"
            pkill -P $$ tail
            break
        fi
        
        # Check for error patterns
        if echo "$line" | grep -qiE "error|warning|exception|critical"; then
            if echo "$line" | grep -qE '\[([0-9-]+)T([0-9:]+)\.'; then
                error_msg=$(echo "$line" | sed 's/^\[[^]]*\] *//; s/"/\\"/g')
                send_alert "$HOST_NAME ❌ Error (${BASH_REMATCH[1]} ${BASH_REMATCH[2]}): $error_msg"
            else
                send_alert "$HOST_NAME ❌ Error: $line"
            fi
        fi
    done
}

# Main loop
TODAY=$(date +%Y-%m-%d)
while true; do
    LOG_FILE="$LOG_DIR/$FILE_PROD-error-$TODAY.log"
    
    if [ ! -f "$LOG_FILE" ]; then
        log "Log file $LOG_FILE not found. Waiting..."
        sleep 60
        continue
    fi
    
    monitor_log "$LOG_FILE"
    sleep 1
done
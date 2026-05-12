#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/updateSert.log"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log_message "=== Обновление SSL сертификатов ==="

if command -v ufw >/dev/null 2>&1; then
    log_message "Отключение UFW"
    ufw disable >> "$LOG_FILE" 2>&1
fi

log_message "Проверка nginx"
if ! nginx -t >> "$LOG_FILE" 2>&1; then
    log_message "❌ Ошибка конфигурации nginx"

    if command -v ufw >/dev/null 2>&1; then
        log_message "Включение UFW"
        ufw --force enable >> "$LOG_FILE" 2>&1
    fi

    exit 1
fi

log_message "Обновление сертификатов"

if certbot renew --nginx >> "$LOG_FILE" 2>&1; then
    log_message "✅ Certbot выполнен успешно"

    log_message "Перезагрузка nginx"
    systemctl reload nginx >> "$LOG_FILE" 2>&1
else
    log_message "❌ Certbot завершился с ошибкой (см. вывод выше)"
fi

if command -v ufw >/dev/null 2>&1; then
    log_message "Включение UFW"
    ufw --force enable >> "$LOG_FILE" 2>&1
fi

log_message "=== Обновление завершено ==="#!/bin/bash

set -u

LOG_FILE="/var/log/updateSert.log"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_message "=== Запуск обновления SSL сертификатов ==="

log_message "Проверка nginx"
if ! nginx -t >> "$LOG_FILE" 2>&1; then
    log_message "❌ Ошибка конфигурации nginx"
    exit 1
fi

log_message "Обновление сертификатов"

if certbot renew --nginx >> "$LOG_FILE" 2>&1; then
    log_message "✅ Certbot выполнен успешно"

    log_message "Перезагрузка nginx"
    systemctl reload nginx
else
    log_message "❌ Certbot завершился с ошибкой"
    log_message "nginx не останавливался, сервис должен продолжать работать"
    exit 1
fi

log_message "=== Обновление завершено ==="
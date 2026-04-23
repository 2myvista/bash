#!/bin/bash

set -eu

LOG_FILE="/var/log/updateSert.log"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_message "=== Запуск обновления SSL сертификатов ==="

# Отключаем UFW только если он установлен
if command -v ufw >/dev/null 2>&1; then
    log_message "Отключение UFW"
    ufw disable
fi

# Останавливаем nginx
log_message "Остановка nginx"
systemctl stop nginx

# Обновляем сертификаты
log_message "Обновление сертификатов"

# if certbot renew 2>&1 | tee -a "$LOG_FILE"; then		# вывод на экран и в файл
if certbot renew >> "$LOG_FILE" 2>&1; then			# вывод только в файл
    log_message "✅ Certbot выполнен успешно"
else
    log_message "❌ Certbot завершился с ошибкой (см. вывод выше)"
fi

# Включаем UFW (если установлен) БЕЗ запроса пользователя
if command -v ufw >/dev/null 2>&1; then
    log_message "Включение UFW"
    ufw --force enable  # Теперь без echo "y" |
fi

# Запускаем nginx
log_message "Запуск nginx"
pkill nginx 2>/dev/null || true
systemctl start nginx

log_message "=== Обновление завершено ==="

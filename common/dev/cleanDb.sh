#!/bin/bash

# Скрипт для безопасного пересоздания базы данных PostgreSQL

DB_NAME=$1
DB_OWNER=$2

if [ -z "$DB_NAME" ]; then
    echo -e "Для запуска используйте cleanDb <название_базы владелец_базы>\n"
    exit 1
fi
if [ -z "$DB_OWNER" ]; then
    DB_OWNER='ergodbu'
    echo "Установлен владелец по умолчанию: ergodbu"
fi

echo "=== Пересоздание базы данных $DB_NAME ==="

# Проверяем существование пользователя ergodbu
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_OWNER'" | grep -q 1; then
    echo "ОШИБКА: Пользователь $DB_OWNER не существует!"
    exit 1
fi

# Проверяем существование базы данных DB_NAME
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
    echo "База данных '$DB_NAME' существует."
else
    echo "База данных '$DB_NAME' не существует."
    exit 1
fi

# Выполняем операции с базой данных
sudo -u postgres psql << EOF
    -- Пытаемся запретить новые подключения (если база существует)
    ALTER DATABASE $DB_NAME ALLOW_CONNECTIONS = off;
    
    -- Завершаем активные подключения
    SELECT pg_terminate_backend(pg_stat_activity.pid) 
    FROM pg_stat_activity 
    WHERE pg_stat_activity.datname = '$DB_NAME' 
    AND pid <> pg_backend_pid();
    
    -- Удаляем базу данных если она существует
    DROP DATABASE IF EXISTS $DB_NAME;
    
    -- Создаем новую базу данных
    CREATE DATABASE $DB_NAME 
    ENCODING 'UTF8' 
    OWNER $DB_OWNER;
    
    -- Разрешаем подключения
    ALTER DATABASE $DB_NAME ALLOW_CONNECTIONS = on;
    
    -- Выводим информацию о созданной базе
    \c $DB_NAME
    SELECT 'База данных создана: ' || current_database() AS status;
    \dn
EOF

echo "=== Операция завершена ==="

realpath ~/test
echo -e "выполните команду\n"
echo -e "sudo -u postgres psql -h localhost -U ergodbu -W '$DB_NAME' < название_backup.dump\n"
echo -e "если архив *.gz\n"
echo -e "gunzip -c ergo_full_04_03_2026.dump.gz | sudo -u postgres psql -h localhost -U ergodbu -d '$DB_NAME'\n"
#!/bin/sh

PSQL="/usr/bin/psql"
PGDUMP="/usr/bin/pg_dump"
SERVICE="/usr/sbin/service"
SUDO="/usr/bin/sudo"

OWNER="ergonode:ergonode"
TARGET_DIR="/home/ergonode/test"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root"
    exit 1
fi

DB_NAME="$1"

if [ -z "$DB_NAME" ]; then
    echo "Usage: $0 <database_name>"
    exit 1
fi

DUMP_FILE="/tmp/ergo_full_$(date +%d_%m_%Y).dump"
TARGET_FILE="$TARGET_DIR/ergo_full_$(date +%d_%m_%Y).dump"

echo "Database: $DB_NAME"
echo "Dump file: $DUMP_FILE"

if ! $SUDO -u postgres $PSQL -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
    echo "Database $DB_NAME not found"
    exit 1
fi

mkdir -p "$TARGET_DIR"

$SERVICE nginx stop >/dev/null

OLDMAX=$($SUDO -u postgres $PSQL "$DB_NAME" -t -c "SHOW max_connections;" 2>/dev/null | tr -d ' ')

$SUDO -u postgres $PSQL -c "ALTER DATABASE $DB_NAME CONNECTION LIMIT 0;" >/dev/null 2>/dev/null

$SUDO -u postgres $PSQL -c \
"SELECT pg_terminate_backend(pid)
 FROM pg_stat_activity
 WHERE datname = '$DB_NAME'
 AND pid <> pg_backend_pid();" >/dev/null 2>/dev/null

$SUDO -u postgres $PGDUMP "$DB_NAME" > "$DUMP_FILE"

DUMP_STATUS=$?

$SUDO -u postgres $PSQL -c "ALTER DATABASE $DB_NAME CONNECTION LIMIT $OLDMAX;" >/dev/null 2>/dev/null

$SERVICE nginx start >/dev/null

if [ "$DUMP_STATUS" -ne 0 ]; then
    echo "pg_dump failed"
    rm -f "$DUMP_FILE"
    exit 1
fi

chown "$OWNER" "$DUMP_FILE"
mv -v "$DUMP_FILE" "$TARGET_FILE"

echo "Done: $TARGET_FILE"
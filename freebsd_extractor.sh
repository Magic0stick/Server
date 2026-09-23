#!/bin/sh
# freebsd_extractor.sh
# Автономный скрипт сбора данных, запускаемый непосредственно внутри FreeBSD
# Версия 4.0: Защита диска (/var/tmp) и пуленепробиваемый AWK-парсинг Nextcloud

# === КОНФИГУРАЦИЯ ПОДКЛЮЧЕНИЯ К WINDOWS ===
WIN_HOST_IP="10.10.0.10"
WIN_SHARE="MigrationStorage"
WIN_USER="admin"
WIN_PASS="F@il2511"

# === ИНИЦИАЛИЗАЦИЯ И ИСПРАВЛЕНИЕ РАЗДЕЛОВ (Перенос в /var/tmp) ===
CURRENT_IP=$(ifconfig | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | head -n 1)
TMP_DIR="/var/tmp/local_backup_$$"
MNT_DIR="/var/tmp/win_share_$$"

mkdir -p "$TMP_DIR"
mkdir -p "$MNT_DIR"

# Ловушка очистки: гарантированно размонтируем шару и удалим локальный мусор при любом исходе
cleanup() {
    echo "[*] Запуск финальной очистки временных файлов в /var/tmp..."
    umount -f "$MNT_DIR" 2>/dev/null
    rm -rf "$TMP_DIR"
    rm -rf "$MNT_DIR"
}
trap cleanup EXIT INT TERM

echo "========================================================="
echo " Запуск автономного сборщика на FreeBSD хосте: $CURRENT_IP"
echo "========================================================="

# 1. МОНТИРОВАНИЕ СЕТЕВОЙ ПАПКИ WINDOWS
echo "[1/6] Подключение к сетевой папке Windows хоста..."
echo "$WIN_PASS" | mount_smbfs -N -I $WIN_HOST_IP -U $WIN_USER //$WIN_USER@$WIN_HOST_IP/$WIN_SHARE $MNT_DIR 2>/dev/null

if ! mount | grep "$MNT_DIR" >/dev/null 2>&1; then
    echo "❌ ОШИБКА: Не удалось примонтировать сетевую папку Windows!"
    echo "Проверьте, что папка расшарена на 10.10.0.10 и доступы верны."
    exit 1
fi
echo "✅ Сетевой диск Windows успешно примонтирован."

# 2. БЭКАП БАЗ ДАННЫХ (MySQL/MariaDB/Postgres)
echo "[2/6] Сбор дампов баз данных..."
DB_DUMP="$TMP_DIR/db_dump.sql"
touch "$DB_DUMP"

for db_p in "F@il2511" "32!p0mik!23" "admin"; do
    if command -v mysqldump >/dev/null 2>&1 || command -v mariadb-dump >/dev/null 2>&1; then
        DB_TOOL=$(command -v mysqldump || command -v mariadb-dump)
        $DB_TOOL -u root -p"$db_p" --all-databases > "$DB_DUMP" 2>/dev/null
        [ -s "$DB_DUMP" ] && echo "  -> Успешный дамп MySQL с паролем СУБД." && break
        
        $DB_TOOL -u admin -p"$db_p" --all-databases > "$DB_DUMP" 2>/dev/null
        [ -s "$DB_DUMP" ] && echo "  -> Успешный дамп MySQL (admin) с паролем СУБД." && break
    fi
done

if command -v pg_dumpall >/dev/null 2>&1; then
    echo "  -> Обнаружен PostgreSQL. Сбор дампа..."
    su - postgres -c "pg_dumpall" > "$TMP_DIR/db_pg.sql" 2>/dev/null
    [ -s "$TMP_DIR/db_pg.sql" ] && cat "$TMP_DIR/db_pg.sql" >> "$DB_DUMP" && rm -f "$TMP_DIR/db_pg.sql"
fi

# 3. СБОР СИСТЕМНЫХ КОНФИГУРАЦИЙ И SSL СЕРТИФИКАТОВ
echo "[3/6] Сканирование и архивация конфигураций..."
CONF_LIST="$TMP_DIR/files_list.txt"
touch "$CONF_LIST"

find /etc /usr/local/etc /var/www /usr/local/www /var/mail /var/vmail -maxdepth 6 \
    \( -path "/dev" -o -path "/proc" -o -path "/sys" -o -path "/tmp" -o -path "/var/tmp" \) -prune -o \
    -type f \( -name "*.conf" -o -name "*.cfg" -o -name "*.crt" -o -name "*.key" -o -name "*.pem" -o -name "*.pfx" -o -name "in4_LanWanLogin.txt" -o -name "config.php" \) \
    -print > "$CONF_LIST" 2>/dev/null

if [ -s "$CONF_LIST" ]; then
    tar -czpf "$TMP_DIR/configs_and_ssl.tar.gz" -T "$CONF_LIST" 2>/dev/null
fi
rm -f "$CONF_LIST"

# 4. СПЕЦ-БЛОК: NEXTCLOUD (Исправлен на пуленепробиваемый AWK-парсинг)
echo "[4/6] Проверка наличия Nextcloud..."
NC_CONF=$(find /usr/local/www /var/www /var/www/html -maxdepth 5 -name "config.php" 2>/dev/null | grep nextcloud | head -n 1)

if [ -n "$NC_CONF" ] && [ -f "$NC_CONF" ]; then
    echo "  -> Найден Nextcloud. Сбор структуры..."
    NC_ROOT=$(dirname $(dirname "$NC_CONF"))
    
    # Бэкап ядра движка (exclude до папки пути во FreeBSD tar)
    tar -czf "$TMP_DIR/nc_core.tar.gz" --exclude=data -C "$NC_ROOT" . 2>/dev/null
    
    # Пуленепробиваемый AWK-парсинг значения datadirectory вне зависимости от переносов строк и табов
    DATA_PATH=$(awk -F "=>" '/datadirectory/ {gsub(/[ \t\x27\",;]/,"",$2); print $2}' "$NC_CONF" | head -n 1)
    
    if [ -n "$DATA_PATH" ] && [ -d "$DATA_PATH" ]; then
        echo "  -> Упаковка пользовательских хранилищ из: $DATA_PATH..."
        tar -czf "$TMP_DIR/nc_user_files.tar.gz" -C "$DATA_PATH" . 2>/dev/null
    else
        echo "  -> ⚠️ Предупреждение: Путь данных Nextcloud не определен или пуст через AWK."
    fi
fi

# 5. СПЕЦ-БЛОК: ТЕЛЕФОНИЯ ASTERISK И КОРПОРАТИВНАЯ ПОЧТА
echo "[5/6] Архивация сервисов телефонии и почты..."
if [ -d "/usr/local/etc/asterisk" ]; then tar -czpf "$TMP_DIR/asterisk_usr.tar.gz" -C /usr/local/etc asterisk 2>/dev/null; fi
if [ -d "/etc/asterisk" ]; then tar -czpf "$TMP_DIR/asterisk_etc.tar.gz" -C /etc asterisk 2>/dev/null; fi
if [ -d "/var/spool/asterisk" ]; then tar -czpf "$TMP_DIR/asterisk_spool.tar.gz" -C /var/spool asterisk 2>/dev/null; fi

MAIL_ITEMS=""
[ -d "/var/mail" ] && MAIL_ITEMS="$MAIL_ITEMS var/mail"
[ -d "/var/vmail" ] && MAIL_ITEMS="$MAIL_ITEMS var/vmail"
[ -d "/usr/local/etc/postfix" ] && MAIL_ITEMS="$MAIL_ITEMS usr/local/etc/postfix"
[ -d "/usr/local/etc/dovecot" ] && MAIL_ITEMS="$MAIL_ITEMS usr/local/etc/dovecot"

if [ -n "$MAIL_ITEMS" ]; then
    tar -czpf "$TMP_DIR/mail_full.tar.gz" -C / $MAIL_ITEMS 2>/dev/null
fi

# 6. ФИНАЛЬНАЯ ПАКОВКА (Перенесено в /var/tmp для защиты от переполнения RAM/tmpfs)
echo "[6/6] Создание локального итогового архива..."
FINAL_ZIP_NAME="backup_host_${CURRENT_IP}_$(date +%Y%m%d_%H%M).tar.gz"
LOCAL_ARCHIVE_PATH="/var/tmp/$FINAL_ZIP_NAME"

# Упаковываем всё содержимое во временную локальную директорию на основном диске
tar -czf "$LOCAL_ARCHIVE_PATH" -C "$TMP_DIR" . 2>/dev/null

if [ -f "$LOCAL_ARCHIVE_PATH" ]; then
    echo "[*] Передача готового бэкапа по сети на Windows-хост..."
    # Копируем готовый монолитный файл на примонтированную шару
    cp -p "$LOCAL_ARCHIVE_PATH" "$MNT_DIR/" 2>/dev/null
    
    if [ -f "$MNT_DIR/$FINAL_ZIP_NAME" ]; then
        echo "========================================================="
        echo " 🎉 БЭКАП УСПЕШНО СФОРМИРОВАН И ПЕРЕДАН НА WINDOWS ХОСТ!"
        echo " Файл на хосте: C:\\MigrationStorage\\$FINAL_ZIP_NAME"
        echo "========================================================="
    else
        echo "❌ ОШИБКА: Сетевое копирование не удалось. Проверьте права на запись шары Windows."
    fi
    # Зачищаем локальный тяжелый архив за собой
    rm -f "$LOCAL_ARCHIVE_PATH"
else
    echo "❌ ОШИБКА: Не удалось локально в /var/tmp собрать итоговый архив."
fi

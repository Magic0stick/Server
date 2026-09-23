#!/bin/sh
# freebsd_extractor.sh
# Автономный скрипт сбора данных, запускаемый непосредственно внутри FreeBSD
# Версия 6.0: Интегрирован Nextcloud Maintenance Mode и защита от дублирования данных

# === КОНФИГУРАЦИЯ ПОДКЛЮЧЕНИЯ К WINDOWS ===
WIN_HOST_IP="10.10.0.10"
WIN_SHARE="MigrationStorage"
WIN_USER="admin"
WIN_PASS="F@il2511"

# === ИНИЦИАЛИЗАЦИЯ И ИСПРАВЛЕНИЕ РАЗДЕЛОВ ===
CURRENT_IP=$(ifconfig | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | head -n 1)
TMP_DIR="/var/tmp/local_backup_$$"
MNT_DIR="/var/tmp/win_share_$$"

mkdir -p "$TMP_DIR"
mkdir -p "$MNT_DIR"

# Ловушка очистки: при любом исходе гарантированно выключаем Maintenance Mode, размонтируем шару и удалим мусор
cleanup() {
    echo "[*] Финализация: отключение режима обслуживания Nextcloud (если был включен)..."
    if [ -n "$NC_OCC_PATH" ] && [ -f "$NC_OCC_PATH" ]; then
        # Определяем пользователя, под которым крутится веб-сервер во FreeBSD (обычно www)
        NC_USER=$(stat -f '%Su' "$NC_OCC_PATH" 2>/dev/null || echo "www")
        su -m "$NC_USER" -c "php $NC_OCC_PATH maintenance:mode --off" >/dev/null 2>&1
    fi

    echo "[*] Запуск очистки временных файлов в /var/tmp..."
    umount -f "$MNT_DIR" 2>/dev/null
    rm -rf "$TMP_DIR"
    rm -rf "$MNT_DIR"
}
trap cleanup EXIT INT TERM

echo "========================================================="
echo " Запуск автономного сборщика на FreeBSD хосте: $CURRENT_IP"
echo "========================================================="

# 0. ПРЕДВАРИТЕЛЬНЫЙ ПОИСК NEXTCLOUD OCC ДЛЯ ДАЛЬНЕЙШЕГО БЛОКИРОВАНИЯ
# Нам нужно найти occ заранее, чтобы заморозить базу перед Шагом 2
NC_OCC_PATH=$(find /usr/local/www /var/www /var/www/html -maxdepth 6 -name "occ" 2>/dev/null | grep nextcloud | head -n 1)

if [ -n "$NC_OCC_PATH" ] && [ -f "$NC_OCC_PATH" ]; then
    NC_USER=$(stat -f '%Su' "$NC_OCC_PATH" 2>/dev/null || echo "www")
    echo "🔐 [NEXTCLOUD] Включение режима обслуживания (Maintenance Mode) для обеспечения консистентности..."
    su -m "$NC_USER" -c "php $NC_OCC_PATH maintenance:mode --on" >/dev/null 2>&1
fi

# 1. МОНТИРОВАНИЕ СЕТЕВОЙ ПАПКИ WINDOWS
echo "[1/6] Подключение к сетевой папке Windows хоста..."
echo "$WIN_PASS" | mount_smbfs -N -I $WIN_HOST_IP -U $WIN_USER //$WIN_USER@$WIN_HOST_IP/$WIN_SHARE $MNT_DIR 2>/dev/null

if ! mount | grep "$MNT_DIR" >/dev/null 2>&1; then
    echo "❌ ОШИБКА: Не удалось примонтировать сетевую папку Windows!"
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

# 4. СПЕЦ-БЛОК: NEXTCLOUD (Ядро + файлы пользователей)
echo "[4/6] Проверка наличия Nextcloud..."
NC_CONF=$(find /usr/local/www /var/www /var/www/html -maxdepth 5 -name "config.php" 2>/dev/null | grep nextcloud | head -n 1)
NC_DATA_PATH=""

if [ -n "$NC_CONF" ] && [ -f "$NC_CONF" ]; then
    echo "  -> Найден Nextcloud. Сбор структуры..."
    NC_ROOT=$(dirname $(dirname "$NC_CONF"))
    
    # Бэкап ядра движка (exclude до папки пути во FreeBSD tar)
    tar -czf "$TMP_DIR/nc_core.tar.gz" --exclude=data -C "$NC_ROOT" . 2>/dev/null
    
    # Пуленепробиваемый AWK-парсинг значения datadirectory вне зависимости от переносов строк и табов
    NC_DATA_PATH=$(awk -F "=>" '/datadirectory/ {gsub(/[ \t\x27\",;]/,"",$2); print $2}' "$NC_CONF" | head -n 1)
    
    if [ -n "$NC_DATA_PATH" ] && [ -d "$NC_DATA_PATH" ]; then
        echo "  -> Упаковка пользовательских хранилищ из: $NC_DATA_PATH..."
        tar -czf "$TMP_DIR/nc_user_files.tar.gz" -C "$NC_DATA_PATH" . 2>/dev/null
    else
        echo "  -> ⚠️ Предупреждение: Путь данных Nextcloud не определен или пуст через AWK."
    fi
fi

# 5. СПЕЦ-БЛОК: ТЕЛЕФОНИЯ, ПОЧТА И ВЕБ-СЕРВЕРЫ (САЙТЫ)
echo "[5/6] Архивация сервисов телефонии, почты и веб-ресурсов..."
# АТС Asterisk
if [ -d "/usr/local/etc/asterisk" ]; then tar -czpf "$TMP_DIR/asterisk_usr.tar.gz" -C /usr/local/etc asterisk 2>/dev/null; fi
if [ -d "/etc/asterisk" ]; then tar -czpf "$TMP_DIR/asterisk_etc.tar.gz" -C /etc asterisk 2>/dev/null; fi
if [ -d "/var/spool/asterisk" ]; then tar -czpf "$TMP_DIR/asterisk_spool.tar.gz" -C /var/spool asterisk 2>/dev/null; fi

# Почта
MAIL_ITEMS=""
[ -d "/var/mail" ] && MAIL_ITEMS="$MAIL_ITEMS var/mail"
[ -d "/var/vmail" ] && MAIL_ITEMS="$MAIL_ITEMS var/vmail"
[ -d "/usr/local/etc/postfix" ] && MAIL_ITEMS="$MAIL_ITEMS usr/local/etc/postfix"
[ -d "/usr/local/etc/dovecot" ] && MAIL_ITEMS="$MAIL_ITEMS usr/local/etc/dovecot"

if [ -n "$MAIL_ITEMS" ]; then
    tar -czpf "$TMP_DIR/mail_full.tar.gz" -C / $MAIL_ITEMS 2>/dev/null
fi

# Выкачка веб-серверов и сайтов целиком (Тело сайтов)
WEB_ITEMS=""
[ -d "/usr/local/www" ] && WEB_ITEMS="$WEB_ITEMS usr/local/www"
[ -d "/var/www" ] && WEB_ITEMS="$WEB_ITEMS var/www"

if [ -n "$WEB_ITEMS" ]; then
    echo "  -> Обнаружены папки веб-серверов. Упаковка сайтов..."
    
    # 🔥 ИСПРАВЛЕНИЕ БАГА #2: Защита от дублирования файлов Nextcloud
    # Если на этой ВМ был найден Nextcloud, исключаем его папку data из общего архива веб-сервера
    if [ -n "$NC_DATA_PATH" ]; then
        # Превращаем абсолютный путь в относительный для корректной работы --exclude в tar
        EXCLUDE_DATA_DIR=$(echo "$NC_DATA_PATH" | sed 's/^\///')
        tar -czpf "$TMP_DIR/web_servers_data.tar.gz" --exclude="$EXCLUDE_DATA_DIR" -C / $WEB_ITEMS 2>/dev/null
    else
        tar -czpf "$TMP_DIR/web_servers_data.tar.gz" -C / $WEB_ITEMS 2>/dev/null
    fi
fi

# 6. ФИНАЛЬНАЯ ПАКОВКА
echo "[6/6] Создание локального итогового архива..."
FINAL_ZIP_NAME="backup_host_${CURRENT_IP}_$(date +%Y%m%d_%H%M).tar.gz"
LOCAL_ARCHIVE_PATH="/var/tmp/$FINAL_ZIP_NAME"

tar -czf "$LOCAL_ARCHIVE_PATH" -C "$TMP_DIR" . 2>/dev/null

if [ -f "$LOCAL_ARCHIVE_PATH" ]; then
    echo "[*] Передача готового бэкапа по сети на Windows-хост..."
    cp -p "$LOCAL_ARCHIVE_PATH" "$MNT_DIR/" 2>/dev/null
    
    if [ -f "$MNT_DIR/$FINAL_ZIP_NAME" ]; then
        echo "========================================================="
        echo " 🎉 БЭКАП УСПЕШНО СФОРМИРОВАН И П ПЕРЕДАН НА WINDOWS ХОСТ!"
        echo " Файл на хосте: C:\\MigrationStorage\\$FINAL_ZIP_NAME"
        echo "========================================================="
    else
        echo "❌ ОШИБКА: Сетевое копирование не удалось. Проверьте права на запись шары Windows."
    fi
    rm -f "$LOCAL_ARCHIVE_PATH"
else
    echo "❌ ОШИБКА: Не удалось локально в /var/tmp собрать итоговый архив."
fi

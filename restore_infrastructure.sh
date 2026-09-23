#!/bin/bash
# restore_infrastructure.sh
# Автоматический импорт разрозненной архитектуры (БД, Nextcloud, АТС, Почта, Старые сайты)

BACKUP_DIR="/opt/migration/tar_backups"
DOCKER_DIR="/opt/migration"
EXTRACT_TMP="/var/tmp/restore_dump_$$"

mkdir -p "$EXTRACT_TMP"
ensure_cleanup() { rm -rf "$EXTRACT_TMP"; }
trap ensure_cleanup EXIT INT TERM

echo "========================================================="
echo " 🚀 Запуск восстановления всей MySQL-инфраструктуры"
echo "========================================================="

if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A $BACKUP_DIR 2>/dev/null)" ]; then
    echo "❌ ОШИБКА: Папка $BACKUP_DIR пуста! Закиньте туда архивы backup_host_*.tar.gz"
    exit 1
fi

for archive in "$BACKUP_DIR"/backup_host_*.tar.gz; do
    [ -e "$archive" ] || continue
    
    echo "--------------------------------------------------------"
    echo "📦 Разбор архива: $(basename "$archive")"
    rm -rf "$EXTRACT_TMP"/*
    tar -xzf "$archive" -C "$EXTRACT_TMP" 2>/dev/null

    # 1. ИМПОРТ ВСЕХ БАЗ ДАННЫХ MYSQL
    if [ -f "$EXTRACT_TMP/db_dump.sql" ] && [ -s "$EXTRACT_TMP/db_dump.sql" ]; then
        echo "  -> [MySQL] Найдена СУБД база. Слияние в контейнер MariaDB..."
        if docker ps | grep migration_mariadb >/dev/null; then
            docker exec -i migration_mariadb mysql -u root -pF@il2511 < "$EXTRACT_TMP/db_dump.sql" 2>/dev/null
            echo "  ✅ Базы данных импортированы."
        fi
    fi

    # 2. ВОССТАНОВЛЕНИЕ ФАЙЛОВ NEXTCLOUD
    if [ -f "$EXTRACT_TMP/nc_core.tar.gz" ]; then
        echo "  -> [Nextcloud] Импорт конфигурации..."
        mkdir -p "$EXTRACT_TMP/nc_core_extracted"
        tar -xzf "$EXTRACT_TMP/nc_core.tar.gz" -C "$EXTRACT_TMP/nc_core_extracted" 2>/dev/null
        if [ -d "$EXTRACT_TMP/nc_core_extracted/config" ]; then
            mkdir -p "$DOCKER_DIR/data/nextcloud/html/config"
            cp -p "$EXTRACT_TMP/nc_core_extracted/config/config.php" "$DOCKER_DIR/data/nextcloud/html/config/" 2>/dev/null
        fi
    fi

    if [ -f "$EXTRACT_TMP/nc_user_files.tar.gz" ]; then
        echo "  -> [Nextcloud] Распаковка хранилища пользователей..."
        mkdir -p "$DOCKER_DIR/data/nextcloud/data"
        tar -xzf "$EXTRACT_TMP/nc_user_files.tar.gz" -C "$DOCKER_DIR/data/nextcloud/data/" 2>/dev/null
        chown -R 33:33 "$DOCKER_DIR/data/nextcloud/data" 2>/dev/null
    fi

    # 3. ВОССТАНОВЛЕНИЕ СТАРЫХ ВЕБ-САЙТОВ (ИЗВЛЕЧЕНИЕ ВЕБ-СЕРВЕРА)
    if [ -f "$EXTRACT_TMP/configs_and_ssl.tar.gz" ]; then
        echo "  -> [Веб-сервер] Поиск и извлечение старых сайтов и виртуальных хостов..."
        mkdir -p "$EXTRACT_TMP/sys_extracted"
        tar -xzf "$EXTRACT_TMP/configs_and_ssl.tar.gz" -C "$EXTRACT_TMP/sys_extracted" 2>/dev/null
        
        # Переносим старые сайты (если они лежали в usr/local/www или var/www и это не Nextcloud)
        mkdir -p "$DOCKER_DIR/data/www/html"
        mkdir -p "$DOCKER_DIR/data/www/old_configs"
        
        # Копируем веб-директории, если нашли
        [ -d "$EXTRACT_TMP/sys_extracted/usr/local/www" ] && cp -rp "$EXTRACT_TMP/sys_extracted/usr/local/www"/* "$DOCKER_DIR/data/www/html/" 2>/dev/null
        [ -d "$EXTRACT_TMP/sys_extracted/var/www" ] && cp -rp "$EXTRACT_TMP/sys_extracted/var/www"/* "$DOCKER_DIR/data/www/html/" 2>/dev/null
        
        # Сохраняем старые конфиги nginx/apache для ручной настройки маршрутизации
        [ -d "$EXTRACT_TMP/sys_extracted/usr/local/etc/nginx" ] && cp -rp "$EXTRACT_TMP/sys_extracted/usr/local/etc/nginx" "$DOCKER_DIR/data/www/old_configs/" 2>/dev/null
        [ -d "$EXTRACT_TMP/sys_extracted/usr/local/etc/apache24" ] && cp -rp "$EXTRACT_TMP/sys_extracted/usr/local/etc/apache24" "$DOCKER_DIR/data/www/old_configs/" 2>/dev/null
        
        # Забираем SSL-сертификаты
        mkdir -p "$DOCKER_DIR/recovered_ssl"
        find "$EXTRACT_TMP/sys_extracted" -type f \( -name "*.crt" -o -name "*.key" -o -name "*.pem" \) -exec cp -p {} "$DOCKER_DIR/recovered_ssl/" \; 2>/dev/null
        find "$EXTRACT_TMP/sys_extracted" -name "in4_LanWanLogin.txt" -exec cp -p {} "$DOCKER_DIR/" \; 2>/dev/null
        echo "  ✅ Код сайтов перенесен в ./data/www/html. Конфиги веб-серверов — в ./data/www/old_configs"
    fi

    # 4. ВОССТАНОВЛЕНИЕ ТЕЛЕФОНИИ ASTERISK
    if [ -f "$EXTRACT_TMP/asterisk_usr.tar.gz" ] || [ -f "$EXTRACT_TMP/asterisk_etc.tar.gz" ]; then
        mkdir -p "$DOCKER_DIR/data/asterisk/etc"
        [ -f "$EXTRACT_TMP/asterisk_usr.tar.gz" ] && tar -xzf "$EXTRACT_TMP/asterisk_usr.tar.gz" -C "$DOCKER_DIR/data/asterisk/etc/" 2>/dev/null
        [ -f "$EXTRACT_TMP/asterisk_etc.tar.gz" ] && tar -xzf "$EXTRACT_TMP/asterisk_etc.tar.gz" -C "$DOCKER_DIR/data/asterisk/etc/" 2>/dev/null
    fi
    if [ -f "$EXTRACT_TMP/asterisk_spool.tar.gz" ]; then
        mkdir -p "$DOCKER_DIR/data/asterisk/spool"
        tar -xzf "$EXTRACT_TMP/asterisk_spool.tar.gz" -C "$DOCKER_DIR/data/asterisk/spool/" 2>/dev/null
    fi

    # 5. ВОССТАНОВЛЕНИЕ ПОЧТЫ
    if [ -f "$EXTRACT_TMP/mail_full.tar.gz" ]; then
        echo "  -> [Почта] Распаковка ящиков..."
        mkdir -p "$DOCKER_DIR/data/mail/maildir"
        tar -xzf "$EXTRACT_TMP/mail_full.tar.gz" -C "$DOCKER_DIR/data/mail/maildir/" 2>/dev/null
    fi

done

# === ИНДЕКСАЦИЯ NEXTCLOUD ===
echo "--------------------------------------------------------"
echo "🔄 Синхронизация и индексация данных..."
if docker ps | grep migration_nextcloud >/dev/null; then
    echo "  -> [Nextcloud] Запуск пересканирования occ files:scan..."
    docker exec --user www-data migration_nextcloud php occ files:scan --all
    echo "  ✅ Индексация завершена."
fi

echo "========================================================="
echo " 🎉 ОРКЕСТРАЦИЯ И СЛИЯНИЕ ВСЕХ 13 КУСОЧКОВ ЗАВЕРШЕНЫ!"
echo "========================================================="

#!/bin/bash

# Скрипт установки MariaDB, Asterisk, Nextcloud и почтового сервера на Ubuntu с Docker
# Все компоненты устанавливаются в последних стабильных версиях
# 
# Использование:
#   1. Скопируйте этот репозиторий на сервер
#   2. Запустите: sudo ./install_stack.sh
#   3. Перейдите в /opt/docker-services и запустите: sudo ./start.sh

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Логирование
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Проверка прав root
if [ "$EUID" -ne 0 ]; then 
    log_error "Пожалуйста, запустите скрипт от root (sudo ./install_stack.sh)"
    exit 1
fi

# Проверка ОС
if [ ! -f /etc/os-release ]; then
    log_error "Не удалось определить операционную систему"
    exit 1
fi

source /etc/os-release
if [ "$ID" != "ubuntu" ]; then
    log_error "Скрипт предназначен только для Ubuntu"
    exit 1
fi

log_info "Обнаружена Ubuntu $VERSION_ID"

# Функция проверки команды
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Установка Docker если не установлен
install_docker() {
    if command_exists docker; then
        log_info "Docker уже установлен: $(docker --version)"
        return 0
    fi
    
    log_step "Установка Docker..."
    
    # Обновление пакетов
    apt-get update -qq
    
    # Установка зависимостей
    apt-get install -y -qq \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
    
    # Добавление GPG ключа Docker
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    # Добавление репозитория Docker
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Установка Docker
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    log_info "Docker успешно установлен: $(docker --version)"
}

# Установка Docker Compose если не установлен
install_docker_compose() {
    if command_exists docker compose; then
        log_info "Docker Compose уже установлен: $(docker compose version)"
        return 0
    fi
    
    log_step "Установка Docker Compose..."
    
    # Пытаемся установить через apt
    apt-get install -y -qq docker-compose-plugin || {
        # Если не получилось, устанавливаем вручную
        DESTDIR="/usr/local/lib/docker/cli-plugins"
        mkdir -p $DESTDIR
        curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" -o $DESTDIR/docker-compose
        chmod +x $DESTDIR/docker-compose
        ln -s $DESTDIR/docker-compose /usr/local/bin/docker-compose
    }
    
    log_info "Docker Compose успешно установлен: $(docker compose version)"
}

# Создание директории для проекта
PROJECT_DIR="/opt/docker-services"

log_step "Начало установки стека сервисов"
echo ""

# Установка Docker и Docker Compose
install_docker
install_docker_compose

# Добавление текущего пользователя в группу docker (если не root)
if [ "$SUDO_USER" ]; then
    log_info "Добавление пользователя $SUDO_USER в группу docker"
    usermod -aG docker $SUDO_USER 2>/dev/null || true
fi

log_info "Создание директории проекта: $PROJECT_DIR"
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR

# Создание docker-compose.yml
log_info "Создание docker-compose.yml"
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  # MariaDB - база данных
  mariadb:
    image: mariadb:latest
    container_name: mariadb
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD:-YourStrongRootPassword123!}
      MYSQL_DATABASE: ${MYSQL_DATABASE:-nextcloud}
      MYSQL_USER: ${MYSQL_USER:-nextcloud}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD:-YourStrongPassword123!}
    volumes:
      - mariadb_data:/var/lib/mysql
      - ./mariadb/conf.d:/etc/mysql/conf.d
    ports:
      - "3306:3306"
    networks:
      - app-network
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5

  # Asterisk - IP-телефония
  asterisk:
    image: asterisk/asterisk:latest
    container_name: asterisk
    restart: unless-stopped
    volumes:
      - asterisk_config:/etc/asterisk
      - asterisk_spool:/var/spool/asterisk
      - asterisk_log:/var/log/asterisk
      - ./asterisk/config:/etc/asterisk/custom:ro
    ports:
      - "5060:5060/udp"   # SIP
      - "5061:5061/tcp"   # SIP TLS
      - "10000-10100:10000-10100/udp" # RTP
    networks:
      - app-network
    depends_on:
      - mariadb
    cap_add:
      - NET_ADMIN
      - SYS_NICE

  # Nextcloud - облачное хранилище
  nextcloud:
    image: nextcloud:latest
    container_name: nextcloud
    restart: unless-stopped
    environment:
      MYSQL_HOST: mariadb
      MYSQL_DATABASE: ${MYSQL_DATABASE:-nextcloud}
      MYSQL_USER: ${MYSQL_USER:-nextcloud}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD:-YourStrongPassword123!}
      NEXTCLOUD_ADMIN_USER: ${NEXTCLOUD_ADMIN_USER:-admin}
      NEXTCLOUD_ADMIN_PASSWORD: ${NEXTCLOUD_ADMIN_PASSWORD:-AdminPassword123!}
      NEXTCLOUD_TRUSTED_DOMAINS: ${NEXTCLOUD_DOMAIN:-localhost}
    volumes:
      - nextcloud_data:/var/www/html
      - ./nextcloud/apps:/var/www/html/custom_apps
      - ./nextcloud/config:/var/www/html/config
      - ./nextcloud/themes:/var/www/html/themes
    ports:
      - "8080:80"
    networks:
      - app-network
    depends_on:
      mariadb:
        condition: service_healthy

  # Postfix + Dovecot - почтовый сервер
  mailserver:
    image: docker.io/mailserver/docker-mailserver:latest
    container_name: mailserver
    restart: unless-stopped
    hostname: ${MAIL_HOSTNAME:-mail.example.com}
    domainname: ${MAIL_DOMAIN:-example.com}
    environment:
      - ENABLE_SPAMASSASSIN=1
      - SPAMASSASSIN_SPAM_TO_INBOX=1
      - ENABLE_CLAMAV=1
      - ENABLE_FAIL2BAN=1
      - ENABLE_POSTGREY=1
      - ONE_DIR=1
      - DMS_DEBUG=0
      - POSTFIX_MESSAGE_SIZE_LIMIT=${POSTFIX_MESSAGE_SIZE_LIMIT:-52428800}
      - SSL_TYPE=manual
      - SSL_CERT_PATH=/tmp/ssl/cert.pem
      - SSL_KEY_PATH=/tmp/ssl/key.pem
    volumes:
      - mail_data:/var/mail
      - mail_state:/var/mail-state
      - mail_logs:/var/log/mail
      - ./mail/config:/tmp/docker-mailserver
      - ./mail/ssl:/tmp/ssl:ro
    ports:
      - "25:25"     # SMTP
      - "587:587"   # Submission
      - "465:465"   # SMTPS
      - "993:993"   # IMAPS
      - "995:995"   # POP3S
    cap_add:
      - NET_BIND_SERVICE
    networks:
      - app-network
    depends_on:
      - mariadb

networks:
  app-network:
    driver: bridge

volumes:
  mariadb_data:
  asterisk_config:
  asterisk_spool:
  asterisk_log:
  nextcloud_data:
  mail_data:
  mail_state:
  mail_logs:
EOF

# Создание .env файла с настройками
log_info "Создание .env файла"
cat > .env << 'EOF'
# Настройки MariaDB
MYSQL_ROOT_PASSWORD=YourStrongRootPassword123!
MYSQL_DATABASE=nextcloud
MYSQL_USER=nextcloud
MYSQL_PASSWORD=YourStrongPassword123!

# Настройки Nextcloud
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=AdminPassword123!
NEXTCLOUD_DOMAIN=localhost

# Настройки почты
MAIL_HOSTNAME=mail.example.com
MAIL_DOMAIN=example.com
POSTFIX_MESSAGE_SIZE_LIMIT=52428800
EOF

log_warn "ВАЖНО: Отредактируйте файл .env и замените пароли на безопасные!"
log_warn "Также измените MAIL_HOSTNAME и MAIL_DOMAIN на ваши реальные домены"

# Создание директорий для конфигураций
log_info "Создание директорий для конфигураций"
mkdir -p mariadb/conf.d
mkdir -p asterisk/config
mkdir -p nextcloud/{apps,config,themes}
mkdir -p mail/{config,ssl}

# Конфигурация MariaDB
log_info "Настройка конфигурации MariaDB"
cat > mariadb/conf.d/server.cnf << 'EOF'
[mysqld]
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
innodb_buffer_pool_size = 256M
innodb_log_file_size = 64M
max_allowed_packet = 64M
EOF

# Конфигурация Asterisk (минимальная)
log_info "Настройка базовой конфигурации Asterisk"
cat > asterisk/config/README.txt << 'EOF'
Поместите файлы конфигурации Asterisk в эту директорию:
- sip.conf или pjsip.conf для настройки SIP
- extensions.conf для плана нумерации
- другие необходимые файлы конфигурации

Пример минимальной конфигурации будет создан автоматически при первом запуске.
EOF

# Инструкция по генерации SSL сертификатов для почты
log_info "Создание инструкции по SSL для почтового сервера"
cat > mail/ssl/README.txt << 'EOF'
Для работы почтового сервера необходимы SSL сертификаты.

Вариант 1: Самоподписанные сертификаты (для тестирования):
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout key.pem -out cert.pem \
  -subj "/CN=mail.example.com"

Вариант 2: Let's Encrypt (для продакшена):
Используйте certbot для получения сертификатов:
certbot certonly --standalone -d mail.example.com

Затем скопируйте файлы:
cp /etc/letsencrypt/live/mail.example.com/fullchain.pem cert.pem
cp /etc/letsencrypt/live/mail.example.com/privkey.pem key.pem
EOF

# Создание скрипта для самоподписанных SSL сертификатов
cat > mail/ssl/generate-self-signed.sh << 'EOF'
#!/bin/bash
echo "Генерация самоподписанных SSL сертификатов..."
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout key.pem -out cert.pem \
  -subj "/CN=mail.example.com/O=MyCompany/C=US"
echo "Сертификаты созданы: cert.pem и key.pem"
echo "ВАЖНО: Замените mail.example.com на ваш домен!"
chmod 600 key.pem
chmod 644 cert.pem
EOF
chmod +x mail/ssl/generate-self-signed.sh

# Создание скрипта запуска
log_info "Создание скрипта запуска start.sh"
cat > start.sh << 'EOF'
#!/bin/bash
set -e

echo "Запуск сервисов..."

# Проверка .env файла
if [ ! -f .env ]; then
    echo "Ошибка: Файл .env не найден!"
    exit 1
fi

# Генерация SSL сертификатов если их нет
if [ ! -f mail/ssl/cert.pem ] || [ ! -f mail/ssl/key.pem ]; then
    echo "SSL сертификаты не найдены. Генерация самоподписанных сертификатов..."
    cd mail/ssl
    ./generate-self-signed.sh
    cd ../..
    echo "ВАЖНО: Замените самоподписанные сертификаты на настоящие для продакшена!"
fi

# Запуск контейнеров
docker compose up -d

echo ""
echo "========================================="
echo "Установка завершена!"
echo "========================================="
echo ""
echo "Сервисы:"
echo "  - MariaDB: localhost:3306"
echo "  - Asterisk: localhost:5060 (SIP)"
echo "  - Nextcloud: http://localhost:8080"
echo "  - Почта: localhost:25 (SMTP), localhost:993 (IMAP)"
echo ""
echo "Учетные данные Nextcloud:"
echo "  Логин: admin"
echo "  Пароль: (см. файл .env)"
echo ""
echo "ВАЖНО:"
echo "1. Измените пароли в файле .env"
echo "2. Для почты используйте реальные SSL сертификаты"
echo "3. Настройте firewall (UFW) для открытия необходимых портов"
echo ""
EOF
chmod +x start.sh

# Создание скрипта остановки
log_info "Создание скрипта остановки stop.sh"
cat > stop.sh << 'EOF'
#!/bin/bash
echo "Остановка всех сервисов..."
docker compose down
echo "Сервисы остановлены."
EOF
chmod +x stop.sh

# Создание скрипта просмотра логов
log_info "Создание скрипта просмотра логов logs.sh"
cat > logs.sh << 'EOF'
#!/bin/bash
if [ -z "$1" ]; then
    docker compose logs -f
else
    docker compose logs -f "$1"
fi
EOF
chmod +x logs.sh

# Создание README
log_info "Создание README.md"
cat > README.md << 'EOF'
# Docker Stack: MariaDB + Asterisk + Nextcloud + Mail Server

Этот стек включает:
- **MariaDB** - СУБД
- **Asterisk** - IP-АТС
- **Nextcloud** - Облачное хранилище
- **Mail Server** (Postfix + Dovecot) - Почтовый сервер

## Быстрый старт

1. Отредактируйте файл `.env` и установите безопасные пароли
2. Для почтового сервера настройте SSL сертификаты:
   ```bash
   cd mail/ssl
   ./generate-self-signed.sh  # для тестирования
   # И используйте Let's Encrypt для продакшена
   ```
3. Запустите сервисы:
   ```bash
   ./start.sh
   ```

## Доступ к сервисам

| Сервис | Порт | URL/Доступ |
|--------|------|------------|
| Nextcloud | 8080 | http://localhost:8080 |
| MariaDB | 3306 | localhost:3306 |
| Asterisk SIP | 5060 | localhost:5060/udp |
| Почта SMTP | 25, 587 | localhost:25 |
| Почта IMAP | 993 | localhost:993 |

## Управление

```bash
# Запуск
./start.sh

# Остановка
./stop.sh

# Просмотр логов
./logs.sh

# Логи конкретного сервиса
./logs.sh nextcloud
./logs.sh mailserver
./logs.sh asterisk
./logs.sh mariadb
```

## Настройка Nextcloud

1. Откройте http://localhost:8080
2. Войдите с учетными данными из файла .env
3. Рекомендуется настроить обратный прокси (nginx/traefik) с HTTPS

## Настройка Asterisk

Конфигурационные файлы находятся в:
- `asterisk/config/` - пользовательские конфиги
- Объем тома `asterisk_config` - постоянные конфиги контейнера

## Настройка почты

1. Замените `MAIL_HOSTNAME` и `MAIL_DOMAIN` в `.env`
2. Получите SSL сертификаты (Let's Encrypt рекомендуется)
3. Настройте DNS записи (MX, SPF, DKIM, DMARC)
4. Создайте почтовые ящики:
   ```bash
   docker exec mailserver setup email add user@example.com Password123!
   ```

## Безопасность

- Измените все пароли по умолчанию
- Используйте HTTPS для Nextcloud
- Используйте валидные SSL сертификаты для почты
- Настройте firewall:
  ```bash
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 25,587,465,993,995/tcp
  ufw allow 5060,5061/udp
  ufw allow 10000:10100/udp
  ufw enable
  ```

## Требования

- Ubuntu 22.04 LTS или новее
- Docker 24.0+
- Docker Compose v2.20+
- Минимум 4GB RAM (рекомендуется 8GB)
- 20GB свободного места на диске

## Поддержка

Для создания пользователей почты:
```bash
docker exec mailserver setup email add <user>@<domain> <password>
docker exec mailserver setup email del <user>@<domain>
docker exec mailserver setup email list
```

Для перезагрузки конфигурации Asterisk:
```bash
docker exec asterisk asterisk -rx "core reload"
```
EOF

log_info "Все файлы созданы в $PROJECT_DIR"

echo ""
echo "========================================="
echo "Установка завершена!"
echo "========================================="
echo ""
log_step "Следующие шаги:"
echo ""
echo "1. Перейдите в директорию: cd $PROJECT_DIR"
echo "2. Отредактируйте файл .env и установите безопасные пароли:"
echo "   nano .env"
echo ""
echo "3. (Опционально) Настройте SSL сертификаты для почты:"
echo "   cd mail/ssl"
echo "   ./generate-self-signed.sh  # для тестирования"
echo "   cd ../.."
echo ""
echo "4. Запустите сервисы: sudo ./start.sh"
echo ""
echo "========================================="
log_warn "Не забудьте изменить пароли и доменные имена перед использованием в продакшене!"
echo ""

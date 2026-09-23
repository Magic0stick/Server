#!/bin/bash
# deploy_all.sh (установочка)
# Финальная версия: автоматизация настройки ОС, сети, Docker и сшивания бэкапов FreeBSD

set -e

PROJECT_DIR="/opt/migration"
BACKUP_DIR="$PROJECT_DIR/tar_backups"
EXTRACT_TMP="/var/tmp/restore_dump_$$"

# Цвета для вывода в консоль
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=========================================================${NC}"
echo -e "${BLUE} 🚀 ЗАПУСК ОСНОВНОГО УСТАНОВЩИКА ИЗ РЕПОЗИТОРИЯ GIT ${NC}"
echo -e "${BLUE}=========================================================${NC}"

# 1. ОБНОВЛЕНИЕ СИСТЕМЫ И УСТАНОВКА ЗАВИСИМОСТЕЙ
echo -e "${BLUE}[1/5] Установка системных утилит и сетевых служб...${NC}"
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl ufw jq openssl cifs-utils apache2-utils

# 2. НАСТРОЙКА БЕЗОПАСНОСТИ SSH (Порт 4422)
echo -e "${BLUE}[2/5] Перевод службы SSH на скрытый порт 4422...${NC}"
if ! grep -E "^Port 4422" /etc/ssh/sshd_config >/dev/null 2>&1; then
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    sudo sed -i 's/#Port 22/Port 4422/' /etc/ssh/sshd_config
    sudo sed -i 's/Port 22/Port 4422/' /etc/ssh/sshd_config
    sudo sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
    sudo sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
    sudo systemctl restart ssh
    echo -e "${GREEN}✅ Служба SSH переведена на порт 4422. Прямой root-вход заблокирован.${NC}"
else
    echo -e "${YELLOW}⚠️ Порт SSH уже изменен на 4422, пропускаем.${NC}"
fi

# 3. НАСТРОЙКА UFW БРАНДМАУЭРА (Исправлен риск блокировки текущей сессии)
echo -e "${BLUE}[3/5] Изоляция портов через брандмауэр UFW...${NC}"
sudo ufw default deny incoming
sudo ufw default allow outgoing

# ИСПРАВЛЕНИЕ: Открываем и старый порт 22, и новый порт 4422 до активации UFW, чтобы не потерять связь!
sudo ufw allow 22/tcp comment 'Временный SSH для текущей сессии'
sudo ufw allow 4422/tcp comment 'Скрытый постоянный SSH'

sudo ufw allow 80/tcp comment 'HTTP (prodick.ru)'
sudo ufw allow 443/tcp comment 'HTTPS (Сайт + Лазейка)'
sudo ufw allow 81/tcp comment 'Nginx Proxy Manager Admin'
sudo ufw allow 5060/udp comment 'SIP Asterisk'
sudo ufw allow 5160/udp comment 'SIP TLS Asterisk'
sudo ufw allow 10000:10100/udp comment 'RTP Voice Asterisk'
sudo ufw allow 25/tcp comment 'SMTP Mail'
sudo ufw allow 143/tcp comment 'IMAP Mail'
sudo ufw allow 587/tcp comment 'Submission Mail'
sudo ufw allow 993/tcp comment 'Secure IMAP'

echo "y" | sudo ufw enable
echo -e "${GREEN}✅ Брандмауэр UFW успешно запущен. Связь с текущей сессией сохранена.${NC}"

# 4. УСТАНОВКА DOCKER И DOCKER COMPOSE
echo -e "${BLUE}[4/5] Инсталляция компонентов Docker...${NC}"
if ! command -v docker >/dev/null 2>&1; then
    # ИСПРАВЛЕНИЕ: Используем корректный официальный URL скрипта установки
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh && rm -f get-docker.sh
    
    # Добавляем пользователя в группу
    sudo usermod -aG docker $USER
    echo -e "${GREEN}✅ Docker и плагин Compose успешно установлены.${NC}"
else
    echo -e "${YELLOW}⚠️ Docker уже присутствует в системе.${NC}"
fi

# 5. СОЗДАНИЕ ДИРЕКТОРИЙ ХРАНЕНИЯ ДАННЫХ КОНТЕЙНЕРОВ
echo -e "${BLUE}[5/5] Генерация локальных volumes для томов Docker...${NC}"
sudo mkdir -p "$BACKUP_DIR"
sudo mkdir -p "$PROJECT_DIR"/data/mysql
sudo mkdir -p "$PROJECT_DIR"/data/npm
sudo mkdir -p "$PROJECT_DIR"/data/nextcloud/html
sudo mkdir -p "$PROJECT_DIR"/data/nextcloud/data
sudo mkdir -p "$PROJECT_DIR"/data/asterisk/etc
sudo mkdir -p "$PROJECT_DIR"/data/asterisk/spool
sudo mkdir -p "$PROJECT_DIR"/data/mail/maildir
sudo mkdir -p "$PROJECT_DIR"/data/mail/old_configs
sudo mkdir -p "$PROJECT_DIR"/data/www/html
sudo mkdir -p "$PROJECT_DIR"/data/www/old_configs
sudo chown -R $USER:$USER "$PROJECT_DIR"

# 6. ЗАПУСК КОМПОЗА И АВТОМАТИЧЕСКОЕ СШИВАНИЕ
echo -e "${BLUE}Запуск контейнеров Docker из репозиторного docker-compose.yml...${NC}"
# ИСПРАВЛЕНИЕ: Вызываем docker compose через sudo, так как группа применится только после релогина
sudo docker compose up -d

echo -e "${YELLOW}Ожидание инициализации MariaDB (10 секунд)...${NC}"
sleep 10

# Проверка наличия архивов в папке перед запуском восстановления
if [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
    echo -e "${RED}⚠️ ВНИМАНИЕ: Папка tar_backups пуста!${NC}"
    echo -e "${YELLOW}Перенесите туда ваши файлы backup_host_*.tar.gz с Windows-шары C:\\MigrationStorage\\ и запустите восстановление вручную:${NC}"
    echo -e "${CYAN}cd /opt/migration && chmod +x restore_infrastructure.sh && ./restore_infrastructure.sh${NC}"
    echo -e "${GREEN}=========================================================${NC}"
    echo -e "${GREEN} 🎉 ОС ПОДГОТОВЛЕНА, КОНТЕЙНЕРЫ ЗАПУЩЕНЫ!${NC}"
    echo -e "${YELLOW} Новое подключение к серверу выполняйте по порту 4422:${NC}"
    echo -e "${CYAN} ssh $USER@\$(hostname -I | awk '{print \$1}') -p 4422${NC}"
    echo -e "${GREEN}=========================================================${NC}"
    exit 0
fi

# Запуск вашего штатного скрипта восстановления restore_infrastructure.sh, если бэкапы уже лежат на месте
if [ -f "restore_infrastructure.sh" ]; then
    chmod +x restore_infrastructure.sh
    ./restore_infrastructure.sh
fi

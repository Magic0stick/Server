# 1. Скачиваем ключ репозитория
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://tailscale.com | sudo tee /etc/apt/keyrings/tailscale-archive-keyring.gpg > /dev/null

# 2. Добавляем репозиторий в список apt
curl -fsSL https://tailscale.com | sudo tee /etc/apt/sources.list.d/tailscale.list

# 3. Обновляем кэш и ставим пакет (здесь вы точно увидите весь процесс)
sudo apt update && sudo apt install -y tailscale

sudo apt update && sudo apt install -y git && \
sudo mkdir -p /opt/migration && \
sudo git clone https://github.com /opt/migration && \
cd /opt/migration && chmod +x deploy_all.sh && ./deploy_all.sh

#!/bin/bash
# Скрипт для автоматической настройки Exit-ноды (VLESS xHTTP Reality + WARP)

# Проверка на root
if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mПожалуйста, запустите скрипт от имени root (sudo).\e[0m"
  exit 1
fi

echo -e "\e[34m=== Подготовка сервера Exit-ноды ===\e[0m"
read -p "Введите домен для маскировки (например, domain.com) или нажмите Enter для пропуска: " DOMAIN

# Генерация случайных параметров
PANEL_PORT=$(shuf -i 10000-60000 -n 1)
VPN_PORT=$(shuf -i 10000-60000 -n 1)
PANEL_USER=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
PANEL_PASS=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
PANEL_PATH=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
SERVER_IP=$(curl -s ifconfig.me)

export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
apt install -y curl socat ufw jq sqlite3 python3 nginx unzip lsb-release gnupg

# Настройка файрвола
echo -e "\e[34m=== Настройка UFW ===\e[0m"
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow $PANEL_PORT/tcp
ufw allow $VPN_PORT/tcp
ufw --force enable

# Установка dummy-сайта и SSL
if [ ! -z "$DOMAIN" ]; then
    echo -e "\e[34m=== Установка маскировочного сайта и Let's Encrypt ===\e[0m"
    apt install -y certbot python3-certbot-nginx
    cd /tmp
    wget -qO template.zip https://html5up.net/identity/download
    unzip -o template.zip -d /var/www/html/
    certbot --nginx -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN
else
    echo -e "\e[33mДомен не указан, пропускаем настройку SSL маскировки.\e[0m"
fi

# Установка Cloudflare WARP
echo -e "\e[34m=== Установка Cloudflare WARP ===\e[0m"
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor --yes -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/cloudflare-client.list
apt update && apt install -y cloudflare-warp
warp-cli --accept-tos registration new
warp-cli --accept-tos mode proxy
warp-cli --accept-tos proxy port 40000
warp-cli --accept-tos connect

# Установка 3x-ui
echo -e "\e[34m=== Установка 3X-UI ===\e[0m"
printf "y\n$PANEL_USER\n$PANEL_PASS\n$PANEL_PORT\n" | bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

# Ждем генерации БД и останавливаем
sleep 5
systemctl stop x-ui

# Настройка пути панели
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '/${PANEL_PATH}/' WHERE key = 'webBasePath';"

# Генерация ключей Xray
KEYS=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519)
PRI_KEY=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
PUB_KEY=$(echo "$KEYS" | grep "Public" | awk '{print $3}')

# Настройка базы 3x-ui через Python (Добавление Inbound xHTTP и маршрутизации WARP)
cat << 'EOF' > /tmp/setup_exit.py
import sqlite3, json, sys, uuid, secrets

vpn_port = int(sys.argv[1])
pri_key = sys.argv[2]
client_id = str(uuid.uuid4())
short_id = secrets.token_hex(4)

conn = sqlite3.connect('/etc/x-ui/x-ui.db')
c = conn.cursor()

# 1. Добавляем Inbound
settings = {
    "clients": [{"id": client_id, "flow": "", "email": "exit-client", "limitIp": 0, "totalGB": 0, "expiryTime": 0, "enable": True, "tgId": "", "subId": ""}],
    "decryption": "none",
    "fallbacks": []
}

stream_settings = {
    "network": "xhttp",
    "security": "reality",
    "xhttpSettings": {"mode": "auto", "host": "", "path": "/", "scMaxConcurrentPosts": "100-1000", "scMaxEachPostBytes": "1000000-10000000", "scMinPostsIntervalMs": "10-50", "noSSEHeader": False, "xPaddingBytes": "100-1000"},
    "realitySettings": {"show": False, "xver": 0, "dest": "dl.google.com:443", "serverNames": ["dl.google.com"], "privateKey": pri_key, "minClientVer": "", "maxClientVer": "", "maxTimeDiff": 0, "shortIds": [short_id]}
}

sniffing = {"enabled": True, "destOverride": ["http", "tls", "quic"], "routeOnly": False}

c.execute("""
    INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
""", (1, 0, 0, 0, "Exit-xHTTP-Reality", 1, 0, "", vpn_port, "vless", json.dumps(settings), json.dumps(stream_settings), f"inbound-{vpn_port}", json.dumps(sniffing)))

# 2. Добавляем Outbound WARP и Маршрутизацию
c.execute("SELECT value FROM settings WHERE key = 'xrayTemplateConfig'")
config = json.loads(c.fetchone()[0])

config.setdefault('outbounds', [])
config['outbounds'].append({
    "tag": "warp-socks", "protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": 40000}]}
})

config.setdefault('routing', {}).setdefault('rules', [])
config['routing']['rules'].insert(0, {
    "type": "field", "domain": ["geosite:google", "geosite:youtube"], "outboundTag": "warp-socks"
})

c.execute("UPDATE settings SET value = ? WHERE key = 'xrayTemplateConfig'", (json.dumps(config),))
conn.commit()
conn.close()

print(f"{client_id}|{short_id}")
EOF

OUTPUT=$(python3 /tmp/setup_exit.py $VPN_PORT $PRI_KEY)
UUID=$(echo $OUTPUT | cut -d'|' -f1)
SHORT_ID=$(echo $OUTPUT | cut -d'|' -f2)

systemctl start x-ui

# Формирование ссылки
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${VPN_PORT}?type=xhttp&security=reality&pbk=${PUB_KEY}&fp=chrome&sni=dl.google.com&sid=${SHORT_ID}&spx=%2F#Exit-Node"

echo -e "\n\e[32m=== УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА ===\e[0m"
echo -e "\e[36mПанель управления:\e[0m http://${SERVER_IP}:${PANEL_PORT}/${PANEL_PATH}/"
echo -e "\e[36mЛогин:\e[0m ${PANEL_USER}"
echo -e "\e[36mПароль:\e[0m ${PANEL_PASS}"
echo -e "\e[36mПорт панели:\e[0m ${PANEL_PORT}"
echo -e "\e[36mПорт VPN:\e[0m ${VPN_PORT}"
echo -e "\n\e[35m[ССЫЛКА ДЛЯ КЛИЕНТОВ ИЛИ BRIDGE-НОДЫ]\e[0m\n${VLESS_LINK}"

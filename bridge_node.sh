#!/bin/bash
# Скрипт для автоматической настройки Bridge-ноды (Chaining VLESS xHTTP)

if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mПожалуйста, запустите скрипт от имени root (sudo).\e[0m"
  exit 1
fi

echo -e "\e[34m=== Подготовка сервера Bridge-ноды ===\e[0m"
read -p "Введите ссылку VLESS с Exit-ноды (с транспортом xhttp): " EXIT_LINK
if [ -z "$EXIT_LINK" ]; then
    echo -e "\e[31mСсылка обязательна для настройки Chaining!\e[0m"
    exit 1
fi

read -p "Введите домен для маскировки (например, domain.ru) или нажмите Enter для пропуска: " DOMAIN

# Генерация случайных параметров
PANEL_PORT=$(shuf -i 10000-60000 -n 1)
VPN_PORT=$(shuf -i 10000-60000 -n 1)
PANEL_USER=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
PANEL_PASS=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
PANEL_PATH=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
SERVER_IP=$(curl -s ifconfig.me)

export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
apt install -y curl socat ufw jq sqlite3 python3 nginx unzip certbot python3-certbot-nginx

# Файрвол
echo -e "\e[34m=== Настройка UFW ===\e[0m"
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow $PANEL_PORT/tcp
ufw allow $VPN_PORT/tcp
ufw --force enable

# Установка маскировочного сайта
if [ ! -z "$DOMAIN" ]; then
    echo -e "\e[34m=== Установка маскировочного сайта и SSL ===\e[0m"
    cd /tmp
    wget -qO template.zip https://html5up.net/identity/download
    unzip -o template.zip -d /var/www/html/
    certbot --nginx -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN
fi

# Установка 3x-ui
echo -e "\e[34m=== Установка 3X-UI ===\e[0m"
printf "y\n$PANEL_USER\n$PANEL_PASS\n$PANEL_PORT\n" | bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

sleep 5
systemctl stop x-ui
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '/${PANEL_PATH}/' WHERE key = 'webBasePath';"

# Ключи для моста
KEYS=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519)
PRI_KEY=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
PUB_KEY=$(echo "$KEYS" | grep "Public" | awk '{print $3}')

# Настройка Inbound (Bridge), Outbound (Exit) и Маршрутизации через Python
cat << 'EOF' > /tmp/setup_bridge.py
import sqlite3, json, sys, uuid, secrets, urllib.parse

vpn_port = int(sys.argv[1])
pri_key = sys.argv[2]
exit_link = sys.argv[3]

client_id = str(uuid.uuid4())
short_id = secrets.token_hex(4)

# Парсинг ссылки Exit-ноды
parsed = urllib.parse.urlparse(exit_link)
exit_uuid = parsed.username
exit_ip = parsed.hostname
exit_port = int(parsed.port)
qs = urllib.parse.parse_qs(parsed.query)

exit_pbk = qs.get('pbk', [''])[0]
exit_sni = qs.get('sni', [''])[0]
exit_sid = qs.get('sid', [''])[0]
exit_fp = qs.get('fp', ['chrome'])[0]

conn = sqlite3.connect('/etc/x-ui/x-ui.db')
c = conn.cursor()

# 1. Inbound Bridge (Российский донор yandex.ru)
settings = {
    "clients": [{"id": client_id, "flow": "", "email": "bridge-client", "limitIp": 0, "totalGB": 0, "expiryTime": 0, "enable": True, "tgId": "", "subId": ""}],
    "decryption": "none", "fallbacks": []
}
stream_settings = {
    "network": "xhttp", "security": "reality",
    "xhttpSettings": {"mode": "auto", "host": "", "path": "/", "scMaxConcurrentPosts": "100-1000", "scMaxEachPostBytes": "1000000-10000000", "scMinPostsIntervalMs": "10-50", "noSSEHeader": False, "xPaddingBytes": "100-1000"},
    "realitySettings": {"show": False, "xver": 0, "dest": "www.yandex.ru:443", "serverNames": ["www.yandex.ru"], "privateKey": pri_key, "minClientVer": "", "maxClientVer": "", "maxTimeDiff": 0, "shortIds": [short_id]}
}
sniffing = {"enabled": True, "destOverride": ["http", "tls", "quic"], "routeOnly": False}

c.execute("""
    INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
""", (1, 0, 0, 0, "Bridge-xHTTP", 1, 0, "", vpn_port, "vless", json.dumps(settings), json.dumps(stream_settings), f"inbound-{vpn_port}", json.dumps(sniffing)))

# 2. Outbound Exit-ноды
c.execute("SELECT value FROM settings WHERE key = 'xrayTemplateConfig'")
config = json.loads(c.fetchone()[0])

config.setdefault('outbounds', [])
config['outbounds'].append({
    "tag": "exit-node",
    "protocol": "vless",
    "settings": {
        "vnext": [{"address": exit_ip, "port": exit_port, "users": [{"id": exit_uuid, "encryption": "none", "flow": ""}]}]
    },
    "streamSettings": {
        "network": "xhttp", "security": "reality", "xhttpSettings": {"path": "/"},
        "realitySettings": {"serverName": exit_sni, "publicKey": exit_pbk, "shortId": exit_sid, "fingerprint": exit_fp}
    }
})

# 3. Маршрутизация (весь трафик с Inbound перенаправлять в Outbound exit-node)
config.setdefault('routing', {}).setdefault('rules', [])
config['routing']['rules'].insert(0, {
    "type": "field", "inboundTag": [f"inbound-{vpn_port}"], "outboundTag": "exit-node"
})

c.execute("UPDATE settings SET value = ? WHERE key = 'xrayTemplateConfig'", (json.dumps(config),))
conn.commit()
conn.close()

print(f"{client_id}|{short_id}")
EOF

OUTPUT=$(python3 /tmp/setup_bridge.py $VPN_PORT $PRI_KEY "$EXIT_LINK")
UUID=$(echo $OUTPUT | cut -d'|' -f1)
SHORT_ID=$(echo $OUTPUT | cut -d'|' -f2)

systemctl start x-ui

echo -e "\n\e[32m=== УСТАНОВКА МОСТА ЗАВЕРШЕНА ===\e[0m"
echo -e "\e[36mПанель управления Bridge-нодой:\e[0m http://${SERVER_IP}:${PANEL_PORT}/${PANEL_PATH}/"
echo -e "\e[36mЛогин:\e[0m ${PANEL_USER}"
echo -e "\e[36mПароль:\e[0m ${PANEL_PASS}"
echo -e "\e[36mПорт панели:\e[0m ${PANEL_PORT}"
echo -e "\e[36mПорт VPN:\e[0m ${VPN_PORT}"
echo -e "\n\e[33mГотово! Перейдите в дашборд панели Bridge-ноды по ссылке выше, скопируйте созданное подключение из раздела 'Подключения' и используйте его в своём клиенте (v2rayTun/Hiddify/v2rayN).\e[0m"

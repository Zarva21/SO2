#!/bin/bash
set -e  # Detener si hay error

# ─── VARIABLES CONFIGURABLES ───────────────────────────────────────────────
NODE_ROLE="MASTER"           # MASTER o BACKUP
NODE_PRIORITY=150            # 150 master / 100 backup
NODE_IP="192.168.137.20"     # IP de este nodo
PEER_IP="192.168.137.21"
PEER_IP1="192.168.137.22"    # IP del nodo par
VIP="192.168.137.100"        # IP virtual compartida
INTERFACE="ens18"
ROUTER_ID=55
AUTH_PASS="1111"
APP_NAME="app1"              # app1 o app2 según el nodo
APP_PORT=3000
# ────────────────────────────────────────────────────────────────────────────




echo " Actualizando sistema..."

sudo apt update -y && sudo apt upgrade -y
sudo apt install -y nano curl


echo " Instalando keepalived..."

sudo apt install keepalived -y
sudo apt install libipset13 -y

echo " Configurando keepalived..."

sudo nano /etc/keepalived/keepalived.conf

cat <<EOF | sudo tee /etc/keepalived/keepalived.conf > /dev/null
vrrp_instance VI_1 {
    state ${NODE_ROLE}
    interface ${INTERFACE}
    virtual_router_id ${ROUTER_ID}
    priority ${NODE_PRIORITY}
    advert_int 1
    unicast_src_ip ${NODE_IP}
    unicast_peer {
        ${PEER_IP}
        ${PEER_IP1}
    }
    authentication {
        auth_type PASS
        auth_pass ${AUTH_PASS}
    }
    virtual_ipaddress {
        ${VIP}/24
    }
}
EOF

sudo systemctl enable --now keepalived.service
sudo systemctl restart keepalived

echo "keepalived activo: $(sudo systemctl is-active keepalived)"


#ya con esto tenemos el HA funcionando


echo " Instalando HAProxy..."


sudo apt install haproxy -y


cat <<EOF | sudo tee /etc/haproxy/haproxy.cfg > /dev/null
global
    log /dev/log local0
    maxconn 2000
    daemon

defaults
    log     global
    mode    http
    option  httplog
    timeout connect 5s
    timeout client  50s
    timeout server  50s

frontend http_front
    bind ${VIP}:80
    default_backend http_back

backend http_back
    balance roundrobin
    option httpchk GET /
    server app1 192.168.137.40:${APP_PORT} check
    server app2 192.168.137.41:${APP_PORT} check
EOF

sudo systemctl restart haproxy
sudo systemctl enable haproxy



echo " Instalando Node.js y npm..."

sudo apt update
sudo apt install nodejs npm -y


echo " Instalando PM2..."
sudo npm install -g pm2




# ── APP EXPRESS ──────────────────────────────────────────────────────────────
echo " Creando estructura de la app..."
mkdir -p ~/myapp/{routes,controllers}

cd ~/myapp

npm init -y
npm install express

# server.js
cat <<EOF > server.js
const express = require("express");
const app = express();
const routes = require("./routes");

app.use("/", routes);

app.listen(${APP_PORT}, () => {
  console.log("Servidor corriendo en puerto ${APP_PORT}");
});
EOF


# routes/index.js
cat <<EOF > routes/index.js
const express = require("express");
const router = express.Router();
const mainController = require("../controllers/mainController");

router.get("/", mainController.home);

module.exports = router;
EOF

# controllers/mainController.js
cat <<EOF > controllers/mainController.js
exports.home = (req, res) => {
  res.send("Respuesta desde ${APP_NAME}");
};
EOF

# ── PM2 ──────────────────────────────────────────────────────────────────────
echo "🚀 Iniciando app con PM2..."
pm2 start server.js --name "${APP_NAME}" -i max
pm2 save

PM2_STARTUP=$(pm2 startup | tail -1)
eval "$PM2_STARTUP"

echo ""
echo " ¡Pipeline completado!"
echo "   VIP:      ${VIP}"
echo "   Rol:      ${NODE_ROLE}"
echo "   HAProxy:  http://${VIP}"
echo "   App:      http://${NODE_IP}:${APP_PORT}"

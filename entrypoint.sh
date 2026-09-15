#!/bin/bash
set -e

ulimit -n 65535 || true

echo "[+] Starting Gateway"

# ==========================
# START SSH
# ==========================

echo "[+] Generating SSH keys"
ssh-keygen -A
mkdir -p /run/sshd

echo "[+] Starting SSHD"
/usr/sbin/sshd


# ==========================
# START UDPGW
# ==========================

echo "[+] Starting UDP Gateway"

badvpn-udpgw \
 --listen-addr 127.0.0.1:7300 \
 --max-clients 1000 \
 --max-connections-for-client 40 \
 --loglevel warning &

UDPGW_PID=$!


# ==========================
# START XRAY
# ==========================

echo "[+] Starting Xray"

xray run \
-config /etc/xray/config.json &

XRAY_PID=$!


# ==========================
# PROXY SELECTOR
# ==========================

ENGINE="${PROXY_ENGINE:-envoy}"

echo "[+] Selected Proxy: $ENGINE"


start_proxy(){

case "$ENGINE" in


envoy)

echo "[+] Starting Envoy"

envoy \
-c /etc/envoy/envoy.yaml &

PROXY_PID=$!

;;


haproxy)

echo "[+] Starting HAProxy"

haproxy \
-f /etc/haproxy/haproxy.cfg \
-db &

PROXY_PID=$!

;;


caddy)

echo "[+] Starting Caddy"

caddy run \
--config /etc/caddy/Caddyfile &

PROXY_PID=$!

;;


traefik)

echo "[+] Starting Traefik"

traefik \
--configFile=/etc/traefik/traefik.yml &

PROXY_PID=$!

;;


h2o)

echo "[+] Starting H2O"

h2o \
-c /etc/h2o/h2o.conf &

PROXY_PID=$!

;;


openresty)

echo "[+] Starting OpenResty"

/usr/local/openresty/bin/openresty \
-g "daemon off;" &

PROXY_PID=$!

;;


*)

echo "[!] Unknown proxy"
echo "[!] Falling back to Envoy"

envoy \
-c /etc/envoy/envoy.yaml &

PROXY_PID=$!

;;

esac

}


start_proxy


# ==========================
# WATCHDOG
# ==========================

echo "[+] Watchdog active"


while true
do

sleep 10


if ! kill -0 $XRAY_PID 2>/dev/null
then

echo "[WATCHDOG] Restarting Xray"

xray run \
-config /etc/xray/config.json &

XRAY_PID=$!

fi



if ! kill -0 $UDPGW_PID 2>/dev/null
then

echo "[WATCHDOG] Restarting UDPGW"

badvpn-udpgw \
 --listen-addr 127.0.0.1:7300 \
 --max-clients 1000 \
 --max-connections-for-client 40 \
 --loglevel warning &

UDPGW_PID=$!

fi



if ! kill -0 $PROXY_PID 2>/dev/null
then

echo "[WATCHDOG] Restarting Proxy"

start_proxy

fi


done

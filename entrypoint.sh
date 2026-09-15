#!/bin/bash
set -e

ulimit -n 65535 || true

# --- Ads toggle: ADS_MODE=ads (normal, ads shown) or noads (ad/tracker
# domains blackholed via DNS). Defaults to noads to match the original
# repo's apparent intent. ---
ADS_MODE="${ADS_MODE:-noads}"
if [ "$ADS_MODE" == "ads" ]; then
    cp /etc/xray/config-ads.json /etc/xray/config.json
else
    cp /etc/xray/config-noads.json /etc/xray/config.json
fi
echo "[+] Ads mode: ${ADS_MODE}"

echo "[+] Starting Xray Core..."
xray run -config /etc/xray/config.json &
XRAY_PID=$!

echo "[+] Starting SSH (dropbear, localhost-only) + WS bridge..."
dropbear -F -E -p 127.0.0.1:2222 \
    -r /etc/dropbear/dropbear_rsa_host_key \
    -r /etc/dropbear/dropbear_ecdsa_host_key &
SSH_PID=$!
websockify --web=/dev/null 127.0.0.1:10016 127.0.0.1:2222 &
SSH_WS_PID=$!

echo "[+] Starting udpgw (UDP relay for SSH tunnel clients)..."
badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 10 &
UDPGW_PID=$!

ENGINE="${PROXY_ENGINE:-haproxy}"
echo "[+] Starting Reverse Proxy Engine: $ENGINE"

start_engine() {
    case "$ENGINE" in
        envoy)
            envoy -c /etc/envoy/envoy.yaml &
            ;;
        haproxy)
            haproxy -f /etc/haproxy/haproxy.cfg -db &
            ;;
        openresty)
            /usr/local/openresty/bin/openresty -g "daemon off;" &
            ;;
        caddy)
            caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
            ;;
        traefik)
            traefik --configFile=/etc/traefik/traefik.yml &
            ;;
        h2o)
            h2o -c /etc/h2o/h2o.conf &
            ;;
        *)
            echo "[-] Unknown PROXY_ENGINE '$ENGINE', falling back to haproxy"
            ENGINE="haproxy"
            haproxy -f /etc/haproxy/haproxy.cfg -db &
            ;;
    esac
    ENGINE_PID=$!
}

start_engine

trap 'echo "[+] Shutting down..."; kill "$XRAY_PID" "$ENGINE_PID" "$SSH_PID" "$SSH_WS_PID" "$UDPGW_PID" 2>/dev/null; exit 0' TERM INT

# Watchdog: restart Xray or the chosen engine if either crashes, instead of
# the container silently running half-broken until the whole thing is
# redeployed.
while true; do
    sleep 10
    if ! kill -0 "$XRAY_PID" 2>/dev/null; then
        echo "[watchdog] xray died, restarting..."
        xray run -config /etc/xray/config.json &
        XRAY_PID=$!
    fi
    if ! kill -0 "$ENGINE_PID" 2>/dev/null; then
        echo "[watchdog] $ENGINE died, restarting..."
        start_engine
    fi
    if ! kill -0 "$SSH_PID" 2>/dev/null; then
        echo "[watchdog] dropbear died, restarting..."
        dropbear -F -E -p 127.0.0.1:2222 \
            -r /etc/dropbear/dropbear_rsa_host_key \
            -r /etc/dropbear/dropbear_ecdsa_host_key &
        SSH_PID=$!
    fi
    if ! kill -0 "$SSH_WS_PID" 2>/dev/null; then
        echo "[watchdog] SSH websocket bridge died, restarting..."
        websockify --web=/dev/null 127.0.0.1:10016 127.0.0.1:2222 &
        SSH_WS_PID=$!
    fi
    if ! kill -0 "$UDPGW_PID" 2>/dev/null; then
        echo "[watchdog] udpgw died, restarting..."
        badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 10 &
        UDPGW_PID=$!
    fi
done

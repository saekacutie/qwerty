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

# --- Raw TCP masked transport: never routed through the HTTP proxy
# engines in this image (Envoy/HAProxy/Caddy/Traefik all route by HTTP
# path, and a raw TCP stream has no path - it needs its own direct
# listener). Off by default because Cloud Run only exposes one port per
# revision, already spent on the HTTP-routed protocols; turning this on
# there just means Xray binds a port nothing can ever reach, quietly.
# Only set TCP_RAW_ENABLED=true when the container has an extra port
# actually opened for it (GCE VM firewall rule, or a GKE LoadBalancer
# Service with an extra port) - see deploy.sh, which sets these for you.
# --- Raw TCP listener: bypasses the HTTP path-routing proxy layer
# (Envoy/HAProxy/Caddy/Traefik all route by path; a raw TCP stream has no
# path). Needs its own direct port, which means Cloud Run can't expose it
# at all (one port per revision, already spent on the HTTP-routed
# protocols) - only turn this on for GCE/GKE, where deploy.sh opens the
# extra TCP port range for you.
TCP_RAW_ENABLED="${TCP_RAW_ENABLED:-false}"
if [ "$TCP_RAW_ENABLED" == "true" ]; then
    TCP_RAW_MASK="${TCP_RAW_MASK:-http}"
    case "$TCP_RAW_MASK" in
        none|http) ;;
        *)
            echo "[-] Unknown TCP_RAW_MASK '$TCP_RAW_MASK', falling back to http"
            TCP_RAW_MASK="http"
            ;;
    esac
    TCP_RAW_PORT_BASE="${TCP_RAW_PORT_BASE:-20000}"
    echo "[+] Raw TCP enabled: mask=${TCP_RAW_MASK} ports=${TCP_RAW_PORT_BASE}-$((TCP_RAW_PORT_BASE+3))"
    TMP_CFG=$(mktemp)
    jq --arg mask "$TCP_RAW_MASK" --argjson base "$TCP_RAW_PORT_BASE" '
      .inbounds |= map(
        if (.streamSettings.network? == "tcp" and (.tag | endswith("-raw"))) then
          .streamSettings.tcpSettings.header.type = $mask
          | .port = ($base + (["trojan-raw","vmess-raw","vless-raw","ss-raw"] | index(.tag)))
        else . end
      )
    ' /etc/xray/config.json > "$TMP_CFG" && mv "$TMP_CFG" /etc/xray/config.json
else
    TMP_CFG=$(mktemp)
    jq '.inbounds |= map(select((.streamSettings.network? == "tcp" and (.tag | endswith("-raw"))) | not))
        | .routing.rules |= map(
            if .outboundTag == "direct" and (.inboundTag? != null) then
              .inboundTag |= map(select(. != "trojan-raw" and . != "vmess-raw" and . != "vless-raw" and . != "ss-raw"))
            else . end
          )' /etc/xray/config.json > "$TMP_CFG" && mv "$TMP_CFG" /etc/xray/config.json
    echo "[+] Raw TCP disabled (TCP_RAW_ENABLED=false) - raw tcp inbounds stripped from config"
fi

echo "[+] Starting Xray Core..."
xray run -config /etc/xray/config.json &
XRAY_PID=$!

ENGINE="${PROXY_ENGINE:-envoy}"
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
        *)
            echo "[-] Unknown PROXY_ENGINE '$ENGINE', falling back to envoy"
            ENGINE="envoy"
            envoy -c /etc/envoy/envoy.yaml &
            ;;
    esac
    ENGINE_PID=$!
}

start_engine

trap 'echo "[+] Shutting down..."; kill "$XRAY_PID" "$ENGINE_PID" 2>/dev/null; exit 0' TERM INT

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
done

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

# --- mKCP: UDP transport, never routed through the HTTP proxy engines in
# this image (Envoy/HAProxy/Caddy/Traefik all route by HTTP path, and KCP
# has no path - it needs its own direct UDP listener). Off by default
# because Cloud Run drops all UDP unconditionally; turning this on there
# just means Xray binds ports nothing can ever reach, quietly. Only set
# KCP_ENABLED=true when the container is actually reachable over UDP
# (GCE VM with a UDP firewall rule, or a GKE LoadBalancer Service that
# exposes UDP ports) - see deploy.sh, which sets these for you.
KCP_ENABLED="${KCP_ENABLED:-false}"
if [ "$KCP_ENABLED" == "true" ]; then
    KCP_MASK="${KCP_MASK:-wechat-video}"
    case "$KCP_MASK" in
        none|srtp|utp|wechat-video|dtls|wireguard) ;;
        *)
            echo "[-] Unknown KCP_MASK '$KCP_MASK', falling back to wechat-video"
            KCP_MASK="wechat-video"
            ;;
    esac
    KCP_SEED="${KCP_SEED:-$(openssl rand -hex 12)}"
    KCP_PORT_BASE="${KCP_PORT_BASE:-20000}"
    echo "[+] mKCP enabled: mask=${KCP_MASK} ports=${KCP_PORT_BASE}-$((KCP_PORT_BASE+3)) seed=${KCP_SEED}"
    TMP_CFG=$(mktemp)
    jq --arg mask "$KCP_MASK" --arg seed "$KCP_SEED" --argjson base "$KCP_PORT_BASE" '
      .inbounds |= map(
        if (.streamSettings.network? == "kcp") then
          .streamSettings.kcpSettings.header.type = $mask
          | .streamSettings.kcpSettings.seed = $seed
          | .port = ($base + (["trojan-kcp","vmess-kcp","vless-kcp","ss-kcp"] | index(.tag)))
        else . end
      )
    ' /etc/xray/config.json > "$TMP_CFG" && mv "$TMP_CFG" /etc/xray/config.json
else
    TMP_CFG=$(mktemp)
    jq '.inbounds |= map(select(.streamSettings.network? != "kcp"))
        | .routing.rules |= map(
            if .outboundTag == "direct" and (.inboundTag? != null) then
              .inboundTag |= map(select(. != "trojan-kcp" and . != "vmess-kcp" and . != "vless-kcp" and . != "ss-kcp"))
            else . end
          )' /etc/xray/config.json > "$TMP_CFG" && mv "$TMP_CFG" /etc/xray/config.json
    echo "[+] mKCP disabled (KCP_ENABLED=false) - kcp inbounds stripped from config"
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

#!/bin/bash
set -e

ulimit -n 65535 || true

ssh-keygen -A
mkdir -p /run/sshd
/usr/sbin/sshd

badvpn-udpgw \
 --listen-addr 127.0.0.1:7300 \
 --max-clients 1000 \
 --max-connections-for-client 40 \
 --loglevel warning &
UDPGW_PID=$!

xray run -config /etc/xray/config.json &
XRAY_PID=$!

ENGINE="${PROXY_ENGINE:-envoy}"

start_proxy() {
case "$ENGINE" in
 envoy) envoy -c /etc/envoy/envoy.yaml ;;
 haproxy) haproxy -f /etc/haproxy/haproxy.cfg -db ;;
 caddy) caddy run --config /etc/caddy/Caddyfile ;;
 traefik) traefik --configFile=/etc/traefik/traefik.yml ;;
 h2o) h2o -c /etc/h2o/h2o.conf ;;
 openresty) /usr/local/openresty/bin/openresty -g "daemon off;" ;;
 *) envoy -c /etc/envoy/envoy.yaml ;;
esac &
PROXY_PID=$!
}

start_proxy

nginx -g "daemon off;" &
NGINX_PID=$!

trap 'kill $XRAY_PID $UDPGW_PID $PROXY_PID $NGINX_PID 2>/dev/null || true; exit 0' TERM INT

while true; do
sleep 10
done

#!/bin/bash
# ==============================================================================
# 4N1 FAST DEPLOYER (FIXED + EXPANDED EDITION)
# ENGINEERED BY SAEKA TOJIRP
# ==============================================================================
set -e

BOLD='\033[1m'; RESET='\033[0m'; NC='\033[0m'
GREEN='\033[1;32m'; RED='\033[1;31m'; CYAN='\033[1;36m'
YELLOW='\033[1;33m'; MAGENTA='\033[1;35m'; WHITE='\033[1;37m'

loading() {
    local t="$1"
    local s="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    for ((i=0;i<5;i++)); do
        for ((j=0;j<${#s};j++)); do
            echo -ne "\r  ${CYAN}${s:$j:1} ${t}...${RESET}"
            sleep 0.05
        done
    done
    echo -ne "\r  ${CYAN}${t} - working...${RESET}\n"
}

clear
echo ""
echo -e "  ${BOLD}${WHITE}4N1 FAST DEPLOYER (FIXED + EXPANDED)${RESET}"
echo -e "  ${MAGENTA}ENGINEERED BY SAEKA TOJIRP${RESET}"
echo ""

PROJECT_ID=$(gcloud config get-value project 2>/dev/null | tr -d '[:space:]')
if [ -z "$PROJECT_ID" ]; then
    echo -e "  ${RED}ERROR: No active GCP project detected. Please run 'gcloud init'.${RESET}"
    exit 1
fi
echo -e "  ${CYAN}PROJECT: ${GREEN}${PROJECT_ID}${RESET}"
echo ""

echo -e "  ${CYAN}==================================================${NC}"
echo -e "  ${GREEN}             CHOOSE PROXY ENGINE${NC}"
echo -e "  ${CYAN}==================================================${NC}"
echo -e "  ${YELLOW}1) HAProxy    - full protocol support incl. gRPC (recommended)${RESET}"
echo -e "  ${YELLOW}2) Envoy      - full protocol support incl. gRPC${RESET}"
echo -e "  ${YELLOW}3) Caddy      - full protocol support incl. gRPC${RESET}"
echo -e "  ${YELLOW}4) H2O        - full protocol support incl. gRPC (less tested)${RESET}"
echo -e "  ${YELLOW}5) Traefik    - full protocol support incl. gRPC (less tested)${RESET}"
echo -e "  ${YELLOW}6) OpenResty  - WS/HTTPUpgrade/XHTTP only, NO gRPC (nginx limitation)${RESET}"
echo ""
read -r -p "$(echo -e "  ${CYAN}SELECT PROXY ENGINE [1-6] (Default 1): ${RESET}")" ENGINE_CHOICE

case "$ENGINE_CHOICE" in
    2) ENGINE="Envoy"; PROXY_ENV="envoy";;
    3) ENGINE="Caddy"; PROXY_ENV="caddy";;
    4) ENGINE="H2O"; PROXY_ENV="h2o";;
    5) ENGINE="Traefik"; PROXY_ENV="traefik";;
    6) ENGINE="OpenResty"; PROXY_ENV="openresty";;
    *) ENGINE="HAProxy"; PROXY_ENV="haproxy";;
esac
echo -e "  ${GREEN}SELECTED PROXY ENGINE: ${ENGINE}${RESET}"
if [ "$PROXY_ENV" == "openresty" ]; then
    echo -e "  ${YELLOW}Note: gRPC endpoints will return 501 on this engine - nginx cannot${RESET}"
    echo -e "  ${YELLOW}multiplex HTTP/1.1 and cleartext HTTP/2 on one port. Pick another${RESET}"
    echo -e "  ${YELLOW}engine if you need the gRPC transport.${RESET}"
fi
echo ""

echo -e "  ${CYAN}==================================================${NC}"
echo -e "  ${GREEN}                  ADS MODE${NC}"
echo -e "  ${CYAN}==================================================${NC}"
echo -e "  ${YELLOW}1) No ads   - blocks known ad/tracker domains via DNS${RESET}"
echo -e "  ${YELLOW}2) Ads      - normal DNS, no blocking${RESET}"
read -r -p "$(echo -e "  ${CYAN}CHOICE [1-2] (Default 1): ${RESET}")" ADS_CHOICE
case "$ADS_CHOICE" in
    2) ADS_MODE="ads";;
    *) ADS_MODE="noads";;
esac
echo -e "  ${GREEN}ADS MODE: ${ADS_MODE}${RESET}"
echo ""

if [ -f "./regions.sh" ]; then
    source ./regions.sh
else
    echo -e "  ${RED}ERROR: regions.sh not found. Please ensure it is in the same directory.${RESET}"
    exit 1
fi

read -r -p "$(echo -e "  ${CYAN}SERVICE NAME [saeka]: ${RESET}")" INPUT_NAME
SERVICE_NAME=${INPUT_NAME:-saeka}

echo ""
echo -e "  ${CYAN}SELECT MODE:${RESET}"
echo -e "  ${YELLOW}1) BROWSING     (1 vCPU / 2Gi  RAM)${RESET}"
echo -e "  ${YELLOW}2) STREAMING    (2 vCPU / 4Gi  RAM)${RESET}"
echo -e "  ${YELLOW}3) GAMING       (4 vCPU / 8Gi  RAM)${RESET}"
echo -e "  ${YELLOW}4) CUSTOM${RESET}"
echo ""
read -r -p "$(echo -e "  ${CYAN}CHOICE: ${RESET}")" MODE_CHOICE

case "$MODE_CHOICE" in
    2) CPU="2"; RAM="4Gi"; MODE="STREAMING"; MAX_INSTANCES="4";;
    3) CPU="4"; RAM="8Gi"; MODE="GAMING"; MAX_INSTANCES="4";;
    4)
        read -r -p "$(echo -e "  ${CYAN}CPU (1/2/4): ${RESET}")" CPU
        read -r -p "$(echo -e "  ${CYAN}RAM (2Gi/4Gi/8Gi): ${RESET}")" RAM
        read -r -p "$(echo -e "  ${CYAN}MAX INSTANCES (1/2/4): ${RESET}")" MAX_INSTANCES
        MODE="CUSTOM"
        ;;
    *) CPU="1"; RAM="2Gi"; MODE="BROWSING"; MAX_INSTANCES="4";;
esac

echo ""
loading "BUILDING CONTAINER IMAGE ($ENGINE)"
if ! gcloud builds submit --tag "gcr.io/${PROJECT_ID}/${SERVICE_NAME}" --project="$PROJECT_ID" --quiet > build.log 2>&1; then
    echo -e "  ${RED}BUILD FAILED. CHECK LOGS BELOW:${RESET}"
    tail -n 20 build.log
    exit 1
fi

# Quota-safe deploy: try the chosen tier, step down automatically rather
# than failing outright on restrictive (e.g. Qwiklabs) quotas.
deploy_attempt() {
    local cpu="$1" mem="$2" maxi="$3" extra="$4"
    gcloud run deploy "$SERVICE_NAME" \
        --image "gcr.io/${PROJECT_ID}/${SERVICE_NAME}" \
        --platform managed --region "$REGION" \
        --cpu "$cpu" --memory "$mem" --port 8080 \
        --max-instances "$maxi" \
        --timeout 3600 --allow-unauthenticated --project="$PROJECT_ID" \
        --set-env-vars "PROXY_ENGINE=${PROXY_ENV},ADS_MODE=${ADS_MODE}" \
        --quiet $extra > deploy.log 2>&1
}

loading "DEPLOYING TO CLOUD RUN IN ${REGION}"
if deploy_attempt "$CPU" "$RAM" "$MAX_INSTANCES" "--concurrency 1000 --cpu-boost --no-cpu-throttling --min-instances 1"; then
    DEPLOY_NOTE="full stability tuning (always-on CPU)"
elif deploy_attempt 1 2Gi 2 "--concurrency 500 --no-cpu-throttling --min-instances 1"; then
    DEPLOY_NOTE="reduced tier - project quota couldn't fit ${MODE}"
elif deploy_attempt 1 2Gi 2 "--concurrency 250 --min-instances 0"; then
    DEPLOY_NOTE="minimal tier, no always-on CPU - expect cold-start delay after idle"
else
    echo -e "  ${RED}DEPLOYMENT FAILED. CHECK LOGS BELOW:${RESET}"
    tail -n 20 deploy.log
    exit 1
fi

SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" --region "$REGION" --project="$PROJECT_ID" --format='value(status.url)' 2>/dev/null)
CLEAN_HOST=$(echo "$SERVICE_URL" | sed 's|https://||')

echo ""
echo -e "  ${CYAN}==================================================${NC}"
echo -e "  ${GREEN}          CUSTOM DOMAIN (OPTIONAL)${NC}"
echo -e "  ${CYAN}==================================================${NC}"
echo -e "  ${YELLOW}Cloud Run domain mapping is a beta feature - it is not GA,${RESET}"
echo -e "  ${YELLOW}some regions see higher latency on mapped domains, and the${RESET}"
echo -e "  ${YELLOW}domain must already be verified for this GCP account in${RESET}"
echo -e "  ${YELLOW}Search Console (https://search.google.com/search-console).${RESET}"
read -r -p "$(echo -e "  ${CYAN}Custom domain to map (blank to skip): ${RESET}")" CUSTOM_DOMAIN
FINAL_HOST="$CLEAN_HOST"
if [ -n "$CUSTOM_DOMAIN" ]; then
    loading "MAPPING ${CUSTOM_DOMAIN}"
    if gcloud beta run domain-mappings create \
        --service "$SERVICE_NAME" --domain "$CUSTOM_DOMAIN" \
        --region "$REGION" --project="$PROJECT_ID" --quiet > domain.log 2>&1; then
        echo -e "  ${GREEN}Mapping created.${RESET} Add the DNS records gcloud just printed"
        echo -e "  ${GREEN}(check domain.log) at your DNS provider, then wait for the${RESET}"
        echo -e "  ${GREEN}managed cert to provision (can take up to ~24h).${RESET}"
        FINAL_HOST="$CUSTOM_DOMAIN"
    else
        echo -e "  ${RED}Domain mapping failed - most likely the domain isn't verified${RESET}"
        echo -e "  ${RED}yet, or this region doesn't support mappings. Continuing with${RESET}"
        echo -e "  ${RED}the default *.run.app host instead. See domain.log for details.${RESET}"
        tail -n 10 domain.log
    fi
fi
echo ""
echo -e "  ${GREEN} (⁠ ⁠ꈍ⁠ᴗ⁠ꈍ⁠) DEPLOYED SUCCESSFULLY WITH ${ENGINE}${RESET}"
echo ""
echo -e "  ${CYAN}RAW HOST   ${GREEN}https://${CLEAN_HOST}${RESET}"
if [ "$FINAL_HOST" != "$CLEAN_HOST" ]; then
    echo -e "  ${CYAN}CUSTOM     ${GREEN}https://${FINAL_HOST}${RESET} ${YELLOW}(once DNS + cert are live)${RESET}"
fi
echo -e "  ${CYAN}TIER       ${GREEN}${DEPLOY_NOTE}${RESET}"
echo -e "  ${CYAN}ENGINE     ${GREEN}${ENGINE}${RESET}"
echo -e "  ${CYAN}ADS MODE   ${GREEN}${ADS_MODE}${RESET}"
echo -e "  ${CYAN}CPU / RAM  ${GREEN}${CPU} vCPU / ${RAM}${RESET}"
echo ""
echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  ${CYAN}                    PATHS & PROTOCOLS${RESET}"
echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  ${GREEN}  VLESS${RESET}        | WS: /vless-saeka   | HU: /vless-saeka-hu   | XH: /vless-saeka-xh   | gRPC: /vless-saeka-grpc"
echo -e "  ${GREEN}  VMess${RESET}        | WS: /vmess-saeka   | HU: /vmess-saeka-hu   | XH: /vmess-saeka-xh   | gRPC: /vmess-saeka-grpc"
echo -e "  ${GREEN}  TROJAN${RESET}       | WS: /saeka-tojirp  | HU: /saeka-tojirp-hu  | XH: /saeka-tojirp-xh  | gRPC: /saeka-tojirp-grpc"
echo -e "  ${GREEN}  Shadowsocks${RESET}  | WS: /ss-saeka      | HU: /ss-saeka-hu      | XH: /ss-saeka-xh      | gRPC: /ss-saeka-grpc"
echo -e "  ${GREEN}  SSH${RESET}          | WS: /saeka         (user: saeka / pass: saeka - same shared demo cred as the rest)"
echo -e "  ${GREEN}  UDPGW${RESET}        | 127.0.0.1:7300 once inside the SSH tunnel - set this in your client's UDPGW field"
echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
if [ "$PROXY_ENV" == "openresty" ]; then
    echo -e "  ${YELLOW}gRPC paths above will return 501 on OpenResty - see engine note.${RESET}"
fi
echo ""

cleanup() {
    if [ "${ALREADY_CLEANED:-0}" -eq 1 ]; then return; fi
    ALREADY_CLEANED=1
    echo -e "\n  ${YELLOW}Cleaning up local build logs...${RESET}"
    rm -f build.log deploy.log domain.log
    echo -e "  ${GREEN}Deployer session closed.${RESET}\n"
    exit 0
}
trap cleanup INT TERM EXIT

echo -e "  ${CYAN}Deployer will stay open so you can copy the details above.${RESET}"
echo -e "  ${CYAN}Press Ctrl+C when done.${RESET}"
while true; do
    sleep 60
done

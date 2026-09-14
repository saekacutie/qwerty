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
echo -e "  ${YELLOW}1) Envoy      - full protocol support incl. gRPC (recommended)${RESET}"
echo -e "  ${YELLOW}2) Caddy      - full protocol support incl. gRPC${RESET}"
echo -e "  ${YELLOW}3) Traefik    - full protocol support incl. gRPC (less tested)${RESET}"
echo -e "  ${YELLOW}4) HAProxy    - WS/HTTPUpgrade/XHTTP only, NO gRPC${RESET}"
echo -e "  ${YELLOW}5) OpenResty  - WS/HTTPUpgrade/XHTTP only, NO gRPC${RESET}"
echo ""
read -r -p "$(echo -e "  ${CYAN}SELECT PROXY ENGINE [1-5] (Default 1): ${RESET}")" ENGINE_CHOICE

case "$ENGINE_CHOICE" in
    2) ENGINE="Caddy"; PROXY_ENV="caddy";;
    3) ENGINE="Traefik"; PROXY_ENV="traefik";;
    4) ENGINE="HAProxy"; PROXY_ENV="haproxy";;
    5) ENGINE="OpenResty"; PROXY_ENV="openresty";;
    *) ENGINE="Envoy"; PROXY_ENV="envoy";;
esac
echo -e "  ${GREEN}SELECTED PROXY ENGINE: ${ENGINE}${RESET}"
if [ "$PROXY_ENV" == "openresty" ]; then
    echo -e "  ${YELLOW}Note: gRPC endpoints will return 501 on this engine - nginx cannot${RESET}"
    echo -e "  ${YELLOW}multiplex HTTP/1.1 and cleartext HTTP/2 on one port. Pick another${RESET}"
    echo -e "  ${YELLOW}engine if you need the gRPC transport.${RESET}"
fi
if [ "$PROXY_ENV" == "haproxy" ]; then
    echo -e "  ${YELLOW}Note: gRPC endpoints will return 501 on this engine - HAProxy has no${RESET}"
    echo -e "  ${YELLOW}ALPN-less h1/h2c auto-detection on a cleartext bind. Pick Envoy,${RESET}"
    echo -e "  ${YELLOW}Caddy, or Traefik if you need the gRPC transport.${RESET}"
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
echo -e "  ${CYAN}==================================================${NC}"
echo -e "  ${GREEN}                 DEPLOY TARGET${NC}"
echo -e "  ${CYAN}==================================================${NC}"
echo -e "  ${YELLOW}1) Cloud Run  - TCP only. mKCP CANNOT work here - Cloud Run drops${RESET}"
echo -e "  ${YELLOW}                all UDP unconditionally, no exception, no config fixes it.${RESET}"
echo -e "  ${YELLOW}2) GCE VM     - TCP+UDP via a firewall rule. mKCP works.${RESET}"
echo -e "  ${YELLOW}3) GKE        - TCP+UDP via a LoadBalancer Service. mKCP works.${RESET}"
read -r -p "$(echo -e "  ${CYAN}CHOICE [1-3] (Default 1): ${RESET}")" TARGET_CHOICE
case "$TARGET_CHOICE" in
    2) DEPLOY_TARGET="gce";;
    3) DEPLOY_TARGET="gke";;
    *) DEPLOY_TARGET="cloudrun";;
esac
echo -e "  ${GREEN}DEPLOY TARGET: ${DEPLOY_TARGET}${RESET}"

if [ "$DEPLOY_TARGET" == "cloudrun" ]; then
    KCP_ENABLED="false"
    echo -e "  ${YELLOW}mKCP forced off for this target.${RESET}"
else
    echo ""
    read -r -p "$(echo -e "  ${CYAN}ENABLE mKCP? [y/N]: ${RESET}")" KCP_YN
    if [[ "$KCP_YN" =~ ^[Yy]$ ]]; then
        KCP_ENABLED="true"
        echo -e "  ${YELLOW}KCP header/mask type: none | srtp | utp | wechat-video | dtls | wireguard${RESET}"
        read -r -p "$(echo -e "  ${CYAN}MASK [wechat-video]: ${RESET}")" KCP_MASK_IN
        KCP_MASK=${KCP_MASK_IN:-wechat-video}
        read -r -p "$(echo -e "  ${CYAN}UDP PORT BASE (uses base..base+3) [20000]: ${RESET}")" KCP_PORT_BASE_IN
        KCP_PORT_BASE=${KCP_PORT_BASE_IN:-20000}
        KCP_SEED=$(openssl rand -hex 12)
        echo -e "  ${GREEN}KCP seed (save this - clients need it): ${KCP_SEED}${RESET}"
    else
        KCP_ENABLED="false"
    fi
fi

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
gcloud builds submit --tag "gcr.io/${PROJECT_ID}/${SERVICE_NAME}" --project="$PROJECT_ID" --quiet > build.log 2>&1
if [ $? -ne 0 ]; then
    echo -e "  ${RED}BUILD FAILED. CHECK LOGS BELOW:${RESET}"
    tail -n 20 build.log
    exit 1
fi

# Common env vars for all three targets
COMMON_ENV="PROXY_ENGINE=${PROXY_ENV},ADS_MODE=${ADS_MODE},KCP_ENABLED=${KCP_ENABLED}"
if [ "$KCP_ENABLED" == "true" ]; then
    COMMON_ENV="${COMMON_ENV},KCP_MASK=${KCP_MASK},KCP_SEED=${KCP_SEED},KCP_PORT_BASE=${KCP_PORT_BASE}"
fi

if [ "$DEPLOY_TARGET" == "cloudrun" ]; then

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
        --set-env-vars "$COMMON_ENV" \
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
KCP_HOST=""

elif [ "$DEPLOY_TARGET" == "gce" ]; then

    read -r -p "$(echo -e "  ${CYAN}ZONE [${REGION}-a]: ${RESET}")" ZONE_IN
    ZONE=${ZONE_IN:-${REGION}-a}

    loading "OPENING FIREWALL (tcp:8080${KCP_ENABLED:+, udp:$KCP_PORT_BASE-$((KCP_PORT_BASE+3))})"
    FW_PORTS="tcp:8080"
    if [ "$KCP_ENABLED" == "true" ]; then
        FW_PORTS="${FW_PORTS},udp:${KCP_PORT_BASE}-$((KCP_PORT_BASE+3))"
    fi
    gcloud compute firewall-rules create "${SERVICE_NAME}-fw" \
        --allow="$FW_PORTS" --target-tags="${SERVICE_NAME}" \
        --project="$PROJECT_ID" --quiet 2>>deploy.log || true

    loading "CREATING GCE VM IN ${ZONE}"
    gcloud compute instances create-with-container "${SERVICE_NAME}" \
        --zone="$ZONE" --tags="${SERVICE_NAME}" \
        --container-image="gcr.io/${PROJECT_ID}/${SERVICE_NAME}" \
        --container-env="$COMMON_ENV" \
        --machine-type=e2-standard-2 \
        --project="$PROJECT_ID" --quiet > deploy.log 2>&1
    if [ $? -ne 0 ]; then
        echo -e "  ${RED}DEPLOYMENT FAILED. CHECK LOGS BELOW:${RESET}"
        tail -n 20 deploy.log
        exit 1
    fi
    DEPLOY_NOTE="GCE VM (e2-standard-2), TLS not terminated - put a Caddy/Traefik cert or an HTTPS LB in front if you need TLS"
    CLEAN_HOST=$(gcloud compute instances describe "${SERVICE_NAME}" --zone="$ZONE" --project="$PROJECT_ID" --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
    KCP_HOST="$CLEAN_HOST"

elif [ "$DEPLOY_TARGET" == "gke" ]; then

    read -r -p "$(echo -e "  ${CYAN}GKE CLUSTER NAME: ${RESET}")" CLUSTER_NAME
    read -r -p "$(echo -e "  ${CYAN}ZONE/REGION of cluster [${REGION}]: ${RESET}")" GKE_LOC_IN
    GKE_LOC=${GKE_LOC_IN:-$REGION}

    loading "FETCHING CLUSTER CREDENTIALS"
    gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$GKE_LOC" --project "$PROJECT_ID" --quiet >> deploy.log 2>&1 \
        || gcloud container clusters get-credentials "$CLUSTER_NAME" --zone "$GKE_LOC" --project "$PROJECT_ID" --quiet >> deploy.log 2>&1

    K8S_MANIFEST="/tmp/${SERVICE_NAME}-k8s.yaml"
    KCP_PORT_LINES=""
    if [ "$KCP_ENABLED" == "true" ]; then
        for i in 0 1 2 3; do
            p=$((KCP_PORT_BASE + i))
            KCP_PORT_LINES="${KCP_PORT_LINES}
    - name: kcp-${p}
      port: ${p}
      targetPort: ${p}
      protocol: UDP"
        done
    fi

    cat > "$K8S_MANIFEST" << YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SERVICE_NAME}
spec:
  replicas: 1
  selector:
    matchLabels: { app: ${SERVICE_NAME} }
  template:
    metadata:
      labels: { app: ${SERVICE_NAME} }
    spec:
      containers:
      - name: ${SERVICE_NAME}
        image: gcr.io/${PROJECT_ID}/${SERVICE_NAME}
        ports:
        - containerPort: 8080
$(if [ "$KCP_ENABLED" == "true" ]; then for i in 0 1 2 3; do echo "        - containerPort: $((KCP_PORT_BASE + i))
          protocol: UDP"; done; fi)
        env:
$(echo "$COMMON_ENV" | tr ',' '\n' | sed -E 's/^([^=]+)=(.*)$/        - name: \1\n          value: "\2"/')
---
apiVersion: v1
kind: Service
metadata:
  name: ${SERVICE_NAME}
spec:
  type: LoadBalancer
  selector: { app: ${SERVICE_NAME} }
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      protocol: TCP${KCP_PORT_LINES}
YAML

    loading "APPLYING K8S MANIFEST"
    kubectl apply -f "$K8S_MANIFEST" >> deploy.log 2>&1
    if [ $? -ne 0 ]; then
        echo -e "  ${RED}DEPLOYMENT FAILED. CHECK LOGS BELOW:${RESET}"
        tail -n 20 deploy.log
        exit 1
    fi
    loading "WAITING FOR LOADBALANCER IP (can take a couple minutes)"
    for i in $(seq 1 30); do
        CLEAN_HOST=$(kubectl get svc "$SERVICE_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        [ -n "$CLEAN_HOST" ] && break
        sleep 10
    done
    DEPLOY_NOTE="GKE LoadBalancer Service, TLS not terminated - front with a GKE Ingress + managed cert if you need TLS"
    KCP_HOST="$CLEAN_HOST"
fi

echo ""
echo -e "  ${GREEN} (⁠ ⁠ꈍ⁠ᴗ⁠ꈍ⁠) DEPLOYED SUCCESSFULLY WITH ${ENGINE}${RESET}"
echo ""
if [ "$DEPLOY_TARGET" == "cloudrun" ]; then
    echo -e "  ${CYAN}RAW HOST   ${GREEN}https://${CLEAN_HOST}${RESET}"
else
    echo -e "  ${CYAN}RAW HOST   ${GREEN}${CLEAN_HOST}${RESET} (no managed TLS - see note below)"
fi
echo -e "  ${CYAN}TARGET     ${GREEN}${DEPLOY_TARGET}${RESET}"
echo -e "  ${CYAN}TIER/NOTE  ${GREEN}${DEPLOY_NOTE}${RESET}"
echo -e "  ${CYAN}ENGINE     ${GREEN}${ENGINE}${RESET}"
echo -e "  ${CYAN}ADS MODE   ${GREEN}${ADS_MODE}${RESET}"
if [ "$DEPLOY_TARGET" == "cloudrun" ]; then
    echo -e "  ${CYAN}CPU / RAM  ${GREEN}${CPU} vCPU / ${RAM}${RESET}"
fi
if [ "$KCP_ENABLED" == "true" ]; then
    echo -e "  ${CYAN}mKCP       ${GREEN}enabled, mask=${KCP_MASK}, host=${KCP_HOST}, ports ${KCP_PORT_BASE}-$((KCP_PORT_BASE+3))/udp, seed=${KCP_SEED}${RESET}"
    echo -e "  ${CYAN}mKCP tags  ${GREEN}trojan-kcp vmess-kcp vless-kcp ss-kcp (matched to port base + index 0-3)${RESET}"
fi
echo ""
echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  ${CYAN}                    PATHS & PROTOCOLS${RESET}"
echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  ${GREEN}  VLESS${RESET}        | WS: /vless-saeka   | HU: /vless-saeka-hu   | XH: /vless-saeka-xh   | gRPC: /vless-saeka-grpc"
echo -e "  ${GREEN}  VMess${RESET}        | WS: /vmess-saeka   | HU: /vmess-saeka-hu   | XH: /vmess-saeka-xh   | gRPC: /vmess-saeka-grpc"
echo -e "  ${GREEN}  TROJAN${RESET}       | WS: /saeka-tojirp  | HU: /saeka-tojirp-hu  | XH: /saeka-tojirp-xh  | gRPC: /saeka-tojirp-grpc"
echo -e "  ${GREEN}  Shadowsocks${RESET}  | WS: /ss-saeka      | HU: /ss-saeka-hu      | XH: /ss-saeka-xh      | gRPC: /ss-saeka-grpc"
echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
if [ "$PROXY_ENV" == "openresty" ] || [ "$PROXY_ENV" == "haproxy" ]; then
    echo -e "  ${YELLOW}gRPC paths above will return 501 on ${ENGINE} - see engine note.${RESET}"
fi
if [ "$KCP_ENABLED" == "true" ]; then
    echo -e "  ${YELLOW}mKCP has no path - it's a raw UDP listener, separate from the routes${RESET}"
    echo -e "  ${YELLOW}above. Point mKCP clients at ${KCP_HOST}:<port> directly, not through${RESET}"
    echo -e "  ${YELLOW}${ENGINE} or the raw host URL.${RESET}"
fi
echo ""

cleanup() {
    if [ "${ALREADY_CLEANED:-0}" -eq 1 ]; then return; fi
    ALREADY_CLEANED=1
    echo -e "\n  ${YELLOW}Cleaning up local build logs...${RESET}"
    rm -f build.log deploy.log
    echo -e "  ${GREEN}Deployer session closed.${RESET}\n"
    exit 0
}
trap cleanup INT TERM EXIT

echo -e "  ${CYAN}Deployer will stay open so you can copy the details above.${RESET}"
echo -e "  ${CYAN}Press Ctrl+C when done.${RESET}"
while true; do
    sleep 60
done

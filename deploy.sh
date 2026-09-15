#!/bin/bash
set -e

BOLD='\033[1m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
RED='\033[1;31m'
RESET='\033[0m'

clear

echo ""
echo -e "${BOLD}${CYAN}SAEKA GATEWAY CLOUD RUN DEPLOYER${RESET}"
echo ""

# ==========================
# PROJECT CHECK
# ==========================

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

if [ -z "$PROJECT_ID" ]; then
    echo -e "${RED}No GCP project selected${RESET}"
    exit 1
fi

echo -e "${GREEN}PROJECT:${RESET} $PROJECT_ID"


# ==========================
# SERVICE NAME
# ==========================

read -p "SERVICE NAME [saeka]: " SERVICE_NAME

SERVICE_NAME=${SERVICE_NAME:-saeka}


# ==========================
# REGION
# ==========================

echo ""
echo "Select Region"
echo "1) asia-southeast1"
echo "2) us-central1"
echo "3) europe-west1"

read -p "Choice: " REGION_CHOICE


case $REGION_CHOICE in
1)
REGION="asia-southeast1"
;;
2)
REGION="us-central1"
;;
3)
REGION="europe-west1"
;;
*)
REGION="us-central1"
;;
esac


# ==========================
# PROXY SELECTOR
# ==========================

echo ""
echo "Select Proxy Engine"
echo ""
echo "1) Envoy"
echo "2) HAProxy"
echo "3) Caddy"
echo "4) Traefik"
echo "5) H2O"
echo "6) OpenResty"

read -p "Proxy: " PROXY_CHOICE


case $PROXY_CHOICE in

1)
PROXY_ENGINE="envoy"
;;

2)
PROXY_ENGINE="haproxy"
;;

3)
PROXY_ENGINE="caddy"
;;

4)
PROXY_ENGINE="traefik"
;;

5)
PROXY_ENGINE="h2o"
;;

6)
PROXY_ENGINE="openresty"
;;

*)
PROXY_ENGINE="envoy"
;;

esac


echo ""
echo -e "${GREEN}Selected Proxy:${RESET} $PROXY_ENGINE"


# ==========================
# RESOURCE PROFILE
# ==========================

echo ""
echo "Select Mode"
echo "1) Normal"
echo "2) High"
echo "3) Ultra"

read -p "Mode: " MODE


case $MODE in

2)
CPU="2"
RAM="4Gi"
MAX="4"
;;

3)
CPU="4"
RAM="8Gi"
MAX="5"
;;

*)
CPU="1"
RAM="2Gi"
MAX="2"
;;

esac


# ==========================
# BUILD
# ==========================

echo ""
echo -e "${CYAN}Building image...${RESET}"

gcloud builds submit \
--tag gcr.io/$PROJECT_ID/$SERVICE_NAME


# ==========================
# DEPLOY
# ==========================

echo ""
echo -e "${CYAN}Deploying Cloud Run...${RESET}"


gcloud run deploy "$SERVICE_NAME" \
--image gcr.io/$PROJECT_ID/$SERVICE_NAME \
--platform managed \
--region "$REGION" \
--port 8080 \
--allow-unauthenticated \
--cpu "$CPU" \
--memory "$RAM" \
--max-instances "$MAX" \
--min-instances 1 \
--timeout 3600 \
--execution-environment gen2 \
--session-affinity \
--set-env-vars PROXY_ENGINE=$PROXY_ENGINE


# ==========================
# RESULT
# ==========================

URL=$(gcloud run services describe "$SERVICE_NAME" \
--region "$REGION" \
--format="value(status.url)")


echo ""
echo -e "${GREEN}DEPLOY COMPLETE${RESET}"
echo ""
echo "SERVICE:"
echo "$SERVICE_NAME"
echo ""
echo "URL:"
echo "$URL"
echo ""
echo "PROXY:"
echo "$PROXY_ENGINE"
echo ""

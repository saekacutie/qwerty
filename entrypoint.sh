FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# ==========================
# Base packages
# ==========================

RUN apt-get update && apt-get install -y \
    curl \
    wget \
    unzip \
    ca-certificates \
    gnupg \
    nginx \
    openssh-server \
    python3 \
    python3-pip \
    procps \
    net-tools \
    supervisor \
    jq \
    && rm -rf /var/lib/apt/lists/*


# ==========================
# Install Xray Core
# ==========================

RUN mkdir -p /usr/local/bin/xray && \
    curl -L \
    https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
    -o /tmp/xray.zip && \
    unzip /tmp/xray.zip -d /tmp/xray && \
    mv /tmp/xray/xray /usr/local/bin/xray && \
    chmod +x /usr/local/bin/xray && \
    rm -rf /tmp/xray /tmp/xray.zip


# ==========================
# Install Envoy Proxy
# ==========================

RUN curl -sL 'https://getenvoy.io/gpg' \
    | gpg --dearmor \
    -o /usr/share/keyrings/getenvoy.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/getenvoy.gpg] https://deb.getenvoy.io/public stable main" \
    > /etc/apt/sources.list.d/getenvoy.list && \
    apt-get update && \
    apt-get install -y getenvoy-envoy && \
    ln -sf /usr/bin/envoy /usr/local/bin/envoy && \
    rm -rf /var/lib/apt/lists/*


# ==========================
# Optional proxy packages
# ==========================

RUN apt-get update && apt-get install -y \
    haproxy \
    && rm -rf /var/lib/apt/lists/*


# ==========================
# SSH configuration
# ==========================

RUN mkdir -p /run/sshd

RUN echo "saeka:saeka" | chpasswd

RUN sed -i \
    's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' \
    /etc/ssh/sshd_config


# ==========================
# Application files
# ==========================

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh


COPY nginx.conf /etc/nginx/nginx.conf


# Xray configs
RUN mkdir -p /etc/xray

COPY xray/ /etc/xray/


# Proxy configs

RUN mkdir -p /etc/envoy

COPY envoy.yaml /etc/envoy/envoy.yaml


RUN mkdir -p /etc/haproxy

COPY haproxy.cfg /etc/haproxy/haproxy.cfg


# ==========================
# Cloud Run port
# ==========================

EXPOSE 8080


# ==========================
# Start
# ==========================

CMD ["/entrypoint.sh"]

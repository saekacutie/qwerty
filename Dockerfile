FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install base deps, OpenResty, HAProxy, Envoy & Xray
RUN apt-get update && apt-get install -y \
    curl wget unzip ca-certificates gnupg lsb-release haproxy \
    debian-keyring debian-archive-keyring apt-transport-https \
    cmake build-essential git ninja-build pkg-config \
    libssl-dev zlib1g-dev libuv1-dev \
    && curl -fsSL https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/openresty.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/ubuntu $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/openresty.list \
    && curl -fsSL https://apt.envoyproxy.io/signing.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/envoy.gpg \
    && echo "deb [arch=amd64,arm64 signed-by=/etc/apt/trusted.gpg.d/envoy.gpg] https://apt.envoyproxy.io $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/envoy.list \
    && apt-get update && apt-get install -y openresty envoy \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
    # FIXED: the line above was previously `curl -ptL ...` - "-p" is
    # --proxytunnel and "-t" is --telnet-option (which consumes the next
    # token as its argument), so the URL was never actually fetched and
    # this entire RUN instruction failed, meaning the image never built.

# Install Caddy (official Cloudsmith apt repo)
RUN curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list \
    && apt-get update && apt-get install -y caddy \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Traefik (pinned latest release binary - no stable apt repo exists)
RUN TRAEFIK_VERSION=$(curl -s https://api.github.com/repos/traefik/traefik/releases/latest | grep -m1 tag_name | sed -E 's/.*"([^"]+)".*/\1/') \
    && wget -q "https://github.com/traefik/traefik/releases/download/${TRAEFIK_VERSION}/traefik_${TRAEFIK_VERSION}_linux_amd64.tar.gz" -O /tmp/traefik.tar.gz \
    && tar -xzf /tmp/traefik.tar.gz -C /tmp traefik \
    && mv /tmp/traefik /usr/local/bin/traefik \
    && chmod +x /usr/local/bin/traefik \
    && rm -f /tmp/traefik.tar.gz

# Build H2O from source (no maintained Ubuntu 22.04 apt package)
# NOTE: this is the least battle-tested step in this Dockerfile - H2O's
# build dependencies have shifted across versions. If this step fails,
# check H2O's current CMake requirements against what's installed above.
RUN git clone --depth 1 https://github.com/h2o/h2o.git /tmp/h2o \
    && cd /tmp/h2o && mkdir -p build && cd build \
    && cmake -DCMAKE_BUILD_TYPE=Release .. \
    && make -j"$(nproc)" h2o \
    && cp h2o /usr/local/bin/h2o \
    && rm -rf /tmp/h2o

# Install Xray-core
RUN wget -q https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
    && unzip Xray-linux-64.zip -d /usr/local/bin/ \
    && chmod +x /usr/local/bin/xray \
    && rm -f Xray-linux-64.zip

# Install SSH-over-WebSocket support: dropbear is a lightweight SSH server;
# websockify bridges its local TCP port to a WebSocket path so it can ride
# the same single HTTP port Cloud Run exposes, exactly like the other
# protocols above. Host key is generated once at BUILD time (not in
# entrypoint.sh) so it stays stable across container restarts of the same
# image/revision - it will change if you rebuild the image.
RUN apt-get update && apt-get install -y dropbear-bin python3-pip \
    && pip3 install --no-cache-dir websockify \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/dropbear \
    && dropbearkey -t rsa -s 2048 -f /etc/dropbear/dropbear_rsa_host_key \
    && dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key \
    && useradd -m -s /bin/bash saeka && echo "saeka:saeka" | chpasswd

# Build badvpn-udpgw from source: plain SSH tunnels only carry TCP, so an
# SSH-based client can't relay UDP (DNS, games, QUIC) on its own. udpgw is
# the standard companion daemon that VPN clients (HTTP Injector, NPV
# Tunnel, etc.) connect to *through* the already-open SSH tunnel to get
# UDP relayed. Same "least battle-tested, check upstream docs if it
# breaks" caveat as the H2O build below - badvpn has no maintained apt
# package and its CMake options have shifted across forks/versions.
RUN git clone --depth 1 https://github.com/ambrop72/badvpn.git /tmp/badvpn \
    && cd /tmp/badvpn && mkdir -p build && cd build \
    && cmake -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 .. \
    && make -j"$(nproc)" \
    && cp udpgw/badvpn-udpgw /usr/local/bin/badvpn-udpgw \
    && rm -rf /tmp/badvpn

# Create config directories
RUN mkdir -p /etc/xray /etc/envoy /etc/haproxy /etc/caddy /etc/traefik /etc/h2o \
    /usr/local/openresty/nginx/conf

# Copy configurations
COPY config-ads.json /etc/xray/config-ads.json
COPY config-noads.json /etc/xray/config-noads.json
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY envoy.yaml /etc/envoy/envoy.yaml
COPY haproxy.cfg /etc/haproxy/haproxy.cfg
COPY Caddyfile /etc/caddy/Caddyfile
COPY traefik.yml /etc/traefik/traefik.yml
COPY traefik-dynamic.yml /etc/traefik/dynamic.yml
COPY h2o.conf /etc/h2o/h2o.conf
COPY entrypoint.sh /entrypoint.sh
COPY index.html /var/www/html/index.html

RUN chmod +x /entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]

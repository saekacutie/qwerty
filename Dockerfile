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

# Install Go (needed to build Caddy with the rate-limit plugin via xcaddy -
# the stock Caddy apt package does NOT include third-party plugins, and
# there is no real Caddyfile directive for rate limiting without one)
RUN wget -q https://go.dev/dl/go1.23.0.linux-amd64.tar.gz -O /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm -f /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:/root/go/bin:${PATH}"

# Build Caddy with the verified mholt/caddy-ratelimit module
RUN go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest \
    && xcaddy build --with github.com/mholt/caddy-ratelimit --output /usr/local/bin/caddy \
    && chmod +x /usr/local/bin/caddy

# Install Traefik (pinned latest release binary - no stable apt repo exists)
RUN TRAEFIK_VERSION=$(curl -s https://api.github.com/repos/traefik/traefik/releases/latest | grep -m1 tag_name | sed -E 's/.*"([^"]+)".*/\1/') \
    && wget -q "https://github.com/traefik/traefik/releases/download/${TRAEFIK_VERSION}/traefik_${TRAEFIK_VERSION}_linux_amd64.tar.gz" -O /tmp/traefik.tar.gz \
    && tar -xzf /tmp/traefik.tar.gz -C /tmp traefik \
    && mv /tmp/traefik /usr/local/bin/traefik \
    && chmod +x /usr/local/bin/traefik \
    && rm -f /tmp/traefik.tar.gz

# H2O removed: its proxy.reverse.url directive is HTTP/1.1-only to backends
# (confirmed via H2O's own docs) and it has no built-in rate limiting, so it
# couldn't meet either the protocol or anti-DDoS requirements for this stack.

# Install Xray-core
RUN wget -q https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
    && unzip Xray-linux-64.zip -d /usr/local/bin/ \
    && chmod +x /usr/local/bin/xray \
    && rm -f Xray-linux-64.zip

# Create config directories
RUN mkdir -p /etc/xray /etc/envoy /etc/haproxy /etc/caddy /etc/traefik \
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
COPY entrypoint.sh /entrypoint.sh
COPY index.html /var/www/html/index.html

RUN chmod +x /entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]

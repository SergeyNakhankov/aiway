#!/usr/bin/env bash
# ============================================================================
#  aiway — transparent AI-service proxy installer
#  Sets up Angie (nginx fork) as SNI proxy + Blocky DNS on a VPS so that
#  AI services (ChatGPT, Claude, Gemini, Copilot, …) are accessible without
#  a VPN by routing their DNS responses to this server.
#
#  Based on: https://habr.com/ru/articles/982070/ by crims0n
#  Usage:    sudo bash install.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/domains.sh"

# ── Paths ────────────────────────────────────────────────────────────────────
ANGIE_CONF="/etc/angie/angie.conf"
ANGIE_STREAM_DIR="/etc/angie/stream.d"
ANGIE_HTTP_DIR="/etc/angie/http.d"
BLOCKY_DIR="/opt/blocky"
BLOCKY_CONFIG="${BLOCKY_DIR}/config.yml"

# ── ASCII banner ─────────────────────────────────────────────────────────────
print_banner() {
    echo -e "${CYAN}${BOLD}"
    cat <<'EOF'
    ___  _
   / _ \(_)_      ____ _ _   _
  / /_\ | \ \ /\ / / _` | | | |
 / /  | | |\ V  V / (_| | |_| |
 \/   |_|_| \_/\_/ \__,_|\__, |
                          |___/

  Transparent AI proxy — VPS edition
EOF
    echo -e "${RESET}"
    echo -e "  ${DIM}Routes AI traffic through your server without a VPN${RESET}"
    echo -e "  ${DIM}Angie (nginx fork) + Blocky DNS + optional DoT/DoH${RESET}\n"
}

# ── Preflight ────────────────────────────────────────────────────────────────
preflight() {
    print_step "Preflight checks"
    check_root
    detect_os

    # Confirm with user
    echo -e "\n  ${YELLOW}This installer will:${RESET}"
    echo -e "   • Install ${BOLD}Angie${RESET} (nginx fork) as SNI proxy on port 443"
    echo -e "   • Install ${BOLD}Blocky${RESET} (Docker) as DNS server on port 53"
    echo -e "   • Redirect ${BOLD}${#AI_APEX_DOMAINS[@]} AI domains${RESET} through this server"
    echo -e "   • Modify ${BOLD}/etc/systemd/resolved.conf${RESET} (disable stub resolver)\n"

    read -rp "  Continue? [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }
}

# ── Gather inputs ─────────────────────────────────────────────────────────────
gather_inputs() {
    print_step "Configuration"

    # VPS public IP
    local detected_ip=""
    detected_ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || \
                  curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || true)

    echo ""
    if [[ -n "$detected_ip" ]]; then
        echo -e "  Detected public IP: ${BOLD}${detected_ip}${RESET}"
        read -rp "  VPS public IP [${detected_ip}]: " VPS_IP
        VPS_IP="${VPS_IP:-$detected_ip}"
    else
        read -rp "  VPS public IP: " VPS_IP
        while [[ -z "$VPS_IP" ]]; do
            print_error "IP address is required."
            read -rp "  VPS public IP: " VPS_IP
        done
    fi

    # Validate IP format
    if ! [[ "$VPS_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        print_error "Invalid IP address: $VPS_IP"
        exit 1
    fi
    print_ok "VPS IP: ${VPS_IP}"

    # Optional domain for DoT / DoH / ACME
    echo ""
    echo -e "  ${DIM}Optional: a domain pointing to this server enables:${RESET}"
    echo -e "  ${DIM}  • HTTPS for the DoH endpoint  (e.g. https://dns.example.com/dns-query)${RESET}"
    echo -e "  ${DIM}  • TLS certificate via ACME for DNS-over-TLS (port 853)${RESET}"
    echo -e "  ${DIM}Leave blank to skip (DoT/DoH will be unavailable).${RESET}\n"
    read -rp "  Domain for DoT/DoH (blank to skip): " DOT_DOMAIN
    DOT_DOMAIN="${DOT_DOMAIN:-}"

    if [[ -n "$DOT_DOMAIN" ]]; then
        # Strip protocol/trailing slash if user pasted a URL
        DOT_DOMAIN="${DOT_DOMAIN#https://}"
        DOT_DOMAIN="${DOT_DOMAIN#http://}"
        DOT_DOMAIN="${DOT_DOMAIN%/}"
        print_ok "DoT/DoH domain: ${DOT_DOMAIN}"

        read -rp "  Email for ACME / Let's Encrypt: " ACME_EMAIL
        while [[ -z "$ACME_EMAIL" ]]; do
            print_error "Email is required for ACME."
            read -rp "  Email for ACME / Let's Encrypt: " ACME_EMAIL
        done
        print_ok "ACME email: ${ACME_EMAIL}"
    else
        print_warn "No domain provided — skipping DoT/DoH configuration."
        ACME_EMAIL=""
    fi
}

# ── Docker ───────────────────────────────────────────────────────────────────
ensure_docker() {
    print_step "Docker"

    if has_cmd docker; then
        print_ok "Docker already installed ($(docker --version | head -1))"
        return
    fi

    print_info "Docker not found — installing via official convenience script..."
    run_quietly "Downloading Docker install script" \
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh

    run_quietly "Installing Docker" bash /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh

    run_quietly "Enabling Docker service" systemctl enable --now docker
    print_ok "Docker installed successfully"
}

# ── Angie ────────────────────────────────────────────────────────────────────
install_angie() {
    print_step "Angie (nginx fork with ACME)"

    if has_cmd angie; then
        print_ok "Angie already installed ($(angie -v 2>&1 | head -1))"
        return
    fi

    run_quietly "Installing prerequisites" \
        apt-get install -y -q curl gnupg2 ca-certificates lsb-release apt-transport-https

    run_quietly "Adding Angie GPG key" bash -c \
        'curl -fsSL https://angie.software/angie/signing.asc | gpg --dearmor -o /usr/share/keyrings/angie.gpg'

    local codename
    codename=$(lsb_release -sc 2>/dev/null || echo "${OS_CODENAME}")

    run_quietly "Adding Angie apt repository" bash -c \
        "echo 'deb [signed-by=/usr/share/keyrings/angie.gpg] https://deb.angie.software/angie/${OS_ID} ${codename} main' \
         > /etc/apt/sources.list.d/angie.list"

    run_quietly "Updating apt cache" apt-get update -q

    run_quietly "Installing Angie" apt-get install -y -q angie

    run_quietly "Enabling Angie service" systemctl enable angie

    print_ok "Angie installed successfully"
}

# ── systemd-resolved conflict ─────────────────────────────────────────────────
fix_resolved() {
    print_step "systemd-resolved (DNSStubListener)"

    local conf="/etc/systemd/resolved.conf"
    if [[ ! -f "$conf" ]]; then
        print_warn "$conf not found — skipping"
        return
    fi

    # Backup once
    if [[ ! -f "${conf}.aiway.bak" ]]; then
        cp "$conf" "${conf}.aiway.bak"
        print_info "Backed up to ${conf}.aiway.bak"
    fi

    # Disable stub listener so port 53 is free for Blocky
    if grep -q "^DNSStubListener=no" "$conf"; then
        print_ok "DNSStubListener=no already set"
    else
        sed -i '/^#\?DNSStubListener=/d' "$conf"
        echo "DNSStubListener=no" >> "$conf"
        print_ok "Set DNSStubListener=no"
    fi

    run_quietly "Restarting systemd-resolved" systemctl restart systemd-resolved
}

# ── Generate Angie config ─────────────────────────────────────────────────────
generate_angie_conf() {
    print_step "Generating Angie configuration"

    mkdir -p "$ANGIE_STREAM_DIR" "$ANGIE_HTTP_DIR"

    # ── main angie.conf ────────────────────────────────────────────────────
    cat > "$ANGIE_CONF" <<ANGIEEOF
# /etc/angie/angie.conf — generated by aiway installer
# Do not edit manually; re-run install.sh to regenerate.

user www-data;
worker_processes auto;
pid /run/angie.pid;
include /etc/angie/modules-enabled/*.conf;

events {
    worker_connections 1024;
    multi_accept on;
}

# ── HTTP block (ACME challenge + DoH) ─────────────────────────────────────
http {
    include       /etc/angie/mime.types;
    default_type  application/octet-stream;

    access_log /var/log/angie/access.log;
    error_log  /var/log/angie/error.log;

    sendfile    on;
    tcp_nopush  on;
    tcp_nodelay on;
    keepalive_timeout 65;
    server_tokens off;

    include ${ANGIE_HTTP_DIR}/*.conf;
}

# ── Stream block (SNI proxy + DoT) ────────────────────────────────────────
stream {
    log_format proxy '\$remote_addr [\$time_local] '
                     '\$protocol \$status \$bytes_sent \$bytes_received '
                     '\$session_time "\$upstream_addr"';

    access_log /var/log/angie/stream.log proxy;

    include ${ANGIE_STREAM_DIR}/*.conf;
}
ANGIEEOF
    print_ok "Written: ${ANGIE_CONF}"

    # ── SNI map + proxy ────────────────────────────────────────────────────
    {
        echo "# /etc/angie/stream.d/ai-proxy.conf — SNI pass-through for AI services"
        echo "# Generated by aiway installer — $(date -u '+%Y-%m-%d %H:%M UTC')"
        echo ""
        echo "map \$ssl_preread_server_name \$upstream_name {"
        echo "    default  passthrough;"
        for domain in "${AI_DOMAINS[@]}"; do
            # wildcard entries in the map use a leading dot
            if [[ "$domain" == \** ]]; then
                local bare="${domain#\*.}"
                printf "    %-45s passthrough;\n" ".${bare}"
            else
                printf "    %-45s passthrough;\n" "${domain}"
            fi
        done
        echo "}"
        echo ""
        echo "server {"
        echo "    listen      443;"
        echo "    ssl_preread on;"
        echo ""
        echo "    proxy_pass          \$ssl_preread_server_name:443;"
        echo "    proxy_connect_timeout 10s;"
        echo "    proxy_timeout       600s;"
        echo "}"
    } > "${ANGIE_STREAM_DIR}/ai-proxy.conf"
    print_ok "Written: ${ANGIE_STREAM_DIR}/ai-proxy.conf"

    # ── HTTP services (ACME + DoH) ─────────────────────────────────────────
    if [[ -n "$DOT_DOMAIN" ]]; then
        cat > "${ANGIE_HTTP_DIR}/local-services.conf" <<HTTPEOF
# /etc/angie/http.d/local-services.conf — ACME challenge + DoH
# Generated by aiway installer

# HTTP → redirect + ACME challenge
server {
    listen 80;
    server_name ${DOT_DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/lib/angie/acme;
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS — DoH endpoint + ACME certificate management
server {
    listen 443 ssl;
    server_name ${DOT_DOMAIN};

    ssl_certificate     /etc/angie/acme/${DOT_DOMAIN}/fullchain.cer;
    ssl_certificate_key /etc/angie/acme/${DOT_DOMAIN}/${DOT_DOMAIN}.key;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache   shared:SSL:10m;

    # DNS-over-HTTPS endpoint (Blocky listens on 4000)
    location /dns-query {
        proxy_pass         http://127.0.0.1:4000/dns-query;
        proxy_http_version 1.1;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
    }

    location / {
        return 200 'aiway DNS proxy is running\n';
        add_header Content-Type text/plain;
    }
}
HTTPEOF

        # ACME client block — Angie's built-in acme module
        cat >> "$ANGIE_CONF" <<ACMEEOF

# ── ACME (Let's Encrypt) ─────────────────────────────────────────────────
acme {
    client {
        name       letsencrypt;
        directory  https://acme-v02.api.letsencrypt.org/directory;
        email      ${ACME_EMAIL};
    }

    certificate ${DOT_DOMAIN} {
        client     letsencrypt;
        domains    ${DOT_DOMAIN};
        webroot    /var/lib/angie/acme;
    }
}
ACMEEOF
        print_ok "Written: ${ANGIE_HTTP_DIR}/local-services.conf"
    else
        # Minimal placeholder so Angie doesn't complain about empty include
        cat > "${ANGIE_HTTP_DIR}/local-services.conf" <<HTTPEOF
# /etc/angie/http.d/local-services.conf
# No domain configured — ACME/DoH disabled.
server {
    listen 80 default_server;
    server_name _;
    return 444;
}
HTTPEOF
        print_ok "Written: ${ANGIE_HTTP_DIR}/local-services.conf (minimal)"
    fi

    # ── DoT — stream server on 853 ────────────────────────────────────────
    if [[ -n "$DOT_DOMAIN" ]]; then
        cat >> "${ANGIE_STREAM_DIR}/ai-proxy.conf" <<DOTEOF

# DNS-over-TLS (port 853) — forwards to Blocky on 53
server {
    listen     853 ssl;
    ssl_certificate     /etc/angie/acme/${DOT_DOMAIN}/fullchain.cer;
    ssl_certificate_key /etc/angie/acme/${DOT_DOMAIN}/${DOT_DOMAIN}.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    proxy_pass          127.0.0.1:53;
    proxy_connect_timeout 5s;
    proxy_timeout       10s;
}
DOTEOF
        print_ok "DoT server block added to ${ANGIE_STREAM_DIR}/ai-proxy.conf"
    fi
}

# ── Blocky ───────────────────────────────────────────────────────────────────
generate_blocky_config() {
    print_step "Generating Blocky DNS configuration"

    mkdir -p "$BLOCKY_DIR"

    # Build customDNS mapping block
    local dns_mapping=""
    for domain in "${AI_APEX_DOMAINS[@]}"; do
        dns_mapping+="    ${domain}: ${VPS_IP}"$'\n'
    done

    cat > "$BLOCKY_CONFIG" <<BLOCKYEOF
# /opt/blocky/config.yml — generated by aiway installer
# Blocky DNS: https://0xerr0r.github.io/blocky/

# ── Upstream resolvers ────────────────────────────────────────────────────
upstreams:
  groups:
    default:
      - 8.8.8.8
      - 8.8.4.4
      - 1.1.1.1
      - 1.0.0.1

# ── Custom DNS overrides (AI domains → this VPS) ─────────────────────────
customDNS:
  mapping:
${dns_mapping}
# ── Ports ─────────────────────────────────────────────────────────────────
ports:
  dns: 53
  http: 4000      # DoH endpoint

# ── Logging ───────────────────────────────────────────────────────────────
log:
  level: warn
  format: text

# ── Performance ───────────────────────────────────────────────────────────
caching:
  minTime: 5m
  maxTime: 30m
  prefetching: true
BLOCKYEOF

    print_ok "Written: ${BLOCKY_CONFIG}"
}

# ── Run Blocky container ──────────────────────────────────────────────────────
start_blocky() {
    print_step "Starting Blocky DNS container"

    # Remove stale container if present
    if docker ps -a --format '{{.Names}}' | grep -q "^blocky$"; then
        print_info "Removing existing blocky container..."
        docker rm -f blocky >/dev/null 2>&1 || true
    fi

    run_quietly "Pulling spx01/blocky image" docker pull spx01/blocky

    docker run -d \
        --name blocky \
        --restart=always \
        -p 53:53/udp \
        -p 53:53/tcp \
        -p 4000:4000 \
        -v "${BLOCKY_CONFIG}:/app/config.yml:ro" \
        spx01/blocky >/dev/null

    print_ok "Blocky container started"

    # Quick self-test
    sleep 2
    if has_cmd dig; then
        local result
        result=$(dig +short +time=3 openai.com @127.0.0.1 2>/dev/null || true)
        if [[ "$result" == "$VPS_IP" ]]; then
            print_ok "DNS test: openai.com → ${VPS_IP} (correct)"
        elif [[ -n "$result" ]]; then
            print_warn "DNS test returned ${result} instead of ${VPS_IP} — check config"
        else
            print_warn "DNS test inconclusive (dig returned empty) — Blocky may still be starting"
        fi
    fi
}

# ── Start/test Angie ─────────────────────────────────────────────────────────
start_angie() {
    print_step "Starting Angie"

    mkdir -p /var/log/angie /var/lib/angie/acme

    # Validate config before starting
    if ! angie -t 2>/dev/null; then
        print_error "Angie config test failed. Output:"
        angie -t
        exit 1
    fi
    print_ok "Angie config test passed"

    run_quietly "Restarting Angie" systemctl restart angie

    sleep 1
    if systemctl is-active --quiet angie; then
        print_ok "Angie is running"
    else
        print_error "Angie failed to start — check: journalctl -u angie -n 50"
        exit 1
    fi
}

# ── Print firewall reminder ───────────────────────────────────────────────────
check_firewall() {
    print_step "Firewall"
    local ports="443/tcp  53/udp  53/tcp"
    [[ -n "$DOT_DOMAIN" ]] && ports+="  853/tcp  80/tcp"

    if has_cmd ufw; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -1)
        if [[ "$ufw_status" == *"active"* ]]; then
            print_info "ufw is active. Opening required ports..."
            ufw allow 443/tcp  comment 'aiway SNI proxy'  >/dev/null
            ufw allow 53/udp   comment 'aiway DNS'         >/dev/null
            ufw allow 53/tcp   comment 'aiway DNS'         >/dev/null
            [[ -n "$DOT_DOMAIN" ]] && ufw allow 853/tcp comment 'aiway DoT' >/dev/null
            [[ -n "$DOT_DOMAIN" ]] && ufw allow 80/tcp  comment 'aiway ACME' >/dev/null
            print_ok "ufw rules added for: ${ports}"
        else
            print_warn "ufw is installed but inactive — no rules applied"
        fi
    elif has_cmd firewall-cmd; then
        firewall-cmd --permanent --add-port=443/tcp >/dev/null
        firewall-cmd --permanent --add-port=53/udp  >/dev/null
        firewall-cmd --permanent --add-port=53/tcp  >/dev/null
        [[ -n "$DOT_DOMAIN" ]] && firewall-cmd --permanent --add-port=853/tcp >/dev/null
        [[ -n "$DOT_DOMAIN" ]] && firewall-cmd --permanent --add-port=80/tcp  >/dev/null
        firewall-cmd --reload >/dev/null
        print_ok "firewalld rules added for: ${ports}"
    else
        print_warn "No supported firewall detected."
        echo -e "  ${YELLOW}Make sure your VPS security group / iptables allows:${RESET}"
        echo -e "  ${BOLD}  ${ports}${RESET}"
    fi
}

# ── Final summary ─────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║           aiway installed successfully!                  ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    echo -e "  ${BOLD}DNS server to use on your devices:${RESET}"
    echo -e "    ${CYAN}${BOLD}${VPS_IP}${RESET}  (plain DNS, port 53)\n"

    if [[ -n "$DOT_DOMAIN" ]]; then
        echo -e "  ${BOLD}DNS-over-TLS:${RESET}"
        echo -e "    ${CYAN}${DOT_DOMAIN}${RESET}  port 853\n"
        echo -e "  ${BOLD}DNS-over-HTTPS:${RESET}"
        echo -e "    ${CYAN}https://${DOT_DOMAIN}/dns-query${RESET}\n"
    fi

    echo -e "  ${BOLD}Device setup instructions:${RESET}"

    echo -e "  ${YELLOW}Android / iOS (Private DNS — DoT):${RESET}"
    if [[ -n "$DOT_DOMAIN" ]]; then
        echo -e "    Settings → Network → Private DNS → ${BOLD}${DOT_DOMAIN}${RESET}"
    else
        echo -e "    Settings → Network → DNS → ${BOLD}${VPS_IP}${RESET}"
    fi

    echo -e "  ${YELLOW}Windows:${RESET}"
    echo -e "    Settings → Network → DNS servers → ${BOLD}${VPS_IP}${RESET}"

    echo -e "  ${YELLOW}macOS:${RESET}"
    echo -e "    System Preferences → Network → DNS → Add ${BOLD}${VPS_IP}${RESET}"

    echo -e "  ${YELLOW}Linux (/etc/resolv.conf):${RESET}"
    echo -e "    nameserver ${BOLD}${VPS_IP}${RESET}"

    echo -e "  ${YELLOW}Router (recommended — covers all devices):${RESET}"
    echo -e "    Set primary DNS to ${BOLD}${VPS_IP}${RESET} in your router's DHCP settings\n"

    echo -e "  ${BOLD}Add more domains later:${RESET}"
    echo -e "    1. Edit ${CYAN}${SCRIPT_DIR}/lib/domains.sh${RESET}"
    echo -e "    2. Re-run: ${BOLD}sudo bash ${SCRIPT_DIR}/install.sh${RESET}"
    echo -e "    Or manually add to ${CYAN}${BLOCKY_CONFIG}${RESET} and restart:"
    echo -e "    ${DIM}docker restart blocky${RESET}\n"

    echo -e "  ${BOLD}Useful commands:${RESET}"
    echo -e "    ${DIM}docker logs blocky            # Blocky DNS logs${RESET}"
    echo -e "    ${DIM}systemctl status angie        # Angie status${RESET}"
    echo -e "    ${DIM}journalctl -u angie -f        # Angie live logs${RESET}"
    echo -e "    ${DIM}dig openai.com @${VPS_IP}     # Test DNS${RESET}"
    echo -e "    ${DIM}sudo bash ${SCRIPT_DIR}/uninstall.sh  # Remove aiway${RESET}\n"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    clear
    print_banner
    preflight
    gather_inputs

    echo ""
    print_step "Starting installation"

    run_quietly "Updating apt package index" apt-get update -q

    ensure_docker
    install_angie
    fix_resolved
    generate_angie_conf
    generate_blocky_config
    start_blocky
    start_angie
    check_firewall

    print_summary
}

main "$@"

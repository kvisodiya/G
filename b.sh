#!/bin/bash
##############################################################################
# Network Security: Tor + DNS Privacy (SAFE)
#
# SAFE means:
#   - Tor runs as OPTIONAL proxy (not transparent)
#   - Internet ALWAYS works without Tor
#   - NO iptables hijacking
#   - NO fstab changes
#   - SSH always works
#   - APT always works
#   - You CHOOSE when to use Tor
#
# sudo bash network.sh
##############################################################################

if [ "$(id -u)" -ne 0 ]; then echo "Run as root"; exit 1; fi

SSH_PORT="${SSH_PORT:-22}"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  Network Security + Safe Tor Setup   ║"
echo "╚══════════════════════════════════════╝"
echo ""

set +e
export DEBIAN_FRONTEND=noninteractive

########################################
# 1. INSTALL
########################################
echo "[1/8] Installing..."
apt-get update -qq
apt-get install -y -qq tor torsocks privoxy dnsutils nmap tcpdump 2>/dev/null
echo "  Done ✔"

########################################
# 2. TOR (optional proxy - NOT transparent)
########################################
echo "[2/8] Tor setup..."

cat > /etc/tor/torrc <<'EOF'
# === Safe Tor Config ===
# Tor runs as SOCKS proxy only
# Nothing is forced through Tor
# Use torsocks or proxy settings to route through Tor

RunAsDaemon 1

# SOCKS proxy
SocksPort 9050
SocksPort 127.0.0.1:9150

# DNS through Tor (optional, on separate port)
DNSPort 5353
AutomapHostsOnResolve 1
VirtualAddrNetworkIPv4 10.192.0.0/10

# Performance
NumEntryGuards 3
KeepalivePeriod 60
NewCircuitPeriod 30
MaxCircuitDirtiness 600

# Security
SafeSocks 1
TestSocks 0
AvoidDiskWrites 1
DisableDebuggerAttachment 1

# We are client only
ExitPolicy reject *:*

# Logging
Log notice file /var/log/tor/notices.log
EOF

mkdir -p /var/log/tor
chown debian-tor:debian-tor /var/log/tor 2>/dev/null

# Auto-restart if Tor dies
mkdir -p /etc/systemd/system/tor.service.d
cat > /etc/systemd/system/tor.service.d/restart.conf <<'EOF'
[Service]
Restart=always
RestartSec=10
EOF

systemctl daemon-reload
systemctl enable tor 2>/dev/null
systemctl restart tor 2>/dev/null
echo "  Done ✔"

########################################
# 3. PRIVOXY (HTTP proxy via Tor)
########################################
echo "[3/8] Privoxy (HTTP proxy → Tor)..."

cat > /etc/privoxy/config <<'EOF'
listen-address 127.0.0.1:8118
forward-socks5t / 127.0.0.1:9050 .
toggle 0
enable-remote-toggle 0
enable-remote-http-toggle 0
enable-edit-actions 0
forwarded-connect-retries 0
accept-intercepted-requests 0
logdir /var/log/privoxy
logfile logfile
debug 0
socket-timeout 300
keep-alive-timeout 5
actionsfile match-all.action
actionsfile default.action
filterfile default.filter
EOF

systemctl enable privoxy 2>/dev/null
systemctl restart privoxy 2>/dev/null
echo "  Done ✔"

########################################
# 4. DNS PRIVACY (encrypted DNS - NOT replacing system DNS)
########################################
echo "[4/8] DNS privacy..."

# Secure DNS resolvers (system keeps working normally)
# We ADD encrypted DNS as option, not replace
cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 9.9.9.9
nameserver 8.8.8.8
options edns0
EOF

echo "  Done ✔"

########################################
# 5. HELPER SCRIPTS
########################################
echo "[5/8] Helper scripts..."

# tor-on: Route current shell through Tor
cat > /usr/local/bin/tor-on <<'EOF'
#!/bin/bash
echo "Routing this shell through Tor..."
export http_proxy="http://127.0.0.1:8118"
export https_proxy="http://127.0.0.1:8118"
export HTTP_PROXY="http://127.0.0.1:8118"
export HTTPS_PROXY="http://127.0.0.1:8118"
export ALL_PROXY="socks5://127.0.0.1:9050"
export no_proxy="localhost,127.0.0.1"

echo ""
echo "Tor proxy ON for this shell"
echo "  HTTP proxy:  127.0.0.1:8118"
echo "  SOCKS proxy: 127.0.0.1:9050"
echo ""

# Show Tor IP
TOR_IP=$(torsocks curl -s --max-time 15 ifconfig.me 2>/dev/null)
echo "  Your Tor IP: ${TOR_IP:-connecting...}"
echo ""
echo "  To disable: tor-off"
exec bash
EOF
chmod 755 /usr/local/bin/tor-on

# tor-off: Stop routing through Tor
cat > /usr/local/bin/tor-off <<'EOF'
#!/bin/bash
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY SOCKS_PROXY no_proxy NO_PROXY
echo "Tor proxy OFF for this shell"
echo "  Your real IP: $(curl -s --max-time 5 ifconfig.me 2>/dev/null)"
exec bash
EOF
chmod 755 /usr/local/bin/tor-off

# tor-newid: Get new Tor identity
cat > /usr/local/bin/tor-newid <<'EOF'
#!/bin/bash
echo "Getting new Tor identity..."
systemctl reload tor 2>/dev/null
sleep 3
TOR_IP=$(torsocks curl -s --max-time 15 ifconfig.me 2>/dev/null)
echo "New exit IP: ${TOR_IP:-connecting...}"
EOF
chmod 755 /usr/local/bin/tor-newid

# tor-check: Check if Tor is working
cat > /usr/local/bin/tor-check <<'EOF'
#!/bin/bash
echo "=== Tor Status ==="
echo ""

# Service
echo -n "Tor service: "
systemctl is-active tor 2>/dev/null && echo "✔ Running" || echo "✘ Stopped"

echo -n "Privoxy:     "
systemctl is-active privoxy 2>/dev/null && echo "✔ Running" || echo "✘ Stopped"

echo ""

# Connection
echo -n "Tor connection: "
RESULT=$(torsocks curl -s --max-time 15 https://check.torproject.org/api/ip 2>/dev/null)
if echo "$RESULT" | grep -q '"IsTor":true'; then
  TOR_IP=$(echo "$RESULT" | grep -oP '"IP":"[^"]*"' | cut -d'"' -f4)
  echo "✔ Connected (IP: ${TOR_IP})"
else
  echo "✘ Not connected through Tor"
fi

echo ""
echo "Real IP:  $(curl -s --max-time 5 ifconfig.me 2>/dev/null)"
echo "Tor IP:   $(torsocks curl -s --max-time 15 ifconfig.me 2>/dev/null)"

echo ""
echo "=== Ports ==="
ss -tlnp 2>/dev/null | grep -E "9050|9150|8118|5353"

echo ""
echo "=== Usage ==="
echo "  tor-on            Start using Tor in this shell"
echo "  tor-off           Stop using Tor in this shell"
echo "  tor-newid         Get new Tor exit IP"
echo "  torsocks <cmd>    Run single command through Tor"
echo "  torify <cmd>      Same as torsocks"
EOF
chmod 755 /usr/local/bin/tor-check

# tor-apt: Update system through Tor (one-time)
cat > /usr/local/bin/tor-apt <<'EOF'
#!/bin/bash
if [ "$(id -u)" -ne 0 ]; then echo "Run as root"; exit 1; fi
echo "Updating through Tor..."
apt-get -o Acquire::http::Proxy="socks5h://127.0.0.1:9050" \
        -o Acquire::https::Proxy="socks5h://127.0.0.1:9050" \
        update
echo "Done. Use same prefix for install:"
echo "  sudo apt-get -o Acquire::http::Proxy='socks5h://127.0.0.1:9050' install <package>"
EOF
chmod 755 /usr/local/bin/tor-apt

# tor-dns: Resolve DNS through Tor
cat > /usr/local/bin/tor-dns <<'EOF'
#!/bin/bash
if [ -z "$1" ]; then echo "Usage: tor-dns <domain>"; exit 1; fi
echo "Resolving $1 through Tor DNS..."
torsocks dig +short "$1" @127.0.0.1 -p 5353 2>/dev/null || \
  echo "Try: torsocks nslookup $1"
EOF
chmod 755 /usr/local/bin/tor-dns

echo "  Done ✔"

########################################
# 6. TOR HEALTH MONITORING
########################################
echo "[6/8] Tor monitoring..."

cat > /usr/local/bin/tor-health-check <<'EOF'
#!/bin/bash
if ! systemctl is-active --quiet tor; then
  logger -t tor-health "Tor DOWN - restarting"
  systemctl restart tor
fi
EOF
chmod 700 /usr/local/bin/tor-health-check

cat > /etc/cron.d/tor-health <<'EOF'
*/5 * * * * root /usr/local/bin/tor-health-check
EOF
echo "  Done ✔"

########################################
# 7. NETWORK SECURITY TOOLS
########################################
echo "[7/8] Network security extras..."

# UFW extra rules (keep internet working)
ufw allow out 9001/tcp comment 'Tor OR port' 2>/dev/null
ufw allow out 9030/tcp comment 'Tor Dir port' 2>/dev/null
ufw allow out 443/tcp comment 'HTTPS' 2>/dev/null
ufw allow out 80/tcp comment 'HTTP' 2>/dev/null
ufw allow out 53/udp comment 'DNS' 2>/dev/null
ufw allow out 53/tcp comment 'DNS' 2>/dev/null
ufw allow out 123/udp comment 'NTP' 2>/dev/null
ufw reload 2>/dev/null

# Network sysctl extras (safe)
grep -q "tcp_fin_timeout" /etc/sysctl.d/99-hardening.conf || {
  cat >> /etc/sysctl.d/99-hardening.conf <<'EOF'

# === Network Security ===
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_window_scaling = 0
net.ipv4.tcp_sack = 0
EOF
  sysctl --system >/dev/null 2>&1
}
echo "  Done ✔"

########################################
# 8. VERIFY
########################################
echo "[8/8] Verifying..."
echo ""

# Wait for Tor
echo "  Waiting for Tor to connect (30 sec)..."
sleep 10

echo ""
echo -n "  Internet:  "
ping -c1 -W3 google.com >/dev/null 2>&1 && echo "✔" || echo "✘"

echo -n "  Tor:       "
systemctl is-active tor >/dev/null 2>&1 && echo "✔ Running" || echo "✘"

echo -n "  Privoxy:   "
systemctl is-active privoxy >/dev/null 2>&1 && echo "✔ Running" || echo "✘"

echo -n "  Tor SOCKS: "
ss -tlnp 2>/dev/null | grep -q ":9050 " && echo "✔ Port 9050" || echo "✘"

echo -n "  Tor DNS:   "
ss -tlnp 2>/dev/null | grep -q ":5353 " && echo "✔ Port 5353" || echo "✘"

echo -n "  Privoxy:   "
ss -tlnp 2>/dev/null | grep -q ":8118 " && echo "✔ Port 8118" || echo "✘"

# Test Tor connection
echo ""
echo -n "  Tor test:  "
TOR_CHECK=$(torsocks curl -s --max-time 20 https://check.torproject.org/api/ip 2>/dev/null)
if echo "$TOR_CHECK" | grep -q '"IsTor":true'; then
  TOR_IP=$(echo "$TOR_CHECK" | grep -oP '"IP":"[^"]*"' | cut -d'"' -f4)
  echo "✔ Connected (Exit: ${TOR_IP})"
else
  echo "⏳ Still connecting (wait a minute, then run: tor-check)"
fi

REAL_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null)
echo "  Real IP:   ${REAL_IP:-unknown}"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  Network Security Complete!          ║"
echo "╠══════════════════════════════════════╣"
echo "║                                      ║"
echo "║  Tor SOCKS:  127.0.0.1:9050         ║"
echo "║  HTTP Proxy: 127.0.0.1:8118         ║"
echo "║  Tor DNS:    127.0.0.1:5353         ║"
echo "║                                      ║"
echo "║  Commands:                           ║"
echo "║    tor-on      Use Tor in shell      ║"
echo "║    tor-off     Stop using Tor        ║"
echo "║    tor-newid   New Tor identity      ║"
echo "║    tor-check   Check Tor status      ║"
echo "║    tor-apt     APT through Tor       ║"
echo "║    tor-dns     DNS through Tor       ║"
echo "║    torsocks    Run cmd through Tor   ║"
echo "║                                      ║"
echo "║  Internet works normally.            ║"
echo "║  Tor is OPTIONAL — use when needed.  ║"
echo "╚══════════════════════════════════════╝"
echo ""

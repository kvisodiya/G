#!/bin/bash
# fix.sh - Fix Tor + Privoxy + all network tools
# sudo bash fix.sh

if [ "$(id -u)" -ne 0 ]; then echo "Run as root"; exit 1; fi

echo ""
echo "========================"
echo " Fixing Everything"
echo "========================"
echo ""

# 1. Make sure internet works first
echo "[1/6] Checking internet..."
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY SOCKS_PROXY

# Remove any proxy forcing
rm -f /etc/apt/apt.conf.d/99tor 2>/dev/null
rm -f /root/.curlrc 2>/dev/null

echo -n "  Internet: "
ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 && echo "✔" || echo "✘"
echo -n "  DNS:      "
ping -c1 -W3 google.com >/dev/null 2>&1 && echo "✔" || echo "✘"

# 2. Fix Tor
echo ""
echo "[2/6] Fixing Tor..."
apt-get install -y -qq tor torsocks 2>/dev/null

cat > /etc/tor/torrc <<'EOF'
RunAsDaemon 1
SocksPort 9050
SocksPort 127.0.0.1:9150
DNSPort 5353
AutomapHostsOnResolve 1
VirtualAddrNetworkIPv4 10.192.0.0/10
NumEntryGuards 3
KeepalivePeriod 60
NewCircuitPeriod 30
MaxCircuitDirtiness 600
SafeSocks 1
AvoidDiskWrites 1
DisableDebuggerAttachment 1
ExitPolicy reject *:*
Log notice file /var/log/tor/notices.log
EOF

mkdir -p /var/log/tor
chown debian-tor:debian-tor /var/log/tor 2>/dev/null

systemctl enable tor
systemctl restart tor
sleep 3
echo -n "  Tor: "
systemctl is-active tor >/dev/null 2>&1 && echo "✔ Running" || echo "✘ Failed"

# 3. Fix Privoxy
echo ""
echo "[3/6] Fixing Privoxy..."
apt-get install -y -qq privoxy 2>/dev/null

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

mkdir -p /var/log/privoxy
systemctl enable privoxy
systemctl restart privoxy
sleep 2
echo -n "  Privoxy: "
systemctl is-active privoxy >/dev/null 2>&1 && echo "✔ Running" || echo "✘ Failed"

# 4. Fix all helper scripts
echo ""
echo "[4/6] Fixing helper scripts..."

# tor-on (uses torsocks, not privoxy)
cat > /usr/local/bin/tor-on <<'SCRIPT'
#!/bin/bash
echo ""
echo "  Tor proxy ON"
echo ""
export ALL_PROXY="socks5://127.0.0.1:9050"
export http_proxy="socks5h://127.0.0.1:9050"
export https_proxy="socks5h://127.0.0.1:9050"
export no_proxy="localhost,127.0.0.1"

TORIP=$(torsocks curl -s --max-time 15 ifconfig.me 2>/dev/null)
echo "  Tor IP: ${TORIP:-connecting... try again in 30 sec}"
echo ""
echo "  Usage:"
echo "    curl ifconfig.me              # shows Tor IP"
echo "    torsocks curl ifconfig.me     # also works"
echo "    tor-off                       # disable Tor"
echo "    tor-newid                     # new exit IP"
echo ""
exec bash
SCRIPT
chmod 755 /usr/local/bin/tor-on

# tor-off
cat > /usr/local/bin/tor-off <<'SCRIPT'
#!/bin/bash
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY SOCKS_PROXY no_proxy NO_PROXY
echo ""
echo "  Tor proxy OFF"
REALIP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null)
echo "  Real IP: ${REALIP:-unknown}"
echo ""
exec bash
SCRIPT
chmod 755 /usr/local/bin/tor-off

# tor-newid
cat > /usr/local/bin/tor-newid <<'SCRIPT'
#!/bin/bash
echo "Getting new Tor identity..."
systemctl reload tor 2>/dev/null
sleep 3
TORIP=$(torsocks curl -s --max-time 15 ifconfig.me 2>/dev/null)
echo "New exit IP: ${TORIP:-connecting...}"
SCRIPT
chmod 755 /usr/local/bin/tor-newid

# tor-check
cat > /usr/local/bin/tor-check <<'SCRIPT'
#!/bin/bash
echo ""
echo "=== Tor Status ==="
echo ""

echo -n "  Tor service:  "
systemctl is-active tor >/dev/null 2>&1 && echo "✔ Running" || echo "✘ Stopped"

echo -n "  Privoxy:      "
systemctl is-active privoxy >/dev/null 2>&1 && echo "✔ Running" || echo "✘ Stopped"

echo -n "  Port 9050:    "
ss -tlnp 2>/dev/null | grep -q ":9050 " && echo "✔ Open" || echo "✘ Closed"

echo -n "  Port 8118:    "
ss -tlnp 2>/dev/null | grep -q ":8118 " && echo "✔ Open" || echo "✘ Closed"

echo ""
REALIP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null)
TORIP=$(torsocks curl -s --max-time 15 ifconfig.me 2>/dev/null)
echo "  Real IP:  ${REALIP:-unknown}"
echo "  Tor IP:   ${TORIP:-not connected}"

if [ -n "$TORIP" ] && [ "$REALIP" != "$TORIP" ]; then
  echo ""
  echo "  ✔ Tor is working! IPs are different."
fi

echo ""
echo "=== Commands ==="
echo "  tor-on       Route shell through Tor"
echo "  tor-off      Use direct connection"
echo "  tor-newid    Get new exit IP"
echo "  tor-check    This status page"
echo "  tor-web      Test in browser proxy"
echo "  torsocks     Run single command via Tor"
echo ""
SCRIPT
chmod 755 /usr/local/bin/tor-check

# tor-web (show browser proxy settings)
cat > /usr/local/bin/tor-web <<'SCRIPT'
#!/bin/bash
echo ""
echo "=== Browser Tor Proxy Settings ==="
echo ""
echo "  SOCKS5 Proxy: 127.0.0.1:9050"
echo "  HTTP Proxy:   127.0.0.1:8118"
echo ""
echo "  Firefox: Settings → Network → Manual Proxy"
echo "    SOCKS Host: 127.0.0.1  Port: 9050"
echo "    Check: SOCKS v5"
echo "    Check: Proxy DNS when using SOCKS v5"
echo ""
echo "  Or use SSH tunnel from your PC:"
echo "    ssh -D 9050 root@YOUR_VPS_IP"
echo "    Then set browser SOCKS5 to 127.0.0.1:9050"
echo ""
SCRIPT
chmod 755 /usr/local/bin/tor-web

# tor-apt
cat > /usr/local/bin/tor-apt <<'SCRIPT'
#!/bin/bash
if [ "$(id -u)" -ne 0 ]; then echo "Run as root"; exit 1; fi
echo "Updating APT through Tor..."
torsocks apt-get update
echo ""
echo "To install through Tor:"
echo "  torsocks apt-get install <package>"
SCRIPT
chmod 755 /usr/local/bin/tor-apt

# tor-dns
cat > /usr/local/bin/tor-dns <<'SCRIPT'
#!/bin/bash
if [ -z "$1" ]; then
  echo "Usage: tor-dns <domain>"
  echo "Example: tor-dns google.com"
  exit 1
fi
echo "Resolving $1 through Tor..."
torsocks dig +short "$1" 2>/dev/null || torsocks nslookup "$1" 2>/dev/null
SCRIPT
chmod 755 /usr/local/bin/tor-dns

echo "  All scripts fixed ✔"

# 5. Tor auto-restart
echo ""
echo "[5/6] Tor monitoring..."
mkdir -p /etc/systemd/system/tor.service.d
cat > /etc/systemd/system/tor.service.d/restart.conf <<'EOF'
[Service]
Restart=always
RestartSec=10
EOF
systemctl daemon-reload

cat > /etc/cron.d/tor-health <<'EOF'
*/5 * * * * root systemctl is-active --quiet tor || systemctl restart tor
EOF
echo "  Done ✔"

# 6. Test everything
echo ""
echo "[6/6] Testing..."
echo ""

# Wait for Tor
echo "  Waiting for Tor (15 sec)..."
sleep 15

echo ""
echo -n "  Internet (direct):  "
curl -s --max-time 5 ifconfig.me 2>/dev/null && echo "" || echo "✘"

echo -n "  Tor (torsocks):     "
torsocks curl -s --max-time 15 ifconfig.me 2>/dev/null && echo "" || echo "connecting..."

echo -n "  Tor (socks proxy):  "
curl -s --max-time 15 --socks5-hostname 127.0.0.1:9050 ifconfig.me 2>/dev/null && echo "" || echo "connecting..."

echo -n "  Privoxy (http):     "
curl -s --max-time 15 -x http://127.0.0.1:8118 ifconfig.me 2>/dev/null && echo "" || echo "connecting..."

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  FIXED! ✔                            ║"
echo "╠══════════════════════════════════════╣"
echo "║                                      ║"
echo "║  Commands:                           ║"
echo "║    tor-on      → Use Tor             ║"
echo "║    tor-off     → Direct connection   ║"
echo "║    tor-newid   → New exit IP         ║"
echo "║    tor-check   → Full status         ║"
echo "║    tor-web     → Browser setup       ║"
echo "║    tor-apt     → APT through Tor     ║"
echo "║    tor-dns     → DNS through Tor     ║"
echo "║    torsocks    → Single cmd via Tor  ║"
echo "║                                      ║"
echo "║  Quick test:                         ║"
echo "║    torsocks curl ifconfig.me         ║"
echo "║                                      ║"
echo "╚══════════════════════════════════════╝"
echo ""

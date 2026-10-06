#!/usr/bin/env bash
# =============================================================================
#  Egress-112 : Multi-location rotating egress proxy (Xray-core)
#  Single-file installer / manager.  Ubuntu 22.04 / 24.04, Debian 12 (x86_64, arm64)
#
#  Install :  bash <(curl -fsSL https://raw.githubusercontent.com/USERNAME/REPOSITORY/main/install.sh
#  Manage  :  egress {install|update|uninstall|status|restart|logs|version}
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

# ----------------------------- constants -------------------------------------
readonly SCRIPT_VERSION="1.1.0"
readonly APP_NAME="egress"
readonly BASE_DIR="/opt/egress"
readonly BIN_DIR="${BASE_DIR}/bin"
readonly ENDPOINT_DIR="${BASE_DIR}/endpoints"
readonly SELECTED_DIR="${BASE_DIR}/selected"
readonly OUT_DIR="${BASE_DIR}/out"
readonly BACKUP_DIR="${BASE_DIR}/backup"
readonly LOG_DIR="/var/log/egress"
readonly INSTALL_LOG="${LOG_DIR}/install.log"
readonly SERVICE_NAME="egress-xray"
readonly SCAN_SERVICE="egress-scan"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly SCAN_SERVICE_FILE="/etc/systemd/system/${SCAN_SERVICE}.service"
readonly SCAN_TIMER_FILE="/etc/systemd/system/${SCAN_SERVICE}.timer"
readonly SYSCTL_FILE="/etc/sysctl.d/99-egress-tuning.conf"
readonly LIMITS_FILE="/etc/security/limits.d/99-egress.conf"
readonly SYSTEMD_LIMITS_FILE="/etc/systemd/system.conf.d/99-egress-limits.conf"
readonly NFT_FILE="/etc/nftables.d/egress.nft"
readonly MANAGER_PATH="${BASE_DIR}/egress.sh"
readonly MANAGER_LINK="/usr/local/bin/egress"
readonly VERSION_FILE="${BASE_DIR}/VERSION"
readonly ENV_FILE="${BASE_DIR}/egress.env"
readonly SVC_USER="egress"
readonly XRAY_REPO="XTLS/Xray-core"
readonly RAW_URL="https://raw.githubusercontent.com/USERNAME/REPOSITORY/main/install.sh"
readonly PORT_START=10835
readonly PORT_END=10946

QDISC="${QDISC:-fq}"                    # fq (best with BBR) | fq_codel | cake
EGRESS_LISTEN="${EGRESS_LISTEN:-0.0.0.0}" # 127.0.0.1 if fed only by a local tunnel
XRAY_VERSION="${XRAY_VERSION:-latest}"  # e.g. v25.1.30 to pin
EGRESS_ALLOW_FROM="${EGRESS_ALLOW_FROM:-}" # optional: comma-separated IPs/CIDRs allowed to reach the SOCKS ports
CURRENT_STEP="startup"
TMP_DIR=""

# ----------------------------- output helpers --------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[34m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_RST=""
fi
_log_file() { [[ -d "${LOG_DIR}" ]] && printf '%s %s\n' "$(date '+%F %T')" "$*" >> "${INSTALL_LOG}" 2>/dev/null || true; }
info()  { printf '%s[INFO]%s  %s\n' "${C_BLU}" "${C_RST}" "$*"; _log_file "[INFO] $*"; }
ok()    { printf '%s[ OK ]%s  %s\n' "${C_GRN}" "${C_RST}" "$*"; _log_file "[OK] $*"; }
warn()  { printf '%s[WARN]%s  %s\n' "${C_YLW}" "${C_RST}" "$*" >&2; _log_file "[WARN] $*"; }
err()   { printf '%s[FAIL]%s  %s\n' "${C_RED}" "${C_RST}" "$*" >&2; _log_file "[FAIL] $*"; }
step()  { CURRENT_STEP="$1"; printf '\n%s==> %s%s\n' "${C_BLU}" "$1" "${C_RST}"; _log_file "==> $1"; }
die()   { err "$*"; exit 1; }

on_error() {
  local rc=$1 line=$2 cmd=$3
  err "Step failed: '${CURRENT_STEP}' (line ${line}, exit ${rc})"
  err "Command: ${cmd}"
  [[ -f "${INSTALL_LOG}" ]] && err "Log: ${INSTALL_LOG}"
  exit "${rc}"
}
cleanup() { [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" && "${TMP_DIR}" == /tmp/egress.* ]] && rm -rf -- "${TMP_DIR}"; return 0; }
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

# ----------------------------- preflight -------------------------------------
require_root() { [[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."; }

detect_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found; unsupported OS."
  # shellcheck source=/dev/null
  . /etc/os-release
  OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-unknown}"; OS_NAME="${PRETTY_NAME:-${OS_ID} ${OS_VER}}"
  case "${OS_ID}" in
    ubuntu)
      case "${OS_VER}" in
        24.04) ok "Detected Ubuntu 24.04 LTS (Noble)";;
        22.04|23.*|25.*) ok "Detected ${OS_NAME}";;
        *) warn "Ubuntu ${OS_VER} is untested; continuing.";;
      esac;;
    debian) ok "Detected ${OS_NAME}";;
    *) command -v apt-get >/dev/null 2>&1 || die "Only apt-based systems (Ubuntu/Debian) are supported. Found: ${OS_NAME}"
       warn "Non-Ubuntu/Debian apt system (${OS_NAME}); continuing.";;
  esac
  command -v systemctl >/dev/null 2>&1 || die "systemd is required."
}

detect_arch() {
  local m; m="$(uname -m)"
  case "${m}" in
    x86_64|amd64)   XRAY_ASSET="Xray-linux-64.zip";;
    aarch64|arm64)  XRAY_ASSET="Xray-linux-arm64-v8a.zip";;
    armv7l)         XRAY_ASSET="Xray-linux-arm32-v7a.zip";;
    *) die "Unsupported architecture: ${m}";;
  esac
  ok "Architecture: ${m} -> ${XRAY_ASSET}"
}

install_deps() {
  step "Installing dependencies"
  local pkgs=(curl wget unzip ca-certificates iproute2 iputils-ping python3 gawk nftables ethtool conntrack jq)
  local missing=()
  local p
  for p in "${pkgs[@]}"; do dpkg -s "${p}" >/dev/null 2>&1 || missing+=("${p}"); done
  if ((${#missing[@]} == 0)); then ok "All dependencies present"; return 0; fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends "${missing[@]}"
  ok "Installed: ${missing[*]}"
}

# ----------------------------- directories -----------------------------------
create_dirs() {
  step "Creating directories"
  install -d -m 755 "${BASE_DIR}" "${BIN_DIR}" "${OUT_DIR}" "${LOG_DIR}"
  install -d -m 700 "${ENDPOINT_DIR}" "${SELECTED_DIR}" "${BACKUP_DIR}"
  touch "${INSTALL_LOG}"; chmod 640 "${INSTALL_LOG}"
  ok "Base: ${BASE_DIR}  Logs: ${LOG_DIR}"
}

# ----------------------------- Xray download ---------------------------------
resolve_xray_version() {
  if [[ "${XRAY_VERSION}" == "latest" ]]; then
    local tag
    tag="$(curl -fsSL --retry 3 --max-time 20 "https://api.github.com/repos/${XRAY_REPO}/releases/latest" 2>/dev/null \
          | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')" || true
    if [[ -n "${tag}" ]]; then XRAY_TAG="${tag}"; else XRAY_TAG="latest"; warn "GitHub API unavailable; using /releases/latest redirect"; fi
  else
    XRAY_TAG="${XRAY_VERSION}"
  fi
}

installed_xray_version() {
  [[ -x "${BIN_DIR}/xray" ]] || { echo "none"; return 0; }
  "${BIN_DIR}/xray" version 2>/dev/null | awk 'NR==1{print $2; exit}' || echo "unknown"
}

download_xray() {
  step "Downloading Xray-core"
  resolve_xray_version
  local base
  if [[ "${XRAY_TAG}" == "latest" ]]; then base="https://github.com/${XRAY_REPO}/releases/latest/download"
  else base="https://github.com/${XRAY_REPO}/releases/download/${XRAY_TAG}"; fi
  local zip_url="${base}/${XRAY_ASSET}" dgst_url="${base}/${XRAY_ASSET}.dgst"

  local cur; cur="$(installed_xray_version)"
  if [[ "${XRAY_TAG}" != "latest" && "v${cur#v}" == "v${XRAY_TAG#v}" && "${FORCE_XRAY:-0}" != "1" ]]; then
    ok "Xray ${cur} already installed; skipping download"; return 0
  fi

  cleanup; TMP_DIR="$(mktemp -d /tmp/egress.XXXXXX)"
  info "URL: ${zip_url}"
  curl -fL --retry 3 --retry-delay 2 --max-time 300 -o "${TMP_DIR}/xray.zip" "${zip_url}" \
    || die "Download failed: ${zip_url}"
  [[ -s "${TMP_DIR}/xray.zip" ]] || die "Downloaded file is empty"

  # --- integrity: official .dgst (SHA2-256) when available, zip CRC always ---
  if curl -fsL --retry 2 --max-time 60 -o "${TMP_DIR}/xray.dgst" "${dgst_url}"; then
    local want have
    want="$(grep -iE '^SHA2?-?256' "${TMP_DIR}/xray.dgst" | head -1 | awk -F'= *' '{print tolower($2)}' | tr -d '[:space:]')"
    have="$(sha256sum "${TMP_DIR}/xray.zip" | awk '{print $1}')"
    if [[ -n "${want}" ]]; then
      [[ "${want}" == "${have}" ]] || die "SHA256 mismatch! expected ${want} got ${have}"
      ok "SHA256 verified against official .dgst"
    else
      warn ".dgst present but no SHA256 line found; relying on zip integrity test"
    fi
  else
    warn "Could not fetch .dgst; relying on zip integrity test only"
  fi
  unzip -tq "${TMP_DIR}/xray.zip" >/dev/null || die "Zip integrity test failed (corrupt download)"
  unzip -oq "${TMP_DIR}/xray.zip" -d "${TMP_DIR}/x"
  [[ -f "${TMP_DIR}/x/xray" ]] || die "xray binary missing in archive"
  chmod 755 "${TMP_DIR}/x/xray"
  "${TMP_DIR}/x/xray" version >/dev/null 2>&1 || die "Downloaded xray binary does not execute on this system"

  # atomic install
  install -m 755 "${TMP_DIR}/x/xray" "${BIN_DIR}/xray.new"
  mv -f "${BIN_DIR}/xray.new" "${BIN_DIR}/xray"
  [[ -f "${TMP_DIR}/x/geoip.dat" ]]   && install -m 644 "${TMP_DIR}/x/geoip.dat"   "${BIN_DIR}/geoip.dat"
  [[ -f "${TMP_DIR}/x/geosite.dat" ]] && install -m 644 "${TMP_DIR}/x/geosite.dat" "${BIN_DIR}/geosite.dat"
  ok "Xray $(installed_xray_version) installed to ${BIN_DIR}/xray"
}

# ----------------------------- project files ---------------------------------
write_locations() {
  step "Writing locations.tsv (112 locations)"
  cat > "${BASE_DIR}/locations.tsv" <<'EOF'
10835	US	United States
10836	DE	Germany
10837	NL	Netherlands
10838	GB	United Kingdom
10839	CH	Switzerland
10840	FR	France
10841	CA	Canada
10842	JP	Japan
10843	SG	Singapore
10844	TR	Turkey
10845	AE	United Arab Emirates
10846	KR	South Korea
10847	SE	Sweden
10848	FI	Finland
10849	NO	Norway
10850	DK	Denmark
10851	PL	Poland
10852	IT	Italy
10853	ES	Spain
10854	AT	Austria
10855	BE	Belgium
10856	CZ	Czech Republic
10857	RO	Romania
10858	HU	Hungary
10859	BG	Bulgaria
10860	GR	Greece
10861	IE	Ireland
10862	PT	Portugal
10863	IS	Iceland
10864	LU	Luxembourg
10865	EE	Estonia
10866	LV	Latvia
10867	LT	Lithuania
10868	UA	Ukraine
10869	MD	Moldova
10870	SK	Slovakia
10871	HR	Croatia
10872	SI	Slovenia
10873	RS	Serbia
10874	AL	Albania
10875	MK	North Macedonia
10876	CY	Cyprus
10877	MT	Malta
10878	GE	Georgia
10879	AM	Armenia
10880	AZ	Azerbaijan
10881	IL	Israel
10882	HK	Hong Kong
10883	TW	Taiwan
10884	IN	India
10885	MY	Malaysia
10886	TH	Thailand
10887	VN	Vietnam
10888	PH	Philippines
10889	ID	Indonesia
10890	AU	Australia
10891	NZ	New Zealand
10892	MX	Mexico
10893	BR	Brazil
10894	AR	Argentina
10895	CL	Chile
10896	CO	Colombia
10897	PE	Peru
10898	ZA	South Africa
10899	EG	Egypt
10900	NG	Nigeria
10901	KE	Kenya
10902	MA	Morocco
10903	DZ	Algeria
10904	CR	Costa Rica
10905	PA	Panama
10906	DO	Dominican Republic
10907	PR	Puerto Rico
10908	EC	Ecuador
10909	UY	Uruguay
10910	PY	Paraguay
10911	BO	Bolivia
10912	VE	Venezuela
10913	GT	Guatemala
10914	SV	El Salvador
10915	HN	Honduras
10916	NI	Nicaragua
10917	JM	Jamaica
10918	BS	Bahamas
10919	TT	Trinidad and Tobago
10920	KZ	Kazakhstan
10921	UZ	Uzbekistan
10922	KG	Kyrgyzstan
10923	PK	Pakistan
10924	BD	Bangladesh
10925	LK	Sri Lanka
10926	NP	Nepal
10927	KH	Cambodia
10928	LA	Laos
10929	MM	Myanmar
10930	MO	Macau
10931	MN	Mongolia
10932	JO	Jordan
10933	LB	Lebanon
10934	QA	Qatar
10935	BH	Bahrain
10936	KW	Kuwait
10937	OM	Oman
10938	IQ	Iraq
10939	GH	Ghana
10940	CI	Ivory Coast
10941	SN	Senegal
10942	TN	Tunisia
10943	AO	Angola
10944	ET	Ethiopia
10945	TZ	Tanzania
10946	UG	Uganda
EOF
  chmod 644 "${BASE_DIR}/locations.tsv"
  local n; n="$(wc -l < "${BASE_DIR}/locations.tsv")"
  [[ "${n}" -eq 112 ]] || die "locations.tsv has ${n} lines, expected 112"
  ok "112 locations written"
}

write_endpoint_templates() {
  step "Creating endpoint templates (existing files are never overwritten)"
  local created=0 port code name
  while IFS=$'\t' read -r port code name; do
    [[ -z "${code}" ]] && continue
    local f="${ENDPOINT_DIR}/${code}.txt"
    [[ -f "${f}" ]] && continue
    cat > "${f}" <<EOF
# ${code} - ${name} - inbound port ${port}
# One candidate per line. Format:  proto|host|port|key=value,key=value
# Lines starting with # are ignored. Multiple protocols/IPs may coexist; the scanner picks the cleanest.
#
# wg|engage.cloudflareclient.com|2408|priv=PRIVATE_KEY_BASE64,pub=PEER_PUBLIC_KEY_BASE64,addr=172.16.0.2/32,reserved=0.0.0,mtu=1280
# vless|host.example.com|443|uuid=00000000-0000-0000-0000-000000000000,security=reality,sni=www.microsoft.com,fp=chrome,pbk=REALITY_PUBLIC_KEY,sid=0123abcd,flow=xtls-rprx-vision,net=tcp
# vless|host.example.com|443|uuid=00000000-0000-0000-0000-000000000000,security=tls,sni=host.example.com,net=ws,path=/ws
# vmess|host.example.com|8443|uuid=00000000-0000-0000-0000-000000000000,security=tls,sni=host.example.com,net=grpc,serviceName=grpc
# trojan|host.example.com|443|pass=TROJAN_PASSWORD,sni=host.example.com,net=tcp
# ss|host.example.com|8388|method=2022-blake3-aes-128-gcm,pass=SHADOWSOCKS_PSK
EOF
    chmod 600 "${f}"; created=$((created + 1))
  done < "${BASE_DIR}/locations.tsv"
  ok "Templates created: ${created} (existing kept)"
}

write_gen_config() {
  step "Writing gen-config.py"
  cat > "${BASE_DIR}/gen-config.py" <<'PYEOF'
#!/usr/bin/env python3
"""Generate Xray config from locations.tsv + selected/<CC>.txt (fallback endpoints/<CC>.txt)."""
import argparse, json, os, sys

BASE = os.path.dirname(os.path.abspath(__file__))

def _envfile():
    d = {}
    p = os.path.join(BASE, "egress.env")
    if os.path.exists(p):
        with open(p, encoding="utf-8") as f:
            for l in f:
                l = l.strip()
                if l and not l.startswith("#") and "=" in l:
                    k, v = l.split("=", 1)
                    d[k.strip()] = v.strip().strip("'\"")
    return d

_E = {**_envfile(), **{k: v for k, v in os.environ.items() if k.startswith("EGRESS_")}}
LISTEN = _E.get("EGRESS_LISTEN", "127.0.0.1")
SOCKS_USER = _E.get("EGRESS_USER", "")
SOCKS_PASS = _E.get("EGRESS_PASS", "")

SOCKOPT = {"tcpKeepAliveInterval": 15, "tcpKeepAliveIdle": 30, "tcpFastOpen": True, "tcpNoDelay": True, "mark": 255}
MUX = {"enabled": True, "concurrency": 8, "xudpConcurrency": 16, "xudpProxyUDP443": "allow"}

def load_locations():
    with open(os.path.join(BASE, "locations.tsv"), encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            port, code, name = line.split("\t", 2)
            yield int(port), code, name

def parse_endpoint(line):
    parts = (line.strip().split("|", 3) + [""])[:4]
    proto, host, port, kv = parts
    opts = dict(p.split("=", 1) for p in kv.split(",") if "=" in p)
    return proto, host, int(port), opts

def selected_endpoint(code):
    for d in ("selected", "endpoints"):
        p = os.path.join(BASE, d, f"{code}.txt")
        if not os.path.exists(p):
            continue
        with open(p, encoding="utf-8") as f:
            for l in f:
                s = l.split("#", 1)[0].strip()
                if s:
                    try:
                        return parse_endpoint(s)
                    except Exception as e:
                        sys.stderr.write(f"[warn] {code}: bad endpoint line skipped ({e})\n")
    return None

def stream(host, o):
    net = o.get("net", "tcp"); sec = o.get("security", "none")
    st = {"network": net, "security": sec, "sockopt": SOCKOPT}
    if sec == "tls":
        st["tlsSettings"] = {"serverName": o.get("sni", host), "fingerprint": o.get("fp", "chrome"),
                             "allowInsecure": o.get("insecure", "0") == "1",
                             "alpn": o["alpn"].split(";") if o.get("alpn") else
                                     (["http/1.1"] if net == "ws" else ["h2"] if net == "grpc" else ["h2", "http/1.1"])}
    elif sec == "reality":
        st["realitySettings"] = {"serverName": o.get("sni", host), "fingerprint": o.get("fp", "chrome"),
                                 "publicKey": o["pbk"], "shortId": o.get("sid", ""), "spiderX": "/"}
    if net == "ws":
        st["wsSettings"] = {"path": o.get("path", "/"), "headers": {"Host": o.get("host", o.get("sni", host))}}
    elif net == "grpc":
        st["grpcSettings"] = {"serviceName": o.get("serviceName", "grpc"), "multiMode": True}
    elif net == "xhttp":
        st["xhttpSettings"] = {"path": o.get("path", "/"), "host": o.get("host", o.get("sni", host))}
    return st

def mux_for(o):
    return {} if o.get("net", "tcp") == "xhttp" else {"mux": MUX}

def outbound(tag, ep):
    proto, host, port, o = ep
    if proto == "wg":
        return {"tag": tag, "protocol": "wireguard", "settings": {
            "secretKey": o["priv"], "address": [a for a in o.get("addr", "172.16.0.2/32").split(";") if a],
            "peers": [dict({"publicKey": o["pub"], "endpoint": f"{host}:{port}",
                       "allowedIPs": ["0.0.0.0/0", "::/0"], "keepAlive": 25},
                      **({"preSharedKey": o["psk"]} if o.get("psk") else {}))],
            "mtu": int(o.get("mtu", 1280)), "reserved": [int(x) for x in o.get("reserved", "0.0.0").split(".")],
            "workers": 2, "domainStrategy": "ForceIPv4"},
            "streamSettings": {"sockopt": SOCKOPT}}
    if proto == "vless":
        user = {"id": o["uuid"], "encryption": "none"}
        if o.get("flow"):
            user["flow"] = o["flow"]
        ob = {"tag": tag, "protocol": "vless",
              "settings": {"vnext": [{"address": host, "port": port, "users": [user]}]},
              "streamSettings": stream(host, o)}
        if not o.get("flow") and o.get("net", "tcp") != "xhttp":
            ob["mux"] = MUX
        return ob
    if proto == "vmess":
        return {"tag": tag, "protocol": "vmess",
                "settings": {"vnext": [{"address": host, "port": port,
                                        "users": [{"id": o["uuid"], "security": o.get("cipher", "auto")}]}]},
                "streamSettings": stream(host, o), **mux_for(o)}
    if proto == "trojan":
        o.setdefault("security", "tls")
        return {"tag": tag, "protocol": "trojan",
                "settings": {"servers": [{"address": host, "port": port, "password": o["pass"]}]},
                "streamSettings": stream(host, o), **mux_for(o)}
    if proto == "ss":
        return {"tag": tag, "protocol": "shadowsocks",
                "settings": {"servers": [{"address": host, "port": port, "method": o["method"],
                                          "password": o["pass"], "uot": True}]},
                "streamSettings": {"network": "tcp", "sockopt": SOCKOPT}, "mux": MUX}
    sys.stderr.write(f"[warn] {tag}: protocol '{proto}' not supported by Xray engine; skipped\n")
    return None

def build():
    inbounds, outbounds, rules, active = [], [], [], 0
    accounts = [{"user": SOCKS_USER, "pass": SOCKS_PASS}] if SOCKS_USER else []
    for port, code, name in load_locations():
        itag, otag = f"in-{code}", f"out-{code}"
        inbounds.append({
            "tag": itag, "listen": LISTEN, "port": port, "protocol": "socks",
            "settings": {"auth": "password" if accounts else "noauth", "accounts": accounts, "udp": True},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"], "routeOnly": True},
            "streamSettings": {"sockopt": {"tcpKeepAliveInterval": 15, "tcpFastOpen": True}}})
        ep = selected_endpoint(code)
        ob = None
        if ep:
            try:
                ob = outbound(otag, ep)
            except KeyError as e:
                sys.stderr.write(f"[warn] {code}: missing option {e}; blocked\n")
        if ob:
            outbounds.append(ob); active += 1
            rules.append({"type": "field", "inboundTag": [itag], "outboundTag": otag})
        else:
            rules.append({"type": "field", "inboundTag": [itag], "outboundTag": "block"})
    outbounds += [{"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}},
                  {"tag": "block", "protocol": "blackhole"}]
    cfg = {"log": {"loglevel": "warning", "access": "none", "error": "/var/log/egress/xray-error.log"},
           "dns": {"servers": ["1.1.1.1", "8.8.8.8", "localhost"], "queryStrategy": "UseIPv4"},
           "inbounds": inbounds, "outbounds": outbounds,
           "routing": {"domainStrategy": "AsIs", "rules": rules},
           "policy": {"levels": {"0": {"handshake": 4, "connIdle": 300, "uplinkOnly": 2,
                                        "downlinkOnly": 5, "bufferSize": 512}}}}
    return cfg, active

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    cfg, active = build()
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    tmp = a.out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    os.replace(tmp, a.out)
    print(f"[ok] {len(cfg['inbounds'])} inbounds, {active} active outbounds -> {a.out}")
PYEOF
  chmod 750 "${BASE_DIR}/gen-config.py"
  ok "gen-config.py written"
}

write_scanner() {
  step "Writing select-clean-ip.sh"
  cat > "${BASE_DIR}/select-clean-ip.sh" <<'SHEOF'
#!/usr/bin/env bash
# Scan endpoints/<CC>.txt, reject loss/jitter, score latency, write selected/<CC>.txt, regen config, reload.
set -uo pipefail
BASE="/opt/egress"
SERVICE="egress-xray"
PING_COUNT="${PING_COUNT:-20}"
PING_INTERVAL="${PING_INTERVAL:-0.2}"
MAX_LOSS="${MAX_LOSS:-5}"
MAX_JITTER="${MAX_JITTER:-40}"
TCP_TIMEOUT="${TCP_TIMEOUT:-3}"
JOBS="${JOBS:-16}"
NO_RELOAD="${NO_RELOAD:-0}"
LOG="/var/log/egress/scan-$(date +%F).log"
mkdir -p "$BASE/selected" /var/log/egress

log(){ echo "$(date '+%F %T') $*" | tee -a "$LOG" >&2; }
resolve(){ getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}'; }

icmp_probe(){
  local ip="$1" out loss avg mdev
  out=$(ping -n -q -c "$PING_COUNT" -i "$PING_INTERVAL" -W 1 "$ip" 2>/dev/null) || true
  loss=$(echo "$out" | awk '/packet loss/{for(i=1;i<=NF;i++) if($i ~ /%/){gsub("%","",$i); print $i; exit}}')
  read -r avg mdev < <(echo "$out" | awk -F'[/ ]' '/rtt|round-trip/{print $8, $10}')
  echo "${loss:-100} ${avg:-9999} ${mdev:-9999}"
}

tcp_probe(){
  local ip="$1" port="$2" n=5 fails=0 t0 t1 dt arr=()
  for _ in $(seq "$n"); do
    t0=$(date +%s%N)
    if timeout "$TCP_TIMEOUT" bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null; then
      t1=$(date +%s%N); dt=$(( (t1-t0)/1000000 )); arr+=("$dt")
    else fails=$((fails+1)); fi
  done
  if ((${#arr[@]}==0)); then echo "$fails 9999 9999"; return; fi
  printf '%s\n' "${arr[@]}" | awk -v f="$fails" '{s+=$1; v[NR]=$1} END{
    m=s/NR; for(i=1;i<=NR;i++) d+=(v[i]-m)^2; printf "%d %.1f %.1f\n", f, m, sqrt(d/NR)}'
}

udp_probe(){
  local ip="$1" port="$2"
  if timeout 2 bash -c "head -c 148 /dev/zero | tr '\\0' '\\1' > /dev/udp/$ip/$port" 2>/dev/null; then echo 0; else echo 1; fi
}

score_line(){
  local line="$1" proto host port ip loss avg jit fails tavg tjit score
  IFS='|' read -r proto host port _ <<<"$line"
  ip=$(resolve "$host"); [[ -z "$ip" ]] && { echo "REJECT dns $line"; return; }
  read -r loss avg jit < <(icmp_probe "$ip")
  if [[ "$proto" == "wg" ]]; then
    [[ "$(udp_probe "$ip" "$port")" == "1" ]] && { echo "REJECT udp-closed $line"; return; }
  else
    read -r fails tavg tjit < <(tcp_probe "$ip" "$port")
    (( fails >= 3 )) && { echo "REJECT tcp-fail($fails/5) $line"; return; }
    if awk -v l="$loss" 'BEGIN{exit !(l>=100)}'; then loss=$((fails*20)); avg=$tavg; jit=$tjit; fi
  fi
  awk -v l="$loss" -v m="$MAX_LOSS"   'BEGIN{exit !(l>m)}' && { echo "REJECT loss=${loss}% $line"; return; }
  awk -v j="$jit"  -v m="$MAX_JITTER" 'BEGIN{exit !(j>m)}' && { echo "REJECT jitter=${jit}ms $line"; return; }
  score=$(awk -v a="$avg" -v j="$jit" -v l="$loss" 'BEGIN{printf "%.1f", a + 2*j + l*20}')
  echo "OK $score $ip loss=${loss}% avg=${avg}ms jit=${jit}ms $line"
}
export -f score_line icmp_probe tcp_probe udp_probe resolve
export PING_COUNT PING_INTERVAL TCP_TIMEOUT MAX_LOSS MAX_JITTER

scan_location(){
  local code="$1" f="$BASE/endpoints/$1.txt" results best line
  [[ -s "$f" ]] || { log "[$code] no endpoints file"; return; }
  results=$(grep -vE '^\s*(#|$)' "$f" | sed 's/[[:space:]]*#.*$//' | \
            xargs -r -d '\n' -P "$JOBS" -I{} bash -c 'score_line "$1"' _ {})
  [[ -z "$results" ]] && { log "[$code] no candidates (template only)"; return; }
  echo "$results" | grep '^REJECT' | sed "s/^/[$code] /" >> "$LOG" || true
  best=$(echo "$results" | grep '^OK' | sort -k2,2n | head -1)
  if [[ -z "$best" ]]; then log "[$code] no clean endpoint - keeping previous selection"; return; fi
  line=$(echo "$best" | awk '{for(i=7;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":""); print ""}')
  printf '# selected %s | %s\n%s\n' "$(date '+%F %T')" "$(echo "$best" | cut -d' ' -f2-6)" "$line" > "$BASE/selected/$code.txt"
  chmod 600 "$BASE/selected/$code.txt"
  log "[$code] OK $(echo "$best" | cut -d' ' -f2-6) -> $(echo "$line" | cut -d'|' -f1,2)"
}

main(){
  local codes c
  if [[ $# -gt 0 ]]; then codes=("$@"); else mapfile -t codes < <(awk -F'\t' '!/^#/{print $2}' "$BASE/locations.tsv"); fi
  log "=== scan start: ${#codes[@]} locations ==="
  for c in "${codes[@]}"; do scan_location "$c"; done
  python3 "$BASE/gen-config.py" --out "$BASE/out/xray.json" || { log "config generation failed"; exit 1; }
  "$BASE/bin/xray" run -test -c "$BASE/out/xray.json" >/dev/null || { log "config test failed; service NOT reloaded"; exit 1; }
  if [[ -f "$BASE/config.json" ]] && cmp -s "$BASE/out/xray.json" "$BASE/config.json"; then
    log "=== config unchanged; no restart needed ==="; exit 0
  fi
  install -m 640 -o root -g egress "$BASE/out/xray.json" "$BASE/config.json"
  if [[ "$NO_RELOAD" == "1" ]]; then log "=== config written (reload skipped) ==="; exit 0; fi
  if systemctl restart "$SERVICE"; then log "=== $SERVICE reloaded ==="; else log "restart failed"; exit 1; fi
}
main "$@"
SHEOF
  chmod 750 "${BASE_DIR}/select-clean-ip.sh"
  ok "select-clean-ip.sh written"
}

# ----------------------------- kernel tuning ---------------------------------
tune_kernel() {
  step "Applying kernel tuning (BBR + ${QDISC})"
  modprobe tcp_bbr 2>/dev/null || true
  modprobe sch_fq_codel 2>/dev/null || true; modprobe sch_cake 2>/dev/null || true; modprobe sch_fq 2>/dev/null || true
  modprobe nf_conntrack 2>/dev/null || true
  cat > "${SYSCTL_FILE}" <<EOF
# Managed by egress install.sh - do not edit (re-run installer instead)
net.core.default_qdisc = ${QDISC}
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.core.netdev_max_backlog = 16384
net.core.netdev_budget = 600
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.ip_local_port_range = 20000 65535
EOF
  chmod 644 "${SYSCTL_FILE}"
  # Apply only our file; tolerate keys the kernel/container doesn't expose.
  if ! sysctl -q -p "${SYSCTL_FILE}" >/dev/null 2>&1; then
    warn "Some sysctl keys were rejected (container/old kernel?); applying one by one"
    local k v
    while IFS='=' read -r k v; do
      k="${k//[[:space:]]/}"; [[ -z "${k}" || "${k}" == \#* ]] && continue
      sysctl -q -w "${k}=${v# }" >/dev/null 2>&1 || warn "sysctl skipped: ${k}"
    done < "${SYSCTL_FILE}"
  fi
  local cc; cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  [[ "${cc}" == "bbr" ]] && ok "BBR active, qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)" \
                         || warn "BBR not active (current: ${cc}); kernel may lack tcp_bbr"
}

tune_limits() {
  step "Raising file-descriptor limits"
  cat > "${LIMITS_FILE}" <<EOF
# Managed by egress
*    soft nofile 1048576
*    hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
  install -d -m 755 "$(dirname "${SYSTEMD_LIMITS_FILE}")"
  cat > "${SYSTEMD_LIMITS_FILE}" <<EOF
[Manager]
DefaultLimitNOFILE=1048576
EOF
  systemctl daemon-reexec 2>/dev/null || true
  ok "nofile limit = 1048576"
}

# ----------------------------- security / env --------------------------------
rand_str() { tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c "${1:-24}" || true; }

write_env() {
  step "Writing ${ENV_FILE}"
  if [[ -f "${ENV_FILE}" ]]; then
    ok "Existing env kept (edit ${ENV_FILE} then 'egress restart')"; return 0
  fi
  local user="${EGRESS_USER:-}" pass="${EGRESS_PASS:-}"
  if [[ "${EGRESS_LISTEN}" != "127.0.0.1" && -z "${user}" ]]; then
    user="egress"; pass="$(rand_str 24)"
    warn "Listening on ${EGRESS_LISTEN}: SOCKS auth auto-enabled (an open proxy on 112 ports gets abused fast)"
  fi
  umask 077
  cat > "${ENV_FILE}" <<EOF
# egress runtime settings (read by gen-config.py)
EGRESS_LISTEN=${EGRESS_LISTEN}
EGRESS_USER=${user}
EGRESS_PASS=${pass}
EOF
  chmod 600 "${ENV_FILE}"
  [[ -n "${user}" ]] && ok "SOCKS auth: ${user} / ${pass}" || ok "SOCKS auth: none (loopback only)"
}

create_user() {
  id -u "${SVC_USER}" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "${SVC_USER}"
  chown "${SVC_USER}:${SVC_USER}" "${LOG_DIR}"
  chmod 750 "${LOG_DIR}"
}

write_firewall() {
  step "Firewall (nftables)"
  install -d -m 755 "$(dirname "${NFT_FILE}")"
  if [[ -z "${EGRESS_ALLOW_FROM}" ]]; then
    printf 'table inet egress\ndelete table inet egress\n' > "${NFT_FILE}"
    ok "No EGRESS_ALLOW_FROM set; port filtering disabled"; return 0
  fi
  local v4=() v6=() a
  IFS=',' read -r -a _allow <<< "${EGRESS_ALLOW_FROM}"
  for a in "${_allow[@]}"; do a="${a//[[:space:]]/}"; [[ -z "${a}" ]] && continue
    if [[ "${a}" == *:* ]]; then v6+=("${a}"); else v4+=("${a}"); fi; done
  {
    echo "table inet egress"
    echo "delete table inet egress"
    echo "table inet egress {"
    echo "  chain input {"
    echo "    type filter hook input priority -5; policy accept;"
    echo "    iif lo accept"
    ((${#v4[@]})) && echo "    ip saddr { $(IFS=,; echo "${v4[*]}") } tcp dport ${PORT_START}-${PORT_END} accept"
    ((${#v4[@]})) && echo "    ip saddr { $(IFS=,; echo "${v4[*]}") } udp dport ${PORT_START}-${PORT_END} accept"
    ((${#v6[@]})) && echo "    ip6 saddr { $(IFS=,; echo "${v6[*]}") } tcp dport ${PORT_START}-${PORT_END} accept"
    ((${#v6[@]})) && echo "    ip6 saddr { $(IFS=,; echo "${v6[*]}") } udp dport ${PORT_START}-${PORT_END} accept"
    echo "    meta l4proto { tcp, udp } th dport ${PORT_START}-${PORT_END} drop"
    echo "  }"
    echo "}"
  } > "${NFT_FILE}"
  nft -c -f "${NFT_FILE}" || die "Generated nftables rules are invalid"
  nft -f "${NFT_FILE}"
  ok "Ports ${PORT_START}-${PORT_END} restricted to: ${EGRESS_ALLOW_FROM}"
}

# ----------------------------- systemd ---------------------------------------
write_services() {
  step "Writing systemd units"
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Egress-112 Xray multi-location proxy
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStartPre=+-/usr/sbin/nft -f ${NFT_FILE}
ExecStartPre=${BIN_DIR}/xray run -test -c ${BASE_DIR}/config.json
ExecStart=${BIN_DIR}/xray run -c ${BASE_DIR}/config.json
Environment=XRAY_LOCATION_ASSET=${BIN_DIR}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
LimitNPROC=65535
TasksMax=infinity
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF

  cat > "${SCAN_SERVICE_FILE}" <<EOF
[Unit]
Description=Egress-112 endpoint scanner (pick cleanest IP per location)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BASE_DIR}/select-clean-ip.sh
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=50min
EOF

  cat > "${SCAN_TIMER_FILE}" <<EOF
[Unit]
Description=Run Egress-112 scanner periodically

[Timer]
OnBootSec=3min
OnUnitActiveSec=30min
RandomizedDelaySec=120
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  ok "Units: ${SERVICE_NAME}.service, ${SCAN_SERVICE}.timer"
}

build_config() {
  step "Generating Xray config"
  python3 "${BASE_DIR}/gen-config.py" --out "${OUT_DIR}/xray.json"
  XRAY_LOCATION_ASSET="${BIN_DIR}" "${BIN_DIR}/xray" run -test -c "${OUT_DIR}/xray.json" >/dev/null \
    || die "Xray rejected generated config (see: ${BIN_DIR}/xray run -test -c ${OUT_DIR}/xray.json)"
  [[ -f "${BASE_DIR}/config.json" ]] && cp -a "${BASE_DIR}/config.json" "${BACKUP_DIR}/config.$(date +%Y%m%d-%H%M%S).json"
  install -m 640 -o root -g "${SVC_USER}" "${OUT_DIR}/xray.json" "${BASE_DIR}/config.json"
  # keep only the 10 newest backups
  find "${BACKUP_DIR}" -maxdepth 1 -name 'config.*.json' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | tail -n +11 | cut -d' ' -f2- | xargs -r rm -f --
  ok "Config installed"
}

install_manager() {
  step "Installing manager command"
  local src="${BASH_SOURCE[0]:-$0}"
  if [[ -f "${src}" && -r "${src}" ]]; then
    [[ "$(readlink -f "${src}")" != "$(readlink -f "${MANAGER_PATH}" 2>/dev/null || true)" ]] \
      && install -m 750 "${src}" "${MANAGER_PATH}"
  else
    # running via: bash <(curl ...)  -> $0 is a pipe, fetch a real copy
    curl -fsSL --retry 3 --max-time 60 -o "${MANAGER_PATH}.new" "${RAW_URL}" \
      || die "Cannot fetch manager script from ${RAW_URL} (set RAW_URL to your repo)"
    bash -n "${MANAGER_PATH}.new" || die "Downloaded manager script has syntax errors"
    install -m 750 "${MANAGER_PATH}.new" "${MANAGER_PATH}"; rm -f "${MANAGER_PATH}.new"
  fi
  ln -sf "${MANAGER_PATH}" "${MANAGER_LINK}"
  echo "${SCRIPT_VERSION}" > "${VERSION_FILE}"
  ok "Command available: ${APP_NAME}"
}

# ----------------------------- commands --------------------------------------
cmd_install() {
  require_root
  step "Preflight"; detect_os; detect_arch
  install_deps
  create_dirs
  create_user
  download_xray
  write_locations
  write_endpoint_templates
  write_gen_config
  write_scanner
  write_env
  tune_kernel
  tune_limits
  write_firewall
  write_services
  build_config
  install_manager
  step "Starting services"
  systemctl enable --now "${SERVICE_NAME}.service" >/dev/null 2>&1
  systemctl restart "${SERVICE_NAME}.service"
  systemctl enable --now "${SCAN_SERVICE}.timer" >/dev/null 2>&1
  sleep 1
  systemctl is-active --quiet "${SERVICE_NAME}" || die "Service failed to start: journalctl -u ${SERVICE_NAME} -n 50"
  ok "Egress-112 ${SCRIPT_VERSION} is running"
  info "Add endpoints in ${ENDPOINT_DIR}/<CC>.txt, then run: ${APP_NAME} scan"
}

cmd_update() {
  require_root
  [[ -d "${BASE_DIR}" ]] || die "Not installed. Run: ${APP_NAME} install"
  detect_arch
  create_user
  download_xray
  write_env
  write_gen_config
  write_scanner
  build_config
  systemctl restart "${SERVICE_NAME}"
  ok "Updated; Xray $(installed_xray_version)"
}

cmd_uninstall() {
  require_root
  local purge="${1:-}"
  step "Uninstalling"
  systemctl disable --now "${SCAN_SERVICE}.timer" "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  nft delete table inet egress 2>/dev/null || true
  rm -f "${SERVICE_FILE}" "${SCAN_SERVICE_FILE}" "${SCAN_TIMER_FILE}" "${SYSCTL_FILE}" \
        "${LIMITS_FILE}" "${SYSTEMD_LIMITS_FILE}" "${NFT_FILE}" "${MANAGER_LINK}"
  systemctl daemon-reload
  if [[ "${purge}" == "--purge" ]]; then
    rm -rf -- "${BASE_DIR}" "${LOG_DIR}"
    userdel "${SVC_USER}" 2>/dev/null || true
    ok "Purged everything"
  else
    local keep="/root/egress-endpoints-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "${keep}" -C "${BASE_DIR}" endpoints egress.env 2>/dev/null || true
    rm -rf -- "${BASE_DIR}"
    ok "Removed. Endpoints backed up to ${keep} (use --purge to skip backup)"
  fi
  info "Kernel sysctl changes revert on next reboot"
}

cmd_status() {
  systemctl --no-pager status "${SERVICE_NAME}" 2>/dev/null | head -n 5 || true
  echo
  systemctl --no-pager list-timers "${SCAN_SERVICE}.timer" 2>/dev/null | head -n 3 || true
  echo
  local active=0 total=0 c
  if [[ -f "${BASE_DIR}/locations.tsv" ]]; then
    total=$(grep -c . "${BASE_DIR}/locations.tsv")
    for c in "${SELECTED_DIR}"/*.txt; do [[ -e "${c}" ]] && active=$((active + 1)); done
  fi
  echo "Locations with a selected endpoint: ${active}/${total}"
  local listening; listening=$(ss -Hltn "sport >= :${PORT_START} and sport <= :${PORT_END}" 2>/dev/null | wc -l)
  echo "Listening TCP ports in range: ${listening}"
}

cmd_logs() {
  local which="${1:-xray}"
  case "${which}" in
    xray)  journalctl -u "${SERVICE_NAME}" -n 100 --no-pager; [[ -f "${LOG_DIR}/xray-error.log" ]] && tail -n 50 "${LOG_DIR}/xray-error.log";;
    scan)  tail -n 100 "${LOG_DIR}/scan-$(date +%F).log" 2>/dev/null || echo "No scan log today";;
    install) tail -n 100 "${INSTALL_LOG}" 2>/dev/null || true;;
    *) die "logs: xray|scan|install";;
  esac
}

usage() {
  cat <<EOF
Egress-112 manager v${SCRIPT_VERSION}
Usage: ${APP_NAME} <command>
  install            install / repair everything
  update             update Xray + helper scripts, keep endpoints
  uninstall [--purge] remove (endpoints backed up unless --purge)
  status             service + selection summary
  restart            restart proxy
  scan [CC ...]      re-scan endpoints now (all or given country codes)
  config             regenerate config from current selections
  logs [xray|scan|install]
  version
Env: EGRESS_LISTEN=127.0.0.1|0.0.0.0  EGRESS_USER/EGRESS_PASS  EGRESS_ALLOW_FROM=1.2.3.4,10.0.0.0/8
     QDISC=fq|fq_codel|cake  XRAY_VERSION=vX.Y.Z  FORCE_XRAY=1
EOF
}

main() {
  local cmd="${1:-install}"; shift || true
  case "${cmd}" in
    install)   cmd_install "$@";;
    update)    cmd_update "$@";;
    uninstall|remove) cmd_uninstall "$@";;
    status)    cmd_status;;
    restart)   require_root; build_config; systemctl restart "${SERVICE_NAME}"; ok "Restarted";;
    scan)      require_root; "${BASE_DIR}/select-clean-ip.sh" "$@";;
    config)    require_root; build_config; systemctl restart "${SERVICE_NAME}"; ok "Config regenerated";;
    logs)      cmd_logs "$@";;
    version|-v|--version) echo "egress ${SCRIPT_VERSION} | xray $(installed_xray_version)";;
    help|-h|--help) usage;;
    *) usage; exit 2;;
  esac
}

main "$@"

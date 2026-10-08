#!/usr/bin/env bash
# =============================================================================
# Xray Node Controller — multi-region VLESS fleet manager
# Version 1.0.0 | Linux with systemd | Bash 4.4+
#
# The controller maintains one Xray service per configured region. Each service
# selects an upstream VLESS node and exposes its local SOCKS endpoint only on
# 127.0.0.1. Node metadata belongs in nodes.yaml; UUIDs and Telegram credentials
# belong exclusively in the root-readable .env file. The generated Xray JSON
# contains credentials and is protected by filesystem permissions.
#
# Quick start:
#   sudo bash node-controller.sh install
#   edit /etc/xray-node-ctrl/nodes.yaml and protected .env
#   sudo xraync healthcheck && sudo xraync status
#
# Commands: install, update, status, health, failover, uninstall, menu,
# net-doctor, test, restart, reload, list; global flags --dry-run, --yes, --help.
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

VERSION="1.0.0"
XRAY_VERSION="25.3.6"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}"
XRAY_USER="xraync"
INSTALL_DIR="/opt/xray-node-ctrl"
BIN_DIR="${INSTALL_DIR}/bin"
XRAY_BIN="${BIN_DIR}/xray"
CONFIG_DIR="/etc/xray-node-ctrl"
NODES_FILE="${CONFIG_DIR}/nodes.yaml"
ENV_FILE="${CONFIG_DIR}/.env"
GENERATED_DIR="${CONFIG_DIR}/generated"
DATA_DIR="/var/lib/xray-node-ctrl"
STATE_FILE="${DATA_DIR}/states.json"
LOG_DIR="/var/log/xray-node-ctrl"
LOG_FILE="${LOG_DIR}/controller.log"
SYSTEMD_DIR="/etc/systemd/system"
UNIT_PREFIX="xray-node-ctrl-"
CTL_PATH="/usr/local/bin/xraync"
LOGROTATE_FILE="/etc/logrotate.d/xray-node-ctrl"
LOCK_FILE="/run/lock/xray-node-ctrl.lock"
REGIONS=(AE-DXB DE NL US-NY US-LA SG JP TR GB)
PORT_BASE="${XRAYNC_PORT_BASE:-10800}"
DOWNLOAD_RETRIES="${DOWNLOAD_RETRIES:-4}"
DRY_RUN=false
ASSUME_YES=false
TMP_FILES=()

now() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log_info() { printf '[%s] [INFO] %s\n' "$(now)" "$*" | tee -a "$LOG_FILE" >&2; }
log_ok() { printf '[%s] [ OK ] %s\n' "$(now)" "$*" | tee -a "$LOG_FILE" >&2; }
log_warn() { printf '[%s] [WARN] %s\n' "$(now)" "$*" | tee -a "$LOG_FILE" >&2; }
log_fail() { printf '[%s] [FAIL] %s\n' "$(now)" "$*" | tee -a "$LOG_FILE" >&2; }
on_error() { local rc=$?; log_fail "خطا در خط ${1:-?}: ${2:-unknown} (exit $rc)"; return "$rc"; }
cleanup() { local f; for f in "${TMP_FILES[@]:-}"; do [[ -n "$f" ]] && rm -rf -- "$f" 2>/dev/null || true; done; }
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap cleanup EXIT

dry_run() {
    if "$DRY_RUN"; then printf '[DRY-RUN]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}
need_root() { (( EUID == 0 )) || { log_fail 'این عملیات به root نیاز دارد.'; return 1; }; }
init_logging() {
    if (( EUID == 0 )); then mkdir -p "$LOG_DIR"; touch "$LOG_FILE"; chmod 0640 "$LOG_FILE"; fi
}
lock_operation() {
    mkdir -p /run/lock
    exec 9>"$LOCK_FILE"
    flock -n 9 || { log_warn 'عملیات دیگری در حال اجراست.'; return 1; }
}
confirm() {
    "$ASSUME_YES" && return 0
    [[ -t 0 ]] || { log_fail 'ورودی تعاملی نیست؛ --yes را بدهید.'; return 1; }
    local answer
    read -r -p "${1:-ادامه می‌دهید؟} [y/N] " answer
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}
backup_file() {
    local f=$1
    [[ -e "$f" ]] || return 0
    cp -a -- "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
}
# Atomic idempotent file write; existing content is backed up only on change.
write_if_changed() {
    local target=$1 mode=$2 owner=$3 group=$4 tmp
    mkdir -p "$(dirname "$target")"
    tmp=$(mktemp "$(dirname "$target")/.write.XXXXXX")
    TMP_FILES+=("$tmp")
    cat >"$tmp"
    if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then rm -f "$tmp"; return 0; fi
    if "$DRY_RUN"; then log_info "DRY-RUN write $target mode=$mode"; rm -f "$tmp"; return 0; fi
    backup_file "$target"
    install -o "$owner" -g "$group" -m "$mode" "$tmp" "$target"
    rm -f "$tmp"
}

usage() {
cat <<'HELP'
xray-node-ctrl: regional VLESS/Xray node manager
Usage: node-controller.sh [global-options] COMMAND
Global options: --dry-run (show planned work), --yes (non-interactive confirmation)
Commands:
 install       install dependencies, create config, units, timer and CLI
 update        verify/update Xray binary, regenerate configs, reload services
 status        summary of service and active region/node
 health        perform health checks and evaluate failover state
 failover      run health evaluation and apply eligible switches
 uninstall     remove service/controller data after confirmation
 menu          interactive administration menu
 net-doctor    local system/network diagnostics (does not expose secrets)
 test          validate inventory and Xray JSON configs
 restart       restart all region services
 reload        regenerate config and restart region services
 list          list configured regions and current selected node
HELP
}

region_slug() { printf '%s' "$1" | tr '[:upper:]_' '[:lower:]\-' | tr -cd 'a-z0-9-'; }
region_index() { local i; for i in "${!REGIONS[@]}"; do [[ "${REGIONS[$i]}" == "$1" ]] && { echo "$i"; return; }; done; return 1; }

install_dependencies() {
    local pm
    for pm in apt-get dnf yum apk; do command -v "$pm" >/dev/null 2>&1 && break; done
    case "$pm" in
      apt-get) "$DRY_RUN" || apt-get update; dry_run apt-get install -y ca-certificates curl python3 python3-yaml unzip coreutils util-linux logrotate ;;
      dnf|yum) dry_run "$pm" install -y ca-certificates curl python3 python3-pyyaml unzip coreutils util-linux logrotate ;;
      apk) dry_run apk add ca-certificates curl python3 py3-yaml unzip coreutils util-linux logrotate ;;
      *) log_fail 'مدیر بسته پیدا نشد؛ پیش‌نیازها را دستی نصب کنید.'; return 1 ;;
    esac
}
require_tools() {
    local c; for c in python3 curl sha256sum unzip systemctl flock; do
      command -v "$c" >/dev/null 2>&1 || { log_fail "ابزار لازم نیست: $c"; return 1; }
    done
}
create_user() {
    if ! getent passwd "$XRAY_USER" >/dev/null; then
      dry_run useradd --system --home-dir "$INSTALL_DIR" --no-create-home --shell /usr/sbin/nologin "$XRAY_USER"
    fi
    "$DRY_RUN" && return 0
    install -d -o root -g "$XRAY_USER" -m 0750 "$INSTALL_DIR" "$BIN_DIR"
    install -d -o root -g root -m 0750 "$CONFIG_DIR"
    install -d -o root -g "$XRAY_USER" -m 0750 "$GENERATED_DIR"
    install -d -o "$XRAY_USER" -g "$XRAY_USER" -m 0750 "$DATA_DIR" "$LOG_DIR"
}
archive_name() {
    case "$(uname -m)" in
      x86_64|amd64) echo Xray-linux-64.zip;;
      aarch64|arm64) echo Xray-linux-arm64-v8a.zip;;
      armv7l) echo Xray-linux-arm32-v7a.zip;;
      *) log_fail "معماری پشتیبانی نمی‌شود: $(uname -m)"; return 1;;
    esac
}
fetch_retry() {
    local url=$1 out=$2 n delay=2
    for ((n=1;n<=DOWNLOAD_RETRIES;n++)); do
      log_info "دریافت تلاش $n/$DOWNLOAD_RETRIES"
      if curl --fail --location --silent --show-error --connect-timeout 15 --max-time 300 "$url" -o "$out"; then return 0; fi
      (( n == DOWNLOAD_RETRIES )) && break
      sleep "$delay"; delay=$((delay*2))
    done
    log_fail "دانلود ناموفق: $url"; return 1
}
install_xray_binary() {
    local name tmp zip sums expected actual
    name=$(archive_name); tmp=$(mktemp -d); TMP_FILES+=("$tmp")
    if "$DRY_RUN"; then log_info "DRY-RUN download Xray v$XRAY_VERSION + SHA256 verification"; return 0; fi
    zip="$tmp/$name"; sums="$tmp/sha256sum.txt"
    fetch_retry "$XRAY_URL/$name" "$zip"
    if ! fetch_retry "$XRAY_URL/sha256sum.txt" "$sums"; then fetch_retry "$XRAY_URL/SHA256SUMS" "$sums"; fi
    expected=$(awk -v f="$name" '$2==f || $2==("*" f) {print $1;exit}' "$sums")
    [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || { log_fail 'هش archive در manifest رسمی نیست.'; return 1; }
    actual=$(sha256sum "$zip" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || { log_fail 'اعتبارسنجی SHA256 ناموفق.'; return 1; }
    unzip -p "$zip" xray >"$tmp/xray"
    [[ -s "$tmp/xray" ]] || { log_fail 'فایل باینری در archive پیدا نشد.'; return 1; }
    chmod 0755 "$tmp/xray"; "$tmp/xray" version >/dev/null
    if [[ -x "$XRAY_BIN" ]] && cmp -s "$tmp/xray" "$XRAY_BIN"; then log_ok 'Xray فعلی برابر نسخهٔ تأییدشده است.'; return; fi
    backup_file "$XRAY_BIN"
    install -o root -g root -m 0755 "$tmp/xray" "$XRAY_BIN"
    log_ok "Xray نصب شد: $($XRAY_BIN version | head -n1)"
}


# =============================================================================
# Protected environment and example inventory
# =============================================================================
create_default_files() {
    if [[ ! -e "$NODES_FILE" ]]; then
      write_if_changed "$NODES_FILE" 0640 root "$XRAY_USER" <<'YAML'
# Inventory is public metadata only: never put a VLESS UUID here.
# For every name, .env must define NODE_<NAME_WITH_PUNCTUATION_AS_UNDERSCORES>_UUID.
# Example key for ae-dxb-primary: NODE_AE_DXB_PRIMARY_UUID
# Add one or more reachable endpoints for each enabled region.
nodes:
  - name: ae-dxb-primary
    region: AE-DXB
    priority: primary
    protocol: VLESS
    transport: ws
    address: edge.example.net
    port: 443
    tls: true
    path: /vless
YAML
    fi
    if [[ ! -e "$ENV_FILE" ]]; then
      local id
      id=$(python3 -c 'import uuid; print(uuid.uuid4())')
      write_if_changed "$ENV_FILE" 0600 root root <<ENV
# Private credentials. Protect this file (chmod 600). Never commit it.
NODE_AE_DXB_PRIMARY_UUID=$id
# Optional; both values must be populated to enable Telegram notifications.
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
ENV
    fi
    "$DRY_RUN" || chmod 0600 "$ENV_FILE"
}

# All inventory parsing/validation runs in Python. .env values are parsed as
# inert text: this script never sources or evaluates secrets as shell commands.
validate_config() {
    [[ -r "$NODES_FILE" && -r "$ENV_FILE" ]] || { log_fail 'nodes.yaml یا .env قابل خواندن نیست.'; return 1; }
    python3 - "$NODES_FILE" "$ENV_FILE" "${REGIONS[*]}" <<'PY'
import re,sys,yaml
yp,ep,region_text=sys.argv[1:]
regions=set(region_text.split())
with open(yp,encoding='utf-8') as f: doc=yaml.safe_load(f)
if not isinstance(doc,dict) or not isinstance(doc.get('nodes'),list) or not doc['nodes']:
    raise SystemExit('nodes.yaml must have a non-empty nodes: list')
required=('name','region','priority','protocol','transport','address','port','tls','path')
seen=set()
for i,n in enumerate(doc['nodes'],1):
    if not isinstance(n,dict): raise SystemExit(f'node {i} must be a mapping')
    missing=[k for k in required if k not in n or n[k] is None]
    if missing: raise SystemExit(f'node {i} missing required fields: {", ".join(missing)}')
    name=n['name']
    if not isinstance(name,str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}',name): raise SystemExit(f'node {i}: invalid name')
    if name.lower() in seen: raise SystemExit(f'duplicate node name: {name}')
    seen.add(name.lower())
    if n['region'] not in regions: raise SystemExit(f'{name}: unsupported region {n["region"]}')
    if n['priority'] not in ('primary','secondary'): raise SystemExit(f'{name}: priority must be primary/secondary')
    if str(n['protocol']).upper()!='VLESS': raise SystemExit(f'{name}: only VLESS is supported')
    if n['transport'] not in ('ws','grpc','tcp'): raise SystemExit(f'{name}: invalid transport')
    if not isinstance(n['address'],str) or not n['address'] or any(c.isspace() for c in n['address']): raise SystemExit(f'{name}: invalid address')
    if type(n['port']) is not int or not 1<=n['port']<=65535: raise SystemExit(f'{name}: invalid port')
    if type(n['tls']) is not bool: raise SystemExit(f'{name}: tls must be boolean')
    if not isinstance(n['path'],str): raise SystemExit(f'{name}: path must be a string')
env={}
for line in open(ep,encoding='utf-8'):
    t=line.strip()
    if not t or t.startswith('#'): continue
    if '=' not in t: raise SystemExit('malformed .env line')
    k,v=t.split('=',1)
    if not re.fullmatch(r'[A-Z][A-Z0-9_]*',k): raise SystemExit(f'invalid .env key {k!r}')
    env[k]=v.strip().strip('"\'')
for n in doc['nodes']:
    key='NODE_'+re.sub('[^A-Za-z0-9]','_',n['name']).upper()+'_UUID'
    if key not in env: raise SystemExit(f'missing protected .env variable: {key}')
    if not re.fullmatch(r'[0-9a-fA-F-]{36}',env[key]): raise SystemExit(f'{key} must be a UUID')
for key in ('TELEGRAM_BOT_TOKEN','TELEGRAM_CHAT_ID'):
    if any(ord(ch)<32 for ch in env.get(key,'')): raise SystemExit(f'invalid control character in {key}')
print(f'Validated {len(doc["nodes"])} node(s), {len(set(n["region"] for n in doc["nodes"]))} region(s).')
PY
}

ensure_state() {
    [[ -s "$STATE_FILE" ]] && return 0
    "$DRY_RUN" && return 0
    mkdir -p "$DATA_DIR"
    printf '{"version":1,"nodes":{},"regions":{},"last_daily_summary":""}\n' >"$STATE_FILE"
    chown "$XRAY_USER:$XRAY_USER" "$STATE_FILE"
    chmod 0640 "$STATE_FILE"
}

# Produce one valid Xray JSON file for every node's region. Candidate nodes are
# emitted as individual outbound tags; failover selection is held in states.json
# and regenerated as the active outbound tag. SOCKS inbound addresses always use
# loopback IPs, never a wildcard or a public interface.
generate_configs() {
    validate_config
    local base=${XRAYNC_PORT_BASE:-$PORT_BASE}
    "$DRY_RUN" && { log_info "DRY-RUN generate region JSON in $GENERATED_DIR (base port $base)"; return 0; }
    python3 - "$NODES_FILE" "$ENV_FILE" "$STATE_FILE" "$GENERATED_DIR" "$base" <<'PY'
import json,os,re,sys,tempfile,time,shutil
import yaml
np,ep,sp,outdir,base=sys.argv[1:]; base=int(base)
regions=['AE-DXB','DE','NL','US-NY','US-LA','SG','JP','TR','GB']
def envread():
    d={}
    for line in open(ep,encoding='utf-8'):
        s=line.strip()
        if s and not s.startswith('#'):
            k,v=s.split('=',1); d[k]=v.strip().strip('"\'')
    return d
def atomic(path,obj):
    raw=(json.dumps(obj,indent=2,ensure_ascii=False)+'\n').encode()
    os.makedirs(os.path.dirname(path),exist_ok=True)
    try:
        if open(path,'rb').read()==raw: return
    except FileNotFoundError: pass
    if os.path.exists(path): shutil.copy2(path,path+'.bak.'+time.strftime('%Y%m%d%H%M%S'))
    fd,tmp=tempfile.mkstemp(prefix='.new-',dir=os.path.dirname(path))
    with os.fdopen(fd,'wb') as f: f.write(raw); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,0o640)
    import pwd,grp
    os.chown(tmp,0,grp.getgrnam('xraync').gr_gid)
    os.replace(tmp,path)
def slug(s): return re.sub(r'[^a-z0-9-]+','-',s.lower()).strip('-')
def tag(n): return 'node-'+slug(n['name'])
nodes=yaml.safe_load(open(np,encoding='utf-8'))['nodes']; secrets=envread()
try: state=json.load(open(sp,encoding='utf-8'))
except (FileNotFoundError,json.JSONDecodeError): state={'version':1,'nodes':{},'regions':{},'last_daily_summary':''}
os.makedirs(outdir,mode=0o750,exist_ok=True)
for idx,region in enumerate(regions):
    group=[n for n in nodes if n['region']==region]
    if not group: continue
    group.sort(key=lambda n:(0 if n['priority']=='primary' else 1,n['name']))
    active=state.get('regions',{}).get(region,{}).get('current_node')
    if active not in [n['name'] for n in group]: active=group[0]['name']
    users=[]; outbounds=[]; routing=[]
    for n in group:
        k='NODE_'+re.sub('[^A-Za-z0-9]','_',n['name']).upper()+'_UUID'
        tagname=tag(n); users.append({'name':n['name'],'uuid':secrets[k]})
        stream={'network':n['transport'],'security':'tls' if n['tls'] else 'none'}
        if n['tls']: stream['tlsSettings']={'serverName':n['address'],'allowInsecure':False}
        if n['transport']=='ws': stream['wsSettings']={'path':n['path'] or '/'}
        elif n['transport']=='grpc': stream['grpcSettings']={'serviceName':n['path']}
        elif n['path']: stream['tcpSettings']={'header':{'type':'http','request':{'path':[n['path']]}}}
        outbounds.append({'tag':tagname,'protocol':'vless','settings':{'vnext':[{'address':n['address'],'port':n['port'],'users':[{'id':secrets[k],'encryption':'none'}]}]},'streamSettings':stream})
    active_tag=tag(next(n for n in group if n['name']==active))
    port=base+idx
    if port>65535: raise SystemExit('SOCKS base port exceeds TCP port range')
    cfg={'log':{'loglevel':'warning'},'inbounds':[{'tag':'socks-in','listen':f'127.0.0.{idx+1}','port':port,'protocol':'socks','settings':{'auth':'noauth','udp':True,'ip':'127.0.0.1'}}], 'outbounds':outbounds+[{'tag':'direct','protocol':'freedom'},{'tag':'block','protocol':'blackhole'}], 'routing':{'domainStrategy':'AsIs','rules':[{'type':'field','inboundTag':['socks-in'],'outboundTag':active_tag}]}}
    # Xray routing rule outboundTag is selected dynamically before service restart.
    atomic(os.path.join(outdir,slug(region)+'.json'),cfg)
print('Generated config(s) for '+', '.join(r for r in regions if any(n['region']==r for n in nodes)))
PY
    chmod 0640 "$GENERATED_DIR"/*.json
    chown root:"$XRAY_USER" "$GENERATED_DIR"/*.json
}


# =============================================================================
# systemd units, CLI installation, and log rotation
# =============================================================================
write_region_units() {
    local region slug unit service timer svc
    for region in "${REGIONS[@]}"; do
      slug=$(region_slug "$region")
      [[ -f "$GENERATED_DIR/$slug.json" ]] || continue
      unit="${SYSTEMD_DIR}/${UNIT_PREFIX}${slug}.service"
      service=$(cat <<UNIT
[Unit]
Description=Xray Node Controller — ${region}
Documentation=man:xray(1)
After=network-online.target
Wants=network-online.target
ConditionPathExists=${GENERATED_DIR}/${slug}.json

[Service]
Type=simple
User=${XRAY_USER}
Group=${XRAY_USER}
UMask=0027
ExecStart=${XRAY_BIN} run -config ${GENERATED_DIR}/${slug}.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3s
StartLimitIntervalSec=120
StartLimitBurst=8
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${LOG_DIR} ${DATA_DIR}
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LockPersonality=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
UNIT
)
      printf '%s\n' "$service" | write_if_changed "$unit" 0644 root root
    done
    timer="${SYSTEMD_DIR}/${UNIT_PREFIX}healthcheck.timer"
    cat <<UNIT | write_if_changed "$timer" 0644 root root
[Unit]
Description=Run Xray Node Controller health checks every five minutes
[Timer]
OnBootSec=90s
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true
Unit=${UNIT_PREFIX}healthcheck.service
[Install]
WantedBy=timers.target
UNIT
    svc="${SYSTEMD_DIR}/${UNIT_PREFIX}healthcheck.service"
    cat <<UNIT | write_if_changed "$svc" 0644 root root
[Unit]
Description=Xray Node Controller health check and failover evaluation
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
User=root
ExecStart=${CTL_PATH} healthcheck --internal
UNIT
    cat <<'ROTATE' | write_if_changed "$LOGROTATE_FILE" 0644 root root
/var/log/xray-node-ctrl/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 xraync xraync
    su xraync xraync
}
ROTATE
}

install_control_script() {
    local source=${BASH_SOURCE[0]}
    "$DRY_RUN" && { log_info "DRY-RUN install CLI at $CTL_PATH"; return; }
    install -d -m 0755 "$(dirname "$CTL_PATH")" "$INSTALL_DIR"
    install -o root -g root -m 0755 "$source" "$INSTALL_DIR/node-controller.sh"
    cat <<'WRAPPER' | write_if_changed "$CTL_PATH" 0755 root root
#!/usr/bin/env bash
exec /opt/xray-node-ctrl/node-controller.sh "$@"
WRAPPER
}

reload_systemd() {
    "$DRY_RUN" && { log_info 'DRY-RUN systemctl daemon-reload'; return; }
    systemctl daemon-reload
}

region_unit_action() {
    local action=$1 region slug
    for region in "${REGIONS[@]}"; do
      slug=$(region_slug "$region")
      [[ -f "$GENERATED_DIR/$slug.json" ]] || continue
      if "$DRY_RUN"; then printf '[DRY-RUN] systemctl %s %s%s.service\n' "$action" "$UNIT_PREFIX" "$slug"
      else systemctl "$action" "${UNIT_PREFIX}${slug}.service" || log_warn "systemctl $action برای $region ناموفق بود"; fi
    done
}

# =============================================================================
# Health sampling, persisted scoring, notifications and failover
# =============================================================================
health_engine() {
    local action=${1:-check}
    validate_config
    "$DRY_RUN" && { log_info "DRY-RUN health scoring and failover action=$action"; return; }
    python3 - "$NODES_FILE" "$ENV_FILE" "$STATE_FILE" "$LOG_FILE" "$action" <<'PY'
import json,os,re,socket,sys,time,statistics,urllib.parse,urllib.request,datetime
import yaml
np,ep,sp,logpath,action=sys.argv[1:]
def envread():
    d={}
    for line in open(ep,encoding='utf-8'):
        s=line.strip()
        if s and not s.startswith('#'):
            k,v=s.split('=',1); d[k]=v.strip().strip('"\'')
    return d
def save(obj):
    tmp=sp+'.tmp'
    with open(tmp,'w') as f: json.dump(obj,f,indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,0o640)
    import pwd,grp
    os.chown(tmp,pwd.getpwnam('xraync').pw_uid,grp.getgrnam('xraync').gr_gid)
    os.replace(tmp,sp)
def log(msg):
    with open(logpath,'a') as f: f.write(time.strftime('[%Y-%m-%dT%H:%M:%S%z] ')+msg+'\n')
def sample(node):
    vals=[]; failures=0
    for _ in range(3):
        start=time.monotonic()
        try:
            with socket.create_connection((node['address'],node['port']),timeout=3): pass
            vals.append((time.monotonic()-start)*1000)
        except (OSError,ValueError): failures+=1
    loss=failures*100/3
    latency=statistics.mean(vals) if vals else 3000.0
    jitter=(max(vals)-min(vals)) if len(vals)>1 else (0.0 if vals else 100.0)
    score=max(0.0,min(100.0,100-max(0,min(latency/10,50))-max(0,min(loss*2,40))-max(0,min(jitter/5,10))))
    return {'latency_ms':round(latency,2),'loss_pct':round(loss,2),'jitter_ms':round(jitter,2),'score':round(score,2),'success':score>=40,'checked_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
def key(n): return 'NODE_'+re.sub('[^A-Za-z0-9]','_',n['name']).upper()+'_UUID'
def notify(env,msg):
    token,chat=env.get('TELEGRAM_BOT_TOKEN',''),env.get('TELEGRAM_CHAT_ID','')
    if not token or not chat: return
    try:
        data=urllib.parse.urlencode({'chat_id':chat,'text':msg}).encode()
        req=urllib.request.Request('https://api.telegram.org/bot'+token+'/sendMessage',data=data)
        with urllib.request.urlopen(req,timeout=8) as r: r.read(2048)
    except Exception as e: log('WARN Telegram notification failed: '+type(e).__name__)
nodes=yaml.safe_load(open(np,encoding='utf-8'))['nodes']; env=envread()
try: state=json.load(open(sp))
except Exception: state={'version':1,'nodes':{},'regions':{},'last_daily_summary':''}
state.setdefault('nodes',{}); state.setdefault('regions',{})
results={}
for n in nodes:
    result=sample(n); prev=state['nodes'].get(n['name'],{})
    result['failures']=prev.get('failures',0)+1 if not result['success'] else 0
    result['successes']=prev.get('successes',0)+1 if result['success'] else 0
    state['nodes'][n['name']]=result; results[n['name']]=result
    log(f"HEALTH {n['name']} region={n['region']} score={result['score']} latency={result['latency_ms']}ms loss={result['loss_pct']}% jitter={result['jitter_ms']}ms")
for region in sorted({n['region'] for n in nodes}):
    group=[n for n in nodes if n['region']==region]
    primary=next((n for n in group if n['priority']=='primary'),group[0])
    reg=state['regions'].setdefault(region,{})
    current=reg.get('current_node')
    if current not in [n['name'] for n in group]: current=primary['name']
    current_node=next(n for n in group if n['name']==current)
    candidates=sorted(group,key=lambda n:(0 if n['priority']=='primary' else 1,-results[n['name']]['score']))
    target=candidates[0]
    switched=False
    # Require three bad consecutive probes before moving away from current.
    if results[current]['failures']>=3 and target['name']!=current and results[target['name']]['success']:
        reg['current_node']=target['name']; reg['switch_reason']='3 consecutive failures'; reg['switched_at']=datetime.datetime.now(datetime.timezone.utc).isoformat(); switched=True
    # Return to primary only after five successes and a 20-point advantage over
    # the currently selected node. This prevents flap during recovery.
    if primary['name']!=current and results[primary['name']]['successes']>=5 and results[primary['name']]['score']>=results[current]['score']+20:
        reg['current_node']=primary['name']; reg['switch_reason']='primary 5 successes + 20 score hysteresis'; reg['switched_at']=datetime.datetime.now(datetime.timezone.utc).isoformat(); switched=True
    if switched:
        old=current; current=reg['current_node']
        msg=f'Xray failover {region}: {old} -> {current} ({reg["switch_reason"]})'
        log('FAILOVER '+msg); notify(env,msg)
    else: reg['current_node']=current
    print(f'{region}: active={reg["current_node"]} score={results[reg["current_node"]]["score"]}')
# Produce one daily summary at/after 00:05 UTC, once per date.
now=datetime.datetime.now(datetime.timezone.utc); today=now.date().isoformat()
if now.hour==0 and now.minute<10 and state.get('last_daily_summary')!=today:
    lines=['Daily Xray health summary:']+[f'{n["region"]}/{n["name"]}: {results[n["name"]]["score"]} ({"up" if results[n["name"]]["success"] else "down"})' for n in nodes]
    notify(env,'\n'.join(lines)); state['last_daily_summary']=today; log('Sent daily health summary')
save(state)
PY
    # Regenerate routing with the newly selected nodes and restart changed groups.
    generate_configs
    region_unit_action restart
}


# =============================================================================
# Operator commands and system lifecycle
# =============================================================================
list_nodes() {
    if [[ ! -r "$NODES_FILE" ]]; then log_warn "فهرست موجود نیست: $NODES_FILE"; return 0; fi
    python3 - "$NODES_FILE" "$STATE_FILE" <<'PY'
import sys,json,yaml,os
nodes=yaml.safe_load(open(sys.argv[1],encoding='utf-8')).get('nodes',[])
try: state=json.load(open(sys.argv[2]))
except Exception: state={}
for n in nodes:
    active=state.get('regions',{}).get(n['region'],{}).get('current_node','(not selected)')
    health=state.get('nodes',{}).get(n['name'],{})
    print(f"{n['region']:6} {n['priority']:9} {n['name']:24} {n['address']}:{n['port']} active={'yes' if active==n['name'] else 'no'} score={health.get('score','n/a')}")
PY
}

status_all() {
    printf 'Xray Node Controller v%s\n' "$VERSION"
    printf 'Config: %s\nState:  %s\n' "$CONFIG_DIR" "$STATE_FILE"
    if command -v systemctl >/dev/null && [[ -d "$SYSTEMD_DIR" ]]; then
      local r slug unit
      for r in "${REGIONS[@]}"; do
        slug=$(region_slug "$r"); unit="${UNIT_PREFIX}${slug}.service"
        [[ -f "$GENERATED_DIR/$slug.json" ]] || continue
        if systemctl is-active --quiet "$unit"; then printf '  %-7s active\n' "$r"; else printf '  %-7s inactive\n' "$r"; fi
      done
      systemctl --no-pager --full status "${UNIT_PREFIX}healthcheck.timer" 2>/dev/null | sed -n '1,3p' || true
    fi
    if [[ -r "$STATE_FILE" ]]; then
      python3 - "$STATE_FILE" <<'PY'
import json,sys
try: s=json.load(open(sys.argv[1]))
except Exception as e: print('State unreadable:',e); raise SystemExit(0)
for region,rec in sorted(s.get('regions',{}).items()): print(f"  selected {region}: {rec.get('current_node','none')}")
PY
    fi
}

run_tests() {
    validate_config
    if [[ ! -x "$XRAY_BIN" ]]; then log_warn "Xray binary missing: $XRAY_BIN"; return 1; fi
    generate_configs
    local f
    shopt -s nullglob
    for f in "$GENERATED_DIR"/*.json; do
      log_info "Xray config test: $f"
      "$XRAY_BIN" run -test -config "$f"
    done
    shopt -u nullglob
    log_ok 'همهٔ کانفیگ‌ها معتبرند.'
}

install_project() {
    need_root; init_logging; lock_operation
    require_tools
    install_dependencies
    "$DRY_RUN" || require_tools
    create_user
    create_default_files
    install_xray_binary
    ensure_state
    validate_config
    generate_configs
    write_region_units
    install_control_script
    reload_systemd
    if ! "$DRY_RUN"; then
      systemctl enable --now "${UNIT_PREFIX}healthcheck.timer"
      region_unit_action enable
      region_unit_action restart
    fi
    install_summary
}

update_project() {
    need_root; init_logging; lock_operation; require_tools
    [[ -d "$CONFIG_DIR" ]] || { log_fail 'نصب موجود نیست؛ ابتدا install اجرا کنید.'; return 1; }
    install_xray_binary
    generate_configs
    write_region_units
    install_control_script
    reload_systemd
    region_unit_action restart
    log_ok 'به‌روزرسانی و بارگذاری سرویس‌ها تمام شد.'
}

reload_project() {
    need_root; init_logging; lock_operation
    generate_configs
    write_region_units
    reload_systemd
    region_unit_action restart
}

install_summary() {
    printf '\n============================================================\n'
    printf ' Xray Node Controller نصب شد (نسخه %s)\n' "$VERSION"
    printf ' تنظیمات: %s\n' "$CONFIG_DIR"
    printf ' Nodes:   %s\n' "$NODES_FILE"
    printf ' Secrets: %s (mode 600)\n' "$ENV_FILE"
    printf ' CLI:     %s\n' "$CTL_PATH"
    printf ' Ports:   127.0.0.x:%s + region index\n' "$PORT_BASE"
    printf ' Timer:   هر 5 دقیقه\n'
    printf ' Next: edit nodes.yaml and .env, then run xraync test\n'
    printf '============================================================\n'
}

uninstall_project() {
    need_root; init_logging
    confirm 'همهٔ سرویس‌ها، تنظیمات خصوصی و داده‌های xray-node-ctrl حذف شوند؟' || { log_info 'حذف لغو شد.'; return 0; }
    lock_operation
    if "$DRY_RUN"; then log_info 'DRY-RUN: stop/disable units and remove installed files'; return; fi
    systemctl disable --now "${UNIT_PREFIX}healthcheck.timer" 2>/dev/null || true
    local r slug
    for r in "${REGIONS[@]}"; do
      slug=$(region_slug "$r")
      systemctl disable --now "${UNIT_PREFIX}${slug}.service" 2>/dev/null || true
      rm -f "$SYSTEMD_DIR/${UNIT_PREFIX}${slug}.service"
    done
    rm -f "$SYSTEMD_DIR/${UNIT_PREFIX}healthcheck.timer" "$SYSTEMD_DIR/${UNIT_PREFIX}healthcheck.service" "$LOGROTATE_FILE" "$CTL_PATH"
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
    # Keep the dedicated system account by default; it may own files outside
    # these paths if the administrator intentionally reused it.
    log_ok 'کنترل‌گر و اطلاعاتش حذف شدند؛ کاربر سیستمی برای امکان بازیابی باقی ماند.'
}

net_doctor() {
    printf '=== Xray Node Controller network diagnostics ===\n'
    printf 'Date: '; date -Is
    printf 'Kernel: '; uname -srmo
    printf 'DNS resolver: '; sed -n '1,6p' /etc/resolv.conf 2>/dev/null | tr '\n' ' '; printf '\n'
    printf 'Routes:\n'; (ip route 2>/dev/null || route -n 2>/dev/null || true) | sed -n '1,12p'
    printf 'Listening controller ports:\n'
    if command -v ss >/dev/null 2>&1; then ss -lntp 2>/dev/null | awk 'NR==1 || /127\.0\.0\./' | sed -n '1,16p'; fi
    printf 'Service failures:\n'
    if command -v systemctl >/dev/null 2>&1; then systemctl --failed --no-legend 2>/dev/null | grep -F "$UNIT_PREFIX" || echo 'none'; fi
    printf 'No UUID or Telegram token is printed by this diagnostic.\n'
}

interactive_menu() {
    local choice
    while true; do
      cat <<'MENU'

Xray Node Controller menu
  1) Status
  2) List nodes
  3) Test configuration
  4) Health check + failover
  5) Restart services
  6) Reload/regenerate
  7) Network diagnostics
  8) Update Xray/controller
  9) Uninstall
  0) Exit
MENU
      read -r -p 'انتخاب: ' choice || return 0
      case "$choice" in
        1) status_all;; 2) list_nodes;; 3) run_tests;;
        4) need_root && health_engine check;;
        5) need_root && init_logging && lock_operation && region_unit_action restart;;
        6) reload_project;; 7) net_doctor;; 8) update_project;;
        9) uninstall_project;; 0) return 0;; *) log_warn 'انتخاب نامعتبر.';;
      esac
    done
}


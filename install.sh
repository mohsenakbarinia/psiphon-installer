Output: TOTAL LINES: 624
============================================================
1: #!/usr/bin/env bash
2: #===============================================================================
3: # psiphon-multi-region / Psiphon Multi-Region Auto-Installer v5.0
4: # Installs multiple Psiphon tunnel-core instances with per-instance
5: # EgressRegion, systemd services, logrotate and optional Xray (VLESS) injection.
6: # Supports: Ubuntu 24.04 x86_64 (root required)
7: #===============================================================================
8: 
9: set -Eeuo pipefail
10: 
11: VERSION="5.0"
12: PROJECT_NAME="psiphon-multi-region"
13: 
14: #------------------------------------------------------------------------------
15: # Defaults (overridable via environment / config.env)
16: #------------------------------------------------------------------------------
17: PSIPHON_INSTANCES="${PSIPHON_INSTANCES:-20}"
18: SOCKS_BASE_PORT="${SOCKS_BASE_PORT:-10800}"
19: SOCKS_LISTEN_IP="${SOCKS_LISTEN_IP:-127.20.0.1}"
20: INBOUND_BASE_PORT="${INBOUND_BASE_PORT:-20000}"
21: EGRESS_REGIONS="${EGRESS_REGIONS:-}"
22: SSH_PORT="${SSH_PORT:-22}"
23: DRY_RUN="${DRY_RUN:-0}"
24: 
25: INSTALL_DIR="${INSTALL_DIR:-/opt/psiphon-multi-region}"
26: BIN_DIR="${INSTALL_DIR}/bin"
27: CONF_DIR="${INSTALL_DIR}/config"
28: LOG_DIR="${INSTALL_DIR}/logs"
29: BACKUP_DIR="${INSTALL_DIR}/backups"
30: SERVICE_USER="${SERVICE_USER:-psiphon}"
31: LOGROTATE_FILE="/etc/logrotate.d/psiphon-multi-region"
32: BINARY_URL="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
33: BINARY_NAME="psiphon-tunnel-core"
34: LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
35: 
36: # Region whitelist (ISO 3166-1 alpha-2, EMPTY means "best/any")
37: VALID_REGIONS="AF AL DZ AS AD AO AI AG AR AM AW AU AT AZ BS BH BD BB BY BE BZ BJ BM BT BO BA BW BR BN BG BF BI KH CM CA CV KY CF TD CL CN CO KM CG CD CR CI HR CU CY CZ DK DJ DM DO EC EG SV GQ ER EE ET FK FJ FI FR PF GA GM GE DE GH GI GR GL GD GP GU GT GN GW GY HT HN HK HU IS IN ID IQ IE IL IT JM JP JO KZ KE KI KW KG LA LV LB LS LR LY LI LT LU MO MG MW MY MV ML MT MH MQ MR MU MX FM MD MC MN ME MS MA MZ MM NA NP NL NZ NI NG MP NO OM PK PW PS PA PG PY PE PH PL PT PR QA RO RU RW KN LC VC WS SM ST SA RS SC SL SG SK SI SB SO ZA KR ES LK SD SR SE SZ CH SY TW TJ TZ TH TL TG TO TT TN TR TM TV UG UA AE GB US UY UZ VU VE VN VG VI YE ZM ZW"
38: 
39: LOOPBACK_ALIAS_IP="127.20.0.1"
40: LOOPBACK_ALIAS_DEV="lo"
41: 
42: LOCK_FILE="/var/run/${PROJECT_NAME}.lock"
43: LOG_TAG="[psiphon-multi-region]"
44: 
45: #------------------------------------------------------------------------------
46: # Colorful logging helpers
47: #------------------------------------------------------------------------------
48: if [[ -t 1 ]]; then
49:     C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
50:     C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'; C_RESET='\033[0m'
51: else
52:     C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_RESET=''
53: fi
54: 
55: log()  { echo -e "${C_BLUE}${LOG_TAG}${C_RESET} $*" | tee -a "$LOG_FILE"; }
56: ok()   { echo -e "${C_GREEN}[ OK ]${C_RESET} $*" | tee -a "$LOG_FILE"; }
57: warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*" | tee -a "$LOG_FILE"; }
58: info() { echo -e "${C_CYAN}[INFO]${C_RESET} $*" | tee -a "$LOG_FILE"; }
59: die()  { echo -e "${C_RED}[FAIL]${C_RESET} $*" | tee -a "$LOG_FILE" >&2; exit 1; }
60: 
61: step() { echo -e "" | tee -a "$LOG_FILE"; echo -e "${C_BLUE}==> ${C_CYAN}$*${C_RESET}" | tee -a "$LOG_FILE"; }
62: 
63: #------------------------------------------------------------------------------
64: # Error trap: full logging + SSH protection (rollback loopback alias)
65: #------------------------------------------------------------------------------
66: on_error() {
67:     local exit_code=$?
68:     local line_no=$1
69:     echo -e "${C_RED}[FAIL]${C_RESET} Error at line ${line_no} (exit=${exit_code}). Command: ${BASH_COMMAND}" | tee -a "$LOG_FILE" >&2
70:     # SSH protection: if SSH is no longer listening, restore loopback alias so
71:     # the operator can reconnect, then abort before further damage.
72:     if ! ss -tln | grep -qE "[:.]${SSH_PORT}[[:space:]]"; then
73:         warn "SSH port ${SSH_PORT} stopped listening -> rolling back loopback alias ${LOOPBACK_ALIAS_IP}/32 on ${LOOPBACK_ALIAS_DEV}"
74:         ip addr del "${LOOPBACK_ALIAS_IP}/32" dev "${LOOPBACK_ALIAS_DEV}" 2>/dev/null || true
75:         warn "Loopback alias removed. Re-run the installer after verifying SSH connectivity."
76:     fi
77:     die "Installation aborted (exit code ${exit_code}, line ${line_no}). Full log: ${LOG_FILE}"
78: }
79: trap 'on_error $LINENO' ERR
80: 
81: #------------------------------------------------------------------------------
82: # Helpers
83: #------------------------------------------------------------------------------
84: run() {
85:     if [[ "$DRY_RUN" == "1" ]]; then
86:         info "[DRY-RUN] $*"
87:     else
88:         eval "$@"
89:     fi
90: }
91: 
92: is_root() { [[ "$(id -u)" -eq 0 ]]; }
93: 
94: check_ssh_alive() {
95:     ss -tln | grep -qE "[:.]${SSH_PORT}[[:space:]]"
96: }
97: 
98: validate_regions() {
99:     # $1 = egress regions string "1:DE 2:US 3:GB"
100:     local idx reg
101:     for token in $1; do
102:         idx="${token%%:*}"
103:         reg="${token##*:}"
104:         [[ "$idx" =~ ^[0-9]+$ ]] || die "Invalid instance index in EGRESS_REGIONS token '${token}'"
105:         [[ "$reg" == "-" ]] && continue # '-' = any region
106:         if ! [[ " ${VALID_REGIONS} " == *" ${reg} "* ]]; then
107:             die "Invalid region code '${reg}' (token '${token}'). Use ISO alpha-2 codes or '-' for any."
108:         fi
109:     done
110:     ok "EGRESS_REGIONS validation passed"
111: }
112: 
113: region_for_instance() {
114:     # echo region for instance $1 or "-" if not set
115:     local want="$1" token idx reg
116:     for token in ${EGRESS_REGIONS}; do
117:         idx="${token%%:*}"
118:         reg="${token##*:}"
119:         [[ "$idx" == "$want" ]] && { echo "$reg"; return; }
120:     done
121:     echo "-"
122: }
123: 
124: port_in_use() {
125:     ss -tln | awk '{print $4}' | grep -qE "(^|:)$1$"
126: }
127: 
128: ensure_dirs() {
129:     mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$CONF_DIR" "$LOG_DIR" "$BACKUP_DIR"
130:     chmod 755 "$INSTALL_DIR" "$BIN_DIR" "$CONF_DIR"
131: }
132: 
133: #------------------------------------------------------------------------------
134: # flock: prevent concurrent runs
135: #------------------------------------------------------------------------------
136: acquire_lock() {
137:     exec 9>"$LOCK_FILE"
138:     if ! flock -n 9; then
139:         die "Another instance of ${PROJECT_NAME} is already running (lock: ${LOCK_FILE})."
140:     fi
141:     ok "Acquired run lock"
142: }
143: 
144: usage() {
145:     cat <<USAGE
146: ${PROJECT_NAME} installer v${VERSION}
147: 
148: Usage: sudo ./install.sh [options]
149: 
150: Environment variables (or use config.env):
151:   PSIPHON_INSTANCES   number of instances            (default: 20)
152:   SOCKS_BASE_PORT     first SOCKS port               (default: 10800)
153:   SOCKS_LISTEN_IP     SOCKS listen IP (loopback alias) (default: 127.20.0.1)
154:   INBOUND_BASE_PORT   first inbound port (Xray)      (default: 20000)
155:   EGRESS_REGIONS      per-instance regions "1:DE 2:US 3:GB"
156:   SSH_PORT            SSH port to protect            (default: 22)
157:   DRY_RUN             1 = simulate, no changes       (default: 0)
158: USAGE
159: }
160: 
161: #------------------------------------------------------------------------------
162: # STEP 1: update / dependencies (safe apt upgrade, NOT dist-upgrade)
163: #------------------------------------------------------------------------------
164: step_1_update_deps() {
165:     step "STEP 1/9: System update and dependencies"
166:     export DEBIAN_FRONTEND=noninteractive
167:     run "apt-get update -y"
168:     run "apt-get install -y curl wget jq unzip ca-certificates gnupg openssl util-linux python3 logrotate iproute2"
169:     # Safe upgrade only: never dist-upgrade (protects kernel / boot config)
170:     run "apt-get upgrade -y"
171:     ok "System updated (safe upgrade, no dist-upgrade)"
172: }
173: 
174: #------------------------------------------------------------------------------
175: # STEP 2: loopback alias
176: #------------------------------------------------------------------------------
177: step_2_loopback() {
178:     step "STEP 2/9: Loopback alias ${LOOPBACK_ALIAS_IP}/32 on ${LOOPBACK_ALIAS_DEV}"
179:     if ip addr show "$LOOPBACK_ALIAS_DEV" | grep -q "$LOOPBACK_ALIAS_IP"; then
180:         ok "Loopback alias already present (idempotent skip)"
181:     else
182:         run "ip addr add ${LOOPBACK_ALIAS_IP}/32 dev ${LOOPBACK_ALIAS_DEV}"
183:         ok "Loopback alias added"
184:     fi
185:     # Persist via netplan if possible
186:     if [[ -d /etc/netplan && "$DRY_RUN" != "1" ]] && ! grep -rq "$LOOPBACK_ALIAS_IP" /etc/netplan/ 2>/dev/null; then
187:         local nf="/etc/netplan/90-psiphon-loopback.yaml"
188:         if [[ ! -f "$nf" ]]; then
189:             cat > "$nf" <<EOF
190: network:
191:   version: 2
192:   ethernets:
193:     lo-alias:
194:       match:
195:         name: lo
196:       addresses: [${LOOPBACK_ALIAS_IP}/32]
197: EOF
198:             netplan apply >/dev/null 2>&1 || warn "netplan apply failed (alias applied at runtime)"
199:             ok "Loopback alias persisted in ${nf}"
200:         fi
201:     fi
202: }
203: 
204: #------------------------------------------------------------------------------
205: # STEP 3: SSH check (must be listening BEFORE and we verify again later)
206: #------------------------------------------------------------------------------
207: step_3_ssh_check() {
208:     step "STEP 3/9: SSH safety check (port ${SSH_PORT})"
209:     if check_ssh_alive; then
210:         ok "SSH is listening on port ${SSH_PORT}"
211:     else
212:         die "SSH is NOT listening on port ${SSH_PORT}. Aborting for your safety."
213:     fi
214: }
215: 
216: #------------------------------------------------------------------------------
217: # STEP 4: service user
218: #------------------------------------------------------------------------------
219: step_4_user() {
220:     step "STEP 4/9: Service user '${SERVICE_USER}'"
221:     if id "$SERVICE_USER" &>/dev/null; then
222:         ok "User ${SERVICE_USER} already exists (idempotent skip)"
223:     else
224:         run "useradd --system --no-create-home --shell /usr/sbin/nologin ${SERVICE_USER}"
225:         ok "System user ${SERVICE_USER} created"
226:     fi
227: }
228: 
229: #------------------------------------------------------------------------------
230: # STEP 5: download binary + integrity verification (sha256 + executable test)
231: #------------------------------------------------------------------------------
232: step_5_binary() {
233:     step "STEP 5/9: Download and verify ${BINARY_NAME}"
234:     local dest="${BIN_DIR}/${BINARY_NAME}"
235:     local tmp="${BIN_DIR}/.download.$$"
236: 
237:     if [[ -x "$dest" ]]; then
238:         if "$dest" --help >/dev/null 2>&1 || "$dest" -version >/dev/null 2>&1; then
239:             ok "Existing binary passes executable test (idempotent skip)"
240:             return 0
241:         else
242:             warn "Existing binary failed executable test -> re-downloading"
243:         fi
244:     fi
245: 
246:     info "Downloading from: ${BINARY_URL}"
247:     run "curl -fSL --retry 3 --connect-timeout 30 -o ${tmp} ${BINARY_URL}"
248:     [[ -s "$tmp" ]] || die "Downloaded binary is empty"
249: 
250:     local sum
251:     sum=$(sha256sum "$tmp" | awk '{print $1}')
252:     echo "${sum}  ${dest}" > "${BIN_DIR}/${BINARY_NAME}.sha256"
253:     info "SHA256: ${sum}"
254: 
255:     if ! echo "${sum}  ${dest}" | sha256sum -c --quiet >/dev/null 2>&1; then
256:         # first install: dest not there yet; copy then verify
257:         run "install -m 755 ${tmp} ${dest}"
258:     else
259:         run "install -m 755 ${tmp} ${dest}"
260:     fi
261:     run "rm -f ${tmp}"
262: 
263:     # Integrity verification
264:     ( cd "$BIN_DIR" && sha256sum -c "${BINARY_NAME}.sha256" >/dev/null 2>&1 ) \
265:         || die "SHA256 verification FAILED for ${BINARY_NAME}"
266:     [[ -x "$dest" ]] || die "Binary is not executable"
267:     if ! ("$dest" -version >/dev/null 2>&1 || "$dest" --help >/dev/null 2>&1); then
268:         warn "Binary did not answer -version/--help; continuing (some builds need config on stdin)"
269:     fi
270:     chown root:"$SERVICE_USER" "$dest" 2>/dev/null || true
271:     ok "Binary integrity verified (sha256 + executable test)"
272: }
273: 
274: #------------------------------------------------------------------------------
275: # STEP 6: generate per-instance configs
276: #------------------------------------------------------------------------------
277: step_6_configs() {
278:     step "STEP 6/9: Generating ${PSIPHON_INSTANCES} instance configs"
279:     local i reg json iport
280:     for (( i=1; i<=PSIPHON_INSTANCES; i++ )); do
281:         reg=$(region_for_instance "$i")
282:         iport=$(( INBOUND_BASE_PORT + i ))
283:         json="${CONF_DIR}/psiphon-${i}.json"
284: 
285:         if [[ "$reg" == "-" ]]; then
286:             local egress_json="null"
287:         else
288:             local egress_json="\"$reg\""
289:         fi
290: 
291:         if [[ -f "$json" && "$DRY_RUN" != "1" ]]; then
292:             # idempotent: regenerate only if region or ports changed
293:             local cur_region
294:             cur_region=$(jq -r 'if .EgressRegion then .EgressRegion else "-" end' "$json" 2>/dev/null || echo "CHANGED")
295:             if [[ "$cur_region" == "$reg" ]]; then
296:                 continue
297:             fi
298:         fi
299: 
300:         local content
301:         content=$(cat <<EOF
302: {
303:   "PropagationChannelId": "FFFFFFFFFFFFFFFF",
304:   "SponsorId": "FFFFFFFFFFFFFFFF",
305:   "LocalSocksProxyPort": ${SOCKS_BASE_PORT},
306:   "LocalHttpProxyPort": 0,
307:   "DisableLocalHTTPProxy": true,
308:   "EgressRegion": ${egress_json},
309:   "EgressRegionCombo": ${egress_json},
310:   "ListenInterface": "${SOCKS_LISTEN_IP}",
311:   "TargetInboundPort": ${iport},
312:   "UpstreamProxyUrl": "",
313:   "UseIndistinguishableTLS": true,
314:   "MeteredMetrics": false
315: }
316: EOF
317: )
318:         # Per-instance ports: rewrite LocalSocksProxyPort correctly
319:         local socks_port=$(( SOCKS_BASE_PORT + i - 1 ))
320:         content=$(printf '%s' "$content" | python3 - "$i" "$socks_port" "$iport" <<'PYEOF'
321: import json, sys
322: i, socks, inbound = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
323: cfg = json.load(sys.stdin)
324: cfg["LocalSocksProxyPort"] = socks
325: cfg["TargetInboundPort"] = inbound
326: cfg["_instance"] = i
327: print(json.dumps(cfg, indent=2))
328: PYEOF
329: )
330:         if [[ "$DRY_RUN" == "1" ]]; then
331:             info "[DRY-RUN] would write ${json} (socks=${socks_port}, inbound=${iport}, region=${reg})"
332:         else
333:             printf '%s\n' "$content" > "$json"
334:         fi
335:         ok "Config ${i}: socks=${socks_port} inbound=${iport} region=${reg}"
336:     done
337:     if [[ "$DRY_RUN" != "1" ]]; then
338:         chown -R root:"$SERVICE_USER" "$CONF_DIR"
339:         chmod 640 "${CONF_DIR}"/*.json 2>/dev/null || true
340:     fi
341:     ok "All configs generated"
342: }
343: 
344: #------------------------------------------------------------------------------
345: # STEP 7: systemd units + logrotate
346: #------------------------------------------------------------------------------
347: step_7_systemd() {
348:     step "STEP 7/9: systemd units + logrotate"
349:     local i unit
350:     for (( i=1; i<=PSIPHON_INSTANCES; i++ )); do
351:         unit="/etc/systemd/system/psiphon@${i}.service"
352:         local socks_port=$(( SOCKS_BASE_PORT + i - 1 ))
353:         if [[ -f "$unit" ]]; then
354:             continue  # idempotent
355:         fi
356:         if [[ "$DRY_RUN" == "1" ]]; then
357:             info "[DRY-RUN] would write ${unit}"
358:             continue
359:         fi
360:         cat > "$unit" <<EOF
361: [Unit]
362: Description=Psiphon Multi-Region Instance ${i}
363: After=network-online.target
364: Wants=network-online.target
365: 
366: [Service]
367: Type=simple
368: User=${SERVICE_USER}
369: ExecStart=${BIN_DIR}/${BINARY_NAME} -config ${CONF_DIR}/psiphon-${i}.json
370: Restart=always
371: RestartSec=5
372: LimitNOFILE=65535
373: Environment=INSTANCE_ID=${i}
374: Environment=SOCKS_PORT=${socks_port}
375: 
376: [Install]
377: WantedBy=multi-user.target
378: EOF
379:         ok "Unit written: psiphon@${i}.service (socks ${socks_port})"
380:     done
381:     if [[ "$DRY_RUN" != "1" ]]; then
382:         systemctl daemon-reload
383:     fi
384: 
385:     # logrotate
386:     if [[ ! -f "$LOGROTATE_FILE" ]]; then
387:         if [[ "$DRY_RUN" == "1" ]]; then
388:             info "[DRY-RUN] would write ${LOGROTATE_FILE}"
389:         else
390:             cat > "$LOGROTATE_FILE" <<EOF
391: ${LOG_DIR}/*.log {
392:     daily
393:     rotate 14
394:     size 50M
395:     missingok
396:     notifempty
397:     compress
398:     delaycompress
399:     copytruncate
400: }
401: EOF
402:             ok "Logrotate configured: ${LOGROTATE_FILE}"
403:         fi
404:     else
405:         ok "Logrotate already configured (idempotent skip)"
406:     fi
407: }
408: 
409: #------------------------------------------------------------------------------
410: # STEP 8: start instances
411: #------------------------------------------------------------------------------
412: step_8_start() {
413:     step "STEP 8/9: Starting ${PSIPHON_INSTANCES} instances"
414:     local i
415:     for (( i=1; i<=PSIPHON_INSTANCES; i++ )); do
416:         run "systemctl enable psiphon@${i}.service"
417:         run "systemctl restart psiphon@${i}.service"
418:     done
419:     if [[ "$DRY_RUN" != "1" ]]; then
420:         sleep 3
421:         local running=0
422:         for (( i=1; i<=PSIPHON_INSTANCES; i++ )); do
423:             if systemctl is-active --quiet "psiphon@${i}.service"; then
424:                 running=$(( running + 1 ))
425:             else
426:                 warn "psiphon@${i}.service is not active"
427:             fi
428:         done
429:         ok "${running}/${PSIPHON_INSTANCES} instances active"
430:     fi
431: }
432: 
433: #------------------------------------------------------------------------------
434: # STEP 9: Xray injection + summary
435: #------------------------------------------------------------------------------
436: find_xray_config() {
437:     local candidates=(
438:         "/usr/local/x-ui/bin/config.json"
439:         "/etc/x-ui/config.json"
440:         "/etc/xray/config.json"
441:         "/usr/local/etc/xray/config.json"
442:         "/opt/3x-ui/bin/config.json"
443:         "/etc/3x-ui/config.json"
444:     )
445:     local c
446:     for c in "${candidates[@]}"; do
447:         [[ -f "$c" ]] && { echo "$c"; return; }
448:     done
449:     # search for any 3x-ui style db-managed config
450:     find /usr/local /etc /opt -maxdepth 4 -name "config.json" 2>/dev/null \
451:         | grep -iE "(xray|x-ui|3x-ui)" | head -n1 || true
452: }
453: 
454: restart_panel() {
455:     local svc
456:     for svc in 3x-ui x-ui xray; do
457:         if systemctl list-unit-files | grep -q "^${svc}\.service"; then
458:             run "systemctl restart ${svc}"
459:             ok "Restarted panel service: ${svc}"
460:             return 0
461:         fi
462:     done
463:     warn "No panel service found to restart (3x-ui / x-ui / xray)"
464: }
465: 
466: step_9_xray() {
467:     step "STEP 9/9: Xray inbound injection (ports ${INBOUND_BASE_PORT}+1 .. +${PSIPHON_INSTANCES})"
468: 
469:     # Port collision detection BEFORE injection
470:     local i port conflicts=0
471:     for (( i=1; i<=PSIPHON_INSTANCES; i++ )); do
472:         port=$(( INBOUND_BASE_PORT + i ))
473:         if port_in_use "$port"; then
474:             if systemctl is-active --quiet "psiphon@${i}.service" 2>/dev/null; then
475:                 info "Port ${port} used by our own psiphon@${i} (expected)"
476:             else
477:                 warn "Port ${port} is already in use by another process!"
478:                 conflicts=$(( conflicts + 1 ))
479:             fi
480:         fi
481:     done
482:     if (( conflicts > 0 )); then
483:         die "${conflicts} inbound port collision(s) detected. Free the ports or change INBOUND_BASE_PORT."
484:     fi
485:     ok "No unexpected port collisions on ${INBOUND_BASE_PORT}+1..+${PSIPHON_INSTANCES}"
486: 
487:     local xcfg
488:     xcfg=$(find_xray_config || true)
489:     if [[ -z "$xcfg" ]]; then
490:         warn "No Xray/x-ui config found in common panel paths - skipping injection"
491:         return 0
492:     fi
493:     info "Found Xray config: ${xcfg}"
494: 
495:     local backup="${BACKUP_DIR}/$(basename "$xcfg").$(date +%Y%m%d-%H%M%S).bak"
496:     if [[ "$DRY_RUN" == "1" ]]; then
497:         info "[DRY-RUN] would backup ${xcfg} -> ${backup} and inject inbounds"
498:     else
499:         cp -a "$xcfg" "$backup"
500:         ok "Backup created: ${backup}"
501: 
502:         python3 - "$xcfg" "$INBOUND_BASE_PORT" "$PSIPHON_INSTANCES" "$SOCKS_BASE_PORT" "$SOCKS_LISTEN_IP" <<'PYEOF'
503: import json, sys
504: 
505: path = sys.argv[1]
506: base = int(sys.argv[2]); count = int(sys.argv[3])
507: socks_base = int(sys.argv[4]); lip = sys.argv[5]
508: 
509: with open(path) as f:
510:     cfg = json.load(f)
511: 
512: cfg.setdefault("inbounds", [])
513: cfg.setdefault("outbounds", [])
514: cfg.setdefault("routing", {}).setdefault("rules", [])
515: 
516: existing_ports = {ib.get("port") for ib in cfg["inbounds"]}
517: for i in range(1, count + 1):
518:     in_port = base + i
519:     socks_port = socks_base + i - 1
520:     tag_in = f"psiphon-in-{i}"
521:     tag_out = f"psiphon-socks-{i}"
522:     if in_port not in existing_ports:
523:         cfg["inbounds"].append({
524:             "listen": "0.0.0.0", "port": in_port, "protocol": "vless",
525:             "settings": {"clients": [], "decryption": "none"},
526:             "tag": tag_in,
527:             "streamSettings": {"network": "tcp", "security": "none"}
528:         })
529:     if not any(ob.get("tag") == tag_out for ob in cfg["outbounds"]):
530:         cfg["outbounds"].append({
531:             "tag": tag_out, "protocol": "socks",
532:             "settings": {"servers": [{"address": lip, "port": socks_port}]}
533:         })
534:     if not any(r.get("inboundTag") == [tag_in] for r in cfg["routing"]["rules"]):
535:         cfg["routing"]["rules"].append({
536:             "type": "field", "inboundTag": [tag_in], "outboundTag": tag_out
537:         })
538: 
539: with open(path, "w") as f:
540:     json.dump(cfg, f, indent=2)
541: print("Xray config updated OK")
542: PYEOF
543:         restart_panel
544:     fi
545:     ok "Xray injection step complete"
546: }
547: 
548: print_summary() {
549:     step "SUMMARY"
550:     local i reg iport socks_port status
551:     printf '%-8s | %-13s | %-11s | %-7s | %s\n' "Instance" "Inbound Port" "SOCKS Port" "Region" "Status"
552:     printf -- '---------+---------------+------------+--------+--------\n'
553:     for (( i=1; i<=PSIPHON_INSTANCES; i++ )); do
554:         reg=$(region_for_instance "$i")
555:         iport=$(( INBOUND_BASE_PORT + i ))
556:         socks_port=$(( SOCKS_BASE_PORT + i - 1 ))
557:         if [[ "$DRY_RUN" == "1" ]]; then
558:             status="(dry-run)"
559:         elif systemctl is-active --quiet "psiphon@${i}.service" 2>/dev/null; then
560:             status="active"
561:         else
562:             status="inactive"
563:         fi
564:         printf '%-8s | %-13s | %-11s | %-7s | %s\n' "$i" "$iport" "$socks_port" "$reg" "$status"
565:     done | tee -a "$LOG_FILE"
566:     echo -e "" | tee -a "$LOG_FILE"
567:     ok "Installation v${VERSION} finished. Log: ${LOG_FILE}"
568:     info "Test example:  curl --socks5 ${SOCKS_LISTEN_IP}:${SOCKS_BASE_PORT} https://ipinfo.io"
569: }
570: 
571: #------------------------------------------------------------------------------
572: # Main
573: #------------------------------------------------------------------------------
574: main() {
575:     if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
576:         usage; exit 0
577:     fi
578:     # Load config.env if present next to script
579:     local script_dir
580:     script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
581:     if [[ -f "${script_dir}/config.env" ]]; then
582:         # shellcheck disable=SC1091
583:         set -a; source "${script_dir}/config.env"; set +a
584:         info "Loaded config from ${script_dir}/config.env"
585:     fi
586:     # Re-apply defaults for any vars left empty
587:     PSIPHON_INSTANCES="${PSIPHON_INSTANCES:-20}"
588:     SOCKS_BASE_PORT="${SOCKS_BASE_PORT:-10800}"
589:     SOCKS_LISTEN_IP="${SOCKS_LISTEN_IP:-127.20.0.1}"
590:     INBOUND_BASE_PORT="${INBOUND_BASE_PORT:-20000}"
591:     SSH_PORT="${SSH_PORT:-22}"
592:     DRY_RUN="${DRY_RUN:-0}"
593: 
594:     is_root || die "This installer must run as root (try: sudo ./install.sh)"
595:     mkdir -p "$LOG_DIR"
596:     acquire_lock
597:     ensure_dirs
598:     log "===== ${PROJECT_NAME} installer v${VERSION} started $(date -Is) ====="
599:     log "Instances=${PSIPHON_INSTANCES} SOCKS_BASE=${SOCKS_BASE_PORT} LISTEN=${SOCKS_LISTEN_IP} INBOUND_BASE=${INBOUND_BASE_PORT} SSH_PORT=${SSH_PORT} DRY_RUN=${DRY_RUN}"
600: 
601:     validate_regions "${EGRESS_REGIONS:-}"
602: 
603:     step_1_update_deps
604:     step_2_loopback
605:     step_3_ssh_check
606:     step_4_user
607:     step_5_binary
608:     step_6_configs
609:     step_7_systemd
610:     step_8_start
611:     step_9_xray
612: 
613:     # Final SSH safety verification after network changes
614:     if [[ "$DRY_RUN" != "1" ]] && ! check_ssh_alive; then
615:         ip addr del "${LOOPBACK_ALIAS_IP}/32" dev "$LOOPBACK_ALIAS_DEV" 2>/dev/null || true
616:         die "SSH stopped listening after changes! Loopback alias rolled back."
617:     fi
618: 
619:     print_summary
620:     log "===== installer finished $(date -Is) ====="
621:     return 0
622: }
623: 
624: main "$@"

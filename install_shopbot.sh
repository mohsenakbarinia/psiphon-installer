#!/usr/bin/env bash
# TGShop: single-file installer. Ubuntu 22.04+/Debian 12+, systemd, Python 3.10+.
# No secrets belong in this file or in Git. Review before executing as root.
set -Eeuo pipefail
umask 027
APP=/opt/tgshop
DATA=/var/lib/tgshop
CONF=/etc/tgshop
if [[ ${EUID} -ne 0 ]]; then echo 'Run with sudo bash install_shopbot.sh'; exit 1; fi
command -v apt-get >/dev/null || { echo 'Only Debian/Ubuntu with apt are supported.'; exit 1; }
[[ -d /run/systemd/system ]] || { echo 'A running systemd is required.'; exit 1; }
if [[ -e "$APP/app.py" ]]; then
  echo 'Existing installation found. This installer refuses to overwrite it. Back up and use a reviewed migration for upgrades.'
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-venv ca-certificates tzdata
python3 -c 'import sys; assert sys.version_info >= (3,10), "Python 3.10+ required"'
id tgshop >/dev/null 2>&1 || useradd --system --home-dir "$DATA" --shell /usr/sbin/nologin tgshop
install -d -m 0755 "$APP"
install -d -m 0750 -o tgshop -g tgshop "$DATA" "$DATA/backups"
install -d -m 0750 -o root -g tgshop "$CONF"
python3 -m venv "$APP/venv"
"$APP/venv/bin/pip" install 'requests==2.32.3' 'openpyxl==3.1.5' 'cryptography==44.0.2'
if [[ ! -f "$CONF/config.json" ]]; then
  read -rsp 'Main bot token (hidden): ' MAIN_TOKEN </dev/tty; echo
  read -rp 'Your numeric Telegram user ID: ' OWNER_ID </dev/tty
  [[ "$MAIN_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { echo 'Invalid token format'; exit 1; }
  [[ "$OWNER_ID" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid owner ID'; exit 1; }
  export MAIN_TOKEN OWNER_ID
  "$APP/venv/bin/python" - "$CONF/config.json" <<'CONFIGPY'
import os,json,sys
from cryptography.fernet import Fernet
import requests
r=requests.post('https://api.telegram.org/bot'+os.environ['MAIN_TOKEN']+'/getMe',timeout=20).json()
if not r.get('ok'): raise SystemExit('Main token rejected by Telegram')
c={'main_token':os.environ['MAIN_TOKEN'],'owner_id':int(os.environ['OWNER_ID']),
   'key':Fernet.generate_key().decode(),'data_dir':'/var/lib/tgshop',
   'backup_dir':'/var/lib/tgshop/backups','backup_interval':1800,'backup_keep':48}
with open(sys.argv[1],'x') as f: json.dump(c,f)
CONFIGPY
  unset MAIN_TOKEN OWNER_ID
fi
chown root:tgshop "$CONF/config.json"
chmod 0640 "$CONF/config.json"
cat > "$APP/app.py" <<'PYAPP'
#!/usr/bin/env python3
"""TGShop beta. Single-process SQLite ledger, tenant scoped, long polling.
No external card terminal integration. All payments are operator attestations.
"""
import os,sys,json,time,uuid,sqlite3,threading,logging,tempfile,hashlib,io,zipfile,argparse
from datetime import datetime
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from zoneinfo import ZoneInfo
from pathlib import Path
from contextlib import contextmanager
import requests
from cryptography.fernet import Fernet
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment

logging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s')
LOG=logging.getLogger('tgshop')
CFG=None; DB=None; CRYPT=None
TZ=ZoneInfo('Asia/Tehran')
MAX_MONEY=10**14  # Keep individual financial values within Excel's exact numeric precision.
DIGITS=str.maketrans('۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩','01234567890123456789')
DDL='''
CREATE TABLE IF NOT EXISTS stores(
 id INTEGER PRIMARY KEY AUTOINCREMENT, bot_id INTEGER UNIQUE NOT NULL,
 token TEXT NOT NULL, owner INTEGER NOT NULL, name TEXT NOT NULL,
 unit TEXT NOT NULL DEFAULT 'toman', group_id INTEGER,
 active INTEGER NOT NULL DEFAULT 1, expires INTEGER NOT NULL,
 created INTEGER NOT NULL, next_report INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS products(
 id INTEGER PRIMARY KEY AUTOINCREMENT, store INTEGER NOT NULL,
 name TEXT NOT NULL, kind TEXT NOT NULL, cash INTEGER NOT NULL,
 pct TEXT NOT NULL, credit INTEGER NOT NULL, active INTEGER NOT NULL DEFAULT 1);
CREATE TABLE IF NOT EXISTS customers(
 id INTEGER PRIMARY KEY AUTOINCREMENT, store INTEGER NOT NULL,
 code INTEGER NOT NULL, name TEXT NOT NULL, phone TEXT NOT NULL,
 rate TEXT NOT NULL, cap_mode TEXT NOT NULL, cap INTEGER NOT NULL DEFAULT 0,
 telegram INTEGER, UNIQUE(store,code), UNIQUE(store,phone), UNIQUE(store,telegram));
CREATE TABLE IF NOT EXISTS ledger(
 id INTEGER PRIMARY KEY AUTOINCREMENT, store INTEGER NOT NULL, customer INTEGER,
 kind TEXT NOT NULL, delta INTEGER NOT NULL, total INTEGER NOT NULL,
 detail TEXT NOT NULL, created INTEGER NOT NULL, actor INTEGER NOT NULL,
 operation TEXT UNIQUE NOT NULL, reverses INTEGER UNIQUE);
CREATE TABLE IF NOT EXISTS sessions(
 scope INTEGER NOT NULL, user INTEGER NOT NULL, data TEXT NOT NULL,
 updated INTEGER NOT NULL, PRIMARY KEY(scope,user));
CREATE TABLE IF NOT EXISTS offsets(scope INTEGER PRIMARY KEY, value INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS outbox(
 id INTEGER PRIMARY KEY AUTOINCREMENT, store INTEGER NOT NULL, chat INTEGER NOT NULL,
 kind TEXT NOT NULL, payload TEXT NOT NULL, dedup TEXT UNIQUE NOT NULL,
 status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
 next_try INTEGER NOT NULL DEFAULT 0, part INTEGER NOT NULL DEFAULT 0,
 text_done INTEGER NOT NULL DEFAULT 0, file_done INTEGER NOT NULL DEFAULT 0,
 error TEXT, created INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS audit(
 id INTEGER PRIMARY KEY AUTOINCREMENT, store INTEGER, actor INTEGER,
 action TEXT NOT NULL, data TEXT NOT NULL, created INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS operations(operation TEXT PRIMARY KEY,created INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS plans(
 id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,days INTEGER NOT NULL,
 price TEXT NOT NULL,active INTEGER NOT NULL DEFAULT 1);
CREATE TABLE IF NOT EXISTS subscription_requests(
 id INTEGER PRIMARY KEY AUTOINCREMENT,store INTEGER NOT NULL,days INTEGER NOT NULL,
 quote TEXT,status TEXT NOT NULL,created INTEGER NOT NULL,actor INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS ledger_account ON ledger(store,customer,id);
CREATE INDEX IF NOT EXISTS products_store ON products(store,active);
CREATE INDEX IF NOT EXISTS outbox_pending ON outbox(status,next_try);
CREATE TRIGGER IF NOT EXISTS audit_no_update BEFORE UPDATE ON audit
 BEGIN SELECT RAISE(ABORT,'Immutable audit'); END;
CREATE TRIGGER IF NOT EXISTS audit_no_delete BEFORE DELETE ON audit
 BEGIN SELECT RAISE(ABORT,'Immutable audit'); END;
CREATE TRIGGER IF NOT EXISTS ledger_no_update BEFORE UPDATE ON ledger
 BEGIN SELECT RAISE(ABORT,'Immutable ledger'); END;
CREATE TRIGGER IF NOT EXISTS ledger_no_delete BEFORE DELETE ON ledger
 BEGIN SELECT RAISE(ABORT,'Immutable ledger'); END;
'''

def now(): return int(time.time())
def stamp(t=None): return datetime.fromtimestamp(t or now(),TZ).strftime('%Y-%m-%d %H:%M:%S')+' تهران'
def dumps(v): return json.dumps(v,ensure_ascii=False,separators=(',',':'))
def rows(c,sql,args=()): return [dict(x) for x in c.execute(sql,args).fetchall()]
def one(c,sql,args=()):
    r=c.execute(sql,args).fetchone(); return dict(r) if r else None
@contextmanager
def conn(write=False):
    c=sqlite3.connect(DB,timeout=30,isolation_level=None)
    c.row_factory=sqlite3.Row
    c.execute('PRAGMA foreign_keys=ON'); c.execute('PRAGMA synchronous=FULL')
    try:
        c.execute('BEGIN IMMEDIATE' if write else 'BEGIN')
        yield c
        c.execute('COMMIT')
    except Exception:
        c.execute('ROLLBACK'); raise
    finally: c.close()
def init(config):
    global CFG,DB,CRYPT
    CFG=config; CRYPT=Fernet(CFG['key'].encode())
    Path(CFG['data_dir']).mkdir(parents=True,exist_ok=True)
    DB=str(Path(CFG['data_dir'])/'shop.db')
    c=sqlite3.connect(DB); c.execute('PRAGMA journal_mode=WAL'); c.executescript(DDL)
    c.close()
def store(sid,c=None):
    if c is not None: return one(c,'SELECT * FROM stores WHERE id=?',(sid,))
    with conn() as q: return store(sid,q)
def claim_operation(c,op):
    if one(c,'SELECT operation FROM operations WHERE operation=?',(op,)):
        raise ValueError('این عملیات قبلاً ثبت شده است. /cancel')
    c.execute('INSERT INTO operations VALUES(?,?)',(op,now()))

def audit(c,sid,uid,action,data):
    c.execute('INSERT INTO audit(store,actor,action,data,created) VALUES(?,?,?,?,?)',
              (sid,uid,action,dumps(data),now()))
def session(scope,uid):
    with conn() as c: r=one(c,'SELECT * FROM sessions WHERE scope=? AND user=?',(scope,uid))
    if not r or r['updated']<now()-1800: return None
    return json.loads(r['data'])
def save_session(scope,uid,s):
    with conn(True) as c:
        c.execute('INSERT INTO sessions VALUES(?,?,?,?) ON CONFLICT(scope,user) DO UPDATE SET data=excluded.data,updated=excluded.updated',
                  (scope,uid,dumps(s),now()))
def clear_session(scope,uid):
    with conn(True) as c: c.execute('DELETE FROM sessions WHERE scope=? AND user=?',(scope,uid))
def norm(v): return str(v).translate(DIGITS).strip()
def decimal(v):
    try: d=Decimal(norm(v).replace(',','').replace('٬','').replace('٫','.'))
    except (InvalidOperation,ValueError): raise ValueError('عدد معتبر وارد کنید.')
    if not d.is_finite() or abs(d)>MAX_MONEY: raise ValueError('عدد خارج از محدوده است.')
    return d

def integer(v):
    d=decimal(v)
    if d!=d.to_integral_value(): raise ValueError('عدد صحیح لازم است.')
    return int(d)
def money(v,st,allow_negative=False):
    d=decimal(v)*(10 if st['unit']=='toman' else 1)
    if d!=d.to_integral_value(): raise ValueError('کوچک‌ترین مبلغ قابل ثبت یک ریال است.')
    n=int(d)
    if abs(n)>MAX_MONEY or (n<0 and not allow_negative): raise ValueError('مبلغ معتبر نیست.')
    return n
def unit(st): return 'تومان' if st['unit']=='toman' else 'ریال'
def fmt(n,st):
    d=Decimal(n)/(10 if st['unit']=='toman' else 1)
    return f'{d:,.1f}'.removesuffix('.0')+' '+unit(st)
def status(b,st): return ('بدهکار: '+fmt(b,st)) if b>0 else ('بستانکار: '+fmt(-b,st) if b<0 else 'تسویه‌شده')
def phone(v):
    p=''.join(x for x in norm(v) if x not in ' -()')
    if p.startswith('0098'): p='+98'+p[4:]
    if p.startswith('09') and len(p)==11: p='+98'+p[1:]
    if p.startswith('98') and len(p)==12: p='+'+p
    if not p.startswith('+') and p.isdigit() and 8<=len(p)<=15: p='+'+p
    if not p.startswith('+') or not p[1:].isdigit() or not 8<=len(p[1:])<=15:
        raise ValueError('شماره معتبر با کد کشور وارد کنید؛ مثلاً 09123456789 یا +989123456789.')
    return p

def balance(c,sid,cid):
    return c.execute('SELECT COALESCE(SUM(delta),0) FROM ledger WHERE store=? AND customer=?',(sid,cid)).fetchone()[0]
def customer(c,sid,cid): return one(c,'SELECT * FROM customers WHERE store=? AND id=?',(sid,cid))
def lookup(c,sid,text):
    t=norm(text)
    r=one(c,'SELECT * FROM customers WHERE store=? AND code=?',(sid,int(t))) if t.isdigit() else None
    if r: return r
    found=rows(c,'SELECT * FROM customers WHERE store=? AND (name=? OR phone=?) LIMIT 3',(sid,t,t))
    if len(found)==1: return found[0]
    raise ValueError('مشتری پیدا نشد یا نام تکراری است؛ کد مشتری را وارد کنید.')
def writable(st):
    if not st or not st['active'] or st['expires']<=now():
        raise ValueError('اشتراک غیرفعال یا منقضی است؛ مشاهده و خروجی حساب همچنان ممکن است.')
def live_check(c,sid):
    st=store(sid,c); writable(st); return st

def kb(items):
    return {'inline_keyboard':[[{'text':label,'callback_data':data} for label,data in row] for row in items]}
def btn(label,data): return (label,data)

class APIError(Exception): pass
class TG:
    def __init__(self,token): self.token=token; self.http=requests.Session()
    def call(self,method,data=None,files=None,timeout=35):
        try:
            r=self.http.post('https://api.telegram.org/bot'+self.token+'/'+method,
                             data=data or {},files=files,timeout=timeout)
            j=r.json()
        except Exception: raise APIError('network_or_invalid_response') from None
        if not j.get('ok'):
            # Never expose a requests exception, as its URL contains the token.
            raise APIError('telegram_'+str(j.get('error_code','unknown')))
        return j['result']
    def send(self,chat,text,markup=None):
        d={'chat_id':chat,'text':text[:4000]}
        if markup: d['reply_markup']=dumps(markup)
        return self.call('sendMessage',d)
    def document(self,chat,name,content):
        return self.call('sendDocument',{'chat_id':chat}, {'document':(name,content)},timeout=90)

def enqueue(c,sid,chat,kind,payload,key):
    c.execute('INSERT OR IGNORE INTO outbox(store,chat,kind,payload,dedup,created) VALUES(?,?,?,?,?,?)',
              (sid,chat,kind,dumps(payload),key,now()))
def snapshot(c,st,cid):
    cu=customer(c,st['id'],cid)
    if not cu: raise ValueError('حساب پیدا نشد.')
    entries=rows(c,'SELECT * FROM ledger WHERE store=? AND customer=? ORDER BY id',(st['id'],cid))
    for e in entries: e['detail']=json.loads(e['detail'])
    return {'type':'account','store':{'name':st['name'],'unit':st['unit']},'customer':cu,
            'entries':entries,'balance':balance(c,st['id'],cid),'at':now()}
def reports(c,st,cid,txid):
    if not cid: return
    p=snapshot(c,st,cid)
    if st['group_id']: enqueue(c,st['id'],st['group_id'],'report',p,f'tx:{txid}:group')
    cu=p['customer']
    if cu['telegram']:
        e=p['entries'][-1]
        text=f"عملیات #{txid}\nفروشگاه: {st['name']}\n{describe(e,st)}\n{status(p['balance'],st)}\n{stamp()}\nصورت‌حساب کامل: /statement"
        enqueue(c,st['id'],cu['telegram'],'text',{'text':text,'audience_cid':cid},f'tx:{txid}:customer')

def insert_entry(c,st,cid,kind,delta,total,detail,actor,op,reverses=None):
    if abs(delta)>MAX_MONEY or abs(total)>MAX_MONEY: raise ValueError('مبلغ خارج از محدوده است.')
    if cid:
        if not customer(c,st['id'],cid): raise ValueError('حساب متعلق به این فروشگاه نیست.')
        if abs(balance(c,st['id'],cid)+delta)>MAX_MONEY: raise ValueError('مانده خارج از محدوده است.')
    c.execute('INSERT INTO ledger(store,customer,kind,delta,total,detail,created,actor,operation,reverses) VALUES(?,?,?,?,?,?,?,?,?,?)',
              (st['id'],cid,kind,delta,total,dumps(detail),now(),actor,op,reverses))
    return c.execute('SELECT last_insert_rowid()').fetchone()[0]

def describe(e,st):
    labels={'sale':'خرید به حساب','cash':'فروش نقدی','payment':'دریافت وجه','opening':'مانده اول دوره','reverse':'اصلاح/لغو معکوس'}
    d=e['detail'] if isinstance(e['detail'],dict) else json.loads(e['detail'])
    text=f"#{e['id']} | {stamp(e['created'])} | {labels.get(e['kind'],e['kind'])}\nمبلغ: {fmt(e['total'],st)} | اثر بر بدهی: {fmt(e['delta'],st)}"
    for it in d.get('items',[]):
        text+=f"\n  {it['name']} × {it['qty']} {'کیلوگرم' if it['kind']=='kg' else 'عدد'} | نرخ {fmt(it['price'],st)} | {fmt(it['amount'],st)}"
    if d.get('note'): text+='\nتوضیح: '+d['note']
    if d.get('reason'): text+='\nدلیل: '+d['reason']
    if e.get('reverses'): text+=f"\nمعکوس سند #{e['reverses']}"
    return text

def report_text(p):
    st=p['store']; title=f"{st['name']}\nزمان گزارش: {stamp(p['at'])}\n"
    if p['type']=='summary':
        return title+'فهرست مانده مشتری‌ها (بدون ریز خرید)\n'+'\n'.join(
            f"{r['code']} | {r['name']} | {r['phone']} | {status(r['balance'],st)}" for r in p['customers'])
    cu=p['customer']; es=p['entries']
    purchase=sum(e['total'] for e in es if e['kind'] in ('sale','cash'))
    receipts=sum(e['total'] for e in es if e['kind']=='payment')
    head=title+f"مشتری: {cu['name']} | کد {cu['code']}\nتلفن: {cu['phone']}\n{status(p['balance'],st)}\nجمع اسناد خرید قبل از اصلاحات: {fmt(purchase,st)}\nجمع اسناد دریافت قبل از اصلاحات: {fmt(receipts,st)}\nاصلاحات و معکوس‌ها جداگانه در ریز حساب درج شده‌اند.\n"
    return head+'\n\n'+'\n\n'.join(describe(e,st) for e in es)

def excel(p):
    st=p['store']; w=Workbook(); sh=w.active; sh.title='خلاصه'; sh.sheet_view.rightToLeft=True
    def amount(v): return Decimal(v)/(10 if st['unit']=='toman' else 1)
    sh.append(['فروشگاه',st['name'],'زمان',stamp(p['at']),'واحد',unit(st)])
    if p['type']=='summary':
        sh.append(['کد','نام','تلفن','مبلغ مانده','وضعیت'])
        for r in p['customers']:
            sh.append([str(r['code']),r['name'],r['phone'],amount(abs(r['balance'])),
                       'بدهکار' if r['balance']>0 else ('بستانکار' if r['balance']<0 else 'تسویه')])
    else:
        cu=p['customer']; sh.append(['کد',str(cu['code']),'نام',cu['name'],'تلفن',cu['phone']])
        sh.append(['مانده',amount(abs(p['balance'])),'وضعیت',status(p['balance'],st)])
        e=w.create_sheet('تراکنش‌ها'); e.append(['شناسه','زمان','نوع','مبلغ','اثر بدهی','مانده پس از سند','ثبت‌کننده','معکوس سند','توضیح'])
        lines=w.create_sheet('اقلام'); lines.append(['فاکتور','کالا','واحد','مقدار','قیمت واحد','مبلغ'])
        b=0
        for r in p['entries']:
            b+=r['delta']; d=r['detail']
            e.append([str(r['id']),stamp(r['created']),r['kind'],amount(r['total']),amount(r['delta']),amount(b),str(r['actor']),str(r['reverses'] or ''),d.get('reason',d.get('note',''))])
            for it in d.get('items',[]): lines.append([str(r['id']),it['name'],it['kind'],it['qty'],amount(it['price']),amount(it['amount'])])
    for sheet in w:
        sheet.sheet_view.rightToLeft=True; sheet.freeze_panes='A2'
        sheet.auto_filter.ref=sheet.dimensions
        for row in sheet:
            for cell in row:
                if isinstance(cell.value,str): cell.data_type='s' # prevent formula injection, preserve phone/code
                else: cell.number_format='#,##0.0'
                cell.alignment=Alignment(horizontal='right',vertical='top')
        for cell in sheet[1]: cell.font=Font(bold=True,color='FFFFFF'); cell.fill=PatternFill('solid',fgColor='245B78')
        for col in sheet.columns:
            sheet.column_dimensions[col[0].column_letter].width=min(55,max(16,max(len(str(x.value or '')) for x in col)+2))
    out=io.BytesIO(); w.save(out); return out.getvalue()
def chunks(text,n=3300): return [text[i:i+n] for i in range(0,len(text),n)] or ['گزارش خالی']

def summary(c,st):
    rs=rows(c,'''SELECT c.code,c.name,c.phone,COALESCE(SUM(l.delta),0) AS balance
 FROM customers c LEFT JOIN ledger l ON l.customer=c.id AND l.store=c.store
 WHERE c.store=? GROUP BY c.id ORDER BY c.code''',(st['id'],))
    return {'type':'summary','store':{'name':st['name'],'unit':st['unit']},'customers':rs,'at':now()}

def delivery_allowed(job,p):
    """Recheck queued destinations after unlinking a customer or changing a group."""
    if job['store']==0: return job['chat']==CFG['owner_id']
    with conn() as c:
        st=store(job['store'],c)
        if not st: return False
        if job['chat']==st['owner']: return True
        if job['chat']<0: return job['chat']==st['group_id']
        cid=p.get('audience_cid') or p.get('customer',{}).get('id')
        if not cid: return False
        cu=customer(c,st['id'],cid)
        return bool(cu and cu['telegram']==job['chat'])

def outbox_loop(stop):
    while not stop.is_set():
        try:
            with conn() as c: job=one(c,"SELECT * FROM outbox WHERE status='pending' AND next_try<=? ORDER BY id LIMIT 1",(now(),))
            if not job: stop.wait(1); continue
            st=store(job['store'])
            token=CFG['main_token'] if job['store']==0 else CRYPT.decrypt(st['token'].encode()).decode()
            api=TG(token); p=json.loads(job['payload'])
            if not delivery_allowed(job,p):
                with conn(True) as c: c.execute("UPDATE outbox SET status='cancelled',error='destination_changed' WHERE id=?",(job['id'],))
                continue
            text=p['text'] if job['kind']=='text' else report_text(p)
            parts=chunks(text)
            for i in range(job['part'],len(parts)):
                if not delivery_allowed(job,p): raise APIError('destination_changed')
                api.send(job['chat'],f"گزارش {job['id']} • بخش {i+1}/{len(parts)}\n"+parts[i])
                with conn(True) as c: c.execute('UPDATE outbox SET part=? WHERE id=?',(i+1,job['id']))
                stop.wait(1.1)
            if job['kind']=='report' and not job['file_done']:
                if not delivery_allowed(job,p): raise APIError('destination_changed')
                content=excel(p)
                if len(content)>45*1024*1024: raise APIError('file_too_large_manual_export_required')
                api.document(job['chat'],f"report_{job['id']}.xlsx",content)
                with conn(True) as c: c.execute('UPDATE outbox SET file_done=1 WHERE id=?',(job['id'],))
            with conn(True) as c:
                c.execute("UPDATE outbox SET status='sent',text_done=1,error=NULL WHERE id=?",(job['id'],))
            stop.wait(1)
        except Exception as ex:
            LOG.warning('Outbox delivery failed: %s',type(ex).__name__)
            if 'job' in locals() and job:
                with conn(True) as c:
                    c.execute('UPDATE outbox SET attempts=attempts+1,next_try=?,error=? WHERE id=?',
                              (now()+min(3600,30*2**min(job['attempts'],7)),type(ex).__name__,job['id']))
            stop.wait(2)

class Worker:
    def __init__(self,sid,token): self.sid=sid; self.api=TG(token); self.stop=threading.Event()
    def send(self,uid,text,markup=None):
        parts=chunks(text)
        for i,part in enumerate(parts):
            result=self.api.send(uid,part,markup if i==len(parts)-1 else None)
        return result
    def ask(self,uid,flow,fields,extra=None):
        s={'flow':flow,'fields':fields,'index':0,'values':{},'op':uuid.uuid4().hex}
        s.update(extra or {}); save_session(self.sid,uid,s)
        self.send(uid,fields[0][1]+'\n\nلغو: /cancel')
    def run(self):
        ready=False
        while not self.stop.is_set():
            try:
                if not ready:
                    self.api.call('deleteWebhook',{'drop_pending_updates':'false'}); ready=True
                    self.api.call('setMyCommands',{'commands':dumps([{'command':'start','description':'منوی اصلی'},
                        {'command':'cancel','description':'انصراف'},{'command':'statement','description':'صورت‌حساب مشتری'}])})
                with conn() as c: r=one(c,'SELECT value FROM offsets WHERE scope=?',(self.sid,))
                updates=self.api.call('getUpdates',{'offset':r['value'] if r else 0,'timeout':25,
                      'allowed_updates':dumps(['message','callback_query'])},timeout=35)
                for up in updates:
                    try: self.handle(up)
                    except (ValueError,sqlite3.IntegrityError) as ex:
                        uid=(up.get('callback_query') or up.get('message') or {}).get('from',{}).get('id')
                        text=str(ex) if isinstance(ex,ValueError) else 'اطلاعات تکراری یا عملیات قبلاً ثبت شده است. /cancel'
                        if uid:
                            try: self.send(uid,text[:1500])
                            except APIError: pass
                    except Exception as ex:
                        LOG.error('Handler failure scope=%s type=%s',self.sid,type(ex).__name__)
                        uid=(up.get('callback_query') or up.get('message') or {}).get('from',{}).get('id')
                        if uid:
                            try: self.send(uid,'عملیات کامل نشد. پیش از تلاش دوباره، حساب و شماره سند را بررسی کنید. /start')
                            except APIError: pass
                    with conn(True) as c:
                        c.execute('INSERT INTO offsets VALUES(?,?) ON CONFLICT(scope) DO UPDATE SET value=excluded.value',
                                  (self.sid,up['update_id']+1))
            except Exception as ex:
                LOG.warning('Polling retry scope=%s type=%s',self.sid,type(ex).__name__); self.stop.wait(8)
    def handle(self,up):
        cb=up.get('callback_query'); msg=up.get('message')
        if cb:
            try: self.api.call('answerCallbackQuery',{'callback_query_id':cb['id']})
            except APIError: pass
            uid=cb['from']['id']; msg=cb.get('message',{})
        else:
            if not msg: return
            uid=msg.get('from',{}).get('id')
        if not uid: return
        if msg.get('chat',{}).get('type')!='private':
            if self.sid and (msg.get('text') or '').split('@')[0]=='/groupid':
                st=store(self.sid)
                if uid==st['owner']:
                    self.api.send(msg['chat']['id'],f"شناسه گروه: {msg['chat']['id']}\nاین شناسه را در تنظیمات خصوصی ربات ثبت کنید.")
            return
        text=(msg.get('text') or '').strip(); data=cb.get('data','') if cb else None
        if self.sid==0:
            if uid!=CFG['owner_id']:
                self.send(uid,'این ربات مدیریت مرکزی است و دسترسی عمومی ندارد.'); return
            self.admin(uid,text,data,msg); return
        st=store(self.sid)
        if uid!=st['owner']:
            self.client(uid,text,data,msg,st); return
        if text in ('/start','/cancel') or data=='home':
            clear_session(self.sid,uid); self.menu(uid,st); return
        if data:
            self.action(uid,data,st); return
        s=session(self.sid,uid)
        if s: self.input(uid,text,s,st,msg)
        else: self.menu(uid,st)
    def menu(self,uid,st):
        self.send(uid,f"🏪 {st['name']}\nواحد: {unit(st)}\nاعتبار تا: {stamp(st['expires'])}\nاین نسخه آزمایشی است؛ پیش از استفاده مالی واقعی تست شود.",kb([
            [btn('فروش نقدی','sale:cash'),btn('فروش به حساب','sale:account')],
            [btn('حساب مشتری‌ها','customers:0'),btn('ثبت مشتری','newcustomer')],
            [btn('کالاها','products:0'),btn('افزودن کالا','newproduct')],
            [btn('اصلاح / لغو سند','revise'),btn('گزارش‌ها','reports')],
            [btn('تنظیمات','settings'),btn('اشتراک','subscription')]]))
    def account(self,uid,cid,st):
        with conn() as c:
            cu=customer(c,self.sid,cid)
            if not cu: raise ValueError('حساب پیدا نشد.')
            b=balance(c,self.sid,cid)
        self.send(uid,f"کد {cu['code']} | {cu['name']}\n{cu['phone']}\n{status(b,st)}\nنرخ حساب: {'نقدی' if cu['rate']=='cash' else 'نسیه'}\nسقف: {cu['cap_mode']} {fmt(cu['cap'],st)}",kb([
            [btn('ثبت پرداخت / پیش‌پرداخت',f'pay:{cid}')],
            [btn('صورت‌حساب متن و اکسل',f'statement:{cid}')],
            [btn('تنظیم نرخ و سقف بدهی',f'accountsettings:{cid}')],
            [btn('قطع اتصال تلگرام مشتری',f'unlink:{cid}')],
            [btn('خانه','home')]]))
    def action(self,uid,data,st):
        if data.startswith('confirm:'):
            return self.confirm(uid,data,st)
        if data.startswith('customers:'):
            off=max(0,int(data.split(':')[1]))
            with conn() as c: cs=rows(c,'SELECT * FROM customers WHERE store=? ORDER BY code LIMIT 15 OFFSET ?',(self.sid,off))
            keyboard=[[btn(f"{r['code']} — {r['name']}",f"account:{r['id']}")] for r in cs]
            keyboard.append([btn('جست‌وجو','findcustomer'),btn('بعدی',f'customers:{off+15}'),btn('خانه','home')])
            self.send(uid,'حساب‌های مشتری‌ها:',kb(keyboard)); return
        if data.startswith('account:'): return self.account(uid,int(data.split(':')[1]),st)
        if data=='findcustomer': self.ask(uid,'find',[['search','کد یا نام دقیق مشتری را وارد کنید:']]); return
        if data.startswith('statement:'):
            cid=int(data.split(':')[1])
            with conn(True) as c: enqueue(c,self.sid,uid,'report',snapshot(c,st,cid),'manual:'+uuid.uuid4().hex)
            self.send(uid,'صورت‌حساب در صف ارسال قرار گرفت.'); return
        if data=='reports':
            with conn(True) as c:
                p=summary(c,st); enqueue(c,self.sid,uid,'report',p,'summary:'+uuid.uuid4().hex)
                totals=rows(c,'SELECT kind,SUM(total) AS total,COUNT(*) AS count FROM ledger WHERE store=? AND created>=? GROUP BY kind',(self.sid,now()-86400))
                pending=c.execute("SELECT COUNT(*) FROM outbox WHERE store=? AND status='pending'",(self.sid,)).fetchone()[0]
            self.send(uid,'گزارش مانده‌ها در صف ارسال است.\nاسناد ۲۴ ساعت گذشته (معکوس‌ها جدا):\n'+'\n'.join(f"{r['kind']}: {fmt(r['total'],st)} ({r['count']} سند)" for r in totals)+f'\nارسال‌های در انتظار: {pending}'); return
        if data=='subscription':
            with conn() as c: ps=rows(c,'SELECT * FROM plans WHERE active=1')
            self.send(uid,'پایان اشتراک: '+stamp(st['expires'])+'\n'+'\n'.join(f"بسته {p['id']}: {p['name']} | {p['days']} روز | {p['price']}" for p in ps),kb([[btn('درخواست مدت دلخواه','subrequest')],[btn('خانه','home')]])); return
        if data=='subrequest': self.ask(uid,'subrequest',[['days','مدت موردنظر، به روز (۱ تا ۳۶۵۰):']]); return
        if data=='settings':
            self.send(uid,'تنظیمات فروشگاه:',kb([[btn('تومان','unit:toman'),btn('ریال','unit:rial')],
                [btn('تنظیم گروه گزارش','setgroup')],[btn('تغییر نام','setname')],[btn('خانه','home')]])); return
        if data.startswith('unit:'):
            u=data.split(':')[1]
            if u not in ('rial','toman'): raise ValueError('واحد نامعتبر')
            # Avoid interpreting a monetary input started under the old display unit.
            clear_session(self.sid,uid)
            with conn(True) as c:
                c.execute('UPDATE stores SET unit=? WHERE id=?',(u,self.sid)); audit(c,self.sid,uid,'unit',u)
            self.send(uid,'واحد نمایش تغییر کرد؛ ارزش حساب‌ها ثابت است. /start'); return
        if data=='setgroup':
            self.ask(uid,'group',[['group','ربات را در گروه ادمین کنید، در گروه /groupid بفرستید و شناسه عددی گروه را اینجا وارد کنید.\nهشدار: اطلاعات مالی و شماره مشتری‌ها به این گروه ارسال می‌شود.']]); return
        if data=='setname': self.ask(uid,'name',[['name','نام جدید فروشگاه:']]); return
        if data.startswith('products:'):
            off=max(0,int(data.split(':')[1]))
            with conn() as c: ps=rows(c,'SELECT * FROM products WHERE store=? ORDER BY id LIMIT 12 OFFSET ?',(self.sid,off))
            self.send(uid,'کالاها:\n'+'\n'.join(f"#{p['id']} {p['name']} | {p['kind']} | نقدی {fmt(p['cash'],st)} | نسیه {fmt(p['credit'],st)} | {'فعال' if p['active'] else 'غیرفعال'}" for p in ps),
                      kb([[btn('اصلاح قیمت','editproduct'),btn('فعال/غیرفعال','toggleproduct')],[btn('بعدی',f'products:{off+12}'),btn('خانه','home')]])); return
        # Writes below require active subscription. Backend checks again at commit.
        writable(st)
        if data=='newproduct':
            self.ask(uid,'product',[['name','نام کالا:'],['kind','نوع کالا: عدد یا کیلو'],['cash',f'قیمت نقدی هر واحد به {unit(st)}:'],['pct','درصد افزایش نسیه این کالا (مثلاً ۲۰):']]); return
        if data=='editproduct':
            self.ask(uid,'editproduct',[['id','کد کالا:'],['cash',f'قیمت نقدی جدید به {unit(st)}:'],['pct','درصد افزایش نسیه جدید:']]); return
        if data=='toggleproduct': self.ask(uid,'toggleproduct',[['id','کد کالایی که وضعیت آن تغییر کند:']]); return
        if data=='newcustomer':
            self.ask(uid,'customer',[['name','نام مشتری:'],['phone','شماره تلفن مشتری:'],['rate','نرخ حساب: نقدی یا نسیه'],
                ['opening',f'مانده اول دوره به {unit(st)}؛ بدهی مثبت، بستانکاری منفی، بدون مانده صفر:']]); return
        if data.startswith('pay:'):
            cid=int(data.split(':')[1])
            with conn() as c:
                if not customer(c,self.sid,cid): raise ValueError('حساب پیدا نشد.')
            self.ask(uid,'payment',[['amount',f'مبلغ دریافت‌شده با کارت‌خوان به {unit(st)}:'],['note','توضیح / شماره رسید (یا -):']],{'cid':cid}); return
        if data.startswith('accountsettings:'):
            self.ask(uid,'accountsettings',[['rate','نرخ: نقدی یا نسیه'],['mode','سقف بدهی: بدون / هشدار / مسدود'],['cap',f'مبلغ سقف به {unit(st)}؛ برای بدون محدودیت صفر:']],{'cid':int(data.split(':')[1])}); return
        if data.startswith('unlink:'):
            self.ask(uid,'unlink',[['confirm','برای قطع اتصال تلگرام مشتری، عبارت «قطع اتصال» را وارد کنید.']],{'cid':int(data.split(':')[1])}); return
        if data=='sale:account': self.ask(uid,'sale_customer',[['search','کد یا نام دقیق مشتری:']]); return
        if data=='sale:cash': self.start_cart(uid,st,None); return
        if data.startswith('pick:'):
            s=session(self.sid,uid)
            if not s or s.get('flow')!='cart': raise ValueError('ابتدا فروش جدید را شروع کنید.')
            pid=int(data.split(':')[1])
            with conn() as c: p=one(c,'SELECT * FROM products WHERE store=? AND id=? AND active=1',(self.sid,pid))
            if not p: raise ValueError('کالا پیدا نشد.')
            s['flow']='quantity'; s['product']=p; save_session(self.sid,uid,s)
            self.send(uid,'مقدار به کیلوگرم (مثلاً ۰٫۵):' if p['kind']=='kg' else 'تعداد صحیح:'); return
        if data.startswith('cartpage:'): self.cart(uid,st,int(data.split(':')[1])); return
        if data=='cartpop':
            s=session(self.sid,uid)
            if not s or s.get('flow')!='cart': raise ValueError('سبد فعالی وجود ندارد.')
            if s['items']: s['items'].pop()
            save_session(self.sid,uid,s); self.cart(uid,st); return
        if data=='cartdone':
            s=session(self.sid,uid)
            if not s or s.get('flow')!='cart' or not s['items']: raise ValueError('سبد خرید خالی است.')
            s['flow']='sale'; s['total']=sum(i['amount'] for i in s['items']); s['detail']={'items':s['items']}
            self.prepare(uid,st,s); return
        if data=='revise':
            self.ask(uid,'revision',[['id','شماره سند خرید، پرداخت یا مانده اول دوره:'],['mode','نوع عملیات: لغو یا اصلاح'],
                ['reason','دلیل اصلاح یا لغو:']],{}); return
        raise ValueError('گزینه معتبر نیست یا منو قدیمی است. /start')
    def input(self,uid,text,s,st,msg):
        if s['flow']=='quantity':
            q=decimal(text); p=s['product']
            if q<=0 or q>1000000 or (p['kind']=='count' and q!=q.to_integral_value()) or q.as_tuple().exponent < -3:
                raise ValueError('مقدار مثبت معتبر لازم است؛ وزن حداکثر سه رقم اعشار و تعداد عدد صحیح.')
            price=p['cash'] if s['rate']=='cash' else p['credit']
            amount=int((Decimal(price)*q).quantize(Decimal(1),rounding=ROUND_HALF_UP))
            if amount<=0 or amount>MAX_MONEY: raise ValueError('مبلغ معتبر نیست.')
            if len(s['items'])>=50: raise ValueError('هر فاکتور حداکثر ۵۰ ردیف دارد؛ /cancel یا سبد جدید.')
            s['items'].append({'product':p['id'],'name':p['name'],'kind':p['kind'],'qty':str(q),'price':price,'amount':amount})
            s.pop('product',None); s['flow']='cart'; save_session(self.sid,uid,s); self.cart(uid,st); return
        if s['flow']=='replacement':
            # Replacement lines use the original invoice unit prices (historical prices).
            # Format: original-line-number:quantity, e.g. 1:2 / 2:0.5 . 0 removes a line.
            old=s['old']; d=json.loads(old['detail'])
            if old['kind'] in ('sale','cash'):
                parts=norm(text).split('/')
                if len(parts)!=len(d.get('items',[])): raise ValueError('برای هر ردیف یک مقدار با / جدا کنید؛ صفر یعنی حذف ردیف.')
                items=[]
                for it,v in zip(d['items'],parts):
                    q=decimal(v)
                    if q<0 or q>1000000 or q.as_tuple().exponent < -3 or (it['kind']=='count' and q!=q.to_integral_value()): raise ValueError('مقدار نامعتبر')
                    if not q: continue
                    amount=int((q*it['price']).quantize(Decimal(1),rounding=ROUND_HALF_UP))
                    if amount<=0: raise ValueError('مبلغ ردیف باید مثبت باشد.')
                    items.append(dict(it,qty=str(q),amount=amount))
                if not items: raise ValueError('برای حذف همه اقلام از لغو استفاده کنید.')
                s['replacement']={'total':sum(i['amount'] for i in items),'detail':{'items':items,'reason':s['values']['reason']}}
            else:
                n=money(text,st,old['kind']=='opening')
                if old['kind']=='payment' and n<=0: raise ValueError('مبلغ دریافت باید مثبت باشد.')
                s['replacement']={'total':n,'detail':{'reason':s['values']['reason']}}
            s['flow']='revision_ready'; self.prepare(uid,st,s); return
        fields=s.get('fields')
        if not fields or s.get('awaiting'): raise ValueError('از دکمه‌های همین عملیات استفاده کنید یا /cancel بزنید.')
        if not text or len(text)>500: raise ValueError('متن کوتاه معتبر وارد کنید.')
        key=fields[s['index']][0]; s['values'][key]=text; s['index']+=1
        if s['index']<len(fields):
            save_session(self.sid,uid,s); self.send(uid,fields[s['index']][1]+'\nلغو: /cancel'); return
        # Persist last prompt so validation errors can be corrected by re-entering it.
        s['index']=len(fields)-1; save_session(self.sid,uid,s)
        self.finish_input(uid,s,st)
    def rate(self,text):
        v={'نقدی':'cash','نسیه':'credit','cash':'cash','credit':'credit'}.get(norm(text))
        if not v: raise ValueError('نرخ باید نقدی یا نسیه باشد؛ برای شروع دوباره /cancel بزنید.')
        return v
    def finish_input(self,uid,s,st):
        f=s['flow']; v=s['values']
        if f=='find':
            with conn() as c: cu=lookup(c,self.sid,v['search'])
            clear_session(self.sid,uid); self.account(uid,cu['id'],st); return
        if f=='sale_customer':
            with conn() as c: cu=lookup(c,self.sid,v['search'])
            self.start_cart(uid,st,cu); return
        if f=='subrequest':
            days=integer(v['days'])
            if not 1<=days<=3650: raise ValueError('مدت بین ۱ تا ۳۶۵۰ روز باشد.')
            with conn(True) as c:
                claim_operation(c,s['op'])
                c.execute('INSERT INTO subscription_requests(store,days,status,created,actor) VALUES(?,?,?,?,?)',(self.sid,days,'requested',now(),uid))
                rid=c.execute('SELECT last_insert_rowid()').fetchone()[0]
                enqueue(c,0,CFG['owner_id'],'text',{'text':f'درخواست اشتراک #{rid}\nفروشگاه {self.sid} {st["name"]}\nمدت: {days} روز\nاز بخش قیمت‌گذاری درخواست مبلغ را اعلام کنید.'},f'subrequest:{rid}')
            clear_session(self.sid,uid); self.send(uid,'درخواست برای ادمین مرکزی ارسال شد.'); return
        if f=='group':
            gid=integer(v['group'])
            chat=self.api.call('getChat',{'chat_id':gid})
            me=self.api.call('getMe'); member=self.api.call('getChatMember',{'chat_id':gid,'user_id':me['id']})
            owner_member=self.api.call('getChatMember',{'chat_id':gid,'user_id':uid})
            if chat['type'] not in ('group','supergroup') or member['status'] not in ('administrator','creator') or owner_member['status'] not in ('administrator','creator'):
                raise ValueError('فروشنده و ربات باید ادمین گروه مقصد باشند.')
            s['gid']=gid; s['group_title']=chat.get('title','گروه'); s['awaiting']=True; s['confirm_step']=1
            save_session(self.sid,uid,s)
            self.send(uid,f"گروه مقصد: {s['group_title']}\nشناسه: {gid}\nاطلاعات مالی و شماره تماس مشتری‌ها به این گروه فرستاده می‌شود. تأیید می‌کنید؟",self.confirm_keyboard(s)); return
        if f=='name':
            with conn(True) as c:
                c.execute('UPDATE stores SET name=? WHERE id=?',(v['name'][:100],self.sid)); audit(c,self.sid,uid,'name',v)
            clear_session(self.sid,uid); self.send(uid,'نام ثبت شد.'); return
        writable(st)
        if f in ('product','editproduct'):
            cash=money(v['cash'],st); pct=decimal(v['pct'])
            if cash<=0 or not 0<=pct<=10000: raise ValueError('قیمت مثبت و درصد بین صفر و ۱۰۰۰۰ لازم است.')
            credit=int((Decimal(cash)*(1+pct/100)).quantize(Decimal(1),rounding=ROUND_HALF_UP))
            if credit>MAX_MONEY: raise ValueError('قیمت بیش از حد بزرگ است.')
            with conn(True) as c:
                live_check(c,self.sid)
                if f=='product':
                    kind={'عدد':'count','تعدادی':'count','کیلو':'kg','کیلویی':'kg','kg':'kg','count':'count'}.get(v['kind'])
                    if not kind: raise ValueError('نوع کالا باید عدد یا کیلو باشد؛ /cancel و دوباره ثبت کنید.')
                    c.execute('INSERT INTO products(store,name,kind,cash,pct,credit) VALUES(?,?,?,?,?,?)',(self.sid,v['name'][:120],kind,cash,str(pct),credit))
                else:
                    r=c.execute('UPDATE products SET cash=?,pct=?,credit=? WHERE store=? AND id=?',(cash,str(pct),credit,self.sid,integer(v['id'])))
                    if not r.rowcount: raise ValueError('کالا پیدا نشد.')
                audit(c,self.sid,uid,f,v)
            clear_session(self.sid,uid); self.send(uid,f'کالا ثبت شد. نقدی: {fmt(cash,st)} | نسیه: {fmt(credit,st)}'); return
        if f=='toggleproduct':
            with conn(True) as c:
                live_check(c,self.sid)
                r=c.execute('UPDATE products SET active=1-active WHERE store=? AND id=?',(self.sid,integer(v['id'])))
                if not r.rowcount: raise ValueError('کالا پیدا نشد.')
                audit(c,self.sid,uid,f,v)
            clear_session(self.sid,uid); self.send(uid,'وضعیت کالا تغییر کرد.'); return
        if f=='customer':
            s['name']=v['name'][:100]; s['phone']=phone(v['phone']); s['rate']=self.rate(v['rate']); s['opening']=money(v['opening'],st,True)
            self.prepare(uid,st,s); return
        if f=='payment':
            s['total']=money(v['amount'],st)
            if s['total']<=0: raise ValueError('مبلغ باید مثبت باشد.')
            s['detail']={'note':v['note']}; self.prepare(uid,st,s); return
        if f=='accountsettings':
            rate=self.rate(v['rate']); mode={'بدون':'none','هشدار':'warn','مسدود':'block'}.get(v['mode'])
            if not mode: raise ValueError('حالت سقف: بدون، هشدار یا مسدود')
            cap=money(v['cap'],st)
            with conn(True) as c:
                live_check(c,self.sid)
                r=c.execute('UPDATE customers SET rate=?,cap_mode=?,cap=? WHERE store=? AND id=?',(rate,mode,cap,self.sid,s['cid']))
                if not r.rowcount: raise ValueError('مشتری پیدا نشد.')
                audit(c,self.sid,uid,f,{'customer':s['cid'],**v})
            clear_session(self.sid,uid); self.account(uid,s['cid'],st); return
        if f=='unlink':
            if v['confirm']!='قطع اتصال': raise ValueError('عبارت تأیید مطابقت ندارد.')
            with conn(True) as c:
                live_check(c,self.sid)
                c.execute('UPDATE customers SET telegram=NULL WHERE store=? AND id=?',(self.sid,s['cid'])); audit(c,self.sid,uid,'unlink',s['cid'])
            clear_session(self.sid,uid); self.send(uid,'اتصال قطع شد. برای اتصال دوباره احراز هویت لازم است.'); return
        if f=='revision':
            with conn() as c:
                old=one(c,'SELECT * FROM ledger WHERE store=? AND id=?',(self.sid,integer(v['id'])))
                if not old or old['kind']=='reverse': raise ValueError('سند اصلی معتبر نیست.')
                if one(c,'SELECT id FROM ledger WHERE reverses=?',(old['id'],)): raise ValueError('این سند قبلاً معکوس شده است.')
            if v['mode'] not in ('لغو','اصلاح'): raise ValueError('نوع عملیات باید لغو یا اصلاح باشد.')
            if len(v['reason'])<3: raise ValueError('دلیل روشن وارد کنید.')
            s['old']=old; s['cid']=old['customer']; s['flow']='revision_ready'
            if v['mode']=='اصلاح':
                s['flow']='replacement'; save_session(self.sid,uid,s)
                d=json.loads(old['detail'])
                if old['kind'] in ('sale','cash'):
                    self.send(uid,'اصلاح تعداد/وزن با قیمت تاریخی؛ برای هر ردیف مقدار جدید را با / جدا کنید. صفر یعنی مرجوعی کامل همان ردیف.\n'+
                              '\n'.join(f"{i+1}. {it['name']} مقدار قبلی {it['qty']}" for i,it in enumerate(d['items']))+'\nمثال: 2 / 0.5 / 0\nبرای تغییر قیمت یا افزودن کالای جدید، سند را لغو و فروش جدید ثبت کنید.')
                else: self.send(uid,f'مبلغ صحیح جدید به {unit(st)} (مانده اولیه می‌تواند منفی باشد):')
                return
            self.prepare(uid,st,s); return
        raise ValueError('فرایند نامعتبر؛ /cancel')
    def start_cart(self,uid,st,cu):
        s={'flow':'cart','cid':cu['id'] if cu else None,'rate':cu['rate'] if cu else 'cash','items':[],'op':uuid.uuid4().hex}
        save_session(self.sid,uid,s); self.cart(uid,st)
    def cart(self,uid,st,offset=0):
        s=session(self.sid,uid)
        if not s or s.get('flow')!='cart': raise ValueError('سبد خرید فعال نیست.')
        with conn() as c: ps=rows(c,'SELECT * FROM products WHERE store=? AND active=1 ORDER BY id LIMIT 10 OFFSET ?',(self.sid,max(0,offset)))
        text='سبد خرید:\n'+'\n'.join(f"{i+1}. {it['name']} × {it['qty']} = {fmt(it['amount'],st)}" for i,it in enumerate(s['items']))
        text+='\nجمع: '+fmt(sum(it['amount'] for it in s['items']),st)+'\nکالا را انتخاب کنید:'
        keys=[[btn(f"{p['name']} — {fmt(p['cash'] if s['rate']=='cash' else p['credit'],st)}",f"pick:{p['id']}")] for p in ps]
        keys.extend([[btn('قبلی',f'cartpage:{max(0,offset-10)}'),btn('بعدی',f'cartpage:{offset+10}')],
            [btn('حذف آخرین ردیف','cartpop'),btn('پیش‌نمایش و ثبت','cartdone')],[btn('انصراف','home')]])
        self.send(uid,text,kb(keys))
    def effect(self,s):
        if s['flow']=='payment': return -s['total']
        if s['flow']=='sale': return s['total'] if s['cid'] else 0
        if s['flow']=='revision_ready':
            old=s['old']; effect=-old['delta']; r=s.get('replacement')
            if r: effect+=(-r['total'] if old['kind']=='payment' else (0 if old['kind']=='cash' else r['total']))
            return effect
        return 0
    def prepare(self,uid,st,s):
        writable(st); cid=s.get('cid'); effect=self.effect(s)
        with conn() as c:
            cu=customer(c,self.sid,cid) if cid else None
            if cid and not cu: raise ValueError('حساب پیدا نشد.')
            b=balance(c,self.sid,cid) if cid else 0
            s['version']=c.execute('SELECT COALESCE(MAX(id),0) FROM ledger WHERE store=? AND customer IS ?',(self.sid,cid)).fetchone()[0]
        s['before']=b; s['after']=b+effect; s['confirm_step']=1; s['awaiting']=True
        s['cap_signature']=[cu['cap_mode'],cu['cap'],cu['rate']] if cu else None
        s['cap_warning']=False
        if cu and effect>0 and s['after']>cu['cap'] and cu['cap_mode']!='none':
            if cu['cap_mode']=='block': raise ValueError('این عملیات بدهی را از سقف مجاز بالاتر می‌برد. ابتدا تنظیم سقف را بررسی کنید.')
            s['cap_warning']=True
        save_session(self.sid,uid,s); self.show_confirmation(uid,st,s)
    def confirm_keyboard(self,s):
        return kb([[btn('بله، مطمئنم',f"confirm:{s['op']}:{s['confirm_step']}")],[btn('انصراف','home')]])
    def show_confirmation(self,uid,st,s):
        f=s['flow']; n=s['confirm_step']; stages=3 if f=='revision_ready' else 1
        text=f'تأیید {n} از {stages}\n'
        if f=='customer':
            text+=f"مشتری: {s['name']}\nشماره: {s['phone']}\nمانده اول دوره: {status(s['opening'],st)}"
        else:
            if s.get('cid'):
                with conn() as c: cu=customer(c,self.sid,s['cid'])
                text+=f"مشتری: {cu['name']} — کد {cu['code']}\n"
            if f=='revision_ready':
                text+=describe(s['old'],st)+f"\nعملیات: {s['values']['mode']}\nدلیل: {s['values']['reason']}\n"
                if s.get('replacement'): text+='مبلغ سند جایگزین: '+fmt(s['replacement']['total'],st)+'\n'
            else:
                text+='مبلغ: '+fmt(s['total'],st)+'\n'
                for it in s.get('items',[]): text+=f"{it['name']} × {it['qty']} = {fmt(it['amount'],st)}\n"
            if s.get('cid'): text+=f"قبل: {status(s['before'],st)}\nبعد: {status(s['after'],st)}\n"
            if f=='payment': text+='این دکمه فقط تأیید فروشنده است؛ استعلام بانکی انجام نمی‌شود.\n'
        if s.get('cap_warning'): text+='⚠️ سقف بدهی رد می‌شود؛ با تأیید اجازه ادامه می‌دهید.\n'
        text+='\nآیا مطمئنید؟'
        if stages==3 and n==3: text+=' سابقه حفظ می‌شود و گزارش تغییر به گروه می‌رود.'
        self.send(uid,text,self.confirm_keyboard(s))
    def confirm(self,uid,data,st):
        parts=data.split(':'); s=session(self.sid,uid)
        if len(parts)!=3 or not s or not s.get('awaiting') or s['op']!=parts[1] or str(s['confirm_step'])!=parts[2]:
            raise ValueError('این دکمه قدیمی، منقضی یا قبلاً استفاده شده است. /start')
        if s['flow']=='group':
            with conn(True) as c:
                c.execute('UPDATE stores SET group_id=?,next_report=0 WHERE id=?',(s['gid'],self.sid))
                audit(c,self.sid,uid,'report_group',{'group':s['gid']})
                enqueue(c,self.sid,s['gid'],'text',{'text':'این گروه برای گزارش مالی فروشگاه متصل شد. فقط افراد مجاز باید عضو باشند.'},'group:'+s['op'])
            clear_session(self.sid,uid); self.send(uid,'گروه گزارش ثبت شد.'); return
        writable(st)
        if s['flow']=='revision_ready' and s['confirm_step']<3:
            # If a new financial entry arrived, restart all three confirmations.
            with conn() as c:
                v=c.execute('SELECT COALESCE(MAX(id),0) FROM ledger WHERE store=? AND customer IS ?',(self.sid,s.get('cid'))).fetchone()[0]
            if v!=s['version']:
                self.send(uid,'حساب تغییر کرده؛ تأییدها از ابتدا محاسبه می‌شوند.'); self.prepare(uid,st,s); return
            s['confirm_step']+=1; save_session(self.sid,uid,s); self.show_confirmation(uid,st,s); return
        txid=None; cid=s.get('cid')
        with conn(True) as c:
            st=live_check(c,self.sid)
            if one(c,'SELECT id FROM ledger WHERE operation=?',(s['op'],)) or one(c,'SELECT id FROM ledger WHERE operation=?',(s['op']+':reverse',)):
                raise ValueError('این عملیات قبلاً ثبت شده است.')
            if s['flow']=='customer':
                code=c.execute('SELECT COALESCE(MAX(code),0)+1 FROM customers WHERE store=?',(self.sid,)).fetchone()[0]
                c.execute('INSERT INTO customers(store,code,name,phone,rate,cap_mode) VALUES(?,?,?,?,?,?)',
                          (self.sid,code,s['name'],s['phone'],s['rate'],'none'))
                cid=c.execute('SELECT last_insert_rowid()').fetchone()[0]
                txid=insert_entry(c,st,cid,'opening',s['opening'],s['opening'],{'note':'مانده اول دوره'},uid,s['op'])
                audit(c,self.sid,uid,'customer_created',{'customer':cid,'code':code})
            else:
                v=c.execute('SELECT COALESCE(MAX(id),0) FROM ledger WHERE store=? AND customer IS ?',(self.sid,cid)).fetchone()[0]
                if v!=s['version']: raise ValueError('حساب از زمان پیش‌نمایش تغییر کرده؛ /cancel و عملیات را دوباره آغاز کنید.')
                if cid:
                    cu=customer(c,self.sid,cid)
                    if [cu['cap_mode'],cu['cap'],cu['rate']]!=s['cap_signature']: raise ValueError('تنظیمات حساب تغییر کرده؛ عملیات را دوباره آغاز کنید.')
                    after=balance(c,self.sid,cid)+self.effect(s)
                    if self.effect(s)>0 and cu['cap_mode']=='block' and after>cu['cap']: raise ValueError('سقف بدهی مجاز نیست.')
                if s['flow']=='payment':
                    txid=insert_entry(c,st,cid,'payment',-s['total'],s['total'],s['detail'],uid,s['op'])
                elif s['flow']=='sale':
                    txid=insert_entry(c,st,cid,'sale' if cid else 'cash',s['total'] if cid else 0,s['total'],s['detail'],uid,s['op'])
                elif s['flow']=='revision_ready':
                    old=one(c,'SELECT * FROM ledger WHERE id=? AND store=?',(s['old']['id'],self.sid))
                    if not old or one(c,'SELECT id FROM ledger WHERE reverses=?',(old['id'],)): raise ValueError('سند قبلاً اصلاح شده یا معتبر نیست.')
                    txid=insert_entry(c,st,cid,'reverse',-old['delta'],-old['total'],{'reason':s['values']['reason'],'original_kind':old['kind']},uid,s['op']+':reverse',old['id'])
                    if s.get('replacement'):
                        r=s['replacement']; delta=-r['total'] if old['kind']=='payment' else (0 if old['kind']=='cash' else r['total'])
                        r['detail']['replaces']=old['id']
                        txid=insert_entry(c,st,cid,old['kind'],delta,r['total'],r['detail'],uid,s['op'])
                    audit(c,self.sid,uid,'financial_revision',{'old':old['id'],'last_new':txid,'reason':s['values']['reason']})
                else: raise ValueError('عملیات نامعتبر')
            if s.get('cap_warning'):
                audit(c,self.sid,uid,'debt_limit_override',{'customer':cid,'transaction':txid,'after':s['after'],'limit':s['cap_signature'][1]})
            reports(c,st,cid,txid)
            if not cid and st['group_id']:
                e=one(c,'SELECT * FROM ledger WHERE id=? AND store=?',(txid,self.sid))
                enqueue(c,self.sid,st['group_id'],'text',{'text':describe(e,st)},f'cash:{txid}')
            c.execute('DELETE FROM sessions WHERE scope=? AND user=?',(self.sid,uid))
        self.send(uid,f'✅ ثبت شد. شماره سند: {txid}'+(f'\nکد مشتری: {code}' if s['flow']=='customer' else '')+'\n/start')
    def client(self,uid,text,data,msg,st):
        with conn() as c: cu=one(c,'SELECT * FROM customers WHERE store=? AND telegram=?',(self.sid,uid))
        if msg.get('contact'):
            contact=msg['contact']
            if contact.get('user_id')!=uid: raise ValueError('فقط شماره تماس متعلق به حساب تلگرام خودتان پذیرفته می‌شود.')
            p=phone(contact['phone_number'])
            with conn(True) as c:
                found=rows(c,'SELECT * FROM customers WHERE store=? AND phone=?',(self.sid,p))
                if len(found)!=1: raise ValueError('شماره با حساب فروشگاه تطبیق ندارد؛ با فروشنده تماس بگیرید.')
                target=found[0]
                if target['telegram'] not in (None,uid): raise ValueError('این حساب قبلاً متصل شده؛ فروشنده باید اتصال قبلی را بررسی کند.')
                if cu and cu['id']!=target['id']: raise ValueError('قبلاً به حساب دیگری متصل هستید؛ فروشنده باید بررسی کند.')
                c.execute('UPDATE customers SET telegram=? WHERE store=? AND id=?',(uid,self.sid,target['id']))
                audit(c,self.sid,uid,'customer_link',{'customer':target['id']}); cu=target
            self.send(uid,'احراز هویت انجام شد.',{'remove_keyboard':True})
        if not cu:
            self.send(uid,'برای مشاهده حساب خود، شماره متعلق به همین حساب تلگرام را به اشتراک بگذارید.',
                {'keyboard':[[{'text':'اشتراک‌گذاری شماره تماس من','request_contact':True}]],'resize_keyboard':True,'one_time_keyboard':True}); return
        if text=='/statement' or data=='my_statement':
            with conn(True) as c:
                if one(c,"SELECT id FROM outbox WHERE store=? AND chat=? AND kind='report' AND created>?",(self.sid,uid,now()-60)):
                    raise ValueError('برای درخواست صورت‌حساب بعدی یک دقیقه صبر کنید.')
                enqueue(c,self.sid,uid,'report',snapshot(c,st,cu['id']),'client:'+uuid.uuid4().hex)
            self.send(uid,'صورت‌حساب شما در صف ارسال است.'); return
        with conn() as c: b=balance(c,self.sid,cu['id'])
        self.send(uid,f"{st['name']}\n{cu['name']} | کد {cu['code']}\n{status(b,st)}",kb([[btn('صورت‌حساب کامل متن و اکسل','my_statement')]]))
    def admin(self,uid,text,data,msg):
        if text in ('/start','/cancel') or data=='adminhome':
            clear_session(0,uid)
            self.send(uid,'مدیریت مرکزی — توکن‌ها را فقط در گفت‌وگوی خصوصی وارد کنید.',kb([
                [btn('اتصال فروشگاه','a:add'),btn('فهرست فروشگاه‌ها','a:list')],
                [btn('فعال/غیرفعال','a:toggle'),btn('تمدید دستی','a:extend')],
                [btn('تعریف بسته قیمت','a:plan'),btn('درخواست‌ها','a:requests')],
                [btn('اعلام قیمت درخواست','a:quote'),btn('تأیید و فعال‌سازی درخواست','a:activate')],
                [btn('سلامت سامانه','a:health')]])); return
        if data:
            if data=='a:list':
                with conn() as c: sts=rows(c,'SELECT id,name,owner,active,expires FROM stores ORDER BY id')
                for p in chunks('\n'.join(f"#{s['id']} {s['name']} | ادمین {s['owner']} | {'فعال' if s['active'] else 'تعلیق'} | {stamp(s['expires'])}" for s in sts) or 'فروشگاهی ثبت نشده است.'): self.send(uid,p)
                return
            if data=='a:requests':
                with conn() as c: rs=rows(c,"SELECT * FROM subscription_requests WHERE status!='activated' ORDER BY id DESC LIMIT 30")
                self.send(uid,'\n'.join(f"#{r['id']} فروشگاه {r['store']} | {r['days']} روز | {r['status']} | {r['quote'] or 'بدون قیمت'}" for r in rs) or 'درخواستی نیست.'); return
            if data=='a:health':
                with conn() as c:
                    dbok=c.execute('PRAGMA quick_check').fetchone()[0]
                    pending=c.execute("SELECT COUNT(*) FROM outbox WHERE status='pending'").fetchone()[0]
                    backup=one(c,"SELECT value FROM meta WHERE key='last_backup'")
                self.send(uid,f"پایگاه داده: {dbok}\nارسال در انتظار: {pending}\nآخرین پشتیبان: {stamp(int(backup['value'])) if backup else 'هنوز گرفته نشده'}\nپشتیبان محلی جایگزین نسخه خارج سرور نیست."); return
            forms={
                'a:add':('admin_add',[['name','نام فروشگاه:'],['owner','آیدی عددی ادمین فروشگاه:'],['days','مدت اولیه اشتراک به روز:'],['token','توکن ربات اختصاصی فروشگاه (هرگز در گروه ارسال نکنید):']]),
                'a:toggle':('admin_toggle',[['id','شناسه فروشگاه برای تغییر وضعیت:']]),
                'a:extend':('admin_extend',[['id','شناسه فروشگاه:'],['days','تعداد روز تمدید پس از تأیید شما:']]),
                'a:plan':('admin_plan',[['name','عنوان بسته:'],['days','تعداد روز:'],['price','مبلغ و واحد و شرایط قیمت (مثلاً ۳۰۰۰۰۰ تومان):']]),
                'a:quote':('admin_quote',[['id','شماره درخواست اشتراک:'],['quote','قیمت نهایی و شرایط پرداخت را بنویسید:']]),
                'a:activate':('admin_activate',[['id','شماره درخواست؛ این عملیات تأیید دستی مالک برای فعال‌سازی است:'],['confirm','برای تأیید عبارت «فعال شود» را وارد کنید:']])}
            if data in forms: self.ask(uid,*forms[data]); return
            raise ValueError('گزینه نامعتبر')
        s=session(0,uid)
        if not s: self.admin(uid,'/start',None,msg); return
        if not text or len(text)>600: raise ValueError('ورودی معتبر لازم است.')
        k=s['fields'][s['index']][0]
        # Store tokens only encrypted, including the temporary session state.
        if k=='token':
            if ':' not in text: raise ValueError('توکن معتبر نیست.')
            s['values'][k]=CRYPT.encrypt(text.encode()).decode()
            try: self.api.call('deleteMessage',{'chat_id':uid,'message_id':msg['message_id']})
            except APIError: pass
        else: s['values'][k]=text
        s['index']+=1
        if s['index']<len(s['fields']):
            save_session(0,uid,s); self.send(uid,s['fields'][s['index']][1]); return
        s['index']=len(s['fields'])-1; save_session(0,uid,s); v=s['values']; f=s['flow']
        if f=='admin_add':
            token=CRYPT.decrypt(v['token'].encode()).decode(); api=TG(token); me=api.call('getMe')
            main_id=int(CFG['main_token'].split(':')[0])
            if me['id']==main_id: raise ValueError('ربات مرکزی را نمی‌توان به‌عنوان فروشگاه ثبت کرد.')
            owner=integer(v['owner']); days=integer(v['days'])
            if owner<=0 or not 1<=days<=3650: raise ValueError('آیدی یا مدت نامعتبر؛ /cancel و دوباره شروع کنید.')
            with conn(True) as c:
                claim_operation(c,s['op'])
                c.execute('INSERT INTO stores(bot_id,token,owner,name,expires,created) VALUES(?,?,?,?,?,?)',
                    (me['id'],v['token'],owner,v['name'][:100],now()+days*86400,now()))
                sid=c.execute('SELECT last_insert_rowid()').fetchone()[0]
                audit(c,sid,uid,'store_created',{'bot_id':me['id'],'owner':owner,'days':days})
            self.send(uid,f"فروشگاه #{sid} متصل شد: @{me.get('username','')}\nادمین فروشگاه /start بزند.")
        elif f=='admin_toggle':
            sid=integer(v['id'])
            with conn(True) as c:
                claim_operation(c,s['op'])
                r=c.execute('UPDATE stores SET active=1-active WHERE id=?',(sid,))
                if not r.rowcount: raise ValueError('فروشگاه پیدا نشد.')
                audit(c,sid,uid,'subscription_toggle',{})
            self.send(uid,'وضعیت تغییر کرد. دسترسی مشاهده حساب حفظ می‌شود.')
        elif f=='admin_extend':
            sid=integer(v['id']); days=integer(v['days'])
            if not 1<=days<=3650: raise ValueError('مدت نامعتبر')
            with conn(True) as c:
                st=store(sid,c)
                if not st: raise ValueError('فروشگاه پیدا نشد.')
                claim_operation(c,s['op'])
                expiry=max(now(),st['expires'])+days*86400
                c.execute('UPDATE stores SET expires=?,active=1 WHERE id=?',(expiry,sid)); audit(c,sid,uid,'extend',{'days':days})
            self.send(uid,'تمدید شد: '+stamp(expiry))
        elif f=='admin_plan':
            days=integer(v['days'])
            if not 1<=days<=3650: raise ValueError('مدت نامعتبر')
            with conn(True) as c:
                claim_operation(c,s['op'])
                c.execute('INSERT INTO plans(name,days,price) VALUES(?,?,?)',(v['name'],days,v['price']))
            self.send(uid,'بسته قیمت ثبت شد. قیمت‌گذاری اختصاصی درخواست‌ها هم ممکن است.')
        elif f=='admin_quote':
            rid=integer(v['id'])
            with conn(True) as c:
                r=one(c,'SELECT * FROM subscription_requests WHERE id=?',(rid,))
                if not r or r['status']=='activated': raise ValueError('درخواست معتبر نیست.')
                claim_operation(c,s['op'])
                c.execute("UPDATE subscription_requests SET quote=?,status='quoted' WHERE id=?",(v['quote'],rid))
                st=store(r['store'],c)
                enqueue(c,st['id'],st['owner'],'text',{'text':f"قیمت درخواست #{rid} برای {r['days']} روز:\n{v['quote']}\nفعال‌سازی پس از هماهنگی و تأیید ادمین مرکزی انجام می‌شود."},'quote:'+s['op'])
                audit(c,st['id'],uid,'subscription_quote',{'request':rid,'quote':v['quote']})
            self.send(uid,'قیمت برای فروشنده ارسال شد.')
        elif f=='admin_activate':
            if v['confirm']!='فعال شود': raise ValueError('عبارت تأیید مطابقت ندارد.')
            rid=integer(v['id'])
            with conn(True) as c:
                r=one(c,'SELECT * FROM subscription_requests WHERE id=?',(rid,))
                if not r or r['status']!='quoted': raise ValueError('درخواست باید قیمت‌گذاری شده و هنوز فعال نشده باشد.')
                st=store(r['store'],c); expiry=max(now(),st['expires'])+r['days']*86400
                c.execute('UPDATE stores SET expires=?,active=1 WHERE id=?',(expiry,st['id']))
                c.execute("UPDATE subscription_requests SET status='activated' WHERE id=?",(rid,))
                audit(c,st['id'],uid,'subscription_activated',{'request':rid})
                enqueue(c,st['id'],st['owner'],'text',{'text':'اشتراک فعال شد. پایان: '+stamp(expiry)},f'activated:{rid}')
            self.send(uid,'اشتراک فعال شد.')
        clear_session(0,uid)

def backup_once():
    """Encrypted full database backup. Key is intentionally not in the backup."""
    target=Path(CFG['backup_dir']); target.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='snapshot-',suffix='.db',dir=CFG['data_dir']); os.close(fd)
    try:
        src=sqlite3.connect(DB); dst=sqlite3.connect(tmp)
        try: src.backup(dst); ok=dst.execute('PRAGMA integrity_check').fetchone()[0]
        finally: dst.close(); src.close()
        if ok!='ok': raise RuntimeError('Backup integrity failed')
        # Fernet is memory based. For large deployments replace with streaming backup/PITR.
        raw=Path(tmp).read_bytes(); encrypted=CRYPT.encrypt(raw)
        name='backup-'+datetime.now(TZ).strftime('%Y%m%d-%H%M%S')+'.db.fernet'
        partial=target/(name+'.tmp')
        with open(partial,'wb') as f: f.write(encrypted); f.flush(); os.fsync(f.fileno())
        os.replace(partial,target/name)
        os.chmod(target/name,0o600)
        for old in sorted(target.glob('backup-*.db.fernet'),reverse=True)[int(CFG.get('backup_keep',48)):]: old.unlink()
        with conn(True) as c:
            c.execute("INSERT INTO meta VALUES('last_backup',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",(str(now()),))
        return str(target/name)
    finally:
        Path(tmp).unlink(missing_ok=True)

def scheduler(stop):
    backup_retry=0
    while not stop.is_set():
        try:
            with conn(True) as c:
                for st in rows(c,'SELECT * FROM stores'):
                    if st['group_id'] and st['next_report']<=now():
                        slot=now()//1800
                        enqueue(c,st['id'],st['group_id'],'report',summary(c,st),f'periodic:{st["id"]}:{slot}')
                        c.execute('UPDATE stores SET next_report=? WHERE id=?',((slot+1)*1800,st['id']))
                    left=st['expires']-now()
                    if 0<left<3*86400:
                        enqueue(c,st['id'],st['owner'],'text',{'text':'یادآوری: اشتراک فروشگاه تا '+stamp(st['expires'])+' معتبر است.'},f'expiry:{st["id"]}:{st["expires"]}:{now()//86400}')
                c.execute('DELETE FROM sessions WHERE updated<?',(now()-86400,))
                # Outbox stores full reports. Retain delivered snapshots 7 days, not forever.
                c.execute("DELETE FROM outbox WHERE status='sent' AND created<?",(now()-7*86400,))
                b=one(c,"SELECT value FROM meta WHERE key='last_backup'")
            if now()>=backup_retry and (not b or now()-int(b['value'])>=int(CFG.get('backup_interval',1800))):
                try: backup_once()
                except Exception as ex:
                    backup_retry=now()+300
                    LOG.error('Backup failed: %s',type(ex).__name__)
                    with conn(True) as c:
                        enqueue(c,0,CFG['owner_id'],'text',{'text':'⚠️ پشتیبان‌گیری پایگاه داده ناموفق بود. فضای دیسک و سرویس را بررسی کنید.'},f'backupfail:{now()//3600}')
        except Exception as ex: LOG.error('Scheduler failure: %s',type(ex).__name__)
        stop.wait(15)

def serve():
    import fcntl,signal
    lock=open(Path(CFG['data_dir'])/'app.lock','w')
    try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError: raise SystemExit('Another instance is running')
    stop=threading.Event()
    signal.signal(signal.SIGTERM,lambda *_:stop.set()); signal.signal(signal.SIGINT,lambda *_:stop.set())
    ws={0:Worker(0,CFG['main_token'])}; threads={}
    for fn in (outbox_loop,scheduler): threading.Thread(target=fn,args=(stop,),daemon=True).start()
    while not stop.is_set():
        with conn() as c: stores=rows(c,'SELECT * FROM stores')
        for st in stores:
            if st['id'] not in ws:
                ws[st['id']]=Worker(st['id'],CRYPT.decrypt(st['token'].encode()).decode())
        for sid,w in ws.items():
            if sid not in threads or not threads[sid].is_alive():
                threads[sid]=threading.Thread(target=w.run,daemon=True); threads[sid].start()
        stop.wait(5)
    for w in ws.values(): w.stop.set()
    for th in threads.values(): th.join(timeout=2)

def restore_check(path,output):
    # Safe offline export only. Never overwrite a live database from a Telegram command.
    out=Path(output)
    if out.exists(): raise SystemExit('Output already exists; refusing overwrite')
    raw=CRYPT.decrypt(Path(path).read_bytes())
    with open(out,'xb') as f: f.write(raw)
    os.chmod(out,0o600)
    c=sqlite3.connect(str(out))
    try: result=c.execute('PRAGMA integrity_check').fetchone()[0]
    finally: c.close()
    if result!='ok': raise SystemExit('Restored DB integrity check failed')
    print('Decrypted database verified:',out)

def selftest():
    import unittest
    class Tests(unittest.TestCase):
        def setUp(self):
            self.tmp=tempfile.TemporaryDirectory()
            init({'key':Fernet.generate_key().decode(),'data_dir':self.tmp.name,'backup_dir':self.tmp.name+'/backups','backup_keep':2,'owner_id':1})
            with conn(True) as c:
                for n in (1,2):
                    c.execute('INSERT INTO stores(bot_id,token,owner,name,expires,created) VALUES(?,?,?,?,?,?)',(n,'encrypted',n,'test',now()+86400,now()))
                    c.execute("INSERT INTO customers(store,code,name,phone,rate,cap_mode) VALUES(?,1,'customer',?,'cash','none')",(n,'+98912345678'+str(n)))
        def tearDown(self): self.tmp.cleanup()
        def test_precision_and_units(self):
            self.assertEqual(money('۱۲۳٫۵',{'unit':'toman'}),1235)
            self.assertEqual(money('1235',{'unit':'rial'}),1235)
            self.assertEqual(phone('09123456789'),'+989123456789')
            with self.assertRaises(ValueError): decimal('NaN')
            with self.assertRaises(ValueError): money('0.01',{'unit':'toman'})
        def test_credit_prepayment_and_tenant(self):
            with conn(True) as c:
                st=store(1,c)
                insert_entry(c,st,1,'sale',500,500,{},1,'sale')
                insert_entry(c,st,1,'payment',-700,700,{},1,'pay')
                self.assertEqual(balance(c,1,1),-200)
                insert_entry(c,st,1,'sale',100,100,{},1,'sale2')
                self.assertEqual(balance(c,1,1),-100)
                self.assertEqual(balance(c,2,1),0)
                with self.assertRaises(ValueError): insert_entry(c,st,2,'sale',100,100,{},1,'bad-tenant')
        def test_immutable_and_duplicate(self):
            with conn(True) as c:
                st=store(1,c); tx=insert_entry(c,st,1,'opening',400,400,{},1,'unique')
                with self.assertRaises(sqlite3.IntegrityError): insert_entry(c,st,1,'opening',400,400,{},1,'unique')
                with self.assertRaises(sqlite3.IntegrityError): c.execute('UPDATE ledger SET delta=0 WHERE id=?',(tx,))
                insert_entry(c,st,1,'reverse',-400,-400,{'reason':'test'},1,'reverse',tx)
                self.assertEqual(balance(c,1,1),0)
                with self.assertRaises(sqlite3.IntegrityError): insert_entry(c,st,1,'reverse',-400,-400,{},1,'reverse2',tx)
        def test_report_and_backup_restore(self):
            from openpyxl import load_workbook
            with conn(True) as c:
                st=store(1,c); insert_entry(c,st,1,'opening',100,100,{},1,'op')
                p=snapshot(c,st,1)
            p['customer']['name']='=1+1'
            data=excel(p); wb=load_workbook(io.BytesIO(data))
            self.assertEqual(wb['خلاصه']['D2'].data_type,'s')
            self.assertIn('مانده',report_text(p))
            path=backup_once(); out=self.tmp.name+'/restored.db'; restore_check(path,out)
            c=sqlite3.connect(out)
            self.assertEqual(c.execute('SELECT SUM(delta) FROM ledger').fetchone()[0],100); c.close()
        def test_debt_limits_and_override_audit(self):
            st=store(1); w=Worker(1,'dummy'); w.send=lambda *a,**k: None
            s={'flow':'sale','cid':1,'op':'cap-sale','items':[], 'total':101,'detail':{}}
            with conn(True) as c: c.execute("UPDATE customers SET cap_mode='block',cap=100 WHERE id=1")
            with self.assertRaises(ValueError): w.prepare(1,st,s)
            with conn(True) as c: c.execute("UPDATE customers SET cap_mode='warn' WHERE id=1")
            w.prepare(1,st,s)
            self.assertTrue(session(1,1)['cap_warning'])
            w.confirm(1,'confirm:cap-sale:1',st)
            with conn() as c:
                self.assertEqual(balance(c,1,1),101)
                self.assertIsNotNone(one(c,"SELECT id FROM audit WHERE action='debt_limit_override'"))
        def test_stale_preview_and_expired_subscription(self):
            st=store(1); w=Worker(1,'dummy'); w.send=lambda *a,**k: None
            s={'flow':'payment','cid':1,'op':'p1','total':50,'detail':{}}
            w.prepare(1,st,s)
            with conn(True) as c: insert_entry(c,st,1,'opening',100,100,{},1,'race')
            with self.assertRaises(ValueError): w.confirm(1,'confirm:p1:1',st)
            w.prepare(1,st,s)
            with conn(True) as c: c.execute('UPDATE stores SET expires=? WHERE id=1',(now()-1,))
            with self.assertRaises(ValueError): w.confirm(1,'confirm:p1:1',st)
            with conn() as c: self.assertEqual(balance(c,1,1),100)
        def test_queue_destination_revocation(self):
            with conn(True) as c:
                c.execute('UPDATE customers SET telegram=77 WHERE id=1')
                c.execute('UPDATE stores SET group_id=-99 WHERE id=1')
                p=snapshot(c,store(1,c),1)
            job={'store':1,'chat':77}
            self.assertTrue(delivery_allowed(job,p))
            self.assertFalse(delivery_allowed({'store':2,'chat':77},p))
            self.assertTrue(delivery_allowed({'store':1,'chat':-99},p))
            with conn(True) as c:
                c.execute('UPDATE customers SET telegram=NULL WHERE id=1')
                c.execute('UPDATE stores SET group_id=-100 WHERE id=1')
            self.assertFalse(delivery_allowed(job,p))
            self.assertFalse(delivery_allowed({'store':1,'chat':-99},p))
        def test_weighted_sale_and_historical_price(self):
            st=store(1); w=Worker(1,'dummy'); w.send=lambda *a,**k: None
            with conn(True) as c:
                c.execute("UPDATE customers SET rate='credit' WHERE id=1")
                c.execute("INSERT INTO products(store,name,kind,cash,pct,credit) VALUES(1,'rice','kg',1000,'20',1200)")
                cu=customer(c,1,1)
            w.start_cart(1,st,cu); w.action(1,'pick:1',st)
            w.input(1,'0.125',session(1,1),st,{})
            s=session(1,1); self.assertEqual(s['items'][0]['amount'],150)
            with conn(True) as c: c.execute('UPDATE products SET credit=5000 WHERE id=1')
            w.action(1,'cartdone',st); s=session(1,1)
            w.confirm(1,f"confirm:{s['op']}:1",st)
            with conn() as c:
                self.assertEqual(balance(c,1,1),150)
                e=one(c,'SELECT detail FROM ledger WHERE customer=1')
                self.assertEqual(json.loads(e['detail'])['items'][0]['price'],1200)
        def test_atomic_replacement(self):
            st=store(1); w=Worker(1,'dummy'); w.send=lambda *a,**k: None
            with conn(True) as c:
                tx=insert_entry(c,st,1,'sale',400,400,{},1,'base-sale')
                old=one(c,'SELECT * FROM ledger WHERE id=?',(tx,))
            s={'flow':'revision_ready','cid':1,'old':old,'op':'fix-op',
               'values':{'mode':'اصلاح','reason':'returned one item'},
               'replacement':{'total':300,'detail':{'items':[]}}}
            w.prepare(1,st,s)
            for n in (1,2,3): w.confirm(1,f'confirm:fix-op:{n}',st)
            with conn() as c:
                self.assertEqual(balance(c,1,1),300)
                self.assertEqual(c.execute('SELECT COUNT(*) FROM ledger').fetchone()[0],3)
        def test_admin_operation_idempotency(self):
            with conn(True) as c:
                claim_operation(c,'admin-op')
                with self.assertRaises(ValueError): claim_operation(c,'admin-op')
        def test_confirm_three_stages(self):
            st=store(1)
            with conn(True) as c:
                tx=insert_entry(c,st,1,'payment',-100,100,{},1,'original')
                old=one(c,'SELECT * FROM ledger WHERE id=?',(tx,))
            w=Worker(1,'dummy'); w.send=lambda *a,**k: None
            s={'flow':'revision_ready','cid':1,'old':old,'op':'rev-op','values':{'mode':'لغو','reason':'test correction'}}
            w.prepare(1,st,s)
            for n in (1,2):
                w.confirm(1,f'confirm:rev-op:{n}',st)
                with conn() as c: self.assertEqual(balance(c,1,1),-100)
            w.confirm(1,'confirm:rev-op:3',st)
            with conn() as c: self.assertEqual(balance(c,1,1),0)
            with self.assertRaises(ValueError): w.confirm(1,'confirm:rev-op:3',st)
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(Tests)
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful(): raise SystemExit(1)

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--config',default='/etc/tgshop/config.json')
    parser.add_argument('--self-test',action='store_true')
    parser.add_argument('--backup',action='store_true')
    parser.add_argument('--restore-check',nargs=2,metavar=('BACKUP','OUTPUT'))
    args=parser.parse_args()
    if args.self_test: selftest()
    else:
        with open(args.config) as f: init(json.load(f))
        if args.backup: print(backup_once())
        elif args.restore_check: restore_check(*args.restore_check)
        else: serve()
PYAPP
chmod 0644 "$APP/app.py"
"$APP/venv/bin/python" -m py_compile "$APP/app.py"
"$APP/venv/bin/python" "$APP/app.py" --self-test
cat > /etc/systemd/system/tgshop.service <<'SERVICE'
[Unit]
Description=TGShop multi-store Telegram accounting bot (beta)
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=simple
User=tgshop
Group=tgshop
WorkingDirectory=/opt/tgshop
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=/opt/tgshop/venv/bin/python /opt/tgshop/app.py --config /etc/tgshop/config.json
Restart=on-failure
RestartSec=10
TimeoutStopSec=60
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/tgshop
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LockPersonality=true

[Install]
WantedBy=multi-user.target
SERVICE
chmod 0644 /etc/systemd/system/tgshop.service
systemctl daemon-reload
systemctl enable --now tgshop
printf '\nInstalled. Open the main bot and send /start.\n'
printf 'Status: sudo systemctl status tgshop\nLogs: sudo journalctl -u tgshop -n 100 --no-pager\n'
printf 'Encrypted local backups: /var/lib/tgshop/backups\n'
printf 'CRITICAL: securely copy /etc/tgshop/config.json OFF SERVER; it contains the only backup decryption key. Never upload it to GitHub.\n'
printf 'Copy encrypted backups to independent storage. Local backups alone cannot protect against server loss.\n'
printf 'This is a beta implementation. Test with dummy accounts before handling real money.\n'

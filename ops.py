import os,sys,json,secrets,subprocess,tempfile,tarfile,hashlib,shutil
from pathlib import Path
from datetime import datetime,timezone,timedelta
from cryptography.hazmat.primitives.ciphers import Cipher,algorithms,modes

DATA=Path('/var/lib/shopbot'); BACKUPS=Path('/var/backups/shopbot'); CONFIG=Path('/etc/shopbot')

def run(args,**kwargs):
    return subprocess.run(args,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kwargs)

def pg(sql,db='postgres'):
    return run(['runuser','-u','postgres','--','psql','-X','-v','ON_ERROR_STOP=1','-d',db,'-At'],input=sql.encode()).stdout.decode().strip()

def encrypt(src,dst,key):
    nonce=secrets.token_bytes(12); ctx=Cipher(algorithms.AES(key),modes.GCM(nonce)).encryptor(); ctx.authenticate_additional_data(b'SBKP1')
    with open(src,'rb') as a,open(dst,'xb') as b:
        b.write(b'SBKP1'+nonce)
        while chunk:=a.read(1024*1024): b.write(ctx.update(chunk))
        b.write(ctx.finalize()); b.write(ctx.tag); b.flush(); os.fsync(b.fileno())

def decrypt(src,dst,key):
    with open(src,'rb') as a:
        if a.read(5)!=b'SBKP1': raise ValueError('backup_format')
        nonce=a.read(12); a.seek(-16,2); end=a.tell(); tag=a.read(16); a.seek(17)
        ctx=Cipher(algorithms.AES(key),modes.GCM(nonce,tag)).decryptor(); ctx.authenticate_additional_data(b'SBKP1')
        with open(dst,'xb') as b:
            remain=end-17
            while remain:
                data=a.read(min(remain,1024*1024)); remain-=len(data); b.write(ctx.update(data))
            b.write(ctx.finalize())

def record(ok,message,path=None):
    DATA.mkdir(mode=0o750,exist_ok=True)
    data={'at':datetime.now(timezone.utc).isoformat(),'ok':ok,'message':message,'file':str(path) if path else None,'independent_copy_configured':bool(os.getenv('BACKUP_REMOTE'))}
    tmp=DATA/'backup-status.tmp'; tmp.write_text(json.dumps(data)); os.chmod(tmp,0o640)
    import pwd,grp
    os.chown(tmp,0,grp.getgrnam('shopbot').gr_gid); tmp.replace(DATA/'backup-status.json')
    # Notification failure never invalidates or deletes a backup.
    try:
        import urllib.request,urllib.parse
        body=urllib.parse.urlencode({'chat_id':os.environ['OWNER_ID'],'text':'Backup '+('OK' if ok else 'FAILED')+' — '+message}).encode()
        req=urllib.request.Request('https://api.telegram.org/bot'+os.environ['CENTRAL_TOKEN']+'/sendMessage',data=body)
        with urllib.request.urlopen(req,timeout=15) as response: response.read()
    except Exception: print('Backup notification unavailable; check local status.',file=sys.stderr)

def backup():
    BACKUPS.mkdir(mode=0o700,parents=True,exist_ok=True)
    key=bytes.fromhex((CONFIG/'backup.key').read_text().strip())
    name=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+secrets.token_hex(4)+'.sbk'
    dest=BACKUPS/name
    with tempfile.TemporaryDirectory(prefix='backup-',dir=DATA) as work:
        root=Path(work); os.chmod(root,0o700)
        # stdout stream avoids postgres needing access to private staging directory.
        with open(root/'db.dump','wb') as f:
            subprocess.run(['runuser','-u','postgres','--','pg_dump','-Fc','--no-owner','--no-acl','shopbot'],stdout=f,stderr=subprocess.PIPE,check=True)
        shutil.copy2(CONFIG/'service.env',root/'service.env'); shutil.copy2(CONFIG/'token.key',root/'token.key')
        with tarfile.open(root/'code.tar.gz','w:gz') as tar: tar.add(Path('/opt/shopbot/current').resolve(),arcname='release')
        hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in root.iterdir() if p.is_file()}
        (root/'manifest.json').write_text(json.dumps({'version':1,'files':hashes,'at':datetime.now(timezone.utc).isoformat()}))
        with tarfile.open(root/'payload.tar','w') as tar:
            for name in ['db.dump','service.env','token.key','code.tar.gz','manifest.json']: tar.add(root/name,arcname=name)
        encrypt(root/'payload.tar',dest,key); os.chmod(dest,0o600)
    remote=os.getenv('BACKUP_REMOTE','')
    if remote:
        if remote.startswith('-') or ':' not in remote: raise ValueError('invalid_remote_destination')
        run(['rsync','--chmod=F600','-e','ssh -oBatchMode=yes -oStrictHostKeyChecking=yes','--',str(dest),remote])
    cutoff=datetime.now(timezone.utc).timestamp()-int(os.getenv('BACKUP_RETENTION_DAYS','14'))*86400
    for old in BACKUPS.glob('*.sbk'):
        if old!=dest and old.stat().st_mtime<cutoff: old.unlink()
    message='encrypted backup created; '+('remote copy succeeded' if remote else 'WARNING: local only; independent destination not configured')
    record(True,message,dest); print(str(dest)); return dest

def unpack(src,root):
    key=bytes.fromhex((CONFIG/'backup.key').read_text().strip()); decrypted=root/'payload.tar'
    decrypt(src,decrypted,key)
    expected={'db.dump','service.env','token.key','code.tar.gz','manifest.json'}
    with tarfile.open(decrypted) as tar:
        if {m.name for m in tar.getmembers()}!=expected: raise ValueError('invalid_members')
        for m in tar.getmembers():
            if not m.isfile(): raise ValueError('invalid_member_type')
            with tar.extractfile(m) as a,open(root/m.name,'wb') as b: shutil.copyfileobj(a,b)
    manifest=json.loads((root/'manifest.json').read_text())
    for name in expected-{'manifest.json'}:
        if manifest['files'][name]!=hashlib.sha256((root/name).read_bytes()).hexdigest(): raise ValueError('checksum_mismatch')

def audit(db):
    # Validate ledger roots and subsequent delta identities without trusting a cached balance.
    sql="""SELECT count(*) FROM events e LEFT JOIN invoices i ON i.shop_id=e.shop_id AND i.id=e.invoice_id
    WHERE (e.kind='sale' AND (i.id IS NULL OR e.amount<>i.total OR e.delta<>CASE WHEN i.method='account' THEN i.total ELSE 0 END))
    OR (e.kind='payment' AND (e.amount<=0 OR e.delta<>-e.amount))
    OR (e.kind='opening' AND e.delta<>e.amount)
    OR (e.kind='return' AND (e.amount>0 OR e.delta<>CASE WHEN i.method='account' THEN e.amount ELSE 0 END))
    OR (e.kind='correction' AND e.delta<>(e.detail->>'delta')::bigint);"""
    errors=int(pg(sql,db))
    errors+=int(pg("SELECT count(*) FROM customers c WHERE c.code>(SELECT customer_seq FROM shops WHERE id=c.shop_id)",db))
    errors+=int(pg("SELECT count(*) FROM (SELECT e.shop_id,e.target_id,sum(-e.amount) AS returned FROM events e WHERE kind='return' GROUP BY e.shop_id,e.target_id) r JOIN events o ON o.shop_id=r.shop_id AND o.id=r.target_id WHERE returned > coalesce((SELECT (a.detail->>'new_amount')::bigint FROM events a WHERE a.shop_id=o.shop_id AND a.target_id=o.id AND a.kind='correction' ORDER BY a.id DESC LIMIT 1),o.amount)",db))
    if errors: raise ValueError('ledger_integrity_failed_'+str(errors))
    print('Ledger checks passed. Balances are computed from immutable events; no balance cache is used.')

def restore(src,testing):
    src=Path(src).resolve()
    with tempfile.TemporaryDirectory(prefix='restore-',dir=DATA) as work:
        root=Path(work); unpack(src,root)
        scratch='shopbot_restore_'+secrets.token_hex(5)
        pg('CREATE DATABASE '+scratch)
        try:
            with open(root/'db.dump','rb') as f:
                run(['runuser','-u','postgres','--','pg_restore','--exit-on-error','--no-owner','--no-acl','-d',scratch],stdin=f)
            audit(scratch)
            if testing:
                print('Authenticated backup decrypted, restored into isolated database and checked. No production data changed.'); return
            if not sys.stdin.isatty() or input('Type RESTORE SHOPBOT to replace production database and configuration: ')!='RESTORE SHOPBOT': raise ValueError('confirmation_required')
            backup()
            run(['systemctl','stop','shopbot.service'])
            pg("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='shopbot' AND pid<>pg_backend_pid()")
            old='shopbot_before_'+datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')
            pg('ALTER DATABASE shopbot RENAME TO '+old)
            pg('ALTER DATABASE '+scratch+' RENAME TO shopbot'); scratch=None
            # Restore matching program code, never execute unverified archive paths.
            dest=Path('/opt/shopbot/releases')/('restored-'+secrets.token_hex(5)); dest.mkdir(mode=0o755)
            with tarfile.open(root/'code.tar.gz','r:gz') as tar:
                for m in tar.getmembers():
                    parts=Path(m.name).parts
                    if not parts or parts[0]!='release' or '..' in parts or m.issym() or m.islnk() or not (m.isfile() or m.isdir()): raise ValueError('invalid_code_archive')
                tar.extractall(dest,filter='data')
            for name in ('service.env','token.key'):
                shutil.copyfile(root/name,CONFIG/name); os.chmod(CONFIG/name,0o640)
                import grp
                os.chown(CONFIG/name,0,grp.getgrnam('shopbot').gr_gid)
            release=dest/'release'
            run(['bash','/usr/local/lib/shopbot/activate-restored.sh',str(release)])
            print('Restored. Previous database retained as '+old+'. Verify bot tokens and financial accounts before accepting new operations.')
        finally:
            if scratch: pg('DROP DATABASE IF EXISTS '+scratch+' WITH (FORCE)')

def health():
    p=DATA/'health.json'; report=json.loads(p.read_text())
    at=datetime.fromisoformat(report['at'])
    if (datetime.now(timezone.utc)-at).total_seconds()>120: raise ValueError('heartbeat_stale')
    pg('SELECT 1','shopbot')
    print('Database and application heartbeat OK; inspect /shops for each bot token health.')

def main():
    if os.geteuid()!=0: raise SystemExit('Run as root.')
    os.umask(0o077)
    cmd=sys.argv[1] if len(sys.argv)>1 else 'health'
    try:
        if cmd=='backup': backup()
        elif cmd in ('restore','test-restore'): restore(sys.argv[2],cmd=='test-restore')
        elif cmd=='audit': audit('shopbot')
        elif cmd=='health': health()
        else: raise ValueError('unknown_command')
    except Exception as e:
        if cmd=='backup': record(False,'Backup failed: '+type(e).__name__)
        print('Operation failed: '+type(e).__name__+'. No secrets printed. Check database, disk space, file permissions, SSH and key.',file=sys.stderr)
        raise SystemExit(1)

if __name__=='__main__': main()

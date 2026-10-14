#!/usr/bin/env bash
# ShopBots installer / updater for Ubuntu 22.04, Ubuntu 24.04 and Debian 12.
#
#   sudo bash install.sh install     first-time setup (interactive: central bot token + owner id)
#   sudo bash install.sh update      safe update: backup -> stop -> replace code -> migrate -> start -> health check
#   sudo bash install.sh status
#   sudo bash install.sh logs [N]
#   sudo bash install.sh backup
#   sudo bash install.sh restore <backup.enc>   (never automatic; asks for typed confirmation)
#   sudo bash install.sh test        runs the unit tests shipped with the app (no DB needed)
#
# Data, secrets and config are never deleted or overwritten by install/update.
set -Eeuo pipefail
umask 027

readonly APP_NAME="shopbots"
readonly APP_DIR="/opt/shopbots"
readonly CODE_DIR="/opt/shopbots/app"
readonly VENV_DIR="/opt/shopbots/venv"
readonly BIN_DIR="/opt/shopbots/bin"
readonly ETC_DIR="/etc/shopbots"
readonly SECRETS_DIR="/etc/shopbots/secrets"
readonly ENV_FILE="/etc/shopbots/shopbots.env"
readonly DATA_DIR="/var/lib/shopbots"
readonly LOG_DIR="/var/log/shopbots"
readonly BACKUP_DIR="/var/backups/shopbots"
readonly SVC_USER="shopbots"
readonly SVC_NAME="shopbots"
readonly DB_NAME="shopbots"
readonly DB_USER="shopbots"
readonly PY_PINS=("aiogram==3.13.1" "asyncpg==0.30.0" "cryptography==43.0.3" "openpyxl==3.1.5" "tzdata==2024.2")
# Official sources only. Replace with YOUR repository when you publish it, e.g.:
#   https://github.com/<your-github-user>/<your-repo>/raw/main/install.sh
readonly SOURCE_HINT="https://github.com/<your-github-user>/shopbots/raw/main/install.sh"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
log()  { printf '%s[shopbots]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()  { printf '%s[error]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

on_error() {
  local line="$1" code="$2"
  printf '%s[error]%s installer stopped at line %s (exit %s). Nothing else was changed after this point.\n' "$RED" "$NC" "$line" "$code" >&2
  printf 'Check: sudo journalctl -u %s -n 50 ; and the messages above. Re-running "install" is safe.\n' "$SVC_NAME" >&2
}
trap 'on_error $LINENO $?' ERR

require_root() { [[ $EUID -eq 0 ]] || die "run with sudo / as root."; }

check_os() {
  [[ -r /etc/os-release ]] || die "unsupported system: /etc/os-release missing. Supported: Ubuntu 22.04, 24.04, Debian 12."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04|debian:12) log "system: ${PRETTY_NAME}" ;;
    *) die "unsupported system (${PRETTY_NAME:-unknown}). Nothing was changed. Supported: Ubuntu 22.04, Ubuntu 24.04, Debian 12." ;;
  esac
  [[ "$(uname -m)" == "x86_64" || "$(uname -m)" == "aarch64" ]] || die "unsupported CPU architecture: $(uname -m)"
}

check_prereqs() {
  command -v systemctl >/dev/null || die "systemd is required."
  if ! command -v curl >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive; apt-get update -y >/dev/null; apt-get install -y curl ca-certificates >/dev/null
  fi
  command -v apt-get >/dev/null || die "apt-get is required."
  local free_mb
  free_mb=$(df -Pm /opt 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
  [[ "${free_mb:-0}" -ge 1024 ]] || die "less than 1 GB free on /opt; free some space first."
  if ! curl -fsS --max-time 10 -o /dev/null https://api.telegram.org 2>/dev/null; then
    die "cannot reach api.telegram.org from this server (outbound HTTPS needed). Nothing was changed."
  fi
}

install_packages() {
  log "installing system packages (apt)…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends python3 python3-venv python3-pip postgresql postgresql-client \
    openssl ca-certificates curl gzip logrotate tzdata >/dev/null
}

ensure_user_and_dirs() {
  id -u "$SVC_USER" >/dev/null 2>&1 || useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$SVC_USER"
  install -d -m 0755 -o root -g root "$APP_DIR" "$CODE_DIR" "$BIN_DIR" "$ETC_DIR"
  install -d -m 0750 -o root -g "$SVC_USER" "$SECRETS_DIR"
  install -d -m 0750 -o "$SVC_USER" -g "$SVC_USER" "$DATA_DIR" "$LOG_DIR" "$BACKUP_DIR"
}

write_file() {  # write_file <path> <mode> ; content from stdin
  local path="$1" mode="$2" tmp
  tmp="$(mktemp "${path}.XXXX")"
  cat > "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$path"
}

deploy_code() {
  log "writing application code to $CODE_DIR"
  local staging
  staging="$(mktemp -d)"
  install -d -m 0755 "$staging/migrations"
  install -d -m 0755 "$staging/shopbots"
  install -d -m 0755 "$staging/shopbots/domain"
  install -d -m 0755 "$staging/shopbots/handlers"
  install -d -m 0755 "$staging/shopbots/render"
  install -d -m 0755 "$staging/tests"
  write_file "$staging/migrations/0001_init.sql" 0644 <<'SHOPBOTS_FILE_EOF'
-- ShopBots initial schema. All money columns are BIGINT rial. All times timestamptz (UTC).

CREATE SEQUENCE fin_event_seq;

CREATE TABLE stores (
    id                         bigserial PRIMARY KEY,
    name                       text NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
    contact                    text,
    bot_token_enc              bytea,
    bot_tg_id                  bigint UNIQUE,
    bot_username               text,
    bot_status                 text NOT NULL DEFAULT 'pending'
                               CHECK (bot_status IN ('pending','running','invalid_token','conflict','disabled','error')),
    bot_status_detail          text,
    is_enabled                 boolean NOT NULL DEFAULT true,
    report_chat_id             bigint,
    report_chat_title          text,
    currency                   text NOT NULL DEFAULT 'toman' CHECK (currency IN ('toman','rial')),
    timezone                   text NOT NULL DEFAULT 'Asia/Tehran',
    jalali                     boolean NOT NULL DEFAULT true,
    rounding_unit_rial         integer NOT NULL DEFAULT 1 CHECK (rounding_unit_rial IN (1,10,100,1000,10000)),
    rounding_mode              text NOT NULL DEFAULT 'half_up' CHECK (rounding_mode IN ('half_up','down','up')),
    notify_customers           boolean NOT NULL DEFAULT true,
    full_report_to_group       boolean NOT NULL DEFAULT true,
    periodic_report_enabled    boolean NOT NULL DEFAULT true,
    periodic_report_minutes    integer NOT NULL DEFAULT 30 CHECK (periodic_report_minutes BETWEEN 5 AND 1440),
    expired_periodic_reports   boolean NOT NULL DEFAULT false,
    expired_customer_access    boolean NOT NULL DEFAULT true,
    subscription_end           timestamptz,
    suspended                  boolean NOT NULL DEFAULT false,
    suspended_reason           text,
    created_at                 timestamptz NOT NULL DEFAULT now(),
    updated_at                 timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE store_admins (
    store_id    bigint NOT NULL REFERENCES stores(id),
    tg_user_id  bigint NOT NULL,
    role        text NOT NULL CHECK (role IN ('owner','staff')),
    added_by    bigint,
    added_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (store_id, tg_user_id)
);
CREATE INDEX store_admins_user_idx ON store_admins(tg_user_id);

CREATE TABLE store_counters (
    store_id bigint NOT NULL REFERENCES stores(id),
    name     text NOT NULL,
    value    bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (store_id, name)
);

CREATE TABLE products (
    id                bigserial PRIMARY KEY,
    store_id          bigint NOT NULL REFERENCES stores(id),
    code              text NOT NULL,
    name              text NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
    category          text,
    unit_type         text NOT NULL CHECK (unit_type IN ('count','kg')),
    cash_price_rial   bigint NOT NULL CHECK (cash_price_rial >= 0),
    credit_markup_pct numeric(7,3) NOT NULL DEFAULT 0 CHECK (credit_markup_pct >= 0 AND credit_markup_pct <= 1000),
    is_active         boolean NOT NULL DEFAULT true,
    version           bigint NOT NULL DEFAULT 0,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (store_id, code),
    UNIQUE (store_id, id)
);
CREATE INDEX products_store_name_idx ON products(store_id, lower(name));

CREATE TABLE customers (
    id            bigserial PRIMARY KEY,
    store_id      bigint NOT NULL REFERENCES stores(id),
    code          bigint NOT NULL,
    name          text NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
    phone         text,
    rate_type     text NOT NULL DEFAULT 'cash' CHECK (rate_type IN ('cash','credit')),
    note          text,
    limit_mode    text NOT NULL DEFAULT 'none' CHECK (limit_mode IN ('none','warn','block')),
    limit_rial    bigint CHECK (limit_rial IS NULL OR limit_rial >= 0),
    balance_rial  bigint NOT NULL DEFAULT 0,          -- cache of SUM(ledger_entries.amount_rial); >0 debtor
    version       bigint NOT NULL DEFAULT 0,          -- bumped on every financial change (optimistic check)
    archived_at   timestamptz,
    created_by    bigint,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (store_id, code),
    UNIQUE (store_id, id),
    CHECK (limit_mode = 'none' OR limit_rial IS NOT NULL)
);
CREATE INDEX customers_store_phone_idx ON customers(store_id, phone);
CREATE INDEX customers_store_name_idx ON customers(store_id, lower(name));

CREATE TABLE invoices (
    id                   bigserial PRIMARY KEY,
    store_id             bigint NOT NULL REFERENCES stores(id),
    number               bigint NOT NULL,
    kind                 text NOT NULL CHECK (kind IN ('cash','account')),
    customer_id          bigint,
    rate_type            text NOT NULL CHECK (rate_type IN ('cash','credit')),
    total_rial           bigint NOT NULL CHECK (total_rial >= 0),
    balance_before_rial  bigint,
    balance_after_rial   bigint,
    credit_used_rial     bigint NOT NULL DEFAULT 0,
    limit_override_by    bigint,
    limit_override_note  text,
    created_by           bigint NOT NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),
    seq                  bigint NOT NULL DEFAULT nextval('fin_event_seq'),
    cancelled_seq        bigint,
    cancelled_at         timestamptz,
    cancelled_by         bigint,
    cancel_reason        text,
    op_id                uuid UNIQUE,
    UNIQUE (store_id, number),
    UNIQUE (store_id, id),
    FOREIGN KEY (store_id, customer_id) REFERENCES customers(store_id, id),
    CHECK (kind = 'cash' OR customer_id IS NOT NULL)
);
CREATE INDEX invoices_store_created_idx ON invoices(store_id, created_at);
CREATE INDEX invoices_customer_idx ON invoices(store_id, customer_id);

CREATE TABLE invoice_lines (
    id               bigserial PRIMARY KEY,
    store_id         bigint NOT NULL,
    invoice_id       bigint NOT NULL,
    line_no          integer NOT NULL,
    product_id       bigint,
    product_code     text NOT NULL,
    product_name     text NOT NULL,
    category         text,
    unit_type        text NOT NULL CHECK (unit_type IN ('count','kg')),
    qty              numeric(14,3) NOT NULL CHECK (qty > 0),
    cash_price_rial  bigint NOT NULL CHECK (cash_price_rial >= 0),
    markup_pct       numeric(7,3) NOT NULL,
    unit_price_rial  bigint NOT NULL CHECK (unit_price_rial >= 0),
    amount_rial      bigint NOT NULL CHECK (amount_rial >= 0),
    UNIQUE (store_id, id),
    UNIQUE (invoice_id, line_no),
    FOREIGN KEY (store_id, invoice_id) REFERENCES invoices(store_id, id),
    FOREIGN KEY (store_id, product_id) REFERENCES products(store_id, id)
);

CREATE TABLE payments (
    id                  bigserial PRIMARY KEY,
    store_id            bigint NOT NULL,
    number              bigint NOT NULL,
    customer_id         bigint NOT NULL,
    amount_rial         bigint NOT NULL CHECK (amount_rial > 0),
    balance_before_rial bigint NOT NULL,
    balance_after_rial  bigint NOT NULL,
    note                text,
    created_by          bigint NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT now(),
    seq                 bigint NOT NULL DEFAULT nextval('fin_event_seq'),
    cancelled_seq       bigint,
    cancelled_at        timestamptz,
    cancelled_by        bigint,
    cancel_reason       text,
    replaced_by         bigint REFERENCES payments(id),
    replaces            bigint REFERENCES payments(id),
    op_id               uuid UNIQUE,
    UNIQUE (store_id, number),
    UNIQUE (store_id, id),
    FOREIGN KEY (store_id, customer_id) REFERENCES customers(store_id, id)
);
CREATE INDEX payments_store_created_idx ON payments(store_id, created_at);

CREATE TABLE invoice_line_changes (
    id            bigserial PRIMARY KEY,
    store_id      bigint NOT NULL,
    invoice_id    bigint NOT NULL,
    line_id       bigint NOT NULL,
    kind          text NOT NULL CHECK (kind IN ('return','correction')),
    qty_delta     numeric(14,3) NOT NULL CHECK (qty_delta <> 0),
    amount_delta  bigint NOT NULL,
    refund_mode   text CHECK (refund_mode IN ('cash','account')),
    reason        text NOT NULL,
    created_by    bigint NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    seq           bigint NOT NULL DEFAULT nextval('fin_event_seq'),
    op_id         uuid,
    UNIQUE (store_id, id),
    FOREIGN KEY (store_id, invoice_id) REFERENCES invoices(store_id, id),
    FOREIGN KEY (store_id, line_id) REFERENCES invoice_lines(store_id, id),
    CHECK (kind <> 'return' OR (qty_delta < 0 AND amount_delta <= 0 AND refund_mode IS NOT NULL))
);
CREATE INDEX line_changes_invoice_idx ON invoice_line_changes(store_id, invoice_id);

-- The ledger is the source of truth for customer balances. Rows are append-only.
CREATE TABLE ledger_entries (
    id                 bigserial PRIMARY KEY,
    store_id           bigint NOT NULL,
    customer_id        bigint NOT NULL,
    kind               text NOT NULL CHECK (kind IN ('opening','sale','payment','return','correction','reversal')),
    amount_rial        bigint NOT NULL,                  -- +debt / -debt
    effective_date     date,                             -- for opening balance
    invoice_id         bigint,
    payment_id         bigint,
    line_change_id     bigint,
    reverses_entry_id  bigint REFERENCES ledger_entries(id),
    note               text,
    created_by         bigint NOT NULL,
    created_at         timestamptz NOT NULL DEFAULT now(),
    seq                bigint NOT NULL DEFAULT nextval('fin_event_seq'),
    op_id              uuid,
    FOREIGN KEY (store_id, customer_id) REFERENCES customers(store_id, id),
    FOREIGN KEY (store_id, invoice_id) REFERENCES invoices(store_id, id),
    FOREIGN KEY (store_id, payment_id) REFERENCES payments(store_id, id),
    FOREIGN KEY (store_id, line_change_id) REFERENCES invoice_line_changes(store_id, id),
    CHECK (amount_rial <> 0 OR kind IN ('opening','reversal'))
);
CREATE INDEX ledger_customer_idx ON ledger_entries(store_id, customer_id, seq);
CREATE UNIQUE INDEX ledger_one_reversal ON ledger_entries(reverses_entry_id) WHERE reverses_entry_id IS NOT NULL;

CREATE OR REPLACE FUNCTION ledger_no_update() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'ledger_entries is append-only';
END $$;
CREATE TRIGGER ledger_entries_append_only BEFORE UPDATE OR DELETE ON ledger_entries
  FOR EACH ROW EXECUTE FUNCTION ledger_no_update();
CREATE TRIGGER line_changes_append_only BEFORE UPDATE OR DELETE ON invoice_line_changes
  FOR EACH ROW EXECUTE FUNCTION ledger_no_update();

-- Multi-step confirmations / idempotency for financial operations.
CREATE TABLE pending_ops (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id          bigint NOT NULL REFERENCES stores(id),
    actor_tg_id       bigint NOT NULL,
    kind              text NOT NULL,
    payload           jsonb NOT NULL,
    step              integer NOT NULL DEFAULT 1,
    customer_id       bigint,
    customer_version  bigint,
    status            text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','done','cancelled','expired')),
    result            jsonb,
    created_at        timestamptz NOT NULL DEFAULT now(),
    expires_at        timestamptz NOT NULL DEFAULT now() + interval '20 minutes',
    done_at           timestamptz
);
CREATE INDEX pending_ops_status_idx ON pending_ops(status, expires_at);

CREATE TABLE audit_log (
    id          bigserial PRIMARY KEY,
    store_id    bigint,
    actor_tg_id bigint,
    action      text NOT NULL,
    details     jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_store_idx ON audit_log(store_id, created_at);

CREATE TABLE customer_links (
    store_id       bigint NOT NULL,
    tg_user_id     bigint NOT NULL,
    customer_id    bigint NOT NULL,
    phone_at_link  text NOT NULL,
    linked_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (store_id, tg_user_id),
    UNIQUE (store_id, customer_id),
    FOREIGN KEY (store_id, customer_id) REFERENCES customers(store_id, id)
);

-- Telegram plumbing
CREATE TABLE processed_updates (
    bot_tg_id    bigint NOT NULL,
    update_id    bigint NOT NULL,
    processed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (bot_tg_id, update_id)
);
CREATE INDEX processed_updates_time_idx ON processed_updates(processed_at);

CREATE TABLE bot_offsets (
    bot_tg_id  bigint PRIMARY KEY,
    next_offset bigint NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE fsm_states (
    bot_tg_id  bigint NOT NULL,
    chat_id    bigint NOT NULL,
    user_id    bigint NOT NULL,
    state      text,
    data       jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (bot_tg_id, chat_id, user_id)
);

-- Transactional outbox (at-least-once delivery)
CREATE TABLE outbox (
    id              bigserial PRIMARY KEY,
    store_id        bigint REFERENCES stores(id),
    via             text NOT NULL CHECK (via IN ('store','central')),
    chat_id         bigint NOT NULL,
    kind            text NOT NULL,
    payload         jsonb NOT NULL DEFAULT '{}'::jsonb,
    content         bytea,
    parent_id       bigint REFERENCES outbox(id),
    part_no         integer,
    dedupe_key      text UNIQUE,
    status          text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','sending','sent','failed','expanded','cancelled')),
    attempts        integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    locked_until    timestamptz,
    last_error      text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    sent_at         timestamptz
);
CREATE INDEX outbox_due_idx ON outbox(next_attempt_at) WHERE status IN ('pending','sending');
CREATE INDEX outbox_store_status_idx ON outbox(store_id, status);

CREATE TABLE report_slots (
    store_id   bigint NOT NULL REFERENCES stores(id),
    slot_start timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (store_id, slot_start)
);

-- Subscriptions (manual approval in v1; payment method intentionally not integrated)
CREATE TABLE subscription_plans (
    id              bigserial PRIMARY KEY,
    kind            text NOT NULL CHECK (kind IN ('package','daily')),
    title           text NOT NULL,
    days            integer CHECK (days IS NULL OR days > 0),
    price_rial      bigint CHECK (price_rial IS NULL OR price_rial >= 0),
    daily_rate_rial bigint CHECK (daily_rate_rial IS NULL OR daily_rate_rial >= 0),
    min_days        integer,
    max_days        integer,
    is_active       boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CHECK ((kind = 'package' AND days IS NOT NULL AND price_rial IS NOT NULL)
        OR (kind = 'daily' AND daily_rate_rial IS NOT NULL AND min_days > 0 AND max_days >= min_days))
);

CREATE TABLE store_plan_prices (
    store_id   bigint NOT NULL REFERENCES stores(id),
    plan_id    bigint NOT NULL REFERENCES subscription_plans(id),
    price_rial bigint NOT NULL CHECK (price_rial >= 0),   -- package: total price; daily: per-day rate
    PRIMARY KEY (store_id, plan_id)
);

CREATE TABLE subscription_requests (
    id           bigserial PRIMARY KEY,
    store_id     bigint NOT NULL REFERENCES stores(id),
    plan_id      bigint REFERENCES subscription_plans(id),
    days         integer NOT NULL CHECK (days > 0),
    price_rial   bigint NOT NULL CHECK (price_rial >= 0),
    status       text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','cancelled')),
    requested_by bigint NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    decided_by   bigint,
    decided_at   timestamptz,
    note         text
);

CREATE TABLE subscription_periods (
    id          bigserial PRIMARY KEY,
    store_id    bigint NOT NULL REFERENCES stores(id),
    start_at    timestamptz NOT NULL,
    end_at      timestamptz NOT NULL,
    days        integer NOT NULL,
    price_rial  bigint NOT NULL DEFAULT 0,
    source      text NOT NULL CHECK (source IN ('initial','request','grant')),
    request_id  bigint REFERENCES subscription_requests(id) UNIQUE,
    created_by  bigint NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CHECK (end_at > start_at)
);

CREATE TABLE subscription_reminders (
    store_id    bigint NOT NULL REFERENCES stores(id),
    end_at      timestamptz NOT NULL,
    days_before integer NOT NULL,
    sent_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (store_id, end_at, days_before)
);

CREATE TABLE support_grants (
    id          bigserial PRIMARY KEY,
    store_id    bigint NOT NULL REFERENCES stores(id),
    granted_by  bigint NOT NULL,
    granted_to  bigint NOT NULL,
    expires_at  timestamptz NOT NULL,
    revoked_at  timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE backup_runs (
    id          bigserial PRIMARY KEY,
    status      text NOT NULL CHECK (status IN ('ok','failed')),
    file_name   text,
    size_bytes  bigint,
    remote      text,
    message     text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    notified    boolean NOT NULL DEFAULT false
);
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/__init__.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""ShopBots: multi-tenant Telegram shop bot platform."""
__version__ = "1.0.0"
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/__main__.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Entry point: python -m shopbots <command>

  migrate            apply pending SQL migrations (transactional, locked)
  serve              run pollers, scheduler and outbox worker (systemd service)
  keycheck           verify master key file permissions and that it decrypts stored tokens
  rotate-key         add a new encryption key (old keys kept so tokens stay readable)
  reconcile          print customers whose cached balance disagrees with the ledger
  rebuild-balances   repair cached balances from the ledger (idempotent)
  newkey             print a new Fernet key (for rotate-key)
"""
from __future__ import annotations

import asyncio
import logging
import signal
import sys

from .config import load_config
from .crypto import KeyFileError, TokenCipher
from .db import create_pool, migrate
from .log import setup_logging

log = logging.getLogger("shopbots")


async def cmd_migrate(cfg):
    applied = await migrate(cfg.database_url)
    print(f"migrations applied: {len(applied)}")


async def cmd_serve(cfg):
    from .runtime import Runtime
    cipher = TokenCipher.from_file(cfg.master_key_file)
    central = cfg.central_token()
    pool = await create_pool(cfg.database_url)
    rt = Runtime(cfg, pool, cipher, central)
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, lambda: asyncio.create_task(rt.shutdown()))
    log.info("shopbots started")
    try:
        await rt.run()
    finally:
        await pool.close()


async def cmd_keycheck(cfg):
    cipher = TokenCipher.from_file(cfg.master_key_file)
    pool = await create_pool(cfg.database_url, min_size=1, max_size=2)
    rows = await pool.fetch("SELECT id, bot_token_enc FROM stores WHERE bot_token_enc IS NOT NULL")
    bad = 0
    for r in rows:
        try:
            cipher.decrypt(r["bot_token_enc"])
        except KeyFileError:
            bad += 1
    await pool.close()
    print(f"keys ok; stores checked: {len(rows)}; undecryptable: {bad}")
    return 1 if bad else 0


async def cmd_reconcile(cfg, rebuild: bool):
    from .domain import ledger
    pool = await create_pool(cfg.database_url, min_size=1, max_size=2)
    async with pool.acquire() as conn:
        if rebuild:
            async with conn.transaction():
                n = await ledger.rebuild_balances(conn)
            print(f"rebuilt {n} balances")
        bad = await ledger.reconcile(conn)
    await pool.close()
    print(f"mismatches: {len(bad)}")
    for r in bad:
        print(f"store={r['store_id']} customer={r['id']} cached={r['balance_rial']} ledger={r['ledger_sum']}")
    return 1 if bad else 0


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "serve"
    cfg = load_config()
    setup_logging(cfg.log_dir, cfg.log_level)
    if cmd == "migrate":
        asyncio.run(cmd_migrate(cfg))
    elif cmd == "serve":
        asyncio.run(cmd_serve(cfg))
    elif cmd == "keycheck":
        return asyncio.run(cmd_keycheck(cfg))
    elif cmd == "reconcile":
        return asyncio.run(cmd_reconcile(cfg, rebuild="--rebuild" in argv))
    elif cmd == "newkey":
        print(TokenCipher.generate_key().decode())
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/config.py" 0644 <<'SHOPBOTS_FILE_EOF'
from __future__ import annotations

import os
from dataclasses import dataclass


def _env(name: str, default: str | None = None) -> str:
    v = os.environ.get(name, default)
    if v is None:
        raise RuntimeError(f"missing required setting {name}")
    return v


@dataclass(frozen=True)
class Config:
    database_url: str
    owner_id: int
    secrets_dir: str
    log_dir: str
    data_dir: str
    log_level: str
    outbox_max_attempts: int
    report_text_max_parts: int
    instance_name: str

    @property
    def master_key_file(self) -> str:
        return os.path.join(self.secrets_dir, "master.key")

    @property
    def central_token_file(self) -> str:
        return os.path.join(self.secrets_dir, "central_bot_token")

    def central_token(self) -> str:
        with open(self.central_token_file, "r", encoding="utf-8") as fh:
            return fh.read().strip()


def load_config() -> Config:
    return Config(
        database_url=_env("SHOPBOTS_DATABASE_URL", "postgresql:///shopbots?host=/var/run/postgresql"),
        owner_id=int(_env("SHOPBOTS_OWNER_ID")),
        secrets_dir=_env("SHOPBOTS_SECRETS_DIR", "/etc/shopbots/secrets"),
        log_dir=_env("SHOPBOTS_LOG_DIR", "/var/log/shopbots"),
        data_dir=_env("SHOPBOTS_DATA_DIR", "/var/lib/shopbots"),
        log_level=_env("SHOPBOTS_LOG_LEVEL", "INFO"),
        outbox_max_attempts=int(_env("SHOPBOTS_OUTBOX_MAX_ATTEMPTS", "12")),
        report_text_max_parts=int(_env("SHOPBOTS_REPORT_TEXT_MAX_PARTS", "15")),
        instance_name=_env("SHOPBOTS_INSTANCE", "shopbots"),
    )
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/crypto.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Bot-token encryption. Keys live in a separate root/service-only file, one Fernet key
per line; the first line encrypts, all lines decrypt (supports rotation)."""
from __future__ import annotations

import os
import stat

from cryptography.fernet import Fernet, InvalidToken, MultiFernet


class KeyFileError(RuntimeError):
    pass


class TokenCipher:
    def __init__(self, keys: list[bytes]):
        if not keys:
            raise KeyFileError("no encryption keys")
        self._f = MultiFernet([Fernet(k) for k in keys])

    @classmethod
    def from_file(cls, path: str, *, check_perms: bool = True) -> "TokenCipher":
        try:
            st = os.stat(path)
        except FileNotFoundError:
            raise KeyFileError(f"key file not found: {path}")
        if check_perms and (st.st_mode & (stat.S_IRWXG | stat.S_IRWXO)):
            raise KeyFileError(f"key file {path} must not be accessible by group/others (chmod 400)")
        with open(path, "rb") as fh:
            keys = [ln.strip() for ln in fh.read().splitlines() if ln.strip() and not ln.startswith(b"#")]
        return cls(keys)

    @staticmethod
    def generate_key() -> bytes:
        return Fernet.generate_key()

    def encrypt(self, plaintext: str) -> bytes:
        return self._f.encrypt(plaintext.encode())

    def decrypt(self, token: bytes) -> str:
        try:
            return self._f.decrypt(bytes(token)).decode()
        except InvalidToken:
            raise KeyFileError("cannot decrypt token: wrong or missing key")

    def rotate(self, token: bytes) -> bytes:
        return self._f.rotate(bytes(token))


def bot_id_from_token(token: str) -> int | None:
    head, sep, tail = (token or "").strip().partition(":")
    if not sep or not head.isdigit() or len(tail) < 30:
        return None
    return int(head)
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/db.py" 0644 <<'SHOPBOTS_FILE_EOF'
from __future__ import annotations

import contextlib
import json
import logging
import os
from typing import AsyncIterator

import asyncpg

log = logging.getLogger(__name__)
MIGRATION_LOCK = -7_000_000_001
MIGRATIONS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "migrations")


async def _init_conn(conn: asyncpg.Connection) -> None:
    await conn.set_type_codec("jsonb", encoder=json.dumps, decoder=json.loads, schema="pg_catalog")
    await conn.set_type_codec("json", encoder=json.dumps, decoder=json.loads, schema="pg_catalog")


async def create_pool(dsn: str, *, min_size: int = 2, max_size: int = 20) -> asyncpg.Pool:
    return await asyncpg.create_pool(dsn, min_size=min_size, max_size=max_size, init=_init_conn,
                                     command_timeout=60)


@contextlib.asynccontextmanager
async def tx(pool: asyncpg.Pool, isolation: str = "read_committed") -> AsyncIterator[asyncpg.Connection]:
    async with pool.acquire() as conn:
        async with conn.transaction(isolation=isolation):
            yield conn


async def migrate(dsn: str, directory: str = MIGRATIONS_DIR) -> list[str]:
    conn = await asyncpg.connect(dsn)
    applied_now: list[str] = []
    try:
        await conn.execute("SELECT pg_advisory_lock($1)", MIGRATION_LOCK)
        await conn.execute("""CREATE TABLE IF NOT EXISTS schema_migrations(
            version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())""")
        done = {r["version"] for r in await conn.fetch("SELECT version FROM schema_migrations")}
        for name in sorted(f for f in os.listdir(directory) if f.endswith(".sql")):
            version = name[:-4]
            if version in done:
                continue
            with open(os.path.join(directory, name), encoding="utf-8") as fh:
                sql = fh.read()
            async with conn.transaction():
                await conn.execute(sql)
                await conn.execute("INSERT INTO schema_migrations(version) VALUES($1)", version)
            log.info("applied migration %s", version)
            applied_now.append(version)
    finally:
        await conn.execute("SELECT pg_advisory_unlock($1)", MIGRATION_LOCK)
        await conn.close()
    return applied_now
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/domain/__init__.py" 0644 <<'SHOPBOTS_FILE_EOF'
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/domain/common.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Shared domain helpers. Every query that touches tenant data takes store_id from the
trusted context (resolved from the bot that received the update), never from user input."""
from __future__ import annotations

import datetime as dt
import json
from dataclasses import dataclass
from typing import Any

import asyncpg

from ..errors import UserError
from ..timefmt import now_utc


@dataclass(frozen=True)
class Store:
    id: int
    name: str
    contact: str | None
    currency: str
    timezone: str
    jalali: bool
    rounding_unit_rial: int
    rounding_mode: str
    report_chat_id: int | None
    report_chat_title: str | None
    notify_customers: bool
    full_report_to_group: bool
    periodic_report_enabled: bool
    periodic_report_minutes: int
    expired_periodic_reports: bool
    expired_customer_access: bool
    subscription_end: dt.datetime | None
    suspended: bool
    suspended_reason: str | None
    is_enabled: bool
    bot_username: str | None
    bot_status: str

    @classmethod
    def from_row(cls, r: asyncpg.Record) -> "Store":
        return cls(**{f: r[f] for f in cls.__dataclass_fields__})

    def subscription_active(self, at: dt.datetime | None = None) -> bool:
        at = at or now_utc()
        return self.subscription_end is not None and self.subscription_end > at

    def writable(self, at: dt.datetime | None = None) -> bool:
        return self.is_enabled and not self.suspended and self.subscription_active(at)

    def write_block_reason(self) -> str | None:
        if not self.is_enabled:
            return "این فروشگاه توسط مدیر سامانه غیرفعال شده است."
        if self.suspended:
            return "اشتراک فروشگاه تعلیق شده است" + (f": {self.suspended_reason}" if self.suspended_reason else ".")
        if not self.subscription_active():
            return "اشتراک فروشگاه منقضی شده است. مشاهده حساب‌ها و دریافت خروجی همچنان ممکن است."
        return None


async def load_store(conn: asyncpg.Connection, store_id: int, *, for_update: bool = False) -> Store:
    r = await conn.fetchrow("SELECT * FROM stores WHERE id=$1" + (" FOR SHARE" if for_update else ""), store_id)
    if r is None:
        raise UserError("فروشگاه یافت نشد.")
    return Store.from_row(r)


async def require_writable(conn: asyncpg.Connection, store_id: int) -> Store:
    """Locks the store row in SHARE mode so a concurrent suspend waits for us."""
    st = await load_store(conn, store_id, for_update=True)
    reason = st.write_block_reason()
    if reason:
        raise UserError(reason)
    return st


async def next_counter(conn: asyncpg.Connection, store_id: int, name: str) -> int:
    """Gap-tolerant, never-reused, concurrency-safe per-store counter (row lock)."""
    v = await conn.fetchval(
        """INSERT INTO store_counters(store_id, name, value) VALUES($1,$2,1)
           ON CONFLICT (store_id, name) DO UPDATE SET value = store_counters.value + 1
           RETURNING value""", store_id, name)
    return int(v)


async def audit(conn: asyncpg.Connection, store_id: int | None, actor: int | None, action: str,
                details: dict[str, Any] | None = None) -> None:
    await conn.execute("INSERT INTO audit_log(store_id, actor_tg_id, action, details) VALUES($1,$2,$3,$4)",
                       store_id, actor, action, json.loads(json.dumps(details or {}, default=str)))


async def role_of(conn: asyncpg.Connection, store_id: int, tg_user_id: int) -> str | None:
    return await conn.fetchval("SELECT role FROM store_admins WHERE store_id=$1 AND tg_user_id=$2",
                               store_id, tg_user_id)


async def require_admin(conn: asyncpg.Connection, store_id: int, tg_user_id: int, *, owner: bool = False) -> str:
    role = await role_of(conn, store_id, tg_user_id)
    if role is None or (owner and role != "owner"):
        from ..errors import AccessDenied
        raise AccessDenied("شما مجوز این کار را ندارید.")
    return role
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/domain/corrections.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Corrections, cancellations and returns with three separate confirmations.

Nothing financial is written before the 3rd confirmation. Every step re-evaluates the
change against the current DB state; if the fingerprint (customer version + record state)
changed, the flow is reset to step 1 with fresh numbers. Originals are never deleted or
overwritten: we append reversal / correction ledger entries and line-change rows."""
from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field
from decimal import Decimal

import asyncpg

from ..errors import AlreadyDone, UserError
from ..money import fmt_balance, fmt_money, line_amount
from ..textutil import esc, fa, fmt_qty
from ..timefmt import fmt_dt
from . import ledger, notify, pendingops
from .common import Store, audit, load_store, require_writable

KINDS = ("cancel_invoice", "cancel_payment", "edit_payment", "edit_opening", "line_correction", "line_return")
TITLES = {
    "cancel_invoice": "لغو فاکتور", "cancel_payment": "لغو پرداخت", "edit_payment": "اصلاح مبلغ پرداخت",
    "edit_opening": "اصلاح مانده اول دوره", "line_correction": "اصلاح مقدار قلم فاکتور", "line_return": "مرجوعی",
}


@dataclass
class Evaluation:
    customer_id: int | None
    fingerprint: str
    record_lines: list[str]
    change_lines: list[str]
    balance_before: int | None = None
    ledger_delta: int = 0
    cash_effect: int = 0          # + customer pays cash to shop, - shop refunds cash
    extra: dict = field(default_factory=dict)

    @property
    def balance_after(self) -> int | None:
        return None if self.balance_before is None else self.balance_before + self.ledger_delta


async def _customer(conn, store_id, cid, lock):
    if cid is None:
        return None
    if lock:
        return await ledger.lock_customer(conn, store_id, cid)
    return await conn.fetchrow("SELECT * FROM customers WHERE store_id=$1 AND id=$2", store_id, cid)


async def _invoice(conn, store_id, invoice_id, lock):
    inv = await conn.fetchrow("SELECT * FROM invoices WHERE store_id=$1 AND id=$2" + (" FOR UPDATE" if lock else ""),
                              store_id, invoice_id)
    if inv is None:
        raise UserError("فاکتور یافت نشد.")
    return inv


async def _line_state(conn, store_id, line_id):
    ln = await conn.fetchrow("SELECT * FROM invoice_lines WHERE store_id=$1 AND id=$2", store_id, line_id)
    if ln is None:
        raise UserError("قلم فاکتور یافت نشد.")
    agg = await conn.fetchrow("SELECT COALESCE(SUM(qty_delta),0) q, COALESCE(SUM(amount_delta),0) a, count(*) n "
                              "FROM invoice_line_changes WHERE store_id=$1 AND line_id=$2", store_id, line_id)
    return ln, Decimal(ln["qty"]) + Decimal(agg["q"]), int(ln["amount_rial"]) + int(agg["a"]), int(agg["n"])


def _fp(*parts) -> str:
    return "|".join(str(p) for p in parts)


async def evaluate(conn: asyncpg.Connection, store: Store, kind: str, payload: dict, *, lock: bool = False) -> Evaluation:
    sid = store.id
    cur = store.currency
    if kind in ("cancel_invoice", "line_correction", "line_return"):
        inv_id = int(payload["invoice_id"])
        inv0 = await _invoice(conn, sid, inv_id, False)
        cust = await _customer(conn, sid, inv0["customer_id"], lock)   # lock order: customer, then invoice
        inv = await _invoice(conn, sid, inv_id, lock)
        if inv["cancelled_seq"]:
            raise UserError("این فاکتور قبلاً لغو شده است.")
        nchanges = await conn.fetchval("SELECT count(*) FROM invoice_line_changes WHERE store_id=$1 AND invoice_id=$2",
                                       sid, inv_id)
        rec = [f"فاکتور <b>#{fa(inv['number'])}</b> ({'نقدی' if inv['kind'] == 'cash' else 'به حساب'}) | "
               f"{fmt_dt(inv['created_at'], store.timezone, store.jalali)}",
               f"مبلغ فاکتور: {fmt_money(inv['total_rial'], cur)}"]
        if cust:
            rec.append(f"مشتری: {esc(cust['name'])} (کد {fa(cust['code'])})")
        fp_base = _fp(cust["version"] if cust else "-", inv["cancelled_seq"], nchanges)
        bal = cust["balance_rial"] if cust else None
        if kind == "cancel_invoice":
            if nchanges:
                raise UserError("برای این فاکتور مرجوعی/اصلاح ثبت شده است؛ لغو کامل ممکن نیست. "
                                "اقلام باقی‌مانده را با مرجوعی برگردانید.")
            if inv["kind"] == "account":
                return Evaluation(cust["id"], fp_base, rec, ["درخواست: <b>لغو کامل فاکتور</b>"], bal, -int(inv["total_rial"]))
            return Evaluation(inv["customer_id"], fp_base, rec,
                              ["درخواست: <b>لغو کامل فاکتور نقدی</b> (برگشت وجه نقد به مشتری خارج از ربات)"],
                              bal, 0, -int(inv["total_rial"]))
        ln, eff_qty, eff_amount, _ = await _line_state(conn, sid, int(payload["line_id"]))
        if ln["invoice_id"] != inv_id:
            raise UserError("قلم فاکتور نامعتبر است.")
        rec.append(f"قلم: {esc(ln['product_name'])} | مقدار فعلی {fmt_qty(eff_qty, ln['unit_type'])} | "
                   f"مبلغ فعلی {fmt_money(eff_amount, cur)}")
        fp = _fp(fp_base, eff_qty, eff_amount)
        if kind == "line_return":
            qty = Decimal(str(payload["qty"]))
            if qty <= 0 or qty > eff_qty:
                raise UserError(f"مقدار مرجوعی باید بیشتر از صفر و حداکثر {fmt_qty(eff_qty, ln['unit_type'])} باشد.")
            if ln["unit_type"] == "count" and qty != qty.to_integral_value():
                raise UserError("برای کالای تعدادی، مقدار باید عدد صحیح باشد.")
            amount = eff_amount if qty == eff_qty else min(eff_amount, line_amount(
                ln["unit_price_rial"], qty, store.rounding_unit_rial, store.rounding_mode))
            mode = payload.get("refund_mode") or "account"
            if inv["kind"] == "account":
                mode = "account"
            if mode == "account" and cust is None:
                raise UserError("مرجوعی اعتباری فقط برای فاکتور متصل به مشتری ممکن است.")
            change = [f"درخواست: <b>مرجوعی</b> {fmt_qty(qty, ln['unit_type'])} به مبلغ {fmt_money(amount, cur)}",
                      "نوع برگشت: " + ("<b>اعتبار به حساب مشتری</b>" if mode == "account" else "<b>برگشت نقدی</b> (خارج از ربات)")]
            ev = Evaluation(inv["customer_id"], fp, rec, change, bal,
                            -amount if mode == "account" else 0, 0 if mode == "account" else -amount)
            ev.extra = {"qty": str(qty), "amount": amount, "mode": mode, "line_id": ln["id"]}
            return ev
        # line_correction
        new_qty = Decimal(str(payload["new_qty"]))
        if new_qty < 0 or (ln["unit_type"] == "count" and new_qty != new_qty.to_integral_value()):
            raise UserError("مقدار جدید نامعتبر است.")
        if new_qty == eff_qty:
            raise UserError("مقدار جدید با مقدار فعلی یکسان است.")
        target = 0 if new_qty == 0 else line_amount(ln["unit_price_rial"], new_qty, store.rounding_unit_rial,
                                                     store.rounding_mode)
        delta = target - eff_amount
        change = [f"درخواست: تغییر مقدار از {fmt_qty(eff_qty, ln['unit_type'])} به <b>{fmt_qty(new_qty, ln['unit_type'])}</b>",
                  f"مبلغ قلم: {fmt_money(eff_amount, cur)} ← <b>{fmt_money(target, cur)}</b> (قیمت واحد زمان فروش)"]
        ev = Evaluation(inv["customer_id"], fp, rec, change, bal,
                        delta if inv["kind"] == "account" else 0, 0 if inv["kind"] == "account" else delta)
        ev.extra = {"qty_delta": str(new_qty - eff_qty), "amount_delta": delta, "line_id": ln["id"]}
        return ev

    if kind in ("cancel_payment", "edit_payment"):
        p0 = await conn.fetchrow("SELECT * FROM payments WHERE store_id=$1 AND id=$2", sid, int(payload["payment_id"]))
        if p0 is None:
            raise UserError("پرداخت یافت نشد.")
        cust = await _customer(conn, sid, p0["customer_id"], lock)
        p = await conn.fetchrow("SELECT * FROM payments WHERE store_id=$1 AND id=$2" + (" FOR UPDATE" if lock else ""),
                                sid, p0["id"])
        if p["cancelled_seq"]:
            raise UserError("این پرداخت قبلاً لغو یا اصلاح شده است.")
        rec = [f"پرداخت <b>#{fa(p['number'])}</b> | {fmt_dt(p['created_at'], store.timezone, store.jalali)}",
               f"مبلغ: {fmt_money(p['amount_rial'], cur)}", f"مشتری: {esc(cust['name'])} (کد {fa(cust['code'])})"]
        fp = _fp(cust["version"], p["cancelled_seq"])
        if kind == "cancel_payment":
            return Evaluation(cust["id"], fp, rec, ["درخواست: <b>لغو پرداخت</b>"], cust["balance_rial"], int(p["amount_rial"]))
        new = int(payload["new_amount"])
        if new <= 0:
            raise UserError("مبلغ جدید باید مثبت باشد. برای حذف اثر پرداخت از «لغو پرداخت» استفاده کنید.")
        if new == p["amount_rial"]:
            raise UserError("مبلغ جدید با مبلغ فعلی یکسان است.")
        return Evaluation(cust["id"], fp, rec,
                          [f"درخواست: اصلاح مبلغ از {fmt_money(p['amount_rial'], cur)} به <b>{fmt_money(new, cur)}</b>"],
                          cust["balance_rial"], int(p["amount_rial"]) - new)

    if kind == "edit_opening":
        cust = await _customer(conn, sid, int(payload["customer_id"]), lock)
        if cust is None:
            raise UserError("مشتری یافت نشد.")
        from .customers import active_opening
        cur_open = await active_opening(conn, sid, cust["id"])
        old = int(cur_open["amount_rial"]) if cur_open else 0
        new = int(payload["new_amount"])
        if new == old:
            raise UserError("مانده جدید با مانده فعلی اول دوره یکسان است.")
        rec = [f"مشتری: {esc(cust['name'])} (کد {fa(cust['code'])})",
               f"مانده اول دوره فعلی: {fmt_balance(old, cur)}"]
        return Evaluation(cust["id"], _fp(cust["version"], cur_open["id"] if cur_open else 0), rec,
                          [f"درخواست: مانده اول دوره جدید <b>{fmt_balance(new, cur)}</b>"], cust["balance_rial"], new - old,
                          extra={"old_entry_id": cur_open["id"] if cur_open else None, "old": old, "new": new})
    raise UserError("نوع عملیات نامعتبر است.")


def step_text(store: Store, kind: str, ev: Evaluation, step: int, reason: str, *, refreshed: bool = False) -> str:
    cur = store.currency
    out = []
    if refreshed:
        out.append("⚠️ <b>حساب یا رکورد بین مراحل تغییر کرد؛ محاسبه تازه شد و تأییدها از ابتدا لازم است.</b>\n")
    out.append(f"✏️ <b>{TITLES[kind]}</b> | مرحله {fa(step)} از ۳")
    out.append("┄┄┄┄┄┄┄┄┄┄┄┄")
    if step == 1:
        out += ev.record_lines + [""] + ev.change_lines + [f"دلیل: {esc(reason)}", "", "❓ <b>آیا مطمئنی؟</b>"]
    elif step == 2:
        out.append("<b>اثر دقیق بر مانده:</b>")
        if ev.balance_before is not None:
            out.append(f"مانده فعلی: {fmt_balance(ev.balance_before, cur)}")
            out.append(f"تغییر مانده: <b>{fmt_money(ev.ledger_delta, cur, signed=True)}</b>")
            out.append(f"مانده پس از ثبت: <b>{fmt_balance(ev.balance_after, cur)}</b>")
        else:
            out.append("این فاکتور به حساب مشتری متصل نیست؛ مانده هیچ حسابی تغییر نمی‌کند.")
        if ev.cash_effect:
            out.append(("💵 وجه نقدی که باید به مشتری برگردانید: " if ev.cash_effect < 0 else "💵 وجه نقدی که باید از مشتری بگیرید: ")
                       + f"<b>{fmt_money(abs(ev.cash_effect), cur)}</b>")
        out += ["", "❓ <b>آیا تأیید می‌کنی؟</b>"]
    else:
        out += ["<b>خلاصه نهایی:</b>"] + ev.change_lines
        if ev.balance_before is not None:
            out.append(f"مانده: {fmt_balance(ev.balance_before, cur)} ← <b>{fmt_balance(ev.balance_after, cur)}</b>")
        out += [f"دلیل: {esc(reason)}",
                "رکورد اصلی حذف نمی‌شود؛ یک رویداد اصلاحی با اطلاعات قبل/بعد، زمان، دلیل و شناسه شما ثبت می‌شود "
                "و گزارش به‌روز ارسال خواهد شد.", "", "❗️ <b>تأیید نهایی؟</b>"]
    return "\n".join(out)


async def start(conn: asyncpg.Connection, store_id: int, actor: int, kind: str, payload: dict) -> tuple[str, str]:
    if kind not in KINDS:
        raise UserError("نوع عملیات نامعتبر است.")
    store = await require_writable(conn, store_id)
    reason = (payload.get("reason") or "").strip()
    if len(reason) < 3:
        raise UserError("دلیل تغییر را وارد کنید (حداقل ۳ نویسه).")
    ev = await evaluate(conn, store, kind, payload)
    payload = {**payload, "fp": ev.fingerprint}
    op_id = await pendingops.create(conn, store_id=store_id, actor=actor, kind=kind, payload=payload,
                                    customer_id=ev.customer_id)
    return str(op_id), step_text(store, kind, ev, 1, reason)


async def advance(pool: asyncpg.Pool, store_id: int, actor: int, op_id, confirmed_step: int) -> dict:
    """Handle the confirmation of `confirmed_step` (1, 2 or 3). Returns {"text", "step", "done"}."""
    async with pool.acquire() as conn:
        try:
            async with conn.transaction():
                op = await pendingops.lock_for_actor(conn, op_id, store_id=store_id, actor=actor)
                if op["kind"] not in KINDS:
                    raise UserError(pendingops.EXPIRED_MSG)
                if op["step"] != confirmed_step:
                    raise UserError("این دکمه مربوط به مرحله دیگری است. از پیام آخر استفاده کنید.")
                store = await require_writable(conn, store_id)
                payload = dict(op["payload"])
                final = confirmed_step == 3
                ev = await evaluate(conn, store, op["kind"], payload, lock=final)
                if ev.fingerprint != payload["fp"]:
                    payload["fp"] = ev.fingerprint
                    await pendingops.set_step(conn, op_id, 1, payload=payload)
                    return {"text": step_text(store, op["kind"], ev, 1, payload["reason"], refreshed=True),
                            "step": 1, "done": False}
                if not final:
                    await pendingops.set_step(conn, op_id, confirmed_step + 1)
                    return {"text": step_text(store, op["kind"], ev, confirmed_step + 1, payload["reason"]),
                            "step": confirmed_step + 1, "done": False}
                result = await _apply(conn, store, actor, op, ev, payload)
                await pendingops.finish(conn, op_id, result)
                return {**result, "done": True}
        except AlreadyDone as e:
            return {**(e.result or {}), "done": True, "already": True}


async def _apply(conn, store: Store, actor: int, op, ev: Evaluation, payload: dict) -> dict:
    kind, sid, op_id, reason = op["kind"], store.id, op["id"], payload["reason"]
    details = {"op_id": str(op_id), "kind": kind, "reason": reason, "payload": payload,
               "balance_before": ev.balance_before, "balance_after": ev.balance_after,
               "ledger_delta": ev.ledger_delta, "cash_effect": ev.cash_effect}
    ref = ""
    if kind == "cancel_invoice":
        inv = await _invoice(conn, sid, int(payload["invoice_id"]), True)
        seq = await conn.fetchval("SELECT nextval('fin_event_seq')")
        await conn.execute("UPDATE invoices SET cancelled_seq=$3, cancelled_at=now(), cancelled_by=$4, cancel_reason=$5 "
                           "WHERE store_id=$1 AND id=$2 AND cancelled_seq IS NULL", sid, inv["id"], seq, actor, reason)
        ref = f"INV-{inv['number']}"
        if inv["kind"] == "account":
            sale = await conn.fetchrow("SELECT * FROM ledger_entries WHERE store_id=$1 AND invoice_id=$2 AND kind='sale'",
                                       sid, inv["id"])
            await ledger.post(conn, store_id=sid, customer_id=inv["customer_id"], kind="reversal",
                              amount_rial=-int(sale["amount_rial"]), actor=actor, op_id=op_id, invoice_id=inv["id"],
                              reverses_entry_id=sale["id"], note=f"لغو فاکتور {inv['number']}: {reason}")
        elif inv["customer_id"]:
            await ledger.bump_version(conn, sid, inv["customer_id"])
        details["before"] = {"status": "active"}
        details["after"] = {"status": "cancelled"}
    elif kind in ("line_return", "line_correction"):
        inv = await _invoice(conn, sid, int(payload["invoice_id"]), True)
        x = ev.extra
        if kind == "line_return":
            qd, ad, mode, ck = -Decimal(x["qty"]), -int(x["amount"]), x["mode"], "return"
        else:
            qd, ad, mode, ck = Decimal(x["qty_delta"]), int(x["amount_delta"]), None, "correction"
        if ad == 0 and ck == "correction" and qd == 0:
            raise UserError("تغییری برای ثبت وجود ندارد.")
        ch = await conn.fetchrow(
            """INSERT INTO invoice_line_changes(store_id, invoice_id, line_id, kind, qty_delta, amount_delta, refund_mode,
                   reason, created_by, op_id) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING *""",
            sid, inv["id"], int(x["line_id"]), ck, qd, ad, mode, reason, actor, op_id)
        ref = f"INV-{inv['number']}/CH-{ch['id']}"
        if ev.ledger_delta:
            await ledger.post(conn, store_id=sid, customer_id=inv["customer_id"],
                              kind="return" if ck == "return" else "correction", amount_rial=ev.ledger_delta,
                              actor=actor, op_id=op_id, invoice_id=inv["id"], line_change_id=ch["id"],
                              note=f"{TITLES[kind]} فاکتور {inv['number']}: {reason}")
        elif inv["customer_id"]:
            await ledger.bump_version(conn, sid, inv["customer_id"])
    elif kind in ("cancel_payment", "edit_payment"):
        p = await conn.fetchrow("SELECT * FROM payments WHERE store_id=$1 AND id=$2 FOR UPDATE", sid, int(payload["payment_id"]))
        entry = await conn.fetchrow("SELECT * FROM ledger_entries WHERE store_id=$1 AND payment_id=$2 AND kind='payment'",
                                    sid, p["id"])
        seq = await conn.fetchval("SELECT nextval('fin_event_seq')")
        await ledger.post(conn, store_id=sid, customer_id=p["customer_id"], kind="reversal",
                          amount_rial=-int(entry["amount_rial"]), actor=actor, op_id=op_id, payment_id=p["id"],
                          reverses_entry_id=entry["id"], note=f"{TITLES[kind]} {p['number']}: {reason}")
        new_id = None
        ref = f"PAY-{p['number']}"
        if kind == "edit_payment":
            from .common import next_counter
            new_amount = int(payload["new_amount"])
            c = await ledger.lock_customer(conn, sid, p["customer_id"])
            number = await next_counter(conn, sid, "payment")
            newp = await conn.fetchrow(
                """INSERT INTO payments(store_id, number, customer_id, amount_rial, balance_before_rial, balance_after_rial,
                       note, created_by, replaces, op_id) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,NULL) RETURNING *""",
                sid, number, p["customer_id"], new_amount, c["balance_rial"], c["balance_rial"] - new_amount,
                f"اصلاح پرداخت {p['number']}: {reason}", actor, p["id"])
            await ledger.post(conn, store_id=sid, customer_id=p["customer_id"], kind="payment", amount_rial=-new_amount,
                              actor=actor, op_id=op_id, payment_id=newp["id"], note=f"اصلاح پرداخت {p['number']}")
            new_id = newp["id"]
            ref += f"→PAY-{number}"
        await conn.execute("UPDATE payments SET cancelled_seq=$3, cancelled_at=now(), cancelled_by=$4, cancel_reason=$5, "
                           "replaced_by=$6 WHERE store_id=$1 AND id=$2", sid, p["id"], seq, actor, reason, new_id)
        details["before"] = {"amount_rial": p["amount_rial"]}
        details["after"] = {"amount_rial": int(payload.get("new_amount") or 0)}
    elif kind == "edit_opening":
        cid = int(payload["customer_id"])
        old_id = ev.extra["old_entry_id"]
        if old_id:
            await ledger.post(conn, store_id=sid, customer_id=cid, kind="reversal", amount_rial=-ev.extra["old"],
                              actor=actor, op_id=op_id, reverses_entry_id=old_id, note=f"برگشت مانده اول دوره قبلی: {reason}")
        eff_date = payload.get("date")
        await ledger.post(conn, store_id=sid, customer_id=cid, kind="opening", amount_rial=ev.extra["new"], actor=actor,
                          op_id=op_id, note=f"مانده اول دوره (اصلاحی): {reason}",
                          effective_date=dt.date.fromisoformat(eff_date) if eff_date else None)
        details["before"] = {"opening": ev.extra["old"]}
        details["after"] = {"opening": ev.extra["new"]}
        ref = f"OPEN-{cid}"
    await audit(conn, sid, actor, f"correction.{kind}", details)
    cust = None
    if ev.customer_id:
        cust = await conn.fetchrow("SELECT * FROM customers WHERE store_id=$1 AND id=$2", sid, ev.customer_id)
        cutoff = await ledger.max_seq_for_customer(conn, sid, ev.customer_id)
        notice = notify.customer_notice(store, title=f"{TITLES[kind]} در حساب شما ثبت شد", ref=ref,
                                        at=dt.datetime.now(dt.timezone.utc), lines=[f"دلیل: {esc(reason)}"],
                                        balance_rial=cust["balance_rial"])
        await notify.after_customer_event(conn, store, ev.customer_id, cutoff, reason=kind, notice_text=notice)
    else:
        await notify.group_text(conn, store, f"✏️ <b>{TITLES[kind]}</b> | {esc(ref)}\n" + "\n".join(ev.change_lines)
                                + f"\nدلیل: {esc(reason)}", dedupe_key=f"corr:{op_id}")
    return {"ref": ref, "balance_after": cust["balance_rial"] if cust else None, "kind": kind,
            "cash_effect": ev.cash_effect}


__all__ = ["start", "advance", "evaluate", "step_text", "TITLES", "load_store"]
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/domain/customers.py" 0644 <<'SHOPBOTS_FILE_EOF'
from __future__ import annotations

import datetime as dt

import asyncpg

from ..errors import UserError
from ..phone import normalize_phone
from ..textutil import to_en_digits
from . import ledger
from .common import audit, next_counter, require_writable

PAGE = 10


async def create(conn: asyncpg.Connection, store_id: int, actor: int, *, name: str, phone: str | None,
                 rate_type: str, note: str | None, limit_mode: str, limit_rial: int | None,
                 opening_rial: int, opening_date: dt.date, opening_note: str | None) -> asyncpg.Record:
    """Create customer + opening-balance ledger entry atomically. Code is allocated via a
    locked per-store counter, so concurrent creates never collide and codes are never reused."""
    await require_writable(conn, store_id)
    if rate_type not in ("cash", "credit") or limit_mode not in ("none", "warn", "block"):
        raise UserError("تنظیمات حساب نامعتبر است.")
    if limit_mode != "none" and (limit_rial is None or limit_rial < 0):
        raise UserError("سقف بدهی نامعتبر است.")
    norm = normalize_phone(phone) if phone else None
    if phone and not norm:
        raise UserError("شماره تلفن نامعتبر است.")
    code = await next_counter(conn, store_id, "customer")
    c = await conn.fetchrow(
        """INSERT INTO customers(store_id, code, name, phone, rate_type, note, limit_mode, limit_rial, created_by)
           VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING *""",
        store_id, code, name, norm, rate_type, note, limit_mode, limit_rial if limit_mode != "none" else None, actor)
    await ledger.lock_customer(conn, store_id, c["id"])
    await ledger.post(conn, store_id=store_id, customer_id=c["id"], kind="opening", amount_rial=opening_rial,
                      actor=actor, note=opening_note or "مانده اول دوره", effective_date=opening_date)
    await audit(conn, store_id, actor, "customer.create", {"customer_id": c["id"], "code": code})
    return await get(conn, store_id, c["id"])


async def get(conn: asyncpg.Connection, store_id: int, customer_id: int) -> asyncpg.Record:
    r = await conn.fetchrow("SELECT * FROM customers WHERE store_id=$1 AND id=$2", store_id, customer_id)
    if r is None:
        raise UserError("مشتری یافت نشد.")
    return r


async def search(conn: asyncpg.Connection, store_id: int, query: str | None, *, include_archived: bool = False,
                 offset: int = 0, limit: int = PAGE, only_debtors: bool = False) -> tuple[list[asyncpg.Record], int]:
    q = to_en_digits((query or "").strip())
    conds = ["store_id=$1"]
    args: list = [store_id]
    if not include_archived:
        conds.append("archived_at IS NULL")
    if only_debtors:
        conds.append("balance_rial > 0")
    if q:
        args.append(f"%{q.replace('%', '').replace('_', '')}%")
        p = f"${len(args)}"
        sub = [f"name ILIKE {p}", f"COALESCE(phone,'') ILIKE {p}"]
        if q.isdigit():
            args.append(int(q[:15]))
            sub.append(f"code = ${len(args)}")
            np = normalize_phone(q)
            if np:
                args.append(np)
                sub.append(f"phone = ${len(args)}")
        conds.append("(" + " OR ".join(sub) + ")")
    where = " AND ".join(conds)
    total = await conn.fetchval(f"SELECT count(*) FROM customers WHERE {where}", *args)
    order = "balance_rial DESC, code" if only_debtors else "code"
    rows = await conn.fetch(f"SELECT * FROM customers WHERE {where} ORDER BY {order} LIMIT {int(limit)} OFFSET {int(offset)}",
                            *args)
    return list(rows), int(total)


EDITABLE = {"name", "phone", "rate_type", "note", "limit"}


async def update(conn: asyncpg.Connection, store_id: int, actor: int, customer_id: int, field: str, value) -> asyncpg.Record:
    if field not in EDITABLE:
        raise ValueError("bad field")
    old = await ledger.lock_customer(conn, store_id, customer_id)
    if field == "phone":
        norm = normalize_phone(value) if value else None
        if value and not norm:
            raise UserError("شماره تلفن نامعتبر است.")
        await conn.execute("UPDATE customers SET phone=$3, updated_at=now() WHERE store_id=$1 AND id=$2",
                           store_id, customer_id, norm)
        if norm != old["phone"]:
            # Phone change revokes the Telegram link: customer must re-verify with the new number.
            await conn.execute("DELETE FROM customer_links WHERE store_id=$1 AND customer_id=$2", store_id, customer_id)
        after = norm
    elif field == "limit":
        mode, amount = value
        if mode not in ("none", "warn", "block"):
            raise UserError("حالت سقف نامعتبر است.")
        await conn.execute("UPDATE customers SET limit_mode=$3, limit_rial=$4, updated_at=now() WHERE store_id=$1 AND id=$2",
                           store_id, customer_id, mode, amount if mode != "none" else None)
        after = {"mode": mode, "limit_rial": amount}
    else:
        if field == "rate_type" and value not in ("cash", "credit"):
            raise UserError("نوع نرخ نامعتبر است.")
        await conn.execute(f"UPDATE customers SET {field}=$3, updated_at=now() WHERE store_id=$1 AND id=$2",
                           store_id, customer_id, value)
        after = value
    before = {"mode": old["limit_mode"], "limit_rial": old["limit_rial"]} if field == "limit" else old.get(field)
    await audit(conn, store_id, actor, "customer.update",
                {"customer_id": customer_id, "field": field, "before": before, "after": after})
    return await get(conn, store_id, customer_id)


async def set_archived(conn: asyncpg.Connection, store_id: int, actor: int, customer_id: int, archived: bool) -> None:
    await ledger.lock_customer(conn, store_id, customer_id)
    await conn.execute("UPDATE customers SET archived_at = CASE WHEN $3 THEN now() ELSE NULL END, updated_at=now() "
                       "WHERE store_id=$1 AND id=$2", store_id, customer_id, archived)
    if archived:
        await conn.execute("DELETE FROM customer_links WHERE store_id=$1 AND customer_id=$2", store_id, customer_id)
    await audit(conn, store_id, actor, "customer.archive" if archived else "customer.unarchive",
                {"customer_id": customer_id})


async def active_opening(conn: asyncpg.Connection, store_id: int, customer_id: int) -> asyncpg.Record | None:
    return await conn.fetchrow(
        """SELECT e.* FROM ledger_entries e
            WHERE e.store_id=$1 AND e.customer_id=$2 AND e.kind='opening'
              AND NOT EXISTS (SELECT 1 FROM ledger_entries r WHERE r.reverses_entry_id=e.id)
            ORDER BY e.seq DESC LIMIT 1""", store_id, customer_id)
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/domain/ledger.py" 0644 <<'SHOPBOTS_FILE_EOF'
from __future__ import annotations

import asyncpg

from ..errors import UserError


async def lock_customer(conn: asyncpg.Connection, store_id: int, customer_id: int) -> asyncpg.Record:
    r = await conn.fetchrow("SELECT * FROM customers WHERE store_id=$1 AND id=$2 FOR UPDATE", store_id, customer_id)
    if r is None:
        raise UserError("مشتری یافت نشد.")
    return r


async def post(conn: asyncpg.Connection, *, store_id: int, customer_id: int, kind: str, amount_rial: int,
               actor: int, op_id=None, note: str | None = None, invoice_id: int | None = None,
               payment_id: int | None = None, line_change_id: int | None = None,
               reverses_entry_id: int | None = None, effective_date=None) -> asyncpg.Record:
    """Append a ledger entry and update the cached balance. Caller must hold the customer lock
    (lock_customer) inside the same transaction."""
    e = await conn.fetchrow(
        """INSERT INTO ledger_entries(store_id, customer_id, kind, amount_rial, effective_date, invoice_id,
               payment_id, line_change_id, reverses_entry_id, note, created_by, op_id)
           VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) RETURNING *""",
        store_id, customer_id, kind, int(amount_rial), effective_date, invoice_id, payment_id, line_change_id,
        reverses_entry_id, note, actor, op_id)
    await conn.execute(
        "UPDATE customers SET balance_rial = balance_rial + $3, version = version + 1, updated_at=now() "
        "WHERE store_id=$1 AND id=$2", store_id, customer_id, int(amount_rial))
    return e


async def bump_version(conn: asyncpg.Connection, store_id: int, customer_id: int) -> None:
    await conn.execute("UPDATE customers SET version=version+1, updated_at=now() WHERE store_id=$1 AND id=$2",
                       store_id, customer_id)


async def max_seq_for_customer(conn: asyncpg.Connection, store_id: int, customer_id: int) -> int:
    v = await conn.fetchval(
        """SELECT GREATEST(
             (SELECT COALESCE(MAX(seq),0) FROM ledger_entries WHERE store_id=$1 AND customer_id=$2),
             (SELECT COALESCE(MAX(GREATEST(seq, COALESCE(cancelled_seq,0))),0) FROM invoices WHERE store_id=$1 AND customer_id=$2),
             (SELECT COALESCE(MAX(c.seq),0) FROM invoice_line_changes c JOIN invoices i
                 ON i.store_id=c.store_id AND i.id=c.invoice_id WHERE c.store_id=$1 AND i.customer_id=$2),
             (SELECT COALESCE(MAX(GREATEST(seq, COALESCE(cancelled_seq,0))),0) FROM payments WHERE store_id=$1 AND customer_id=$2))""",
        store_id, customer_id)
    return int(v or 0)


async def reconcile(conn: asyncpg.Connection, store_id: int | None = None) -> list[asyncpg.Record]:
    """Return customers whose cached balance differs from the ledger sum (should be empty)."""
    return await conn.fetch(
        """SELECT c.store_id, c.id, c.code, c.balance_rial, COALESCE(SUM(l.amount_rial),0) AS ledger_sum
             FROM customers c LEFT JOIN ledger_entries l ON l.store_id=c.store_id AND l.customer_id=c.id
            WHERE ($1::bigint IS NULL OR c.store_id=$1)
            GROUP BY c.store_id, c.id
           HAVING c.balance_rial <> COALESCE(SUM(l.amount_rial),0)""", store_id)


async def rebuild_balances(conn: asyncpg.Connection, store_id: int | None = None) -> int:
    """Recompute cached balances from the ledger (repair tool)."""
    res = await conn.execute(
        """UPDATE customers c SET balance_rial = s.total, version = c.version + 1
             FROM (SELECT c2.store_id, c2.id, COALESCE(SUM(l.amount_rial),0) total
                     FROM customers c2 LEFT JOIN ledger_entries l ON l.store_id=c2.store_id AND l.customer_id=c2.id
                    WHERE ($1::bigint IS NULL OR c2.store_id=$1) GROUP BY c2.store_id, c2.id) s
            WHERE c.store_id=s.store_id AND c.id=s.id AND c.balance_rial <> s.total""", store_id)
    return int(res.split()[-1])
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/domain/notify.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Transactional outbox producers. Rows are inserted in the SAME transaction as the
financial write, so a committed sale/payment always has its report queued, and a
Telegram failure can never roll back the financial record."""
from __future__ import annotations

from typing import Any

import asyncpg

from ..money import fmt_balance, fmt_money
from ..textutil import esc, fa
from ..timefmt import fmt_dt


async def enqueue(conn: asyncpg.Connection, *, via: str, chat_id: int, kind: str, store_id: int | None = None,
                  payload: dict[str, Any] | None = None, content: bytes | None = None, dedupe_key: str | None = None,
                  parent_id: int | None = None, part_no: int | None = None, delay_seconds: int = 0) -> int | None:
    return await conn.fetchval(
        """INSERT INTO outbox(store_id, via, chat_id, kind, payload, content, dedupe_key, parent_id, part_no, next_attempt_at)
           VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9, now() + make_interval(secs => $10))
           ON CONFLICT (dedupe_key) DO NOTHING RETURNING id""",
        store_id, via, chat_id, kind, payload or {}, content, dedupe_key, parent_id, part_no, float(delay_seconds))


def stmt_button() -> list[list[dict]]:
    return [[{"text": "📄 دریافت صورت‌حساب کامل", "data": "cst:stmt"}]]


async def customer_link(conn: asyncpg.Connection, store_id: int, customer_id: int) -> int | None:
    return await conn.fetchval("SELECT tg_user_id FROM customer_links WHERE store_id=$1 AND customer_id=$2",
                               store_id, customer_id)


async def after_customer_event(conn: asyncpg.Connection, store, customer_id: int, cutoff_seq: int, *,
                               reason: str, notice_text: str | None) -> None:
    if store.report_chat_id and store.full_report_to_group:
        await enqueue(conn, via="store", store_id=store.id, chat_id=store.report_chat_id, kind="gen_statement",
                      payload={"customer_id": customer_id, "cutoff_seq": cutoff_seq, "reason": reason},
                      dedupe_key=f"stmt:{store.id}:{customer_id}:{cutoff_seq}")
    if notice_text and store.notify_customers:
        tg = await customer_link(conn, store.id, customer_id)
        if tg:
            await enqueue(conn, via="store", store_id=store.id, chat_id=tg, kind="text",
                          payload={"text": notice_text, "buttons": stmt_button()},
                          dedupe_key=f"cnotice:{store.id}:{customer_id}:{cutoff_seq}")


async def group_text(conn: asyncpg.Connection, store, text: str, dedupe_key: str | None = None) -> None:
    if store.report_chat_id:
        await enqueue(conn, via="store", store_id=store.id, chat_id=store.report_chat_id, kind="text",
                      payload={"text": text}, dedupe_key=dedupe_key)


async def store_admins_text(conn: asyncpg.Connection, store_id: int, text: str, *, owners_only: bool = False,
                            dedupe_prefix: str | None = None, buttons=None) -> None:
    rows = await conn.fetch("SELECT tg_user_id FROM store_admins WHERE store_id=$1" +
                            (" AND role='owner'" if owners_only else ""), store_id)
    for r in rows:
        await enqueue(conn, via="store", store_id=store_id, chat_id=r["tg_user_id"], kind="text",
                      payload={"text": text, **({"buttons": buttons} if buttons else {})},
                      dedupe_key=f"{dedupe_prefix}:{r['tg_user_id']}" if dedupe_prefix else None)


async def owner_text(conn: asyncpg.Connection, owner_id: int, text: str, *, buttons=None,
                     dedupe_key: str | None = None) -> None:
    await enqueue(conn, via="central", chat_id=owner_id, kind="text",
                  payload={"text": text, **({"buttons": buttons} if buttons else {})}, dedupe_key=dedupe_key)


def customer_notice(store, *, title: str, ref: str, at, lines: list[str], balance_rial: int) -> str:
    out = [f"🔔 <b>{esc(title)}</b> | {esc(store.name)}",
           f"تاریخ: {fmt_dt(at, store.timezone, store.jalali)}",
           f"شناسه پیگیری: <code>{esc(ref)}</code>"]
    out += lines
    out.append(f"مانده حساب شما: <b>{fmt_balance(balance_rial, store.currency)}</b>")
    return "\n".join(out)


def money(store, v: int) -> str:
    return fmt_money(v, store.currency)


__all__ = ["enqueue", "after_customer_event", "group_text", "store_admins_text", "owner_text", "customer_notice",
           "money", "fa"]
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/domain/payments.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Customer payments (card reader, outside the bot). The bot only RECORDS a payment the
seller confirms; it never claims bank-side verification."""
from __future__ import annotations

import asyncpg

from ..errors import AlreadyDone, StaleOperation, UserError
from ..money import MAX_AMOUNT_RIAL, fmt_money
from . import ledger, notify, pendingops
from .common import audit, next_counter, require_writable


def payment_effect(balance_before: int, amount: int) -> dict:
    debt = max(balance_before, 0)
    settled = min(debt, amount)
    return {"balance_before": balance_before, "amount": amount, "debt_settled": settled,
            "credit_created": amount - settled, "balance_after": balance_before - amount}


async def preview(conn: asyncpg.Connection, store_id: int, actor: int, customer_id: int, amount_rial: int,
                  note: str | None) -> dict:
    if amount_rial <= 0 or amount_rial > MAX_AMOUNT_RIAL:
        raise UserError("مبلغ پرداخت باید مثبت باشد.")
    store = await require_writable(conn, store_id)
    c = await conn.fetchrow("SELECT * FROM customers WHERE store_id=$1 AND id=$2", store_id, customer_id)
    if c is None:
        raise UserError("مشتری یافت نشد.")
    eff = payment_effect(c["balance_rial"], amount_rial)
    op_id = await pendingops.create(conn, store_id=store_id, actor=actor, kind="payment",
                                    payload={"amount": amount_rial, "note": note}, customer_id=customer_id,
                                    customer_version=c["version"])
    return {"op_id": op_id, "store": store, "customer": c, "effect": eff}


async def commit(pool: asyncpg.Pool, store_id: int, actor: int, op_id) -> dict:
    async with pool.acquire() as conn:
        try:
            async with conn.transaction():
                return await _commit(conn, store_id, actor, op_id)
        except AlreadyDone as e:
            return {**e.result, "already": True}


async def _commit(conn, store_id, actor, op_id) -> dict:
    op = await pendingops.lock_for_actor(conn, op_id, store_id=store_id, actor=actor, kind="payment")
    store = await require_writable(conn, store_id)
    c = await ledger.lock_customer(conn, store_id, op["customer_id"])
    if c["version"] != op["customer_version"]:
        raise StaleOperation("حساب مشتری بین پیش‌نمایش و تأیید تغییر کرده است. پیش‌نمایش تازه را بررسی کنید.")
    amount = int(op["payload"]["amount"])
    eff = payment_effect(c["balance_rial"], amount)
    number = await next_counter(conn, store_id, "payment")
    pay = await conn.fetchrow(
        """INSERT INTO payments(store_id, number, customer_id, amount_rial, balance_before_rial, balance_after_rial,
               note, created_by, op_id) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING *""",
        store_id, number, c["id"], amount, eff["balance_before"], eff["balance_after"], op["payload"].get("note"),
        actor, op_id)
    await ledger.post(conn, store_id=store_id, customer_id=c["id"], kind="payment", amount_rial=-amount, actor=actor,
                      op_id=op_id, payment_id=pay["id"], note=op["payload"].get("note") or f"پرداخت {number}")
    result = {"payment_id": pay["id"], "number": number, "amount": amount, "balance_after": eff["balance_after"]}
    await pendingops.finish(conn, op_id, result)
    await audit(conn, store_id, actor, "payment.create", {"payment_id": pay["id"], "amount_rial": amount,
                                                          "customer_id": c["id"]})
    cutoff = await ledger.max_seq_for_customer(conn, store_id, c["id"])
    lines = [f"مبلغ دریافتی: <b>{fmt_money(amount, store.currency)}</b>"]
    if eff["credit_created"]:
        lines.append(f"بستانکاری ایجادشده: {fmt_money(eff['credit_created'], store.currency)}")
    notice = notify.customer_notice(store, title="پرداخت شما ثبت شد", ref=f"PAY-{number}", at=pay["created_at"],
                                    lines=lines, balance_rial=eff["balance_after"])
    await notify.after_customer_event(conn, store, c["id"], cutoff, reason="payment", notice_text=notice)
    return result
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/domain/pendingops.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Pending operations: the single mechanism for previews, multi-step confirmation and
idempotent commits. A committed op is marked 'done' in the same DB transaction as the
financial write, so retries / double clicks return the stored result instead of writing again."""
from __future__ import annotations

import datetime as dt
import uuid
from typing import Any

import asyncpg

from ..errors import AlreadyDone, UserError

EXPIRED_MSG = "این عملیات منقضی یا نامعتبر است. لطفاً از ابتدا شروع کنید."


async def create(conn: asyncpg.Connection, *, store_id: int, actor: int, kind: str, payload: dict[str, Any],
                 customer_id: int | None = None, customer_version: int | None = None,
                 ttl_minutes: int = 20) -> uuid.UUID:
    op_id = uuid.uuid4()
    await conn.execute(
        """INSERT INTO pending_ops(id, store_id, actor_tg_id, kind, payload, customer_id, customer_version, expires_at)
           VALUES($1,$2,$3,$4,$5,$6,$7, now() + make_interval(mins => $8))""",
        op_id, store_id, actor, kind, payload, customer_id, customer_version, ttl_minutes)
    return op_id


def parse_id(text: str) -> uuid.UUID | None:
    try:
        return uuid.UUID(text)
    except (ValueError, TypeError):
        return None


async def lock_for_actor(conn: asyncpg.Connection, op_id: uuid.UUID, *, store_id: int, actor: int,
                         kind: str | None = None) -> asyncpg.Record:
    """Lock an op row; only the actor who created it, in the same store, may continue it."""
    r = await conn.fetchrow("SELECT * FROM pending_ops WHERE id=$1 AND store_id=$2 AND actor_tg_id=$3 FOR UPDATE",
                            op_id, store_id, actor)
    if r is None or (kind and r["kind"] != kind):
        raise UserError(EXPIRED_MSG)
    if r["status"] == "done":
        raise AlreadyDone(r["result"])
    if r["status"] != "pending":
        raise UserError(EXPIRED_MSG)
    if r["expires_at"] < dt.datetime.now(dt.timezone.utc):
        await conn.execute("UPDATE pending_ops SET status='expired' WHERE id=$1", op_id)
        raise UserError(EXPIRED_MSG)
    return r


async def set_step(conn: asyncpg.Connection, op_id: uuid.UUID, step: int, *, customer_version: int | None = None,
                   payload: dict | None = None) -> None:
    await conn.execute(
        """UPDATE pending_ops SET step=$2, customer_version=COALESCE($3, customer_version),
               payload=COALESCE($4, payload), expires_at=now()+interval '20 minutes' WHERE id=$1""",
        op_id, step, customer_version, payload)


async def finish(conn: asyncpg.Connection, op_id: uuid.UUID, result: dict[str, Any]) -> None:
    await conn.execute("UPDATE pending_ops SET status='done', result=$2, done_at=now() WHERE id=$1 AND status='pending'",
                       op_id, result)


async def cancel(conn: asyncpg.Connection, op_id: uuid.UUID, *, store_id: int, actor: int) -> bool:
    res = await conn.execute(
        "UPDATE pending_ops SET status='cancelled' WHERE id=$1 AND store_id=$2 AND actor_tg_id=$3 AND status='pending'",
        op_id, store_id, actor)
    return res.endswith("1")
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/domain/products.py" 0644 <<'SHOPBOTS_FILE_EOF'
from __future__ import annotations

from decimal import Decimal

import asyncpg

from ..errors import UserError
from .common import audit

PAGE = 8


async def create(conn: asyncpg.Connection, store_id: int, actor: int, *, code: str, name: str, category: str | None,
                 unit_type: str, cash_price_rial: int, markup_pct: Decimal) -> asyncpg.Record:
    if unit_type not in ("count", "kg"):
        raise UserError("نوع واحد نامعتبر است.")
    if cash_price_rial < 0 or markup_pct < 0:
        raise UserError("قیمت و درصد نمی‌توانند منفی باشند.")
    try:
        r = await conn.fetchrow(
            """INSERT INTO products(store_id, code, name, category, unit_type, cash_price_rial, credit_markup_pct)
               VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING *""",
            store_id, code, name, category, unit_type, cash_price_rial, markup_pct)
    except asyncpg.UniqueViolationError:
        raise UserError("کالایی با این کد در فروشگاه وجود دارد.")
    await audit(conn, store_id, actor, "product.create", {"product_id": r["id"], "code": code})
    return r


async def get(conn: asyncpg.Connection, store_id: int, product_id: int) -> asyncpg.Record:
    r = await conn.fetchrow("SELECT * FROM products WHERE store_id=$1 AND id=$2", store_id, product_id)
    if r is None:
        raise UserError("کالا یافت نشد.")
    return r


ALLOWED_FIELDS = {"name", "category", "cash_price_rial", "credit_markup_pct", "is_active"}


async def update_field(conn: asyncpg.Connection, store_id: int, actor: int, product_id: int, field: str, value):
    if field not in ALLOWED_FIELDS:
        raise ValueError("field not allowed")
    old = await get(conn, store_id, product_id)
    # Field name comes from the fixed allow-list above, values are parameters.
    r = await conn.fetchrow(
        f"UPDATE products SET {field}=$3, version=version+1, updated_at=now() WHERE store_id=$1 AND id=$2 RETURNING *",
        store_id, product_id, value)
    await audit(conn, store_id, actor, "product.update",
                {"product_id": product_id, "field": field, "before": old[field], "after": value})
    return r


async def search(conn: asyncpg.Connection, store_id: int, query: str | None, *, active_only: bool,
                 offset: int = 0, limit: int = PAGE) -> tuple[list[asyncpg.Record], int]:
    q = (query or "").strip()
    like = f"%{q.replace('%', '').replace('_', '')}%" if q else "%"
    where = "store_id=$1 AND (code ILIKE $2 OR name ILIKE $2 OR COALESCE(category,'') ILIKE $2)"
    if active_only:
        where += " AND is_active"
    total = await conn.fetchval(f"SELECT count(*) FROM products WHERE {where}", store_id, like)
    rows = await conn.fetch(
        f"""SELECT * FROM products WHERE {where}
            ORDER BY (upper(code)=upper($3)) DESC, is_active DESC, name LIMIT $4 OFFSET $5""",
        store_id, like, q, limit, offset)
    return list(rows), int(total)
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/domain/reports.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Report data builders. Statements are cut at an explicit event sequence number so the
text and the xlsx sent for one event always describe the same state."""
from __future__ import annotations

import datetime as dt
import uuid
from decimal import Decimal

import asyncpg

from ..timefmt import now_utc
from .customers import get as get_customer


def new_report_id(prefix: str) -> str:
    return f"{prefix}-{uuid.uuid4().hex[:10].upper()}"


async def customer_statement(conn: asyncpg.Connection, store_id: int, customer_id: int,
                             cutoff_seq: int | None = None) -> dict:
    c = await get_customer(conn, store_id, customer_id)
    if cutoff_seq is None:
        cutoff_seq = int(await conn.fetchval("SELECT last_value FROM fin_event_seq"))
    entries = await conn.fetch(
        """SELECT e.*, r.kind AS reversed_kind, r.invoice_id AS r_invoice_id, r.payment_id AS r_payment_id
             FROM ledger_entries e LEFT JOIN ledger_entries r ON r.id = e.reverses_entry_id
            WHERE e.store_id=$1 AND e.customer_id=$2 AND e.seq <= $3 ORDER BY e.seq""",
        store_id, customer_id, cutoff_seq)
    invoices = {r["id"]: r for r in await conn.fetch(
        "SELECT * FROM invoices WHERE store_id=$1 AND customer_id=$2 AND seq <= $3", store_id, customer_id, cutoff_seq)}
    lines: dict[int, list] = {}
    if invoices:
        for ln in await conn.fetch("SELECT * FROM invoice_lines WHERE store_id=$1 AND invoice_id = ANY($2::bigint[]) "
                                   "ORDER BY invoice_id, line_no", store_id, list(invoices)):
            lines.setdefault(ln["invoice_id"], []).append(dict(ln))
    changes = list(await conn.fetch(
        """SELECT ch.*, l.product_name, l.unit_type FROM invoice_line_changes ch
             JOIN invoice_lines l ON l.store_id=ch.store_id AND l.id=ch.line_id
            WHERE ch.store_id=$1 AND ch.invoice_id = ANY($2::bigint[]) AND ch.seq <= $3 ORDER BY ch.seq""",
        store_id, list(invoices) or [0], cutoff_seq))
    payments = {r["id"]: r for r in await conn.fetch(
        "SELECT * FROM payments WHERE store_id=$1 AND customer_id=$2 AND seq <= $3", store_id, customer_id, cutoff_seq)}
    ch_by_id = {ch["id"]: ch for ch in changes}

    def line_status(inv_id, ln):
        notes = []
        for ch in changes:
            if ch["line_id"] == ln["id"]:
                notes.append(("مرجوعی " if ch["kind"] == "return" else "اصلاح ") + f"{ch['qty_delta']:+}")
        if invoices[inv_id]["cancelled_seq"] and invoices[inv_id]["cancelled_seq"] <= cutoff_seq:
            notes.append("لغو شده")
        return "، ".join(notes)

    events: list[dict] = []
    for e in entries:
        k = e["kind"]
        ev = {"seq": e["seq"], "at": e["created_at"], "amount": e["amount_rial"], "affects": True, "desc": e["note"] or "",
              "lk": k, "rk": e["reversed_kind"]}
        if k == "opening":
            ev["label"] = "مانده اول دوره"
            if e["effective_date"]:
                ev["at"] = dt.datetime.combine(e["effective_date"], dt.time(12, 0), tzinfo=dt.timezone.utc)
                ev["at_recorded"] = e["created_at"]
        elif k == "sale":
            inv = invoices.get(e["invoice_id"])
            ev["label"] = "خرید به حساب" + (" (نرخ نسیه)" if inv and inv["rate_type"] == "credit" else " (نرخ نقدی)")
            ev["ref"] = inv["number"] if inv else ""
            ev["items"] = [dict(x, status=line_status(inv["id"], x)) for x in lines.get(e["invoice_id"], [])] if inv else []
            if inv and inv["limit_override_by"]:
                ev["desc"] = (ev["desc"] + " | " if ev["desc"] else "") + "عبور از سقف بدهی با تأیید فروشنده"
        elif k == "payment":
            p = payments.get(e["payment_id"])
            pre = p is not None and p["balance_before_rial"] <= 0
            mixed = p is not None and 0 < p["balance_before_rial"] < p["amount_rial"]
            ev["label"] = "پیش‌پرداخت" if pre else ("پرداخت (مازاد بستانکار شد)" if mixed else "پرداخت")
            ev["ref"] = p["number"] if p else ""
            if p is not None and p["replaces"]:
                ev["label"] += " - اصلاحی"
        elif k == "return":
            ch = ch_by_id.get(e["line_change_id"])
            inv = invoices.get(e["invoice_id"])
            ev["label"] = "مرجوعی به حساب"
            ev["ref"] = inv["number"] if inv else ""
            if ch:
                ev["desc"] = f"{ch['product_name']} مقدار {abs(ch['qty_delta'])} | دلیل: {ch['reason']}"
        elif k == "correction":
            ch = ch_by_id.get(e["line_change_id"])
            inv = invoices.get(e["invoice_id"])
            ev["label"] = "اصلاح فاکتور"
            ev["ref"] = inv["number"] if inv else ""
            if ch:
                ev["desc"] = f"{ch['product_name']} تغییر مقدار {ch['qty_delta']:+} | دلیل: {ch['reason']}"
        elif k == "reversal":
            rk = e["reversed_kind"]
            if rk == "sale":
                inv = invoices.get(e["r_invoice_id"])
                ev["label"], ev["ref"] = "لغو فاکتور", (inv["number"] if inv else "")
            elif rk == "payment":
                p = payments.get(e["r_payment_id"])
                ev["label"] = "برگشت پرداخت (اصلاح)" if p is not None and p["replaced_by"] else "لغو پرداخت"
                ev["ref"] = p["number"] if p else ""
            elif rk == "opening":
                ev["label"] = "برگشت مانده اول دوره قبلی (اصلاح)"
            else:
                ev["label"] = "رویداد معکوس"
        events.append(ev)

    # informational (non-balance) events: cash invoices linked to this customer, cash refunds
    for inv in invoices.values():
        if inv["kind"] != "cash":
            continue
        events.append({"seq": inv["seq"], "at": inv["created_at"], "amount": 0, "affects": False,
                       "label": "خرید نقدی", "ref": inv["number"], "info_amount": inv["total_rial"], "desc": "",
                       "items": [dict(x, status=line_status(inv["id"], x)) for x in lines.get(inv["id"], [])]})
        if inv["cancelled_seq"] and inv["cancelled_seq"] <= cutoff_seq:
            events.append({"seq": inv["cancelled_seq"], "at": inv["cancelled_at"], "amount": 0, "affects": False,
                           "label": "لغو فاکتور نقدی", "ref": inv["number"], "info_amount": inv["total_rial"],
                           "desc": inv["cancel_reason"] or ""})
    for ch in changes:
        inv = invoices[ch["invoice_id"]]
        if inv["kind"] == "cash" and ch["refund_mode"] != "account":
            label = "مرجوعی نقدی" if ch["kind"] == "return" else "اصلاح فاکتور نقدی"
            events.append({"seq": ch["seq"], "at": ch["created_at"], "amount": 0, "affects": False, "label": label,
                           "ref": inv["number"], "info_amount": abs(ch["amount_delta"]), "delta": ch["amount_delta"],
                           "desc": f"{ch['product_name']} مقدار {ch['qty_delta']:+} | دلیل: {ch['reason']}"})
        elif inv["kind"] == "cash" and ch["refund_mode"] == "account":
            pass  # has its own ledger 'return' entry
    events.sort(key=lambda x: x["seq"])

    bal = 0
    totals = dict(opening=0, account_sales=0, cash_sales=0, payments=0, decreases=0, increases=0, cash_refunds=0)
    for ev in events:
        a = ev["amount"]
        if ev["affects"]:
            bal += a
            ev["balance"] = bal
            ev["debit"] = a if a > 0 else 0
            ev["credit"] = -a if a < 0 else 0
            lk, rk = ev["lk"], ev.get("rk")
            if lk == "opening" or (lk == "reversal" and rk == "opening"):
                totals["opening"] += a
            elif lk == "sale" or (lk == "reversal" and rk == "sale"):
                totals["account_sales"] += a
            elif lk == "payment" or (lk == "reversal" and rk == "payment"):
                totals["payments"] -= a
            elif a < 0:
                totals["decreases"] += -a
            else:
                totals["increases"] += a
        else:
            ev["balance"] = bal
            ev["debit"] = ev["credit"] = 0
            if ev["label"] == "خرید نقدی":
                totals["cash_sales"] += ev["info_amount"]
            elif ev["label"] == "لغو فاکتور نقدی":
                totals["cash_sales"] -= ev["info_amount"]
            elif ev["label"] == "مرجوعی نقدی":
                totals["cash_refunds"] += ev["info_amount"]
            elif ev["label"] == "اصلاح فاکتور نقدی":
                totals["cash_sales"] += ev["delta"]
    return {"customer": dict(c), "cutoff_seq": cutoff_seq, "generated_at": now_utc(), "report_id": new_report_id("ST"),
            "events": events, "totals": totals, "balance": bal}


async def customer_list(conn: asyncpg.Connection, store_id: int) -> list[asyncpg.Record]:
    return list(await conn.fetch(
        """SELECT code, name, phone, balance_rial, archived_at FROM customers
            WHERE store_id=$1 AND (archived_at IS NULL OR balance_rial <> 0) ORDER BY code""", store_id))


async def management(conn: asyncpg.Connection, store_id: int, start: dt.datetime, end: dt.datetime) -> dict:
    inv = await conn.fetchrow(
        """SELECT
             COALESCE(SUM(total_rial) FILTER (WHERE kind='cash'),0) cash_total,
             count(*) FILTER (WHERE kind='cash') cash_count,
             COALESCE(SUM(total_rial) FILTER (WHERE kind='account'),0) account_total,
             count(*) FILTER (WHERE kind='account') account_count
           FROM invoices WHERE store_id=$1 AND created_at >= $2 AND created_at < $3 AND cancelled_seq IS NULL""",
        store_id, start, end)
    ch = await conn.fetchrow(
        """SELECT
             COALESCE(SUM(c.amount_delta) FILTER (WHERE i.kind='cash'),0) cash_delta,
             COALESCE(SUM(c.amount_delta) FILTER (WHERE i.kind='account'),0) account_delta,
             COALESCE(SUM(-c.amount_delta) FILTER (WHERE c.kind='return' AND c.refund_mode='cash'),0) cash_refunds
           FROM invoice_line_changes c JOIN invoices i ON i.store_id=c.store_id AND i.id=c.invoice_id
           WHERE c.store_id=$1 AND c.created_at >= $2 AND c.created_at < $3 AND i.cancelled_seq IS NULL""",
        store_id, start, end)
    pay = await conn.fetchrow(
        """SELECT COALESCE(SUM(amount_rial),0) total, count(*) n FROM payments
            WHERE store_id=$1 AND created_at >= $2 AND created_at < $3 AND cancelled_seq IS NULL""", store_id, start, end)
    bal = await conn.fetchrow(
        """SELECT COALESCE(SUM(balance_rial) FILTER (WHERE balance_rial>0),0) recv,
                  COALESCE(-SUM(balance_rial) FILTER (WHERE balance_rial<0),0) cred
             FROM customers WHERE store_id=$1""", store_id)
    products = await conn.fetch(
        """SELECT l.product_code, l.product_name, l.unit_type,
                  SUM(l.qty) + COALESCE(SUM(chs.qd),0) AS qty,
                  SUM(l.amount_rial) + COALESCE(SUM(chs.ad),0) AS amount
             FROM invoice_lines l
             JOIN invoices i ON i.store_id=l.store_id AND i.id=l.invoice_id
             LEFT JOIN LATERAL (SELECT SUM(qty_delta) qd, SUM(amount_delta) ad FROM invoice_line_changes c
                                 WHERE c.store_id=l.store_id AND c.line_id=l.id) chs ON true
            WHERE l.store_id=$1 AND i.created_at >= $2 AND i.created_at < $3 AND i.cancelled_seq IS NULL
            GROUP BY l.product_code, l.product_name, l.unit_type
            HAVING SUM(l.amount_rial) + COALESCE(SUM(chs.ad),0) > 0
            ORDER BY amount DESC""", store_id, start, end)
    debtors = await conn.fetch("SELECT code, name, phone, balance_rial FROM customers WHERE store_id=$1 AND balance_rial>0 "
                               "ORDER BY balance_rial DESC", store_id)
    creditors = await conn.fetch("SELECT code, name, phone, balance_rial FROM customers WHERE store_id=$1 AND balance_rial<0 "
                                 "ORDER BY balance_rial", store_id)
    plist = [dict(p, qty=Decimal(p["qty"]), amount=int(p["amount"])) for p in products]
    return {
        "start": start, "end": end, "generated_at": now_utc(),
        "cash_sales": int(inv["cash_total"]) + int(ch["cash_delta"]), "cash_count": inv["cash_count"],
        "account_sales": int(inv["account_total"]) + int(ch["account_delta"]), "account_count": inv["account_count"],
        "cash_refunds": int(ch["cash_refunds"]),
        "payments": int(pay["total"]), "payment_count": pay["n"],
        "receivables": int(bal["recv"]), "credits": int(bal["cred"]),
        "top_products": plist[:10], "all_products": plist,
        "debtors": [dict(d) for d in debtors[:15]], "debtors_more": max(0, len(debtors) - 15),
        "all_debtors": [dict(d) for d in debtors], "all_creditors": [dict(d) for d in creditors],
    }
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/domain/sales.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Cash and on-account sales. Prices/markups are snapshotted into invoice lines."""
from __future__ import annotations

from decimal import Decimal
from typing import Any

import asyncpg

from ..errors import AlreadyDone, StaleOperation, UserError
from ..money import fmt_money, line_amount, unit_price_for
from ..textutil import fa, fmt_qty
from . import ledger, notify, pendingops
from .common import Store, audit, load_store, next_counter, require_writable

MAX_CART_ITEMS = 60


async def price_lines(conn: asyncpg.Connection, store: Store, items: list[dict], rate_type: str) -> list[dict]:
    """items: [{"pid": int, "qty": "1.25"}] -> priced line snapshots (store-scoped product lookup)."""
    if not items:
        raise UserError("سبد خرید خالی است.")
    if len(items) > MAX_CART_ITEMS:
        raise UserError("تعداد اقلام سبد بیش از حد مجاز است.")
    pids = [int(i["pid"]) for i in items]
    rows = {r["id"]: r for r in await conn.fetch(
        "SELECT * FROM products WHERE store_id=$1 AND id = ANY($2::bigint[])", store.id, pids)}
    out = []
    for i, it in enumerate(items, 1):
        p = rows.get(int(it["pid"]))
        if p is None or not p["is_active"]:
            raise StaleOperation("یکی از کالاهای سبد غیرفعال یا حذف شده است. سبد را اصلاح کنید.")
        qty = Decimal(str(it["qty"]))
        if qty <= 0 or (p["unit_type"] == "count" and qty != qty.to_integral_value()):
            raise UserError("مقدار نامعتبر در سبد.")
        up = unit_price_for(rate_type, p["cash_price_rial"], p["credit_markup_pct"])
        out.append({
            "line_no": i, "product_id": p["id"], "product_code": p["code"], "product_name": p["name"],
            "category": p["category"], "unit_type": p["unit_type"], "qty": str(qty),
            "cash_price_rial": int(p["cash_price_rial"]), "markup_pct": str(p["credit_markup_pct"]),
            "unit_price_rial": up,
            "amount_rial": line_amount(up, qty, store.rounding_unit_rial, store.rounding_mode),
            "pver": int(p["version"]),
        })
    return out


def account_effect(balance_before: int, total: int) -> dict:
    credit_avail = max(0, -balance_before)
    return {"balance_before": balance_before, "total": total, "credit_used": min(credit_avail, total),
            "balance_after": balance_before + total}


def limit_check(customer, balance_after: int) -> tuple[str, str | None]:
    """returns (state, message): state in ok|warn|block. Based on final debt after purchase
    (credit already netted in balance_after)."""
    mode = customer["limit_mode"]
    if mode == "none":
        return "ok", None
    limit = int(customer["limit_rial"] or 0)
    debt = max(balance_after, 0)
    if debt <= limit:
        return "ok", None
    return ("warn" if mode == "warn" else "block"), str(debt - limit)


async def preview(conn: asyncpg.Connection, store_id: int, actor: int, *, kind: str, items: list[dict],
                  customer_id: int | None) -> dict[str, Any]:
    """Validate and price the cart; create a pending op that must be confirmed to commit."""
    store = await require_writable(conn, store_id)
    customer = None
    if customer_id is not None:
        customer = await conn.fetchrow("SELECT * FROM customers WHERE store_id=$1 AND id=$2", store_id, customer_id)
        if customer is None:
            raise UserError("مشتری یافت نشد.")
        if customer["archived_at"]:
            raise UserError("این مشتری بایگانی شده است.")
    if kind == "account" and customer is None:
        raise UserError("برای فروش به حساب، مشتری را انتخاب کنید.")
    rate_type = customer["rate_type"] if kind == "account" else "cash"
    lines = await price_lines(conn, store, items, rate_type)
    total = sum(ln["amount_rial"] for ln in lines)
    eff = account_effect(customer["balance_rial"], total) if kind == "account" else None
    lim_state, over = limit_check(customer, eff["balance_after"]) if eff else ("ok", None)
    payload = {"kind": kind, "items": items, "rate_type": rate_type, "lines": lines, "total": total}
    op_id = await pendingops.create(conn, store_id=store_id, actor=actor, kind="sale", payload=payload,
                                    customer_id=customer_id, customer_version=customer["version"] if customer else None)
    return {"op_id": op_id, "store": store, "customer": customer, "lines": lines, "total": total, "rate_type": rate_type,
            "account": eff, "limit_state": lim_state, "over_rial": int(over) if over else 0, "kind": kind}


async def commit(pool: asyncpg.Pool, store_id: int, actor: int, op_id, *, override_limit: bool) -> dict:
    async with pool.acquire() as conn:
        try:
            async with conn.transaction():
                return await _commit(conn, store_id, actor, op_id, override_limit)
        except AlreadyDone as e:
            return {**e.result, "already": True}


async def _commit(conn, store_id, actor, op_id, override_limit) -> dict:
    op = await pendingops.lock_for_actor(conn, op_id, store_id=store_id, actor=actor, kind="sale")
    store = await require_writable(conn, store_id)
    p = op["payload"]
    kind = p["kind"]
    customer = None
    if op["customer_id"] is not None:
        customer = await ledger.lock_customer(conn, store_id, op["customer_id"])
        if customer["archived_at"]:
            raise UserError("این مشتری بایگانی شده است.")
        if customer["version"] != op["customer_version"]:
            raise StaleOperation("حساب مشتری بین پیش‌نمایش و تأیید تغییر کرده است. پیش‌نمایش تازه را بررسی کنید.")
        if kind == "account" and customer["rate_type"] != p["rate_type"]:
            raise StaleOperation("نوع نرخ مشتری تغییر کرده است.")
    lines = await price_lines(conn, store, p["items"], p["rate_type"])
    if [(ln["product_id"], ln["unit_price_rial"], ln["amount_rial"]) for ln in lines] != \
            [(ln["product_id"], ln["unit_price_rial"], ln["amount_rial"]) for ln in p["lines"]]:
        raise StaleOperation("قیمت یا تنظیمات یکی از کالاها تغییر کرده است. پیش‌نمایش تازه را بررسی کنید.")
    total = sum(ln["amount_rial"] for ln in lines)
    eff = None
    override_by = None
    if kind == "account":
        eff = account_effect(customer["balance_rial"], total)
        state, over = limit_check(customer, eff["balance_after"])
        if state == "block":
            raise UserError(f"این فروش از سقف بدهی مشتری عبور می‌کند ({fmt_money(int(over), store.currency)} بیش از سقف) "
                            "و طبق تنظیم حساب، مجاز نیست.")
        if state == "warn":
            if not override_limit:
                raise UserError("این فروش از سقف بدهی عبور می‌کند؛ برای ادامه باید عبور از سقف را تأیید کنید.")
            override_by = actor
    number = await next_counter(conn, store_id, "invoice")
    inv = await conn.fetchrow(
        """INSERT INTO invoices(store_id, number, kind, customer_id, rate_type, total_rial, balance_before_rial,
               balance_after_rial, credit_used_rial, limit_override_by, limit_override_note, created_by, op_id)
           VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) RETURNING *""",
        store_id, number, kind, customer["id"] if customer else None, p["rate_type"], total,
        eff["balance_before"] if eff else None, eff["balance_after"] if eff else None,
        eff["credit_used"] if eff else 0, override_by,
        "عبور از سقف با تأیید فروشنده" if override_by else None, actor, op_id)
    await conn.executemany(
        """INSERT INTO invoice_lines(store_id, invoice_id, line_no, product_id, product_code, product_name, category,
               unit_type, qty, cash_price_rial, markup_pct, unit_price_rial, amount_rial)
           VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)""",
        [(store_id, inv["id"], ln["line_no"], ln["product_id"], ln["product_code"], ln["product_name"], ln["category"],
          ln["unit_type"], Decimal(ln["qty"]), ln["cash_price_rial"], Decimal(ln["markup_pct"]), ln["unit_price_rial"],
          ln["amount_rial"]) for ln in lines])
    balance_after = None
    if kind == "account":
        await ledger.post(conn, store_id=store_id, customer_id=customer["id"], kind="sale", amount_rial=total,
                          actor=actor, op_id=op_id, invoice_id=inv["id"], note=f"فاکتور {number}")
        balance_after = eff["balance_after"]
    elif customer is not None:
        await ledger.bump_version(conn, store_id, customer["id"])
        balance_after = customer["balance_rial"]
    result = {"invoice_id": inv["id"], "number": number, "total": total, "kind": kind}
    await pendingops.finish(conn, op_id, result)
    await audit(conn, store_id, actor, "invoice.create",
                {"invoice_id": inv["id"], "number": number, "kind": kind, "total_rial": total,
                 "customer_id": customer["id"] if customer else None, "limit_override": bool(override_by)})
    if customer is not None:
        cutoff = await ledger.max_seq_for_customer(conn, store_id, customer["id"])
        lines_txt = [f"{ln['product_name']}: {fmt_qty(Decimal(ln['qty']), ln['unit_type'])} = {fmt_money(ln['amount_rial'], store.currency)}"
                     for ln in lines]
        title = "خرید نقدی ثبت شد" if kind == "cash" else "خرید به حساب ثبت شد"
        notice = notify.customer_notice(store, title=title, ref=f"INV-{number}", at=inv["created_at"],
                                        lines=lines_txt + [f"جمع فاکتور: <b>{fmt_money(total, store.currency)}</b>"],
                                        balance_rial=balance_after)
        await notify.after_customer_event(conn, store, customer["id"], cutoff, reason="sale", notice_text=notice)
    elif store.report_chat_id and store.full_report_to_group:
        from ..render.text import invoice_final
        await notify.group_text(conn, store, invoice_final(store, inv, lines), dedupe_key=f"inv:{store_id}:{inv['id']}")
    return result


async def invoice_with_lines(conn: asyncpg.Connection, store_id: int, *, invoice_id: int | None = None,
                             number: int | None = None):
    if invoice_id is not None:
        inv = await conn.fetchrow("SELECT * FROM invoices WHERE store_id=$1 AND id=$2", store_id, invoice_id)
    else:
        inv = await conn.fetchrow("SELECT * FROM invoices WHERE store_id=$1 AND number=$2", store_id, number)
    if inv is None:
        raise UserError("فاکتور یافت نشد.")
    lines = await conn.fetch(
        """SELECT l.*, l.qty + COALESCE((SELECT SUM(qty_delta) FROM invoice_line_changes c WHERE c.store_id=l.store_id AND c.line_id=l.id),0) AS eff_qty,
                  l.amount_rial + COALESCE((SELECT SUM(amount_delta) FROM invoice_line_changes c WHERE c.store_id=l.store_id AND c.line_id=l.id),0) AS eff_amount
             FROM invoice_lines l WHERE l.store_id=$1 AND l.invoice_id=$2 ORDER BY l.line_no""", store_id, inv["id"])
    return inv, [dict(x) for x in lines]


__all__ = ["preview", "commit", "price_lines", "account_effect", "limit_check", "invoice_with_lines", "load_store", "fa"]
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/domain/stores_admin.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Central-admin operations on stores. Deliberately exposes NO customer financial details."""
from __future__ import annotations

import datetime as dt

import asyncpg

from ..crypto import TokenCipher, bot_id_from_token
from ..errors import UserError
from .common import audit
from .subscriptions import extend


async def create_store(conn: asyncpg.Connection, cipher: TokenCipher, actor: int, *, name: str, token: str,
                       bot_tg_id: int, bot_username: str, admin_id: int, initial_days: int) -> int:
    if bot_id_from_token(token) != bot_tg_id:
        raise UserError("توکن با ربات تأییدشده مطابقت ندارد.")
    exists = await conn.fetchval("SELECT id FROM stores WHERE bot_tg_id=$1", bot_tg_id)
    if exists:
        raise UserError("این ربات قبلاً برای فروشگاه دیگری ثبت شده است.")
    sid = await conn.fetchval(
        """INSERT INTO stores(name, bot_token_enc, bot_tg_id, bot_username, subscription_end)
           VALUES($1,$2,$3,$4,NULL) RETURNING id""", name, cipher.encrypt(token), bot_tg_id, bot_username)
    await conn.execute("INSERT INTO store_admins(store_id, tg_user_id, role, added_by) VALUES($1,$2,'owner',$3)",
                       sid, admin_id, actor)
    if initial_days > 0:
        await extend(conn, sid, actor, initial_days, source="initial")
    await audit(conn, sid, actor, "store.create", {"name": name, "bot_tg_id": bot_tg_id, "admin_id": admin_id})
    return sid


async def replace_token(conn, cipher: TokenCipher, actor: int, store_id: int, token: str, bot_tg_id: int, username: str):
    other = await conn.fetchval("SELECT id FROM stores WHERE bot_tg_id=$1 AND id<>$2", bot_tg_id, store_id)
    if other:
        raise UserError("این ربات برای فروشگاه دیگری ثبت شده است.")
    old = await conn.fetchval("SELECT bot_tg_id FROM stores WHERE id=$1", store_id)
    await conn.execute("UPDATE stores SET bot_token_enc=$2, bot_tg_id=$3, bot_username=$4, bot_status='pending', "
                       "bot_status_detail=NULL, updated_at=now() WHERE id=$1", store_id, cipher.encrypt(token), bot_tg_id,
                       username)
    if old and old != bot_tg_id:
        # A new bot cannot see chats/customers of the old bot: links and FSM of the old bot are now meaningless.
        await conn.execute("DELETE FROM fsm_states WHERE bot_tg_id=$1", old)
    await audit(conn, store_id, actor, "store.token_replace", {"old_bot": old, "new_bot": bot_tg_id})


async def add_admin(conn, actor: int, store_id: int, tg_user_id: int, role: str):
    if role not in ("owner", "staff"):
        raise UserError("نقش نامعتبر است.")
    await conn.execute("INSERT INTO store_admins(store_id, tg_user_id, role, added_by) VALUES($1,$2,$3,$4) "
                       "ON CONFLICT (store_id, tg_user_id) DO UPDATE SET role=EXCLUDED.role", store_id, tg_user_id, role, actor)
    await audit(conn, store_id, actor, "store.admin_add", {"tg_user_id": tg_user_id, "role": role})


async def remove_admin(conn, actor: int, store_id: int, tg_user_id: int):
    owners = await conn.fetchval("SELECT count(*) FROM store_admins WHERE store_id=$1 AND role='owner' AND tg_user_id<>$2",
                                 store_id, tg_user_id)
    role = await conn.fetchval("SELECT role FROM store_admins WHERE store_id=$1 AND tg_user_id=$2", store_id, tg_user_id)
    if role is None:
        raise UserError("این کاربر ادمین فروشگاه نیست.")
    if role == "owner" and owners == 0:
        raise UserError("فروشگاه باید حداقل یک مالک داشته باشد.")
    await conn.execute("DELETE FROM store_admins WHERE store_id=$1 AND tg_user_id=$2", store_id, tg_user_id)
    await audit(conn, store_id, actor, "store.admin_remove", {"tg_user_id": tg_user_id})


async def set_enabled(conn, actor: int, store_id: int, enabled: bool):
    await conn.execute("UPDATE stores SET is_enabled=$2, bot_status=CASE WHEN $2 THEN 'pending' ELSE 'disabled' END, "
                       "updated_at=now() WHERE id=$1", store_id, enabled)
    await audit(conn, store_id, actor, "store.enable" if enabled else "store.disable", {})


async def support_grant_active(conn, store_id: int, tg_user_id: int) -> asyncpg.Record | None:
    return await conn.fetchrow("SELECT * FROM support_grants WHERE store_id=$1 AND granted_to=$2 AND revoked_at IS NULL "
                               "AND expires_at > now() ORDER BY id DESC LIMIT 1", store_id, tg_user_id)


async def grant_support(conn, store_id: int, granted_by: int, granted_to: int, hours: int) -> dt.datetime:
    if not (1 <= hours <= 168):
        raise UserError("مدت دسترسی باید بین ۱ تا ۱۶۸ ساعت باشد.")
    exp = dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=hours)
    await conn.execute("INSERT INTO support_grants(store_id, granted_by, granted_to, expires_at) VALUES($1,$2,$3,$4)",
                       store_id, granted_by, granted_to, exp)
    await audit(conn, store_id, granted_by, "support.grant", {"to": granted_to, "hours": hours})
    return exp


async def revoke_support(conn, store_id: int, actor: int):
    await conn.execute("UPDATE support_grants SET revoked_at=now() WHERE store_id=$1 AND revoked_at IS NULL", store_id)
    await audit(conn, store_id, actor, "support.revoke", {})


async def support_summary(conn, store_id: int, actor: int) -> dict:
    """Aggregate-only view for a granted support session; every access is audited."""
    if not await support_grant_active(conn, store_id, actor):
        raise UserError("دسترسی پشتیبانی فعال برای این فروشگاه ندارید. فروشنده باید آن را از تنظیمات فعال کند.")
    row = await conn.fetchrow(
        """SELECT count(*) customers,
                  COALESCE(SUM(balance_rial) FILTER (WHERE balance_rial>0),0) recv,
                  COALESCE(-SUM(balance_rial) FILTER (WHERE balance_rial<0),0) cred
             FROM customers WHERE store_id=$1""", store_id)
    inv = await conn.fetchval("SELECT count(*) FROM invoices WHERE store_id=$1", store_id)
    failed = await conn.fetchval("SELECT count(*) FROM outbox WHERE store_id=$1 AND status='failed'", store_id)
    from .ledger import reconcile
    mism = await reconcile(conn, store_id)
    await audit(conn, store_id, actor, "support.view_summary", {})
    return {"customers": row["customers"], "receivables": int(row["recv"]), "credits": int(row["cred"]),
            "invoices": inv, "failed_outbox": failed, "mismatches": len(mism)}
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/domain/subscriptions.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Store subscriptions. v1: seller requests a period, sees the price, central admin
approves manually. Renewal of an active subscription is appended to the current end."""
from __future__ import annotations

import datetime as dt

import asyncpg

from ..errors import UserError
from .common import audit

MAX_DAYS = 3650


async def plans(conn: asyncpg.Connection, *, active_only: bool = True) -> list[asyncpg.Record]:
    return list(await conn.fetch("SELECT * FROM subscription_plans" + (" WHERE is_active" if active_only else "") +
                                 " ORDER BY kind, days NULLS LAST, id"))


async def quote(conn: asyncpg.Connection, store_id: int, plan_id: int, days: int | None) -> tuple[int, int, asyncpg.Record]:
    plan = await conn.fetchrow("SELECT * FROM subscription_plans WHERE id=$1 AND is_active", plan_id)
    if plan is None:
        raise UserError("این تعرفه در دسترس نیست.")
    custom = await conn.fetchval("SELECT price_rial FROM store_plan_prices WHERE store_id=$1 AND plan_id=$2",
                                 store_id, plan_id)
    if plan["kind"] == "package":
        return int(plan["days"]), int(custom if custom is not None else plan["price_rial"]), plan
    if days is None or not (plan["min_days"] <= days <= plan["max_days"]):
        raise UserError(f"تعداد روز باید بین {plan['min_days']} و {plan['max_days']} باشد.")
    rate = int(custom if custom is not None else plan["daily_rate_rial"])
    return days, rate * days, plan


async def create_request(conn: asyncpg.Connection, store_id: int, actor: int, plan_id: int, days: int | None) -> asyncpg.Record:
    d, price, plan = await quote(conn, store_id, plan_id, days)
    pending = await conn.fetchval("SELECT count(*) FROM subscription_requests WHERE store_id=$1 AND status='pending'",
                                  store_id)
    if pending:
        raise UserError("یک درخواست تمدید در انتظار بررسی دارید.")
    r = await conn.fetchrow(
        """INSERT INTO subscription_requests(store_id, plan_id, days, price_rial, requested_by)
           VALUES($1,$2,$3,$4,$5) RETURNING *""", store_id, plan_id, d, price, actor)
    await audit(conn, store_id, actor, "subscription.request", {"request_id": r["id"], "days": d, "price_rial": price})
    return r


async def extend(conn: asyncpg.Connection, store_id: int, actor: int, days: int, *, price_rial: int = 0,
                 source: str = "grant", request_id: int | None = None) -> dt.datetime:
    if not (0 < days <= MAX_DAYS):
        raise UserError("تعداد روز نامعتبر است.")
    st = await conn.fetchrow("SELECT subscription_end FROM stores WHERE id=$1 FOR UPDATE", store_id)
    now = dt.datetime.now(dt.timezone.utc)
    start = st["subscription_end"] if st["subscription_end"] and st["subscription_end"] > now else now
    end = start + dt.timedelta(days=days)
    await conn.execute("INSERT INTO subscription_periods(store_id, start_at, end_at, days, price_rial, source, request_id, "
                       "created_by) VALUES($1,$2,$3,$4,$5,$6,$7,$8)", store_id, start, end, days, price_rial, source,
                       request_id, actor)
    await conn.execute("UPDATE stores SET subscription_end=$2, updated_at=now() WHERE id=$1", store_id, end)
    await audit(conn, store_id, actor, "subscription.extend", {"days": days, "start": start, "end": end, "source": source})
    return end


async def decide(conn: asyncpg.Connection, request_id: int, actor: int, approve: bool, note: str | None = None):
    r = await conn.fetchrow(
        "UPDATE subscription_requests SET status=$2, decided_by=$3, decided_at=now(), note=$4 "
        "WHERE id=$1 AND status='pending' RETURNING *", request_id, "approved" if approve else "rejected", actor, note)
    if r is None:
        raise UserError("این درخواست قبلاً بررسی شده یا وجود ندارد.")
    end = None
    if approve:
        end = await extend(conn, r["store_id"], actor, r["days"], price_rial=r["price_rial"], source="request",
                           request_id=r["id"])
    return r, end


async def set_suspended(conn: asyncpg.Connection, store_id: int, actor: int, suspended: bool, reason: str | None):
    await conn.execute("UPDATE stores SET suspended=$2, suspended_reason=$3, updated_at=now() WHERE id=$1",
                       store_id, suspended, reason if suspended else None)
    await audit(conn, store_id, actor, "subscription.suspend" if suspended else "subscription.unsuspend", {"reason": reason})
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/errors.py" 0644 <<'SHOPBOTS_FILE_EOF'
class UserError(Exception):
    """Error whose message is safe to show to the Telegram user (Persian)."""


class AccessDenied(UserError):
    pass


class StaleOperation(UserError):
    """The account changed between confirmation steps; preview must be refreshed."""


class AlreadyDone(Exception):
    def __init__(self, result=None):
        super().__init__("already done")
        self.result = result or {}
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/fsm.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Tiny persistent FSM (Postgres), keyed by (bot, chat, user)."""
from __future__ import annotations

import asyncpg


async def get(conn: asyncpg.Connection, bot: int, chat: int, user: int) -> tuple[str | None, dict]:
    r = await conn.fetchrow("SELECT state, data FROM fsm_states WHERE bot_tg_id=$1 AND chat_id=$2 AND user_id=$3",
                            bot, chat, user)
    return (r["state"], dict(r["data"])) if r else (None, {})


async def set(conn: asyncpg.Connection, bot: int, chat: int, user: int, state: str | None, data: dict | None = None):
    await conn.execute(
        """INSERT INTO fsm_states(bot_tg_id, chat_id, user_id, state, data, updated_at) VALUES($1,$2,$3,$4,$5,now())
           ON CONFLICT (bot_tg_id, chat_id, user_id) DO UPDATE SET state=EXCLUDED.state, data=EXCLUDED.data, updated_at=now()""",
        bot, chat, user, state, data or {})


async def clear(conn, bot, chat, user):
    await set(conn, bot, chat, user, None, {})
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/handlers/__init__.py" 0644 <<'SHOPBOTS_FILE_EOF'

SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/handlers/central.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Central (owner) bot: register stores, approve subscriptions, suspend/enable, grant support."""
from __future__ import annotations

from ..crypto import TokenCipher, bot_id_from_token
from ..domain import stores_admin, subscriptions
from ..errors import UserError
from ..fsm import clear, get as fsm_get, set as fsm_set
from ..textutil import clean_text, esc, fa, parse_positive_int, to_en_digits
from .common import BACK, Ctx, kb

MENU = kb([("➕ فروشگاه جدید", "c:new"), ("🏪 فروشگاه‌ها", "c:list")],
          [("🔑 درخواست‌های اشتراک", "c:req")])


async def home(ctx: Ctx):
    await clear(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id)
    await ctx.reply("👑 <b>پنل مدیریت سامانه</b>", MENU)


async def stores_list(ctx: Ctx):
    rows = await ctx.conn.fetch("SELECT id, name, bot_username, bot_status, subscription_end, suspended, is_enabled "
                                "FROM stores ORDER BY id")
    lines = []
    for r in rows:
        state = "⛔️ غیرفعال" if not r["is_enabled"] else "⏸ تعلیق" if r["suspended"] else \
            ("✅ فعال" if r["subscription_end"] and r["subscription_end"].timestamp() > __import__("time").time() else "⌛️ منقضی")
        lines.append(f"{fa(r['id'])}. <b>{esc(r['name'])}</b> @{esc(r['bot_username'] or '-')} · {state} · ربات: {esc(r['bot_status'])}")
    await ctx.reply("🏪 <b>فروشگاه‌ها</b>\n" + ("\n".join(lines) or "—"), kb([BACK]))


async def requests(ctx: Ctx):
    rows = await ctx.conn.fetch("""SELECT r.id, r.days, r.price_rial, s.name FROM subscription_requests r
        JOIN stores s ON s.id=r.store_id WHERE r.status='pending' ORDER BY r.id LIMIT 10""")
    if not rows:
        await ctx.reply("درخواست در انتظاری نیست.", kb([BACK]))
        return
    btns = []
    for r in rows:
        btns.append([(f"✅ {r['name']} · {fa(r['days'])} روز", f"c:ok:{r['id']}"), ("✖️", f"c:no:{r['id']}")])
    await ctx.reply("🔑 <b>درخواست‌های تمدید</b> (با تأیید شما فعال می‌شود):", kb(*btns, [BACK]))


async def new_store_start(ctx: Ctx):
    await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "ns:name", {})
    await ctx.reply("نام فروشگاه؟", kb([BACK]))


async def new_store_step(ctx: Ctx, state: str, data: dict, cipher: TokenCipher, central_bot_tg_id: int):
    t = (ctx.text or "").strip()
    if state == "ns:name":
        data["name"] = clean_text(t, max_len=100)
        await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "ns:token", data)
        await ctx.reply("توکن ربات فروشگاه (از BotFather). پیام توکن پس از ثبت حذف نمی‌شود؛ لطفاً خودتان پاکش کنید.", kb([BACK]))
    elif state == "ns:token":
        bid = bot_id_from_token(t)
        if bid is None or bid == central_bot_tg_id:
            raise UserError("توکن نامعتبر است یا توکن ربات مرکزی است.")
        data["token"], data["bot_id"] = t, bid
        await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "ns:admin", data)
        await ctx.reply("آیدی عددی تلگرام مالک فروشگاه؟", kb([BACK]))
    elif state == "ns:admin":
        data["admin"] = parse_positive_int(t)
        await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "ns:days", data)
        await ctx.reply("مدت اشتراک اولیه (روز)؟ «۰» یعنی فعلاً بدون اشتراک.", kb([BACK]))
    elif state == "ns:days":
        days = parse_positive_int(t, allow_zero=True, maximum=3650)
        name = data["name"]
        await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, None, {})
        from ..tg import verify_token
        from ..tg import BotPool
        bot = BotPool().get(data["bot_id"], data["token"])
        try:
            me = await verify_token(bot)
        finally:
            await bot.session.close()
        sid = await stores_admin.create_store(ctx.conn, cipher, ctx.user_id, name=data["name"], token=data["token"],
                                              bot_tg_id=data["bot_id"], bot_username=me.username,
                                              admin_id=data["admin"], initial_days=days)
        await ctx.reply(f"✅ فروشگاه <b>{esc(name)}</b> ثبت شد (شناسه {fa(sid)}). "
                        "ربات فروشگاه در چند ثانیه آنلاین می‌شود.", MENU)


async def decide(ctx: Ctx, rid: int, approve: bool):
    r, end = await subscriptions.decide(ctx.conn, rid, ctx.user_id, approve)
    await ctx.reply(("✅ تمدید تأیید شد." if approve else "✖️ درخواست رد شد.") +
                    (f" پایان اعتبار جدید: {fa(end.date())}" if end else ""), MENU)


async def route(ctx: Ctx, cipher: TokenCipher, central_bot_tg_id: int):
    state, data = await fsm_get(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id)
    if ctx.data:
        p = ctx.data.split(":")
        if ctx.data == "m:home" or ctx.data == "c:home":
            return await home(ctx)
        if ctx.data == "c:new":
            return await new_store_start(ctx)
        if ctx.data == "c:list":
            return await stores_list(ctx)
        if ctx.data == "c:req":
            return await requests(ctx)
        if p[0] == "c" and p[1] in ("ok", "no"):
            return await decide(ctx, int(p[2]), p[1] == "ok")
        return await home(ctx)
    if state and state.startswith("ns:"):
        return await new_store_step(ctx, state, data, cipher, central_bot_tg_id)
    return await home(ctx)
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/handlers/common.py" 0644 <<'SHOPBOTS_FILE_EOF'
from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass
class Ctx:
    """Everything a handler needs. store_id is resolved from the receiving bot, never from user input."""
    conn: Any
    pool: Any
    bot_tg_id: int
    chat_id: int
    user_id: int
    store_id: int | None
    text: str | None = None
    data: str | None = None
    reply: Any = None   # callable(text, buttons) -> sends/edits the message
    state: str | None = None
    fsm: dict | None = None
    currency: str = "toman"


def kb(*rows: list[tuple[str, str]]) -> list[list[dict]]:
    return [[{"text": t, "data": d} for t, d in r] for r in rows]


BACK = ("⬅️ بازگشت", "m:home")
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/handlers/store_bot.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Seller and customer handlers for one store's bot. Every query is scoped by ctx.store_id."""
from __future__ import annotations

import logging
import uuid

from ..errors import AccessDenied, UserError
from ..domain import common as dcommon
from ..domain import corrections, customers, payments, pendingops, products, reports, sales
from ..fsm import clear, get as fsm_get, set as fsm_set
from ..money import fmt_money, parse_amount
from ..phone import normalize_phone
from ..render import text as R
from ..render.excel import customer_list_xlsx, management_xlsx, statement_xlsx
from ..textutil import clean_code, clean_text, esc, fa, fmt_qty, parse_percent, parse_qty, to_en_digits
from ..timefmt import now_utc
from .common import BACK, Ctx, kb

log = logging.getLogger(__name__)
MENU = kb([("🛒 فروش نقدی", "m:cash"), ("📒 فروش به حساب", "m:acc")],
          [("👥 حساب مشتری‌ها", "m:cust"), ("➕ ثبت مشتری", "m:newcust")],
          [("📦 مدیریت کالاها", "m:prod"), ("➕ ثبت کالا", "m:newprod")],
          [("💳 ثبت پرداخت", "m:pay"), ("✏️ اصلاح و لغو", "m:corr")],
          [("📊 گزارش‌ها", "m:rep"), ("⚙️ تنظیمات", "m:set")],
          [("📈 وضعیت اشتراک", "m:sub")])
PAY_PREFIX = "pay"


def menu_text(store) -> str:
    return f"🏪 <b>{esc(store.name)}</b>\nیکی از گزینه‌ها را انتخاب کنید:"


async def load(ctx: Ctx):
    return await dcommon.load_store(ctx.conn, ctx.store_id)


async def start(ctx: Ctx):
    st = await load(ctx)
    if await dcommon.role_of(ctx.conn, ctx.store_id, ctx.user_id):
        await ctx.reply(menu_text(st), MENU)
        return
    link = await ctx.conn.fetchrow("SELECT customer_id FROM customer_links WHERE store_id=$1 AND tg_user_id=$2",
                                   ctx.store_id, ctx.user_id)
    if link:
        await customer_home(ctx, link["customer_id"])
        return
    await ctx.reply("برای دسترسی به حساب خود، شماره‌ام را به اشتراک می‌گذارم را بزنید.\n"
                    "(تایپ شماره کافی نیست.)", None)


async def share_contact(ctx: Ctx, phone_raw: str, contact_user_id: int | None):
    """Customer self-link: contact must be the sender's own, and match exactly one account."""
    if contact_user_id != ctx.user_id:
        raise UserError("فقط شماره خودتان را با دکمه اشتراک‌گذاری ارسال کنید.")
    norm = normalize_phone(phone_raw)
    rows = await ctx.conn.fetch("SELECT id FROM customers WHERE store_id=$1 AND phone=$2 AND archived_at IS NULL",
                                ctx.store_id, norm) if norm else []
    if len(rows) != 1:
        await ctx.reply("حساب مطابق با این شماره پیدا نشد یا نیاز به بررسی فروشنده دارد. با فروشگاه تماس بگیرید.", None)
        return
    await ctx.conn.execute(
        """INSERT INTO customer_links(store_id, tg_user_id, customer_id, phone_at_link) VALUES($1,$2,$3,$4)
           ON CONFLICT (store_id, customer_id) DO NOTHING""", ctx.store_id, ctx.user_id, rows[0]["id"], norm)
    await customer_home(ctx, rows[0]["id"])


async def customer_home(ctx: Ctx, customer_id: int):
    st = await load(ctx)
    c = await customers.get(ctx.conn, ctx.store_id, customer_id)
    link = await ctx.conn.fetchrow("SELECT tg_user_id FROM customer_links WHERE store_id=$1 AND customer_id=$2 AND tg_user_id=$3",
                                   ctx.store_id, customer_id, ctx.user_id)
    if link is None:
        raise AccessDenied("این حساب به شما متصل نیست.")
    await ctx.reply(R.customer_card(st, c, linked=True),
                    kb([("📄 دریافت صورت‌حساب کامل", "cst:stmt")]))


async def customer_statement_for_self(ctx: Ctx):
    link = await ctx.conn.fetchrow("SELECT customer_id FROM customer_links WHERE store_id=$1 AND tg_user_id=$2",
                                   ctx.store_id, ctx.user_id)
    if link is None:
        raise AccessDenied("حساب شما متصل نیست.")
    st = await load(ctx)
    cutoff = await ctx.conn.fetchval("SELECT last_value FROM fin_event_seq")
    data = await reports.customer_statement(ctx.conn, ctx.store_id, link["customer_id"], int(cutoff))
    header, lines = R.statement_lines(st, data)
    for part in R.split_parts(header, lines):
        await ctx.reply(part, None)
    await ctx.conn.execute(
        """INSERT INTO outbox(store_id, via, chat_id, kind, content, payload, dedupe_key)
           VALUES($1,'store',$2,'file',$3,$4,$5) ON CONFLICT (dedupe_key) DO NOTHING""",
        ctx.store_id, ctx.user_id, statement_xlsx(st, data),
        {"filename": f"statement-{data['customer']['code']}.xlsx", "caption": "فایل اکسل صورت‌حساب"},
        f"selfstmt:{ctx.store_id}:{ctx.user_id}:{uuid.uuid4()}")


async def home(ctx: Ctx):
    await clear(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id)
    st = await load(ctx)
    await ctx.reply(menu_text(st), MENU)


async def require_role(ctx: Ctx):
    role = await dcommon.role_of(ctx.conn, ctx.store_id, ctx.user_id)
    if role is None:
        raise AccessDenied("شما ادمین این فروشگاه نیستید.")
    return role


# ---------- product management ----------
async def new_product_start(ctx: Ctx):
    await require_role(ctx)
    await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "np:code", {})
    await ctx.reply("کد کالا را وارد کنید (حروف انگلیسی/عدد، حداکثر ۲۰ نویسه):", kb([BACK]))


async def new_product_step(ctx: Ctx, state: str, data: dict):
    t = ctx.text or ""
    if state == "np:code":
        data["code"] = clean_code(t)
        await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "np:name", data)
        await ctx.reply("نام کالا؟", kb([BACK]))
    elif state == "np:name":
        data["name"] = clean_text(t, max_len=100)
        await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "np:unit", data)
        await ctx.reply("نوع واحد را انتخاب کنید:", kb([("عددی", "np:unit:count"), ("کیلویی", "np:unit:kg")], [BACK]))
    elif state == "np:price":
        data["price"] = parse_amount(t, ctx.currency, allow_zero=True)
        await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "np:markup", data)
        await ctx.reply("درصد افزایش نسیه این کالا؟ (مثلاً ۱۰ یا ۰ برای بدون افزایش)", kb([BACK]))
    elif state == "np:markup":
        data["markup"] = parse_percent(t)
        await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, None, {})
        p = await products.create(ctx.conn, ctx.store_id, ctx.user_id, code=data["code"], name=data["name"], category=None,
                                  unit_type=data["unit"], cash_price_rial=data["price"], markup_pct=data["markup"])
        await ctx.reply(f"✅ کالا ثبت شد: <b>{esc(p['name'])}</b> (<code>{esc(p['code'])}</code>)", MENU)


# ---------- sales ----------
async def sale_start(ctx: Ctx, kind: str):
    await require_role(ctx)
    await dcommon.require_admin(ctx.conn, ctx.store_id, ctx.user_id)
    cart = {"kind": kind, "items": [], "customer_id": None}
    if kind == "account":
        await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "sale:customer", cart)
        await ctx.reply("مشتری را با کد، نام یا شماره جست‌وجو کنید:", kb([BACK]))
    else:
        await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "sale:product", cart)
        await ctx.reply("نام یا کد کالا را بفرستید:", kb([("🧺 سبد فعلی", "sale:cart"), BACK]))


async def sale_search_customer(ctx: Ctx, data: dict):
    rows, total = await customers.search(ctx.conn, ctx.store_id, ctx.text, limit=8)
    if not rows:
        await ctx.reply("مشتری‌ای پیدا نشد. دوباره جست‌وجو کنید.", kb([BACK]))
        return
    await ctx.reply("مشتری را انتخاب کنید:",
                    kb(*[[(f"{r['name']} · {fa(r['code'])}", f"sc:{r['id']}")] for r in rows], [BACK]))


async def sale_pick_customer(ctx: Ctx, cid: int, data: dict):
    c = await customers.get(ctx.conn, ctx.store_id, cid)
    data["customer_id"] = cid
    await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "sale:product", data)
    await ctx.reply(f"مشتری: <b>{esc(c['name'])}</b>. حالا نام یا کد کالا را بفرستید:", kb([("🧺 سبد", "sale:cart"), BACK]))


async def sale_search_product(ctx: Ctx, data: dict):
    rows, _ = await products.search(ctx.conn, ctx.store_id, ctx.text, active_only=True, limit=8)
    if not rows:
        await ctx.reply("کالایی پیدا نشد.", kb([BACK]))
        return
    await ctx.reply("کالا را انتخاب کنید:",
                    kb(*[[(f"{r['name']} ({'کیلویی' if r['unit_type'] == 'kg' else 'عددی'})", f"sp:{r['id']}")] for r in rows], [BACK]))


async def sale_pick_product(ctx: Ctx, pid: int, data: dict):
    p = await products.get(ctx.conn, ctx.store_id, pid)
    data["pending_pid"] = pid
    hint = "وزن (مثلاً ۰٫۲۵ کیلوگرم)" if p["unit_type"] == "kg" else "تعداد (عدد صحیح مثبت)"
    await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "sale:qty", data)
    await ctx.reply(f"<b>{esc(p['name'])}</b>: {hint} را وارد کنید:", kb([BACK]))


async def sale_qty(ctx: Ctx, data: dict):
    p = await products.get(ctx.conn, ctx.store_id, data["pending_pid"])
    qty = parse_qty(ctx.text or "", p["unit_type"])
    data["items"].append({"pid": p["id"], "qty": str(qty)})
    await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "sale:product", data)
    rows = [("➕ کالای دیگر", "sale:more"), ("👀 پیش‌نمایش فاکتور", "sale:preview")]
    await ctx.reply(f"✅ {esc(p['name'])} {fmt_qty(qty, p['unit_type'])} به سبد اضافه شد.", kb(rows, [("🗑 حذف آخرین قلم", "sale:undo")], [BACK]))


async def sale_preview(ctx: Ctx, data: dict):
    if not data["items"]:
        raise UserError("سبد خالی است.")
    res = await sales.preview(ctx.conn, ctx.store_id, ctx.user_id, kind=data["kind"], items=data["items"],
                              customer_id=data["customer_id"])
    account = None
    if res["account"]:
        a = res["account"]
        account = {"balance_before": a["balance_before"], "credit_used": a["credit_used"], "balance_after": a["balance_after"]}
    limit_msg = None
    if res["limit_state"] == "block":
        limit_msg = "⛔️ این فروش از سقف بدهی مشتری بیشتر است و مجاز نیست."
    elif res["limit_state"] == "warn":
        limit_msg = f"⚠️ این فروش از سقف بدهی عبور می‌کند ({fmt_money(res['over_rial'], ctx.currency)} بیشتر)."
    text = R.invoice_preview(res["store"], kind=data["kind"], rate_type=res["rate_type"], lines=res["lines"],
                             total=res["total"], customer=res["customer"], account=account, limit_msg=limit_msg)
    op = str(res["op_id"])
    buttons = []
    if res["limit_state"] == "block":
        buttons = kb([BACK])
    elif res["limit_state"] == "warn":
        buttons = kb([("✅ تأیید با عبور از سقف", f"ok:{op}:1")], [("✖️ انصراف", f"cx:{op}")])
    else:
        buttons = kb([("✅ ثبت قطعی فاکتور", f"ok:{op}:0")], [("✖️ انصراف", f"cx:{op}")])
    await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "sale:review", data)
    await ctx.reply(text, buttons)


async def sale_confirm(ctx: Ctx, op_id: str, override: bool):
    res = await sales.commit(ctx.pool, ctx.store_id, ctx.user_id, uuid.UUID(op_id), override_limit=override)
    await clear(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id)
    st = await load(ctx)
    if res.get("already"):
        await ctx.reply("این فاکتور قبلاً ثبت شده است.", MENU)
        return
    inv, lines = await sales.invoice_with_lines(ctx.conn, ctx.store_id, invoice_id=res["invoice_id"])
    cust = await customers.get(ctx.conn, ctx.store_id, inv["customer_id"]) if inv["customer_id"] else None
    await ctx.reply(R.invoice_final(st, inv, lines, cust), MENU)


async def sale_cancel(ctx: Ctx, op_id: str):
    await pendingops.cancel(ctx.conn, uuid.UUID(op_id), store_id=ctx.store_id, actor=ctx.user_id)
    await clear(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id)
    await ctx.reply("فروش لغو شد. هیچ تغییری ثبت نشد.", MENU)


# ---------- payments ----------
async def pay_start(ctx: Ctx):
    await require_role(ctx)
    await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "pay:customer", {})
    await ctx.reply("مشتری را جست‌وجو کنید:", kb([BACK]))


async def pay_amount(ctx: Ctx, data: dict):
    amount = parse_amount(ctx.text or "", ctx.currency)
    res = await payments.preview(ctx.conn, ctx.store_id, ctx.user_id, data["customer_id"], amount, None)
    e = res["effect"]
    text = (f"💳 <b>پرداخت مشتری</b>\nمشتری: <b>{esc(res['customer']['name'])}</b>\n"
            f"مبلغ دریافتی: <b>{fmt_money(amount, ctx.currency)}</b>\n"
            f"مانده قبل: {fmt_money(e['balance_before'], ctx.currency)}\n"
            f"مانده بعد از پرداخت: <b>{fmt_money(e['balance_after'], ctx.currency)}</b>\n"
            "<i>ربات فقط ثبت می‌کند؛ دریافت وجه را خودتان با کارت‌خوان تأیید کنید.</i>")
    await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, None, {})
    op = str(res["op_id"])
    await ctx.reply(text, kb([("✅ پرداخت شد، ثبت کن", f"pp:{op}")], [("✖️ انصراف", f"cx:{op}")]))


async def pay_confirm(ctx: Ctx, op_id: str):
    res = await payments.commit(ctx.pool, ctx.store_id, ctx.user_id, uuid.UUID(op_id))
    st = await load(ctx)
    if res.get("already"):
        await ctx.reply("این پرداخت قبلاً ثبت شده است.", MENU)
        return
    await ctx.reply(f"✅ پرداخت <code>PAY-{fa(res['number'])}</code> ثبت شد. "
                    f"مانده جدید: <b>{fmt_money(res['balance_after'], st.currency)}</b>", MENU)


# ---------- customers ----------
async def customers_list(ctx: Ctx, query: str | None, offset: int, debtors: bool):
    await require_role(ctx)
    rows, total = await customers.search(ctx.conn, ctx.store_id, query, offset=offset, only_debtors=debtors)
    if not rows and not offset:
        await ctx.reply("مشتری‌ای پیدا نشد.", kb([BACK]))
        return
    st = await load(ctx)
    lines = [f"{fa(r['code'])} · {esc(r['name'])} · {fmt_money(abs(r['balance_rial']), st.currency)} "
             f"({'بدهکار' if r['balance_rial'] > 0 else 'بستانکار' if r['balance_rial'] < 0 else 'تسویه'})" for r in rows]
    btns = [[(f"{r['name']} · {fa(r['code'])}", f"cu:{r['id']}")] for r in rows]
    nav = []
    if offset:
        nav.append(("◀️ قبلی", f"cl:{offset - customers.PAGE}:{int(debtors)}"))
    if offset + customers.PAGE < total:
        nav.append(("بعدی ▶️", f"cl:{offset + customers.PAGE}:{int(debtors)}"))
    await ctx.reply(f"👥 <b>مشتری‌ها</b> ({fa(total)} مورد)\n" + "\n".join(lines),
                    kb(*btns, *([nav] if nav else []), [BACK]))


async def customer_card(ctx: Ctx, cid: int):
    await require_role(ctx)
    st = await load(ctx)
    c = await customers.get(ctx.conn, ctx.store_id, cid)
    linked = await ctx.conn.fetchval("SELECT count(*) FROM customer_links WHERE store_id=$1 AND customer_id=$2",
                                     ctx.store_id, cid)
    await ctx.reply(R.customer_card(st, c, linked=bool(linked)),
                    kb([("📄 صورت‌حساب کامل", f"cs:{cid}"), ("💳 ثبت پرداخت", f"cp:{cid}")],
                       [("✏️ ویرایش نام", f"ce:name:{cid}"), ("📱 ویرایش تلفن", f"ce:phone:{cid}")],
                       [("🔄 نوع نرخ", f"ce:rate:{cid}"), ("🚫 بایگانی", f"ce:arch:{cid}")],
                       [BACK]))


async def new_customer_start(ctx: Ctx):
    await require_role(ctx)
    await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "nc:name", {})
    await ctx.reply("نام مشتری؟", kb([BACK]))


async def new_customer_step(ctx: Ctx, state: str, data: dict):
    t = (ctx.text or "").strip()
    if state == "nc:name":
        data["name"] = clean_text(t, max_len=100)
        await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "nc:phone", data)
        await ctx.reply("شماره تلفن (یا «-» برای نداشتن):", kb([BACK]))
    elif state == "nc:phone":
        if t in ("-", "—"):
            data["phone"] = None
        else:
            data["phone"] = normalize_phone(t)
            if not data["phone"]:
                raise UserError("شماره تلفن نامعتبر است.")
        await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "nc:rate", data)
        await ctx.reply("نوع نرخ مشتری؟", kb([("نرخ نقدی", "nr:cash"), ("نرخ نسیه", "nr:credit")], [BACK]))
    elif state == "nc:opening":
        if t in ("0", "۰", "صفر"):
            opening = 0
        elif t.startswith(("ب ", "ب", "بستانکار")):
            # «ب 5000» = opening credit (customer owes us nothing, we owe them)
            num = t.replace("بستانکار", "").replace("ب", "", 1).strip()
            opening = -parse_amount(num, ctx.currency)
        else:
            opening = parse_amount(t, ctx.currency)
        data["opening"] = opening
        await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, None, {})
        from datetime import date
        c = await customers.create(ctx.conn, ctx.store_id, ctx.user_id, name=data["name"], phone=data["phone"],
                                   rate_type=data["rate"], note=None, limit_mode="none", limit_rial=None,
                                   opening_rial=opening, opening_date=date.today(), opening_note="مانده اول دوره")
        st = await load(ctx)
        await ctx.reply("✅ مشتری ثبت شد.\n" + R.customer_card(st, c), kb([("👤 باز کردن حساب", f"cu:{c['id']}")], [BACK]))


async def nc_rate(ctx: Ctx, rate: str):
    data = (await fsm_get(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id))[1]
    data["rate"] = rate
    await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "nc:opening", data)
    await ctx.reply("مانده اول دوره؟ «۰» برای صفر، مبلغ عادی برای بدهکار، یا «ب مبلغ» برای بستانکار.", kb([BACK]))


# ---------- reports (on-demand) ----------
async def report_menu(ctx: Ctx):
    await require_role(ctx)
    await ctx.reply("کدام گزارش؟", kb([("📋 فهرست مانده مشتری‌ها", "rp:list")],
                                       [("📊 گزارش مدیریتی امروز", "rp:today"), ("📊 گزارش مدیریتی این ماه", "rp:month")],
                                       [BACK]))


async def report_send(ctx: Ctx, which: str):
    await require_role(ctx)
    st = await load(ctx)
    from ..timefmt import local_day_bounds, month_bounds, local_today
    if which == "list":
        rows = await reports.customer_list(ctx.conn, ctx.store_id)
        rid = reports.new_report_id("LST")
        header, lines = R.customer_list_lines(st, rows, now_utc(), rid)
        for part in R.split_parts(header, lines):
            await ctx.reply(part, None)
        for i, blob in enumerate(customer_list_xlsx(st, rows, now_utc(), rid), 1):
            await ctx.conn.execute("""INSERT INTO outbox(store_id, via, chat_id, kind, content, payload, dedupe_key)
                VALUES($1,'store',$2,'file',$3,$4,$5)""", ctx.store_id, ctx.chat_id, blob,
                                   {"filename": f"customers-{i}.xlsx"}, f"rep:{rid}:{i}:{ctx.chat_id}:{uuid.uuid4()}")
        return
    if which == "today":
        d = local_today(st.timezone)
        start, end = local_day_bounds(d, st.timezone)
    else:
        start, end = month_bounds(st.timezone, st.jalali)
    rep = await reports.management(ctx.conn, ctx.store_id, start, end)
    header, lines = R.management_lines(st, rep)
    for part in R.split_parts(header, lines):
        await ctx.reply(part, None)
    await ctx.conn.execute("""INSERT INTO outbox(store_id, via, chat_id, kind, content, payload, dedupe_key)
        VALUES($1,'store',$2,'file',$3,$4,$5)""", ctx.store_id, ctx.chat_id, management_xlsx(st, rep),
                           {"filename": f"management-{which}.xlsx"}, f"mgmt:{ctx.store_id}:{ctx.chat_id}:{uuid.uuid4()}")


async def statement_for_seller(ctx: Ctx, cid: int):
    await require_role(ctx)
    st = await load(ctx)
    cutoff = int(await ctx.conn.fetchval("SELECT last_value FROM fin_event_seq"))
    data = await reports.customer_statement(ctx.conn, ctx.store_id, cid, cutoff)
    header, lines = R.statement_lines(st, data)
    for part in R.split_parts(header, lines):
        await ctx.reply(part, None)
    await ctx.conn.execute("""INSERT INTO outbox(store_id, via, chat_id, kind, content, payload, dedupe_key)
        VALUES($1,'store',$2,'file',$3,$4,$5)""", ctx.store_id, ctx.chat_id, statement_xlsx(st, data),
                           {"filename": f"statement-{data['customer']['code']}.xlsx"},
                           f"stmt-seller:{data['report_id']}:{ctx.chat_id}")


# ---------- corrections (3-step) ----------
async def corr_start(ctx: Ctx, invoice_number: int):
    await require_role(ctx)
    await dcommon.require_admin(ctx.conn, ctx.store_id, ctx.user_id)
    inv = await ctx.conn.fetchval("SELECT id FROM invoices WHERE store_id=$1 AND number=$2", ctx.store_id, invoice_number)
    if inv is None:
        raise UserError("فاکتوری با این شماره پیدا نشد.")
    await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "corr:reason",
                  {"invoice_id": inv, "kind": "cancel_invoice"})
    await ctx.reply("دلیل لغو این فاکتور را بنویسید (حداقل ۳ نویسه):", kb([BACK]))


async def corr_reason(ctx: Ctx, data: dict):
    data["reason"] = clean_text(ctx.text, max_len=200)
    kind = data.pop("kind")
    op_id, text = await corrections.start(ctx.conn, ctx.store_id, ctx.user_id, kind, data)
    await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, None, {})
    await ctx.reply(text, kb([("✅ ادامه (مرحله ۱)", f"cf:{op_id}:1")], [("✖️ انصراف", f"cx:{op_id}")]))


async def corr_advance(ctx: Ctx, op_id: str, step: int):
    res = await corrections.advance(ctx.pool, ctx.store_id, ctx.user_id, uuid.UUID(op_id), step)
    if res["done"]:
        st = await load(ctx)
        await ctx.reply(f"✅ ثبت شد: <code>{esc(res.get('ref'))}</code>. گزارش‌ها در صف ارسال هستند.", MENU)
        return
    nxt = res["step"]
    await ctx.reply(res["text"], kb([(f"✅ تأیید (مرحله {fa(nxt)})", f"cf:{op_id}:{nxt}")], [("✖️ انصراف", f"cx:{op_id}")]))


async def cancel_any(ctx: Ctx, op_id: str):
    ok = await pendingops.cancel(ctx.conn, uuid.UUID(op_id), store_id=ctx.store_id, actor=ctx.user_id)
    await clear(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id)
    await ctx.reply("انصراف داده شد. هیچ تغییر مالی ثبت نشد." if ok else "این عملیات دیگر فعال نیست.", MENU)


# ---------- subscription ----------
async def sub_info(ctx: Ctx):
    st = await load(ctx)
    end = st.subscription_end
    status = "فعال" if st.writable() else ("تعلیق" if st.suspended else "منقضی/غیرفعال")
    await ctx.reply(f"📈 <b>وضعیت اشتراک</b>\nوضعیت: <b>{status}</b>\n"
                    f"پایان اعتبار: {R.fmt_dt(end, st.timezone, st.jalali) if end else '-'}\n"
                    "برای تمدید به مدیر سامانه پیام دهید.", MENU)


# ---------- settings ----------
async def settings_menu(ctx: Ctx):
    await require_role(ctx)
    st = await load(ctx)
    await ctx.reply(f"⚙️ <b>تنظیمات</b>\nواحد پول: {'تومان' if st.currency == 'toman' else 'ریال'}\n"
                    f"تقویم: {'شمسی' if st.jalali else 'میلادی'} | منطقه زمانی: {esc(st.timezone)}\n"
                    f"گزارش گروه: {esc(st.report_chat_title or 'تنظیم نشده')}",
                    kb([("💱 تغییر واحد پول", "st:cur"), ("📅 تقویم شمسی/میلادی", "st:cal")],
                       [("👥 تنظیم گروه گزارش", "st:grp")], [BACK]))


async def toggle_setting(ctx: Ctx, field: str):
    await dcommon.require_admin(ctx.conn, ctx.store_id, ctx.user_id, owner=True)
    if field == "currency":
        await ctx.conn.execute("UPDATE stores SET currency = CASE WHEN currency='toman' THEN 'rial' ELSE 'toman' END "
                               "WHERE id=$1", ctx.store_id)
        await dcommon.audit(ctx.conn, ctx.store_id, ctx.user_id, "store.currency_display_change", {})
    elif field == "jalali":
        await ctx.conn.execute("UPDATE stores SET jalali = NOT jalali WHERE id=$1", ctx.store_id)
    await settings_menu(ctx)


# ---------- router ----------
async def route(ctx: Ctx):
    """Dispatch a callback or text message. Old/expired callbacks degrade to the menu."""
    state, data = await fsm_get(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id)
    d = ctx.data
    t = (ctx.text or "").strip()
    if d:
        p = d.split(":")
        head = p[0]
        if d == "m:home" or d == "cx:home":
            return await home(ctx)
        if d == "m:cash":
            return await sale_start(ctx, "cash")
        if d == "m:acc":
            return await sale_start(ctx, "account")
        if d == "m:cust":
            return await customers_list(ctx, None, 0, False)
        if d == "m:newcust":
            return await new_customer_start(ctx)
        if d == "m:prod":
            await require_role(ctx)
            rows, total = await products.search(ctx.conn, ctx.store_id, None, active_only=False, limit=15)
            body = "\n".join(f"{esc(r['name'])} · <code>{esc(r['code'])}</code> · {fmt_money(r['cash_price_rial'], ctx.currency)} "
                             f"· نسیه +{fa(r['credit_markup_pct'])}٪ · {'فعال' if r['is_active'] else 'غیرفعال'}" for r in rows)
            return await ctx.reply(f"📦 <b>کالاها</b> ({fa(total)})\n{body or '—'}", kb([("➕ ثبت کالا", "m:newprod")], [BACK]))
        if d == "m:newprod":
            return await new_product_start(ctx)
        if d.startswith("np:unit:"):
            await require_role(ctx)
            data["unit"] = d.split(":")[2]
            await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "np:price", data)
            return await ctx.reply("قیمت نقدی هر واحد؟ (تومان)", kb([BACK]))
        if d == "m:pay":
            return await pay_start(ctx)
        if d == "m:rep":
            return await report_menu(ctx)
        if d.startswith("rp:"):
            return await report_send(ctx, d.split(":")[1])
        if d == "m:set":
            return await settings_menu(ctx)
        if d == "st:cur":
            return await toggle_setting(ctx, "currency")
        if d == "st:cal":
            return await toggle_setting(ctx, "jalali")
        if d == "m:sub":
            return await sub_info(ctx)
        if d == "m:corr":
            await require_role(ctx)
            return await ctx.reply("برای لغو فاکتور، شماره فاکتور را به شکل «لغو 123» بفرستید.", kb([BACK]))
        if head == "sc":
            return await sale_pick_customer(ctx, int(p[1]), data)
        if head == "sp":
            return await sale_pick_product(ctx, int(p[1]), data)
        if d == "sale:more":
            await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "sale:product", data)
            return await ctx.reply("نام یا کد کالای بعدی را بفرستید:", kb([("👀 پیش‌نمایش", "sale:preview"), BACK]))
        if d == "sale:undo":
            if data.get("items"):
                data["items"].pop()
            await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "sale:product", data)
            return await ctx.reply(f"آخرین قلم حذف شد. تعداد اقلام سبد: {fa(len(data.get('items', [])))}",
                                   kb([("👀 پیش‌نمایش", "sale:preview")], [BACK]))
        if d == "sale:preview":
            return await sale_preview(ctx, data)
        if d == "sale:cart":
            return await ctx.reply(f"سبد: {fa(len(data.get('items', [])))} قلم", kb([("👀 پیش‌نمایش", "sale:preview")], [BACK]))
        if head == "ok":
            return await sale_confirm(ctx, p[1], p[2] == "1")
        if head == "pp":
            return await pay_confirm(ctx, p[1])
        if head == "cx":
            return await cancel_any(ctx, p[1])
        if head == "cu":
            return await customer_card(ctx, int(p[1]))
        if head == "cs":
            return await statement_for_seller(ctx, int(p[1]))
        if head == "cp":
            cust = await customers.get(ctx.conn, ctx.store_id, int(p[1]))
            await fsm_set(ctx.conn, ctx.bot_tg_id, ctx.chat_id, ctx.user_id, "pay:amount", {"customer_id": cust["id"]})
            return await ctx.reply(f"مبلغ دریافتی از <b>{esc(cust['name'])}</b> را به {'تومان' if ctx.currency == 'toman' else 'ریال'} بفرستید:", kb([BACK]))
        if head == "cl":
            return await customers_list(ctx, None, int(p[1]), p[2] == "1")
        if head == "nr":
            return await nc_rate(ctx, p[1])
        if head == "cf":
            return await corr_advance(ctx, p[1], int(p[2]))
        if head == "cst" and p[1] == "stmt":
            return await customer_statement_for_self(ctx)
        return await home(ctx)

    # text messages
    if ctx.text and ctx.text.startswith(("لغو ", "لغو")) and state is None:
        n = to_en_digits(ctx.text).replace("لغو", "").strip()
        if n.isdigit():
            return await corr_start(ctx, int(n))
    if state is None:
        return await home(ctx)
    if state == "sale:customer":
        return await sale_search_customer(ctx, data)
    if state == "sale:product":
        return await sale_search_product(ctx, data)
    if state == "sale:qty":
        return await sale_qty(ctx, data)
    if state == "pay:customer":
        rows, _ = await customers.search(ctx.conn, ctx.store_id, t, limit=8)
        await ctx.reply("مشتری را انتخاب کنید:", kb(*[[(f"{r['name']} · {fa(r['code'])}", f"cp:{r['id']}")] for r in rows], [BACK]))
        return
    if state == "pay:amount":
        return await pay_amount(ctx, data)
    if state == "corr:reason":
        return await corr_reason(ctx, data)
    if state.startswith(("np:", "nc:")):
        if state.startswith("np:"):
            return await new_product_step(ctx, state, data)
        return await new_customer_step(ctx, state, data)
    return await home(ctx)


__all__ = ["route", "start", "share_contact", "customer_statement_for_self"]
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/jalali.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Gregorian <-> Jalali conversion (arithmetic algorithm, valid for 1900-2200)."""
from __future__ import annotations

import datetime as dt

_G_D_M = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]


def g2j(gy: int, gm: int, gd: int) -> tuple[int, int, int]:
    gy2 = gy + 1 if gm > 2 else gy
    days = 355666 + 365 * gy + (gy2 + 3) // 4 - (gy2 + 99) // 100 + (gy2 + 399) // 400 + gd + _G_D_M[gm - 1]
    jy = -1595 + 33 * (days // 12053)
    days %= 12053
    jy += 4 * (days // 1461)
    days %= 1461
    if days > 365:
        jy += (days - 1) // 365
        days = (days - 1) % 365
    if days < 186:
        jm, jd = 1 + days // 31, 1 + days % 31
    else:
        jm, jd = 7 + (days - 186) // 30, 1 + (days - 186) % 30
    return jy, jm, jd


def j2g(jy: int, jm: int, jd: int) -> tuple[int, int, int]:
    jy += 1595
    days = -355668 + 365 * jy + (jy // 33) * 8 + ((jy % 33) + 3) // 4 + jd
    days += (jm - 1) * 31 if jm < 7 else (jm - 7) * 30 + 186
    gy = 400 * (days // 146097)
    days %= 146097
    if days > 36524:
        days -= 1
        gy += 100 * (days // 36524)
        days %= 36524
        if days >= 365:
            days += 1
    gy += 4 * (days // 1461)
    days %= 1461
    if days > 365:
        gy += (days - 1) // 365
        days = (days - 1) % 365
    gd = days + 1
    leap = (gy % 4 == 0 and gy % 100 != 0) or gy % 400 == 0
    months = [0, 31, 29 if leap else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    gm = 0
    while gm < 13 and gd > months[gm]:
        gd -= months[gm]
        gm += 1
    return gy, gm, gd


def jalali_month_length(jy: int, jm: int) -> int:
    if jm <= 6:
        return 31
    if jm <= 11:
        return 30
    gy, gm, gd = j2g(jy + 1, 1, 1)
    last = dt.date(gy, gm, gd) - dt.timedelta(days=1)
    return g2j(last.year, last.month, last.day)[2]


def date_from_jalali(jy: int, jm: int, jd: int) -> dt.date:
    if not (1 <= jm <= 12) or not (1 <= jd <= jalali_month_length(jy, jm)):
        raise ValueError("invalid jalali date")
    return dt.date(*j2g(jy, jm, jd))


def to_jalali_str(d: dt.date) -> str:
    y, m, dd = g2j(d.year, d.month, d.day)
    return f"{y:04d}/{m:02d}/{dd:02d}"
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/log.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Logging with size-based rotation and a redaction filter for bot tokens / secrets."""
from __future__ import annotations

import logging
import logging.handlers
import os
import re
import sys

_TOKEN_RE = re.compile(r"\b\d{6,12}:[A-Za-z0-9_-]{30,}\b")
_BOT_URL_RE = re.compile(r"/bot\d{6,12}:[A-Za-z0-9_-]{30,}")


def redact(s: str) -> str:
    s = _BOT_URL_RE.sub("/bot<redacted>", s)
    return _TOKEN_RE.sub("<redacted-token>", s)


class RedactFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        try:
            msg = record.getMessage()
        except Exception:
            return True
        red = redact(msg)
        if red != msg:
            record.msg, record.args = red, ()
        if record.exc_info and record.exc_info[1] is not None:
            text = logging.Formatter().formatException(record.exc_info)
            record.exc_text = redact(text)
        return True


def setup_logging(log_dir: str | None, level: str = "INFO") -> None:
    root = logging.getLogger()
    root.setLevel(level.upper())
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
    flt = RedactFilter()
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stdout)]
    if log_dir and os.path.isdir(log_dir) and os.access(log_dir, os.W_OK):
        handlers.append(logging.handlers.RotatingFileHandler(
            os.path.join(log_dir, "shopbots.log"), maxBytes=10 * 1024 * 1024, backupCount=5, encoding="utf-8"))
    for h in handlers:
        h.setFormatter(fmt)
        h.addFilter(flt)
        root.addHandler(h)
    # aiohttp/aiogram may log request URLs; keep them quiet and redacted.
    for noisy in ("aiohttp.access", "aiogram.event"):
        logging.getLogger(noisy).setLevel(logging.WARNING)
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/money.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Money: stored as integer RIAL (BIGINT) everywhere. 1 toman = 10 rial.

Display currency never changes stored values.
"""
from __future__ import annotations

from decimal import ROUND_DOWN, ROUND_HALF_UP, ROUND_UP, Decimal

from .errors import UserError
from .textutil import _clean_number, fa

RIAL_PER_TOMAN = 10
MAX_AMOUNT_RIAL = 10**15
ROUNDING_MODES = {"half_up": ROUND_HALF_UP, "down": ROUND_DOWN, "up": ROUND_UP}
ROUNDING_UNITS = (1, 10, 100, 1000, 10000)
CURRENCY_LABEL = {"toman": "تومان", "rial": "ریال"}


def round_rial(value, unit: int = 1, mode: str = "half_up") -> int:
    if unit <= 0:
        raise ValueError("rounding unit must be positive")
    v = Decimal(value)
    q = (v / Decimal(unit)).quantize(Decimal(1), rounding=ROUNDING_MODES[mode])
    return int(q * unit)


def credit_unit_price(cash_price_rial: int, markup_pct) -> int:
    """credit price = cash * (1 + pct/100), rounded half-up to whole rial."""
    pct = Decimal(markup_pct)
    if pct < 0:
        raise ValueError("negative markup")
    return round_rial(Decimal(cash_price_rial) * (Decimal(1) + pct / Decimal(100)), 1, "half_up")


def unit_price_for(rate_type: str, cash_price_rial: int, markup_pct) -> int:
    if rate_type == "cash":
        return int(cash_price_rial)
    if rate_type == "credit":
        return credit_unit_price(cash_price_rial, markup_pct)
    raise ValueError("unknown rate type")


def line_amount(unit_price_rial: int, qty, unit: int, mode: str) -> int:
    return round_rial(Decimal(unit_price_rial) * Decimal(qty), unit, mode)


def to_display(rial: int, currency: str) -> Decimal:
    if currency == "toman":
        return Decimal(rial) / RIAL_PER_TOMAN
    return Decimal(rial)


def fmt_money(rial: int, currency: str, *, with_unit: bool = True, signed: bool = False) -> str:
    v = to_display(int(rial), currency)
    neg = v < 0
    v = abs(v)
    if v == v.to_integral_value():
        s = f"{int(v):,}"
    else:
        s = f"{v:,.1f}"
    s = s.replace(",", "٬").replace(".", "٫")
    if neg:
        s = "−" + s
    elif signed and v != 0:
        s = "+" + s
    s = fa(s)
    return f"{s} {CURRENCY_LABEL[currency]}" if with_unit else s


def parse_amount(text: str, currency: str, *, allow_zero: bool = False) -> int:
    """Parse a user-entered amount in the store's display currency -> rial."""
    s = _clean_number(text)
    if s.startswith("-") or s.startswith("−"):
        raise UserError("مبلغ منفی پذیرفته نیست.")
    if not s.isdigit() or len(s) > 16:
        raise UserError(f"مبلغ را به‌صورت عدد صحیح به {CURRENCY_LABEL[currency]} وارد کنید.")
    v = int(s)
    rial = v * RIAL_PER_TOMAN if currency == "toman" else v
    if rial == 0 and not allow_zero:
        raise UserError("مبلغ باید بیشتر از صفر باشد.")
    if rial > MAX_AMOUNT_RIAL:
        raise UserError("مبلغ بیش از حد مجاز است.")
    return rial


def balance_status(balance_rial: int) -> str:
    if balance_rial > 0:
        return "بدهکار"
    if balance_rial < 0:
        return "بستانکار"
    return "تسویه"


def fmt_balance(balance_rial: int, currency: str) -> str:
    return f"{fmt_money(abs(balance_rial), currency)} ({balance_status(balance_rial)})"
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/outbox.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Outbox dispatcher: at-least-once delivery with leases, backoff and rate-limit awareness.
Telegram failures never touch financial rows (they are committed before enqueueing)."""
from __future__ import annotations

import asyncio
import logging
import os
import socket

import asyncpg

from .render.text import split_parts
from .tg import BotPool, SendError

log = logging.getLogger(__name__)
WORKER_ID = f"{socket.gethostname()}:{os.getpid()}"
LEASE = "2 minutes"


def backoff_seconds(attempts: int) -> int:
    return min(3600, 15 * (2 ** min(attempts, 8)))


async def claim(conn: asyncpg.Connection, limit: int = 20) -> list[asyncpg.Record]:
    return list(await conn.fetch(
        """UPDATE outbox SET status='sending', attempts=attempts+1, locked_until = now() + interval '%s'
            WHERE id IN (SELECT id FROM outbox WHERE status='pending' AND next_attempt_at <= now()
                          ORDER BY id LIMIT $1 FOR UPDATE SKIP LOCKED)
           RETURNING *""" % LEASE, limit))


async def release_stale(conn: asyncpg.Connection) -> None:
    await conn.execute("UPDATE outbox SET status='pending' WHERE status='sending' AND locked_until < now()")


async def mark_sent(conn, row_id: int):
    await conn.execute("UPDATE outbox SET status='sent', sent_at=now(), locked_until=NULL, last_error=NULL WHERE id=$1", row_id)


async def mark_failed(conn, row, err: str, max_attempts: int, *, permanent: bool, retry_after: float | None):
    if permanent or row["attempts"] >= max_attempts:
        await conn.execute("UPDATE outbox SET status='failed', last_error=$2, locked_until=NULL WHERE id=$1",
                           row["id"], err[:500])
    else:
        delay = retry_after or backoff_seconds(row["attempts"])
        await conn.execute("UPDATE outbox SET status='pending', last_error=$2, locked_until=NULL, "
                           "next_attempt_at = now() + make_interval(secs => $3) WHERE id=$1",
                           row["id"], err[:500], float(delay))


async def deliver(pool: asyncpg.Pool, bots: BotPool, row, resolve_bot, max_attempts: int) -> None:
    """resolve_bot(row) -> (aiogram Bot) or raises SendError(permanent=True)."""
    async with pool.acquire() as conn:
        try:
            bot = await resolve_bot(conn, row)
            kind = row["kind"]
            payload = row["payload"] or {}
            if kind == "text":
                await BotPool.send(bot, row["chat_id"], payload["text"], payload.get("buttons"))
            elif kind == "file":
                await BotPool.send_file(bot, row["chat_id"], payload["filename"], bytes(row["content"]),
                                        payload.get("caption"))
            else:
                raise SendError(f"unknown outbox kind {kind}", permanent=True)
            await mark_sent(conn, row["id"])
        except SendError as e:
            log.warning("outbox %s send failed: %s", row["id"], e)
            await mark_failed(conn, row, str(e), max_attempts, permanent=e.permanent, retry_after=e.retry_after)
        except Exception as e:  # never let one row kill the worker
            log.exception("outbox %s unexpected error", row["id"])
            await mark_failed(conn, row, type(e).__name__, max_attempts, permanent=False, retry_after=None)
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/phone.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Phone normalisation. Canonical form: +<country><number>, digits only after '+'."""
from __future__ import annotations

import re

from .textutil import to_en_digits


def normalize_phone(raw: str | None) -> str | None:
    if raw is None:
        return None
    s = to_en_digits(str(raw)).strip()
    s = re.sub(r"[\s\-\(\)\.\u200c]", "", s)
    if s.startswith("00"):
        s = "+" + s[2:]
    plus = s.startswith("+")
    digits = s[1:] if plus else s
    if not digits.isdigit():
        return None
    # Iranian mobile/landline forms
    if not plus:
        if digits.startswith("0") and len(digits) == 11:          # 09121234567 / 02112345678
            return "+98" + digits[1:]
        if digits.startswith("9") and len(digits) == 10:          # 9121234567
            return "+98" + digits
        if digits.startswith("98") and len(digits) == 12:         # 989121234567 (Telegram contact)
            return "+" + digits
    if digits.startswith("980") and len(digits) == 13:            # +9809121234567 typo form
        digits = "98" + digits[3:]
    if 8 <= len(digits) <= 15 and not digits.startswith("0"):
        return "+" + digits
    return None
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/render/__init__.py" 0644 <<'SHOPBOTS_FILE_EOF'
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/render/excel.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Real, editable .xlsx output (openpyxl): RTL sheets, bold headers, autofilter,
numeric formats, phones stored as text, and formula-injection protection."""
from __future__ import annotations

import io
import re
from decimal import Decimal

from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

from ..money import CURRENCY_LABEL, balance_status, to_display
from ..timefmt import fmt_dt

_DANGEROUS = ("=", "+", "-", "@", "\t", "\r", "\n", "｜", "＝")
HEADER_FILL = PatternFill("solid", fgColor="1F4E78")
HEADER_FONT = Font(bold=True, color="FFFFFF")
TITLE_FONT = Font(bold=True, size=14)
THIN = Side(style="thin", color="BBBBBB")
BORDER = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)
MAX_ROWS_PER_FILE = 200_000


def safe_text(v) -> str:
    """Neutralise spreadsheet formula injection for any user-supplied string."""
    s = "" if v is None else str(v)
    if s and s[0] in _DANGEROUS:
        return "'" + s
    return s


class Sheet:
    def __init__(self, ws, currency: str):
        self.ws = ws
        self.currency = currency
        self.ws.sheet_view.rightToLeft = True
        self.row = 1
        self.money_fmt = "#,##0" if currency == "rial" else "#,##0.0"

    def title(self, text: str, width: int):
        c = self.ws.cell(row=self.row, column=1, value=safe_text(text))
        c.font = TITLE_FONT
        if width > 1:
            self.ws.merge_cells(start_row=self.row, start_column=1, end_row=self.row, end_column=width)
        self.row += 1

    def kv(self, key: str, value, *, money: bool = False):
        self.ws.cell(row=self.row, column=1, value=safe_text(key)).font = Font(bold=True)
        self._put(self.row, 2, value, "money" if money else "text")
        self.row += 1

    def blank(self):
        self.row += 1

    def table(self, headers: list[tuple[str, str, int]], rows: list[list]):
        """headers: (title, type, width) with type in text|money|qty|int|phone"""
        hr = self.row
        for i, (h, _, w) in enumerate(headers, 1):
            c = self.ws.cell(row=hr, column=i, value=h)
            c.fill, c.font, c.border = HEADER_FILL, HEADER_FONT, BORDER
            c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
            self.ws.column_dimensions[get_column_letter(i)].width = w
        self.row += 1
        for r in rows:
            for i, v in enumerate(r, 1):
                cell = self._put(self.row, i, v, headers[i - 1][1])
                cell.border = BORDER
            self.row += 1
        last = self.row - 1
        if last >= hr:
            self.ws.auto_filter.ref = f"A{hr}:{get_column_letter(len(headers))}{max(last, hr)}"
        self.ws.freeze_panes = self.ws.cell(row=hr + 1, column=1)

    def _put(self, row, col, value, typ):
        ws = self.ws
        if typ == "money":
            v = None if value is None else float(to_display(int(value), self.currency))
            c = ws.cell(row=row, column=col, value=v)
            c.number_format = self.money_fmt
        elif typ == "qty":
            c = ws.cell(row=row, column=col, value=None if value is None else float(Decimal(value)))
            c.number_format = "#,##0.###"
        elif typ == "int":
            c = ws.cell(row=row, column=col, value=value)
            c.number_format = "0"
        else:  # text / phone (phones are validated "+digits" and kept as text to preserve format)
            sval = str(value) if typ == "phone" and re.fullmatch(r"\+?\d{0,15}", str(value or "")) else safe_text(value)
            c = ws.cell(row=row, column=col, value=sval)
            c.number_format = "@"
            c.data_type = "s"
        c.alignment = Alignment(horizontal="right", vertical="top", wrap_text=(typ == "text"))
        return c


def _wb_bytes(wb: Workbook) -> bytes:
    bio = io.BytesIO()
    wb.save(bio)
    return bio.getvalue()


def _fmt(store, d):
    return fmt_dt(d, store.timezone, store.jalali, persian_digits=False)


def statement_xlsx(store, data) -> bytes:
    cur = store.currency
    wb = Workbook()
    s = Sheet(wb.active, cur)
    wb.active.title = "خلاصه"
    c = data["customer"]
    t = data["totals"]
    s.title(f"صورت‌حساب کامل مشتری - {store.name}", 2)
    s.kv("نام مشتری", c["name"])
    s.kv("کد مشتری", str(c["code"]))
    s.kv("شماره تلفن", c["phone"] or "")
    s.kv("واحد پول", CURRENCY_LABEL[cur])
    s.kv("زمان تهیه", _fmt(store, data["generated_at"]))
    s.kv("شناسه گزارش", data["report_id"])
    s.kv("نقطه برش رویداد", str(data["cutoff_seq"]))
    s.blank()
    s.kv("مانده اول دوره", t["opening"], money=True)
    s.kv("خرید به حساب", t["account_sales"], money=True)
    s.kv("خرید نقدی (بدون اثر بر مانده)", t["cash_sales"], money=True)
    s.kv("پرداخت‌ها و پیش‌پرداخت‌ها", t["payments"], money=True)
    s.kv("مرجوعی/اصلاحات کاهنده", t["decreases"], money=True)
    s.kv("اصلاحات افزاینده", t["increases"], money=True)
    s.kv("مرجوعی نقدی پرداختی", t["cash_refunds"], money=True)
    s.kv("مانده نهایی (مثبت = بدهکار)", data["balance"], money=True)
    s.kv("وضعیت", balance_status(data["balance"]))
    wb.active.column_dimensions["A"].width = 34
    wb.active.column_dimensions["B"].width = 30

    s2 = Sheet(wb.create_sheet("گردش حساب"), cur)
    s2.title(f"گردش حساب {c['name']} (کد {c['code']})", 9)
    rows = []
    for i, ev in enumerate(data["events"], 1):
        rows.append([i, _fmt(store, ev["at"]), ev["label"], str(ev.get("ref") or ""), ev.get("desc") or "",
                     ev["debit"] or None, ev["credit"] or None,
                     ev["balance"] if ev["affects"] else None, "بله" if ev["affects"] else "خیر"])
    s2.table([("ردیف", "int", 7), ("تاریخ", "text", 18), ("نوع", "text", 24), ("مرجع", "text", 12),
              ("شرح", "text", 40), ("بدهکار", "money", 16), ("بستانکار", "money", 16),
              ("مانده پس از رویداد", "money", 18), ("اثر بر مانده", "text", 12)], rows)

    s3 = Sheet(wb.create_sheet("ریز اقلام"), cur)
    s3.title("ریز اقلام فاکتورها", 10)
    items = []
    for ev in data["events"]:
        for it in ev.get("items", []):
            items.append([str(ev.get("ref") or ""), _fmt(store, ev["at"]), ev["label"], it["product_code"],
                          it["product_name"], "کیلوگرم" if it["unit_type"] == "kg" else "عدد", it["qty"],
                          it["unit_price_rial"], it["amount_rial"], it.get("status", "")])
    s3.table([("فاکتور", "text", 10), ("تاریخ", "text", 18), ("نوع", "text", 22), ("کد کالا", "text", 12),
              ("نام کالا", "text", 26), ("واحد", "text", 9), ("مقدار", "qty", 10), ("قیمت واحد", "money", 15),
              ("مبلغ", "money", 15), ("وضعیت/تغییرات", "text", 30)], items)
    return _wb_bytes(wb)


def customer_list_xlsx(store, rows, generated_at, report_id) -> list[bytes]:
    files = []
    chunks = [rows[i:i + MAX_ROWS_PER_FILE] for i in range(0, len(rows), MAX_ROWS_PER_FILE)] or [[]]
    for n, chunk in enumerate(chunks, 1):
        wb = Workbook()
        s = Sheet(wb.active, store.currency)
        wb.active.title = "مانده مشتری‌ها"
        s.title(f"فهرست مانده مشتری‌ها - {store.name}", 6)
        s.kv("زمان تهیه", _fmt(store, generated_at))
        s.kv("واحد پول", CURRENCY_LABEL[store.currency])
        s.kv("شناسه گزارش", report_id + (f" (بخش {n} از {len(chunks)})" if len(chunks) > 1 else ""))
        s.blank()
        s.table([("کد", "int", 8), ("نام", "text", 28), ("شماره تلفن", "phone", 16),
                 ("مانده (مثبت = بدهکار)", "money", 20), ("مبلغ مطلق", "money", 18), ("وضعیت", "text", 12)],
                [[r["code"], r["name"], r["phone"] or "", r["balance_rial"], abs(r["balance_rial"]),
                  balance_status(r["balance_rial"])] for r in chunk])
        files.append(_wb_bytes(wb))
    return files


def management_xlsx(store, rep) -> bytes:
    wb = Workbook()
    s = Sheet(wb.active, store.currency)
    wb.active.title = "خلاصه"
    s.title(f"گزارش مدیریتی - {store.name}", 2)
    s.kv("از", _fmt(store, rep["start"]))
    s.kv("تا", _fmt(store, rep["end"]))
    s.kv("زمان تهیه", _fmt(store, rep["generated_at"]))
    s.kv("واحد پول", CURRENCY_LABEL[store.currency])
    s.blank()
    s.kv("فروش نقدی خالص", rep["cash_sales"], money=True)
    s.kv("فروش به حساب خالص", rep["account_sales"], money=True)
    s.kv("پرداخت‌های دریافتی", rep["payments"], money=True)
    s.kv("مرجوعی نقدی پرداختی", rep["cash_refunds"], money=True)
    s.kv("مطالبات فعلی", rep["receivables"], money=True)
    s.kv("بستانکاری فعلی مشتری‌ها", rep["credits"], money=True)
    s.kv("توضیح", "ارقام فروش هستند نه سود؛ بهای خرید کالا ثبت نمی‌شود.")
    wb.active.column_dimensions["A"].width = 30
    wb.active.column_dimensions["B"].width = 30
    s2 = Sheet(wb.create_sheet("کالاهای پرفروش"), store.currency)
    s2.table([("ردیف", "int", 7), ("کد", "text", 12), ("نام کالا", "text", 28), ("واحد", "text", 10),
              ("مقدار", "qty", 12), ("مبلغ", "money", 18)],
             [[i, p["product_code"], p["product_name"], "کیلوگرم" if p["unit_type"] == "kg" else "عدد", p["qty"],
               p["amount"]] for i, p in enumerate(rep["all_products"], 1)])
    s3 = Sheet(wb.create_sheet("مشتری‌های بدهکار"), store.currency)
    s3.table([("کد", "int", 8), ("نام", "text", 28), ("شماره تلفن", "phone", 16), ("بدهی", "money", 18)],
             [[d["code"], d["name"], d["phone"] or "", d["balance_rial"]] for d in rep["all_debtors"]])
    s4 = Sheet(wb.create_sheet("بستانکاران"), store.currency)
    s4.table([("کد", "int", 8), ("نام", "text", 28), ("شماره تلفن", "phone", 16), ("بستانکاری", "money", 18)],
             [[d["code"], d["name"], d["phone"] or "", -d["balance_rial"]] for d in rep["all_creditors"]])
    return _wb_bytes(wb)
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/render/text.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Telegram HTML text rendering (only tags Telegram supports: b, i, code, pre, u)."""
from __future__ import annotations

from typing import Iterable

from ..money import balance_status, fmt_balance, fmt_money
from ..textutil import esc, fa, fmt_qty
from ..timefmt import fmt_dt

TG_LIMIT = 4096
SAFE_LIMIT = 3800
SEP = "┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄"
UNIT_FA = {"count": "عددی", "kg": "کیلویی"}
RATE_FA = {"cash": "نرخ نقدی", "credit": "نرخ نسیه"}
LIMIT_FA = {"none": "بدون محدودیت", "warn": "سقف با هشدار", "block": "سقف با جلوگیری"}


def split_parts(header: str, lines: Iterable[str], *, limit: int = SAFE_LIMIT) -> list[str]:
    """Split on line boundaries; every part gets a numbered header. Never drops content.
    A single over-long line is hard-wrapped."""
    chunks: list[list[str]] = [[]]
    size = 0
    budget = limit - len(header) - 40
    for ln in lines:
        while len(ln) > budget:
            head, ln = ln[:budget], ln[budget:]
            if chunks[-1]:
                chunks.append([])
            chunks[-1].append(head)
            chunks.append([])
            size = 0
        if size + len(ln) + 1 > budget and chunks[-1]:
            chunks.append([])
            size = 0
        chunks[-1].append(ln)
        size += len(ln) + 1
    chunks = [c for c in chunks if c] or [[]]
    n = len(chunks)
    out = []
    for i, c in enumerate(chunks, 1):
        h = header if n == 1 else f"{header}\n<i>بخش {fa(i)} از {fa(n)}</i>"
        out.append(h + "\n" + "\n".join(c))
    return out


def money(store, rial: int, **kw) -> str:
    return fmt_money(rial, store.currency, **kw)


def invoice_lines_text(store, lines) -> list[str]:
    out = []
    for i, ln in enumerate(lines, 1):
        out.append(f"{fa(i)}. <b>{esc(ln['product_name'])}</b> <code>{esc(ln['product_code'])}</code>")
        out.append(f"    {fmt_qty(ln['qty'], ln['unit_type'])} × {money(store, ln['unit_price_rial'])}"
                   f" = <b>{money(store, ln['amount_rial'])}</b>")
    return out


def invoice_preview(store, *, kind: str, rate_type: str, lines, total: int, customer=None, account=None,
                    limit_msg: str | None = None) -> str:
    title = "🧾 <b>پیش‌نمایش فاکتور فروش نقدی</b>" if kind == "cash" else "🧾 <b>پیش‌نمایش فاکتور فروش به حساب</b>"
    out = [title, SEP]
    if customer is not None:
        out.append(f"👤 مشتری: <b>{esc(customer['name'])}</b> (کد {fa(customer['code'])})")
    out.append(f"نرخ: {RATE_FA[rate_type]}")
    out.append(SEP)
    out += invoice_lines_text(store, lines)
    out.append(SEP)
    out.append(f"💰 جمع فاکتور: <b>{money(store, total)}</b>")
    if account:
        out.append(f"مانده قبلی: {fmt_balance(account['balance_before'], store.currency)}")
        out.append(f"بستانکاری قابل استفاده: {money(store, account['credit_used'])}")
        out.append(f"مانده جدید: <b>{fmt_balance(account['balance_after'], store.currency)}</b>")
    if kind == "cash" and customer is not None:
        out.append("<i>فروش نقدی است و به بدهی مشتری اضافه نمی‌شود؛ فقط در سابقه نمایش داده می‌شود.</i>")
    if limit_msg:
        out.append(limit_msg)
    return "\n".join(out)


def invoice_final(store, inv, lines, customer=None) -> str:
    kind = "فروش نقدی" if inv["kind"] == "cash" else "فروش به حساب"
    out = [f"✅ <b>فاکتور {kind} ثبت شد</b>", SEP,
           f"شماره فاکتور: <code>{fa(inv['number'])}</code>",
           f"تاریخ: {fmt_dt(inv['created_at'], store.timezone, store.jalali)}"]
    if customer is not None:
        out.append(f"👤 {esc(customer['name'])} (کد {fa(customer['code'])})")
    out.append(SEP)
    out += invoice_lines_text(store, lines)
    out.append(SEP)
    out.append(f"💰 جمع: <b>{money(store, inv['total_rial'])}</b>")
    if inv["kind"] == "account":
        out.append(f"مانده جدید: <b>{fmt_balance(inv['balance_after_rial'], store.currency)}</b>")
    if inv["cancelled_seq"]:
        out.append("⛔️ <b>این فاکتور لغو شده است.</b>")
    return "\n".join(out)


def customer_card(store, c, *, linked: bool = False) -> str:
    out = [f"👤 <b>{esc(c['name'])}</b>", SEP,
           f"کد مشتری: <code>{fa(c['code'])}</code>",
           f"تلفن: {fa(esc(c['phone'])) if c['phone'] else '-'}",
           f"نوع نرخ: {RATE_FA[c['rate_type']]}",
           f"سقف بدهی: {LIMIT_FA[c['limit_mode']]}" + (f" ({money(store, c['limit_rial'])})" if c['limit_mode'] != 'none' else ""),
           f"مانده: <b>{fmt_balance(c['balance_rial'], store.currency)}</b>"]
    if c["note"]:
        out.append(f"یادداشت: {esc(c['note'])}")
    if c["archived_at"]:
        out.append("🗄 <b>بایگانی‌شده</b>")
    out.append("📱 پنل مشتری: " + ("متصل" if linked else "متصل نیست"))
    return "\n".join(out)


def statement_lines(store, data) -> tuple[str, list[str]]:
    c = data["customer"]
    cur = store.currency
    header = (f"📒 <b>صورت‌حساب کامل مشتری</b> | {esc(store.name)}\n"
              f"👤 <b>{esc(c['name'])}</b> | کد {fa(c['code'])} | {fa(esc(c['phone'])) if c['phone'] else 'بدون شماره'}")
    out = [f"شناسه گزارش: <code>{esc(data['report_id'])}</code>",
           f"زمان تهیه: {fmt_dt(data['generated_at'], store.timezone, store.jalali)} | واحد: {money(store, 0).split()[-1]}",
           f"نقطه برش رویداد: <code>{fa(data['cutoff_seq'])}</code>", SEP]
    for ev in data["events"]:
        when = fmt_dt(ev["at"], store.timezone, store.jalali)
        amt = ""
        if ev["debit"]:
            amt = f"بدهکار {fmt_money(ev['debit'], cur)}"
        elif ev["credit"]:
            amt = f"بستانکار {fmt_money(ev['credit'], cur)}"
        elif ev.get("info_amount"):
            amt = f"مبلغ {fmt_money(ev['info_amount'], cur)}"
        line = f"▫️ {when} | <b>{esc(ev['label'])}</b>"
        if ev.get("ref"):
            line += f" #{fa(ev['ref'])}"
        out.append(line)
        if amt:
            out.append(f"    {amt}" + (f" | مانده: {fmt_balance(ev['balance'], cur)}" if ev["affects"] else " | <i>بدون اثر بر مانده</i>"))
        if ev.get("desc"):
            out.append(f"    {esc(ev['desc'])}")
        for it in ev.get("items", []):
            out.append(f"      • {esc(it['product_name'])}: {fmt_qty(it['qty'], it['unit_type'])} × "
                       f"{fmt_money(it['unit_price_rial'], cur)} = {fmt_money(it['amount_rial'], cur)}")
    t = data["totals"]
    out += [SEP, "<b>جمع‌ها</b>",
            f"مانده اول دوره: {fmt_balance(t['opening'], cur)}",
            f"خرید به حساب: {fmt_money(t['account_sales'], cur)}",
            f"خرید نقدی (بدون اثر بر مانده): {fmt_money(t['cash_sales'], cur)}",
            f"پرداخت‌ها و پیش‌پرداخت‌ها: {fmt_money(t['payments'], cur)}",
            f"مرجوعی/اصلاحات کاهنده: {fmt_money(t['decreases'], cur)}",
            f"اصلاحات افزاینده: {fmt_money(t['increases'], cur)}",
            f"مرجوعی نقدی پرداخت‌شده به مشتری: {fmt_money(t['cash_refunds'], cur)}",
            SEP,
            f"🔚 مانده نهایی: <b>{fmt_balance(data['balance'], cur)}</b>",
            f"وضعیت: <b>{balance_status(data['balance'])}</b>"]
    return header, out


def customer_list_lines(store, rows, generated_at, report_id) -> tuple[str, list[str]]:
    header = f"📋 <b>فهرست مانده حساب مشتری‌ها</b> | {esc(store.name)}"
    out = [f"زمان تهیه: {fmt_dt(generated_at, store.timezone, store.jalali)} | واحد: {money(store, 0).split()[-1]}",
           f"شناسه گزارش: <code>{esc(report_id)}</code>", SEP]
    debt = credit = 0
    for r in rows:
        b = r["balance_rial"]
        debt += max(b, 0)
        credit += max(-b, 0)
        phone = fa(esc(r["phone"])) if r["phone"] else "-"
        out.append(f"{fa(r['code'])} | {esc(r['name'])} | {phone} | {fmt_money(abs(b), store.currency)} | {balance_status(b)}")
    out += [SEP, f"تعداد مشتری: {fa(len(rows))}",
            f"جمع مطالبات (بدهی مشتری‌ها): {fmt_money(debt, store.currency)}",
            f"جمع بستانکاری مشتری‌ها: {fmt_money(credit, store.currency)}"]
    return header, out


def management_lines(store, rep) -> tuple[str, list[str]]:
    cur = store.currency
    header = f"📊 <b>گزارش مدیریتی</b> | {esc(store.name)}"
    out = [f"بازه: {fmt_dt(rep['start'], store.timezone, store.jalali)} تا {fmt_dt(rep['end'], store.timezone, store.jalali)}",
           f"زمان تهیه: {fmt_dt(rep['generated_at'], store.timezone, store.jalali)}", SEP,
           f"🛒 فروش نقدی (خالص): <b>{fmt_money(rep['cash_sales'], cur)}</b> ({fa(rep['cash_count'])} فاکتور)",
           f"📒 فروش به حساب (خالص): <b>{fmt_money(rep['account_sales'], cur)}</b> ({fa(rep['account_count'])} فاکتور)",
           f"💳 پرداخت‌های دریافتی: <b>{fmt_money(rep['payments'], cur)}</b> ({fa(rep['payment_count'])} مورد)",
           f"↩️ مرجوعی نقدی پرداختی: {fmt_money(rep['cash_refunds'], cur)}",
           SEP,
           f"📌 مطالبات فعلی (بدهی مشتری‌ها): <b>{fmt_money(rep['receivables'], cur)}</b>",
           f"📌 بستانکاری فعلی مشتری‌ها: <b>{fmt_money(rep['credits'], cur)}</b>",
           "<i>این ارقام «فروش» هستند، نه سود؛ بهای خرید کالا در سامانه ثبت نمی‌شود.</i>", SEP,
           "<b>کالاهای پرفروش (بر اساس مبلغ)</b>"]
    if not rep["top_products"]:
        out.append("—")
    for i, p in enumerate(rep["top_products"], 1):
        out.append(f"{fa(i)}. {esc(p['product_name'])} | {fmt_qty(p['qty'], p['unit_type'])} | {fmt_money(p['amount'], cur)}")
    out += [SEP, "<b>مشتری‌های بدهکار</b>"]
    if not rep["debtors"]:
        out.append("—")
    for d in rep["debtors"]:
        out.append(f"{fa(d['code'])} | {esc(d['name'])} | {fmt_money(d['balance_rial'], cur)}")
    if rep.get("debtors_more"):
        out.append(f"<i>و {fa(rep['debtors_more'])} مشتری بدهکار دیگر (فهرست کامل در فایل اکسل)</i>")
    return header, out
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/runtime.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Long-polling runners (one per bot token), scheduler and outbox worker.

Guarantees:
- one polling loop per bot: a Postgres advisory lock keyed by the bot id is held for the loop's life;
- each update is processed at most once: processed_updates is written in the same transaction as its effects;
- a broken token only stops its own runner; everything else keeps running;
- periodic reports are enqueued with a slot-based dedupe key, so concurrent workers never double-send."""
from __future__ import annotations

import asyncio
import datetime as dt
import logging
import uuid
from typing import Any

import asyncpg
from aiogram.types import Update

from . import outbox
from .config import Config
from .crypto import TokenCipher
from .domain import notify, reports
from .domain.common import Store, load_store
from .errors import AccessDenied, UserError
from .handlers import central as H_central
from .handlers import store_bot as H_store
from .handlers.common import Ctx
from .money import fmt_money
from .render import text as R
from .render.excel import customer_list_xlsx
from .timefmt import now_utc
from .tg import BotPool, SendError, verify_token

log = logging.getLogger(__name__)
ADVISORY_BASE = 8_100_000_000


def _lock_key(bot_tg_id: int) -> int:
    return ADVISORY_BASE + (bot_tg_id % 1_000_000_000)


class Runtime:
    def __init__(self, cfg: Config, pool: asyncpg.Pool, cipher: TokenCipher, central_token: str):
        self.cfg = cfg
        self.pool = pool
        self.cipher = cipher
        self.central_token = central_token
        self.central_id = int(central_token.split(":")[0])
        self.bots = BotPool()
        self.stop = asyncio.Event()
        self.tasks: dict[int, asyncio.Task] = {}

    # ---------- polling ----------
    async def run_poller(self, bot_tg_id: int, token: str, store_id: int | None):
        lock_conn = await self.pool.acquire()
        try:
            got = await lock_conn.fetchval("SELECT pg_try_advisory_lock($1)", _lock_key(bot_tg_id))
            if not got:
                log.error("another worker already polls bot %s; not starting a second loop", bot_tg_id)
                return
            bot = self.bots.get(bot_tg_id, token)
            try:
                me = await verify_token(bot)
            except SendError as e:
                await self._mark_bot(bot_tg_id, store_id, "invalid_token" if e.permanent else "error", str(e))
                return
            if me.id != bot_tg_id:
                await self._mark_bot(bot_tg_id, store_id, "invalid_token", "token does not match stored bot id")
                return
            await self._mark_bot(bot_tg_id, store_id, "running", None)
            backoff = 1
            while not self.stop.is_set():
                try:
                    offset = await lock_conn.fetchval("SELECT next_offset FROM bot_offsets WHERE bot_tg_id=$1", bot_tg_id) or 0
                    updates = await bot.get_updates(offset=offset, timeout=25,
                                                    allowed_updates=["message", "callback_query"])
                    backoff = 1
                    for u in updates:
                        await self._handle(bot_tg_id, token, store_id, u)
                        await lock_conn.execute(
                            """INSERT INTO bot_offsets(bot_tg_id, next_offset) VALUES($1,$2)
                               ON CONFLICT (bot_tg_id) DO UPDATE SET next_offset=GREATEST(bot_offsets.next_offset, EXCLUDED.next_offset), updated_at=now()""",
                            bot_tg_id, u.update_id + 1)
                except asyncio.CancelledError:
                    raise
                except Exception as e:
                    from aiogram.exceptions import TelegramUnauthorizedError
                    if isinstance(e, TelegramUnauthorizedError):
                        await self._mark_bot(bot_tg_id, store_id, "invalid_token", "token revoked")
                        return
                    log.warning("poll error bot %s: %s", bot_tg_id, type(e).__name__)
                    await asyncio.sleep(min(backoff, 60))
                    backoff = min(backoff * 2, 60)
        finally:
            try:
                await lock_conn.execute("SELECT pg_advisory_unlock($1)", _lock_key(bot_tg_id))
            finally:
                await self.pool.release(lock_conn)

    async def _mark_bot(self, bot_tg_id, store_id, status, detail):
        if store_id is not None:
            await self.pool.execute("UPDATE stores SET bot_status=$2, bot_status_detail=$3, updated_at=now() WHERE id=$1",
                                    store_id, status, (detail or "")[:300])

    async def _handle(self, bot_tg_id: int, token: str, store_id: int | None, upd: Update):
        async with self.pool.acquire() as conn:
            async with conn.transaction():
                inserted = await conn.fetchval(
                    "INSERT INTO processed_updates(bot_tg_id, update_id) VALUES($1,$2) ON CONFLICT DO NOTHING RETURNING 1",
                    bot_tg_id, upd.update_id)
                if not inserted:
                    return
                msg = upd.message
                cq = upd.callback_query
                chat_id = (msg.chat.id if msg else cq.message.chat.id if cq and cq.message else None)
                user_id = (msg.from_user.id if msg else cq.from_user.id)
                if chat_id is None:
                    return
                bot = self.bots.get(bot_tg_id, token)

                async def reply(text, buttons=None):
                    await BotPool.send(bot, chat_id, text, buttons)

                if cq:
                    try:
                        await bot.answer_callback_query(cq.id)   # stop the loading spinner on the button
                    except Exception:
                        pass

                if store_id is None:
                    if user_id != self.cfg.owner_id:
                        return
                    ctx = Ctx(conn=conn, pool=self.pool, bot_tg_id=bot_tg_id, chat_id=chat_id, user_id=user_id,
                              store_id=None, text=msg.text if msg else None, data=cq.data if cq else None, reply=reply)
                    await H_central.route(ctx, self.cipher, self.central_id)
                    return
                st = await load_store(conn, store_id)
                ctx = Ctx(conn=conn, pool=self.pool, bot_tg_id=bot_tg_id, chat_id=chat_id, user_id=user_id,
                          store_id=store_id, text=msg.text if msg else None, data=cq.data if cq else None,
                          reply=reply, currency=st.currency)
                if msg and msg.chat.type != "private":
                    await self._group_command(ctx, msg, st)
                    return
                if msg and msg.contact:
                    await self._guarded(ctx, st, lambda: H_store.share_contact(ctx, msg.contact.phone_number, msg.contact.user_id))
                    return
                if not st.is_enabled:
                    await reply("این فروشگاه غیرفعال است.")
                    return
                read_only = (cq is not None and cq.data is not None and
                             cq.data.startswith(("m:home", "m:cust", "cl:", "cu:", "cs:", "rp:", "m:sub", "cst:", "st:")))
                if not st.writable() and not read_only:
                    await reply(st.write_block_reason())
                    return
                if ctx.text and ctx.text.strip() == "/start":
                    return await self._guarded(ctx, st, lambda: H_store.start(ctx))
                await self._guarded(ctx, st, lambda: H_store.route(ctx))

    async def _guarded(self, ctx: Ctx, st: Store, fn):
        try:
            await fn()
        except AccessDenied as e:
            await ctx.reply(str(e))
        except UserError as e:
            await ctx.reply(f"⚠️ {e}")

    async def _group_command(self, ctx: Ctx, msg, st: Store):
        if (msg.text or "").strip() != "/setreport":
            return
        if await ctx.conn.fetchval("SELECT 1 FROM store_admins WHERE store_id=$1 AND tg_user_id=$2 AND role='owner'",
                                   ctx.store_id, ctx.user_id) is None:
            return
        await ctx.conn.execute("UPDATE stores SET report_chat_id=$2, report_chat_title=$3, updated_at=now() WHERE id=$1",
                               ctx.store_id, ctx.chat_id, (msg.chat.title or "")[:100])
        await ctx.conn.execute("INSERT INTO audit_log(store_id, actor_tg_id, action, details) VALUES($1,$2,'store.report_group_set',$3)",
                               ctx.store_id, ctx.user_id, {"chat_id": ctx.chat_id})
        await ctx.reply("✅ این گروه برای گزارش‌ها ثبت شد. ربات باید دسترسی ارسال پیام و فایل داشته باشد.\n"
                        "<i>توجه: گزارش‌ها شامل اطلاعات مالی و شماره تماس مشتری‌ها هستند؛ فقط اعضای مورد اعتماد را اضافه کنید.</i>", None)

    # ---------- scheduler ----------
    async def run_scheduler(self):
        while not self.stop.is_set():
            try:
                await self._tick_reports()
                await self._tick_reminders()
            except Exception:
                log.exception("scheduler tick failed")
            await asyncio.sleep(30)

    async def _tick_reports(self):
        now = now_utc()
        rows = await self.pool.fetch("""SELECT * FROM stores WHERE report_chat_id IS NOT NULL AND periodic_report_enabled
                                        AND is_enabled""")
        for r in rows:
            st = Store.from_row(r)
            if not st.subscription_active(now) and not st.expired_periodic_reports:
                continue
            period = st.periodic_report_minutes * 60
            slot_epoch = int(now.timestamp()) // period * period
            slot = dt.datetime.fromtimestamp(slot_epoch, dt.timezone.utc)
            if now.timestamp() - slot_epoch > 120:
                continue   # the slot is old (e.g. after a long downtime): wait for the next one
            async with self.pool.acquire() as conn:
                async with conn.transaction():
                    got = await conn.fetchval("INSERT INTO report_slots(store_id, slot_start) VALUES($1,$2) "
                                              "ON CONFLICT DO NOTHING RETURNING 1", st.id, slot)
                    if not got:
                        continue
                    rows2 = await reports.customer_list(conn, st.id)
                    rid = reports.new_report_id("LST")
                    header, lines = R.customer_list_lines(st, rows2, now, rid)
                    parts = R.split_parts(header, lines)
                    prev = None
                    for i, text in enumerate(parts, 1):
                        prev = await notify.enqueue(conn, via="store", store_id=st.id, chat_id=st.report_chat_id,
                                                    kind="text", payload={"text": text},
                                                    dedupe_key=f"slot:{st.id}:{slot_epoch}:t{i}", parent_id=prev, part_no=i)
                    for i, blob in enumerate(customer_list_xlsx(st, rows2, now, rid), 1):
                        await notify.enqueue(conn, via="store", store_id=st.id, chat_id=st.report_chat_id, kind="file",
                                             content=blob, payload={"filename": f"customers-{slot_epoch}-{i}.xlsx"},
                                             dedupe_key=f"slot:{st.id}:{slot_epoch}:f{i}")

    async def _tick_reminders(self):
        rows = await self.pool.fetch("SELECT id, name, subscription_end FROM stores WHERE subscription_end IS NOT NULL "
                                     "AND is_enabled")
        now = now_utc()
        for r in rows:
            left = (r["subscription_end"] - now).total_seconds() / 86400
            for d in (7, 3, 1):
                if 0 < left <= d:
                    async with self.pool.acquire() as conn:
                        async with conn.transaction():
                            ok = await conn.fetchval("INSERT INTO subscription_reminders(store_id, end_at, days_before) "
                                                     "VALUES($1,$2,$3) ON CONFLICT DO NOTHING RETURNING 1",
                                                     r["id"], r["subscription_end"], d)
                            if ok:
                                await notify.store_admins_text(
                                    conn, r["id"], f"⏰ اشتراک فروشگاه <b>{r['name']}</b> تا {d} روز دیگر تمام می‌شود.",
                                    owners_only=True, dedupe_prefix=f"rem:{r['id']}:{r['subscription_end'].timestamp():.0f}:{d}")
                    break

    # ---------- outbox ----------
    async def _resolve_bot(self, conn, row):
        if row["via"] == "central":
            return self.bots.get(self.central_id, self.central_token)
        st = await conn.fetchrow("SELECT bot_tg_id, bot_token_enc, is_enabled, suspended FROM stores WHERE id=$1", row["store_id"])
        if st is None or not st["is_enabled"] or not st["bot_token_enc"]:
            raise SendError("store bot unavailable", permanent=True)
        token = self.cipher.decrypt(st["bot_token_enc"])
        return self.bots.get(st["bot_tg_id"], token)

    async def run_outbox(self):
        while not self.stop.is_set():
            try:
                async with self.pool.acquire() as conn:
                    await outbox.release_stale(conn)
                    rows = await outbox.claim(conn, 20)
                if not rows:
                    await asyncio.sleep(2)
                    continue
                for row in rows:
                    await outbox.deliver(self.pool, self.bots, row, self._resolve_bot, self.cfg.outbox_max_attempts)
                    await asyncio.sleep(0.05)   # ~20 msg/s overall, well under Telegram's global limit
            except Exception:
                log.exception("outbox loop error")
                await asyncio.sleep(5)

    # ---------- supervisor ----------
    async def run(self):
        for t in (self.run_scheduler(), self.run_outbox()):
            self.tasks[id(t)] = asyncio.create_task(t)
        await self.sync_bots()
        while not self.stop.is_set():
            await self.sync_bots()
            await asyncio.sleep(20)

    async def sync_bots(self):
        """Start a poller for every enabled bot that is not running yet."""
        async with self.pool.acquire() as conn:
            key = ("central", self.central_id)
            if key not in self.tasks or self.tasks[key].done():
                self.tasks[key] = asyncio.create_task(self.run_poller(self.central_id, self.central_token, None))
            rows = await conn.fetch("SELECT id, bot_tg_id, bot_token_enc FROM stores WHERE is_enabled "
                                    "AND bot_token_enc IS NOT NULL AND bot_status <> 'invalid_token'")
        for r in rows:
            key = ("store", r["id"])
            t = self.tasks.get(key)
            if t and not t.done():
                continue
            try:
                token = self.cipher.decrypt(r["bot_token_enc"])
            except Exception:
                await self._mark_bot(r["bot_tg_id"], r["id"], "error", "cannot decrypt token; check master key")
                continue
            self.tasks[key] = asyncio.create_task(self.run_poller(r["bot_tg_id"], token, r["id"]))

    async def shutdown(self):
        self.stop.set()
        for t in self.tasks.values():
            t.cancel()
        await asyncio.gather(*self.tasks.values(), return_exceptions=True)
        await self.bots.close()
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/textutil.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Digit normalisation and strict numeric parsing for Persian/English input."""
from __future__ import annotations

import html
import re
from decimal import Decimal, InvalidOperation

from .errors import UserError

_FA = "۰۱۲۳۴۵۶۷۸۹"
_AR = "٠١٢٣٤٥٦٧٨٩"
_TO_EN = {ord(c): str(i) for i, c in enumerate(_FA)}
_TO_EN.update({ord(c): str(i) for i, c in enumerate(_AR)})
_TO_FA = {ord(str(i)): c for i, c in enumerate(_FA)}

MAX_COUNT = 1_000_000
MAX_WEIGHT = Decimal("100000")
WEIGHT_PLACES = 3


def to_en_digits(s: str) -> str:
    return s.translate(_TO_EN)


def fa(s) -> str:
    return str(s).translate(_TO_FA)


def esc(s) -> str:
    return html.escape("" if s is None else str(s), quote=False)


def _clean_number(text: str) -> str:
    if text is None:
        raise UserError("ورودی خالی است.")
    s = to_en_digits(str(text)).strip()
    s = s.replace("٫", ".")
    s = s.replace(",", "").replace("٬", "").replace(" ", "").replace("\u200c", "")
    return s


def parse_positive_int(text: str, *, maximum: int = 10**15, allow_zero: bool = False) -> int:
    s = _clean_number(text)
    if not re.fullmatch(r"\d{1,16}", s):
        raise UserError("لطفاً فقط یک عدد صحیح معتبر وارد کنید.")
    v = int(s)
    if v == 0 and not allow_zero:
        raise UserError("عدد باید بزرگ‌تر از صفر باشد.")
    if v > maximum:
        raise UserError("عدد وارد شده بیش از حد مجاز است.")
    return v


def parse_decimal(text: str, *, places: int, maximum: Decimal, allow_zero: bool = False) -> Decimal:
    s = _clean_number(text)
    if not re.fullmatch(r"\d{1,12}(\.\d{1,%d})?" % places, s) and not re.fullmatch(r"\.\d{1,%d}" % places, s):
        raise UserError(f"عدد نامعتبر است (حداکثر {fa(places)} رقم اعشار، بدون علامت منفی).")
    if s.startswith("."):
        s = "0" + s
    try:
        v = Decimal(s)
    except InvalidOperation:
        raise UserError("عدد نامعتبر است.")
    if v == 0 and not allow_zero:
        raise UserError("عدد باید بزرگ‌تر از صفر باشد.")
    if v > maximum:
        raise UserError("عدد وارد شده بیش از حد مجاز است.")
    return v


def parse_qty(text: str, unit_type: str) -> Decimal:
    """count -> positive integer; kg -> positive decimal with up to 3 places."""
    if unit_type == "count":
        return Decimal(parse_positive_int(text, maximum=MAX_COUNT))
    if unit_type == "kg":
        return parse_decimal(text, places=WEIGHT_PLACES, maximum=MAX_WEIGHT)
    raise ValueError("unknown unit type")


def parse_percent(text: str) -> Decimal:
    return parse_decimal(text, places=3, maximum=Decimal("1000"), allow_zero=True)


def fmt_qty(qty: Decimal, unit_type: str) -> str:
    q = Decimal(qty)
    if unit_type == "count":
        return fa(f"{int(q):,}".replace(",", "٬")) + " عدد"
    s = format(q.quantize(Decimal("0.001")).normalize(), "f")
    return fa(s.replace(".", "٫")) + " کیلوگرم"


def clean_text(text: str | None, *, max_len: int = 200, allow_empty: bool = False) -> str:
    s = (text or "").strip()
    s = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", s)
    s = re.sub(r"\s+", " ", s)
    if not s and not allow_empty:
        raise UserError("متن خالی پذیرفته نیست.")
    if len(s) > max_len:
        raise UserError(f"متن طولانی است (حداکثر {fa(max_len)} نویسه).")
    return s


def clean_code(text: str) -> str:
    s = to_en_digits((text or "").strip())
    if not re.fullmatch(r"[A-Za-z0-9\-_]{1,20}", s):
        raise UserError("کد فقط می‌تواند شامل حروف انگلیسی، عدد، - و _ باشد (حداکثر ۲۰ نویسه).")
    return s.upper()
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/tg.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Thin Telegram layer on top of aiogram 3 Bot objects, with per-token error isolation."""
from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from typing import Any

from aiogram import Bot
from aiogram.client.session.aiohttp import AiohttpSession
from aiogram.exceptions import TelegramAPIError, TelegramRetryAfter, TelegramUnauthorizedError
from aiogram.types import BufferedInputFile, InlineKeyboardButton, InlineKeyboardMarkup

log = logging.getLogger(__name__)


class SendError(Exception):
    def __init__(self, msg: str, *, retry_after: float | None = None, permanent: bool = False):
        super().__init__(msg)
        self.retry_after = retry_after
        self.permanent = permanent


def keyboard(rows: list[list[dict]] | None):
    if not rows:
        return None
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text=b["text"], callback_data=b["data"]) for b in row] for row in rows])


class BotPool:
    """One aiogram Bot per token. A bad token only marks that bot as failed."""

    def __init__(self):
        self._bots: dict[int, Bot] = {}

    def get(self, bot_tg_id: int, token: str) -> Bot:
        b = self._bots.get(bot_tg_id)
        if b is None:
            b = Bot(token=token, session=AiohttpSession(timeout=60))
            self._bots[bot_tg_id] = b
        return b

    async def close(self):
        for b in self._bots.values():
            await b.session.close()
        self._bots.clear()

    @staticmethod
    async def send(bot: Bot, chat_id: int, text: str, buttons=None) -> int:
        try:
            m = await bot.send_message(chat_id, text, parse_mode="HTML", reply_markup=keyboard(buttons),
                                       disable_web_page_preview=True)
            return m.message_id
        except TelegramRetryAfter as e:
            raise SendError("rate limited", retry_after=float(e.retry_after))
        except TelegramUnauthorizedError:
            raise SendError("bot token unauthorized", permanent=True)
        except TelegramAPIError as e:
            permanent = any(s in str(e) for s in ("chat not found", "bot was blocked", "forbidden", "not enough rights"))
            raise SendError(f"telegram error: {e.__class__.__name__}", permanent=permanent)
        except asyncio.TimeoutError:
            raise SendError("network timeout")

    @staticmethod
    async def send_file(bot: Bot, chat_id: int, filename: str, content: bytes, caption: str | None = None) -> int:
        try:
            m = await bot.send_document(chat_id, BufferedInputFile(content, filename=filename), caption=caption,
                                        parse_mode="HTML")
            return m.message_id
        except TelegramRetryAfter as e:
            raise SendError("rate limited", retry_after=float(e.retry_after))
        except TelegramAPIError as e:
            permanent = any(s in str(e) for s in ("chat not found", "bot was blocked", "forbidden", "not enough rights"))
            raise SendError(f"telegram error: {e.__class__.__name__}", permanent=permanent)
        except asyncio.TimeoutError:
            raise SendError("network timeout")


@dataclass
class Incoming:
    bot_tg_id: int
    update_id: int
    raw: Any


async def verify_token(bot: Bot) -> Any:
    """getMe; raises SendError if the token is invalid."""
    try:
        return await bot.get_me()
    except TelegramUnauthorizedError:
        raise SendError("invalid token", permanent=True)
    except TelegramAPIError as e:
        raise SendError(f"telegram error: {e.__class__.__name__}")
SHOPBOTS_FILE_EOF
  write_file "$staging/shopbots/timefmt.py" 0644 <<'SHOPBOTS_FILE_EOF'
from __future__ import annotations

import datetime as dt
import re
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .errors import UserError
from .jalali import date_from_jalali, g2j
from .textutil import fa, to_en_digits

UTC = dt.timezone.utc


def now_utc() -> dt.datetime:
    return dt.datetime.now(UTC)


def tz(name: str) -> ZoneInfo:
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        return ZoneInfo("Asia/Tehran")


def valid_tz(name: str) -> bool:
    try:
        ZoneInfo(name)
        return True
    except (ZoneInfoNotFoundError, ValueError):
        return False


def fmt_date(d: dt.date, jalali: bool) -> str:
    if jalali:
        y, m, dd = g2j(d.year, d.month, d.day)
        return fa(f"{y:04d}/{m:02d}/{dd:02d}")
    return fa(d.strftime("%Y-%m-%d"))


def fmt_dt(value: dt.datetime | None, tzname: str, jalali: bool, *, persian_digits: bool = True) -> str:
    if value is None:
        return "-"
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    local = value.astimezone(tz(tzname))
    if jalali:
        y, m, d = g2j(local.year, local.month, local.day)
        s = f"{y:04d}/{m:02d}/{d:02d} {local:%H:%M}"
    else:
        s = local.strftime("%Y-%m-%d %H:%M")
    return fa(s) if persian_digits else s


def parse_user_date(text: str, jalali: bool) -> dt.date:
    s = to_en_digits((text or "").strip()).replace("-", "/").replace(".", "/")
    m = re.fullmatch(r"(\d{4})/(\d{1,2})/(\d{1,2})", s)
    if not m:
        raise UserError("تاریخ را به شکل ۱۴۰۵/۰۱/۱۵ وارد کنید." if jalali else "تاریخ را به شکل 2026-01-15 وارد کنید.")
    y, mo, d = map(int, m.groups())
    try:
        return date_from_jalali(y, mo, d) if jalali else dt.date(y, mo, d)
    except ValueError:
        raise UserError("تاریخ نامعتبر است.")


def local_day_bounds(d: dt.date, tzname: str) -> tuple[dt.datetime, dt.datetime]:
    z = tz(tzname)
    start = dt.datetime.combine(d, dt.time.min, tzinfo=z)
    end = dt.datetime.combine(d + dt.timedelta(days=1), dt.time.min, tzinfo=z)
    return start.astimezone(UTC), end.astimezone(UTC)


def local_today(tzname: str) -> dt.date:
    return now_utc().astimezone(tz(tzname)).date()


def month_bounds(tzname: str, jalali: bool) -> tuple[dt.datetime, dt.datetime]:
    today = local_today(tzname)
    if jalali:
        from .jalali import j2g, jalali_month_length
        jy, jm, _ = g2j(today.year, today.month, today.day)
        first = dt.date(*j2g(jy, jm, 1))
        last = first + dt.timedelta(days=jalali_month_length(jy, jm) - 1)
    else:
        first = today.replace(day=1)
        nxt = (first + dt.timedelta(days=32)).replace(day=1)
        last = nxt - dt.timedelta(days=1)
    s, _ = local_day_bounds(first, tzname)
    _, e = local_day_bounds(last, tzname)
    return s, e
SHOPBOTS_FILE_EOF
  write_file "$staging/tests/__init__.py" 0644 <<'SHOPBOTS_FILE_EOF'
SHOPBOTS_FILE_EOF
  write_file "$staging/tests/test_pure.py" 0644 <<'SHOPBOTS_FILE_EOF'
"""Pure unit tests (no database, no network). Run: python -m unittest discover -s tests -t ."""
import datetime as dt
import os
import stat
import tempfile
import unittest
from decimal import Decimal

import sys
import types

# asyncpg is only needed by the DB layer; stub it so pure functions can be imported without it.
if "asyncpg" not in sys.modules:
    try:
        import asyncpg  # noqa: F401
    except ImportError:
        _stub = types.ModuleType("asyncpg")
        _stub.Connection = object
        _stub.Pool = object
        _stub.Record = dict
        _stub.UniqueViolationError = type("UniqueViolationError", (Exception,), {})
        sys.modules["asyncpg"] = _stub

from shopbots.crypto import KeyFileError, TokenCipher, bot_id_from_token
from shopbots.errors import UserError
from shopbots.jalali import date_from_jalali, g2j, j2g, jalali_month_length
from shopbots.money import credit_unit_price, fmt_money, line_amount, parse_amount, round_rial, unit_price_for
from shopbots.phone import normalize_phone
from shopbots.render.excel import safe_text
from shopbots.render.text import split_parts
from shopbots.log import redact
from shopbots.textutil import parse_percent, parse_qty, to_en_digits, clean_code
from shopbots.domain.payments import payment_effect
from shopbots.domain.sales import account_effect, limit_check


class Digits(unittest.TestCase):
    def test_persian_and_arabic_digits(self):
        self.assertEqual(to_en_digits("۱۲٣"), "123")

    def test_qty_count_rejects_fraction_negative_zero(self):
        self.assertEqual(parse_qty("۳", "count"), Decimal(3))
        for bad in ("1.5", "-1", "0", "abc", ""):
            with self.assertRaises(UserError, msg=bad):
                parse_qty(bad, "count")

    def test_qty_kg_accepts_persian_decimal_and_limits_places(self):
        self.assertEqual(parse_qty("۰٫۲۵", "kg"), Decimal("0.25"))
        self.assertEqual(parse_qty("1,250.5", "kg"), Decimal("1250.5"))
        with self.assertRaises(UserError):
            parse_qty("0.2501", "kg")
        with self.assertRaises(UserError):
            parse_qty("-0.5", "kg")

    def test_percent(self):
        self.assertEqual(parse_percent("۱۰"), Decimal("10"))
        self.assertEqual(parse_percent("0"), Decimal("0"))
        with self.assertRaises(UserError):
            parse_percent("-5")

    def test_clean_code(self):
        self.assertEqual(clean_code("ab-1"), "AB-1")
        with self.assertRaises(UserError):
            clean_code("a b")


class Money(unittest.TestCase):
    def test_credit_price_formula(self):
        # 1000 toman cash = 10000 rial; +10% => 11000 rial
        self.assertEqual(credit_unit_price(10000, Decimal("10")), 11000)
        self.assertEqual(unit_price_for("cash", 10000, Decimal("10")), 10000)

    def test_rounding_units_and_modes(self):
        self.assertEqual(round_rial(12345, 100, "half_up"), 12300)
        self.assertEqual(round_rial(12345, 100, "down"), 12300)
        self.assertEqual(round_rial(12301, 100, "up"), 12400)
        self.assertEqual(round_rial(12350, 100, "half_up"), 12400)

    def test_line_amount_kg(self):
        # 0.25 kg at 2,000,000 rial/kg = 500,000 rial
        self.assertEqual(line_amount(2_000_000, Decimal("0.25"), 1, "half_up"), 500_000)

    def test_toman_input_stored_as_rial(self):
        self.assertEqual(parse_amount("۲۵۰۰", "toman"), 25_000)
        self.assertEqual(parse_amount("2500", "rial"), 2500)
        with self.assertRaises(UserError):
            parse_amount("-100", "toman")
        with self.assertRaises(UserError):
            parse_amount("0", "toman")

    def test_display_changes_only_format(self):
        self.assertIn("۲٬۵۰۰", fmt_money(25_000, "toman"))
        self.assertIn("۲۵٬۰۰۰", fmt_money(25_000, "rial"))


class Ledger(unittest.TestCase):
    def test_payment_settles_debt_then_credits(self):
        e = payment_effect(balance_before=30_000, amount=50_000)
        self.assertEqual(e["debt_settled"], 30_000)
        self.assertEqual(e["credit_created"], 20_000)
        self.assertEqual(e["balance_after"], -20_000)

    def test_prepayment_uses_credit_on_purchase(self):
        a = account_effect(balance_before=-20_000, total=50_000)
        self.assertEqual(a["credit_used"], 20_000)
        self.assertEqual(a["balance_after"], 30_000)

    def test_limit_modes(self):
        cust_none = {"limit_mode": "none", "limit_rial": None}
        cust_warn = {"limit_mode": "warn", "limit_rial": 100_000}
        cust_block = {"limit_mode": "block", "limit_rial": 100_000}
        self.assertEqual(limit_check(cust_none, 10**9)[0], "ok")
        self.assertEqual(limit_check(cust_warn, 150_000), ("warn", "50000"))
        self.assertEqual(limit_check(cust_block, 150_000)[0], "block")
        # credit nets against the limit: balance -50k then +120k => debt 70k <= 100k
        self.assertEqual(limit_check(cust_block, 70_000)[0], "ok")
        self.assertEqual(limit_check(cust_block, 100_000)[0], "ok")


class Jalali(unittest.TestCase):
    def test_known_dates(self):
        self.assertEqual(g2j(2026, 3, 21), (1405, 1, 1))
        self.assertEqual(g2j(2024, 3, 20), (1403, 1, 1))
        self.assertEqual(date_from_jalali(1405, 1, 1), dt.date(2026, 3, 21))

    def test_roundtrip_every_day_in_range(self):
        d = dt.date(2020, 1, 1)
        while d < dt.date(2035, 1, 1):
            jy, jm, jd = g2j(d.year, d.month, d.day)
            self.assertEqual(j2g(jy, jm, jd), (d.year, d.month, d.day))
            d += dt.timedelta(days=1)

    def test_esfand_length(self):
        self.assertIn(jalali_month_length(1404, 12), (29, 30))
        self.assertEqual(jalali_month_length(1404, 1), 31)


class Phone(unittest.TestCase):
    def test_iranian_forms_normalize_to_same_value(self):
        for raw in ("09121234567", "۰۹۱۲۱۲۳۴۵۶۷", "+989121234567", "00989121234567", "9121234567", "0912 123 4567"):
            self.assertEqual(normalize_phone(raw), "+989121234567", raw)

    def test_invalid(self):
        self.assertIsNone(normalize_phone("abc"))
        self.assertIsNone(normalize_phone("123"))


class Crypto(unittest.TestCase):
    def test_roundtrip_and_rotation(self):
        k1, k2 = TokenCipher.generate_key(), TokenCipher.generate_key()
        old = TokenCipher([k1])
        token = old.encrypt("123456:ABC_secret_token_value_that_is_long_enough")
        new = TokenCipher([k2, k1])
        self.assertEqual(new.decrypt(token), "123456:ABC_secret_token_value_that_is_long_enough")
        self.assertEqual(new.decrypt(new.rotate(token)), "123456:ABC_secret_token_value_that_is_long_enough")
        with self.assertRaises(KeyFileError):
            TokenCipher([k2]).decrypt(token)

    def test_keyfile_permissions(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, "master.key")
        with open(p, "wb") as fh:
            fh.write(TokenCipher.generate_key() + b"\n")
        os.chmod(p, 0o644)
        with self.assertRaises(KeyFileError):
            TokenCipher.from_file(p)
        os.chmod(p, 0o400)
        self.assertIsNotNone(TokenCipher.from_file(p))
        self.assertFalse(os.stat(p).st_mode & (stat.S_IRWXG | stat.S_IRWXO))

    def test_bot_id(self):
        self.assertEqual(bot_id_from_token("123456:" + "a" * 35), 123456)
        self.assertIsNone(bot_id_from_token("nope"))


class Safety(unittest.TestCase):
    def test_formula_injection(self):
        self.assertEqual(safe_text("=HYPERLINK(1)"), "'=HYPERLINK(1)")
        self.assertEqual(safe_text("+98"), "'+98")
        self.assertEqual(safe_text("عادی"), "عادی")

    def test_log_redaction(self):
        s = "GET https://api.telegram.org/bot123456789:AAEhBOweik6ad9r_QXMENQv6xTgbeFPbHIg/getMe"
        self.assertNotIn("AAEhBOweik", redact(s))

    def test_split_parts_never_drops_content(self):
        lines = [f"row {i} " + "x" * 80 for i in range(300)]
        parts = split_parts("<b>H</b>", lines, limit=1000)
        self.assertGreater(len(parts), 1)
        joined = "\n".join(parts)
        for ln in lines:
            self.assertIn(ln, joined)
        for p in parts:
            self.assertLessEqual(len(p), 1000)


if __name__ == "__main__":
    unittest.main()
SHOPBOTS_FILE_EOF
  rm -rf "${CODE_DIR}.new"
  mv "$staging" "${CODE_DIR}.new"
  if [[ -d "$CODE_DIR" ]]; then rm -rf "${CODE_DIR}.prev"; mv "$CODE_DIR" "${CODE_DIR}.prev"; fi
  mv "${CODE_DIR}.new" "$CODE_DIR"
  chmod -R a+rX,go-w "$CODE_DIR"
}

setup_venv() {
  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    python3 -m venv "$VENV_DIR"
  fi
  "$VENV_DIR/bin/pip" install --quiet --upgrade pip
  "$VENV_DIR/bin/pip" install --quiet "${PY_PINS[@]}"
  chown -R root:root "$VENV_DIR"; chmod -R go-w "$VENV_DIR"
}

ensure_db() {
  local pw_file="$SECRETS_DIR/db_password"
  if [[ ! -s "$pw_file" ]]; then
    umask 077
    openssl rand -hex 32 > "$pw_file"
    chown root:"$SVC_USER" "$pw_file"; chmod 0640 "$pw_file"
    umask 027
  fi
  local pw; pw="$(cat "$pw_file")"
  systemctl enable --now postgresql >/dev/null 2>&1 || true
  # password goes through stdin (not argv) and is hex-only, so no quoting issues
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
    sudo -u postgres psql -v ON_ERROR_STOP=1 -q <<SQL_ROLE
CREATE ROLE ${DB_USER} LOGIN PASSWORD '${pw}';
SQL_ROLE
  else
    sudo -u postgres psql -v ON_ERROR_STOP=1 -q <<SQL_ROLE
ALTER ROLE ${DB_USER} PASSWORD '${pw}';
SQL_ROLE
  fi
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
  fi
}

ensure_master_key() {
  local key="$SECRETS_DIR/master.key"
  if [[ ! -s "$key" ]]; then
    umask 077
    "$VENV_DIR/bin/python" -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())' > "$key"
    umask 027
    chown root:"$SVC_USER" "$key"; chmod 0400 "$key"
    chown "$SVC_USER":"$SVC_USER" "$key"
    log "created encryption key. COPY IT OFF THIS SERVER NOW (password manager): $key"
    warn "without this key, encrypted bot tokens and backups cannot be read."
  fi
}

prompt_central_config() {
  [[ -f "$ENV_FILE" ]] && return 0
  printf '%sFirst-time setup%s\n' "$GREEN" "$NC"
  local token owner
  while :; do
    read -r -s -p "Central bot token (input hidden): " token; echo
    [[ "$token" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$ ]] && break
    warn "token format looks wrong; try again."
  done
  while :; do
    read -r -p "Owner numeric Telegram id: " owner
    [[ "$owner" =~ ^[0-9]{4,15}$ ]] && break
    warn "owner id must be digits only."
  done
  write_file "$SECRETS_DIR/central_bot_token" 0640 <<<"$token"
  chown root:"$SVC_USER" "$SECRETS_DIR/central_bot_token"
  local db_pw; db_pw="$(cat "$SECRETS_DIR/db_password")"
  write_file "$ENV_FILE" 0640 <<EOF_ENV
SHOPBOTS_DATABASE_URL=postgresql://${DB_USER}:${db_pw}@127.0.0.1:5432/${DB_NAME}
SHOPBOTS_OWNER_ID=${owner}
SHOPBOTS_SECRETS_DIR=${SECRETS_DIR}
SHOPBOTS_LOG_DIR=${LOG_DIR}
SHOPBOTS_DATA_DIR=${DATA_DIR}
SHOPBOTS_LOG_LEVEL=INFO
SHOPBOTS_OUTBOX_MAX_ATTEMPTS=12
SHOPBOTS_REPORT_TEXT_MAX_PARTS=15
SHOPBOTS_INSTANCE=${APP_NAME}
PYTHONPATH=${CODE_DIR}
EOF_ENV
  chown root:"$SVC_USER" "$ENV_FILE"
  unset token db_pw
  # Verify the token with Telegram without putting it in argv (curl reads it from a 0600 config file).
  local cfg; cfg="$(mktemp)"; chmod 600 "$cfg"
  printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$(cat "$SECRETS_DIR/central_bot_token")" > "$cfg"
  if curl -fsS --max-time 15 --config "$cfg" >/dev/null 2>&1; then log "central bot token accepted by Telegram."
  else warn "Telegram did not accept the central token (checked with getMe). Fix it with: sudo bash install.sh set-token"; fi
  rm -f "$cfg"
}

install_units() {
  write_file "/etc/systemd/system/${SVC_NAME}.service" 0644 <<EOF_UNIT
[Unit]
Description=ShopBots Telegram platform
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
WorkingDirectory=${CODE_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${VENV_DIR}/bin/python -m shopbots serve
Restart=always
RestartSec=5
StartLimitIntervalSec=300
StartLimitBurst=20
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
ReadWritePaths=${DATA_DIR} ${LOG_DIR} ${BACKUP_DIR}
ReadOnlyPaths=${SECRETS_DIR}
UMask=0027
KillMode=mixed
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF_UNIT
  write_file "/etc/systemd/system/${SVC_NAME}-backup.service" 0644 <<EOF_BSVC
[Unit]
Description=ShopBots encrypted database backup
[Service]
Type=oneshot
User=root
ExecStart=${BIN_DIR}/backup.sh
EOF_BSVC
  write_file "/etc/systemd/system/${SVC_NAME}-backup.timer" 0644 <<EOF_BTIMER
[Unit]
Description=Daily ShopBots backup
[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true
RandomizedDelaySec=300
[Install]
WantedBy=timers.target
EOF_BTIMER
  write_file "/etc/logrotate.d/${SVC_NAME}" 0644 <<EOF_LR
${LOG_DIR}/*.log {
    daily
    rotate 14
    maxsize 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0640 ${SVC_USER} ${SVC_USER}
}
EOF_LR
  systemctl daemon-reload
  systemctl enable "${SVC_NAME}.service" >/dev/null
  systemctl enable --now "${SVC_NAME}-backup.timer" >/dev/null
}

install_bin() {
  write_file "${BIN_DIR}/backup.sh" 0750 <<'EOF_BK'
#!/usr/bin/env bash
# Encrypted logical backup of the shopbots database. Failure is logged and recorded.
set -Eeuo pipefail
umask 077
BACKUP_DIR=/var/backups/shopbots
KEY=/etc/shopbots/secrets/master.key
ENV=/etc/shopbots/shopbots.env
LOG=/var/log/shopbots/backup.log
set -a; . "$ENV"; set +a
RETENTION_DAYS="${SHOPBOTS_BACKUP_RETENTION_DAYS:-14}"
REMOTE="${SHOPBOTS_BACKUP_REMOTE:-}"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
out="$BACKUP_DIR/shopbots-${ts}.dump.gz.enc"
fail() { echo "$(date -u +%FT%TZ) FAILED: $*" | tee -a "$LOG" >&2; exit 1; }
[[ -r "$KEY" ]] || fail "master key not readable"
# shellcheck disable=SC1090
sudo_pg() { runuser -u postgres -- "$@"; }
if ! sudo_pg pg_dump --format=custom --no-owner shopbots 2>/dev/null \
    | gzip -9 | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass file:"$KEY" -out "$out" 2>>"$LOG"; then
  rm -f "$out"; fail "pg_dump/encryption pipeline failed"
fi
size=$(stat -c %s "$out")
[[ "$size" -gt 100 ]] || { rm -f "$out"; fail "backup file suspiciously small"; }
if [[ -n "$REMOTE" ]]; then
  if scp -q -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$out" "$REMOTE" 2>>"$LOG"; then
    echo "$(date -u +%FT%TZ) OK remote copy $REMOTE" >> "$LOG"
  else
    echo "$(date -u +%FT%TZ) WARN remote copy failed; local copy kept" >> "$LOG"
  fi
else
  echo "$(date -u +%FT%TZ) WARN no SHOPBOTS_BACKUP_REMOTE set: backup exists only on THIS server" >> "$LOG"
fi
find "$BACKUP_DIR" -name 'shopbots-*.dump.gz.enc' -mtime +"$RETENTION_DAYS" -delete
echo "$(date -u +%FT%TZ) OK $(basename "$out") ${size} bytes" >> "$LOG"
echo "backup ok: $out"
EOF_BK
  write_file "${BIN_DIR}/restore-test.sh" 0750 <<'EOF_RT'
#!/usr/bin/env bash
# Restore an encrypted backup into a TEMPORARY database and print row counts. Never touches live data.
set -Eeuo pipefail
[[ $# -eq 1 ]] || { echo "usage: restore-test.sh <file.dump.gz.enc>"; exit 2; }
KEY=/etc/shopbots/secrets/master.key
TMPDB="shopbots_restore_test_$(date +%s)"
work="$(mktemp -d)"; trap 'rm -rf "$work"; runuser -u postgres -- dropdb --if-exists "$TMPDB" 2>/dev/null || true' EXIT
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass file:"$KEY" -in "$1" | gunzip > "$work/db.dump"
runuser -u postgres -- createdb "$TMPDB"
runuser -u postgres -- pg_restore --no-owner -d "$TMPDB" "$work/db.dump"
runuser -u postgres -- psql -d "$TMPDB" -tAc "SELECT 'stores='||count(*) FROM stores; SELECT 'customers='||count(*) FROM customers; SELECT 'ledger='||count(*) FROM ledger_entries;"
echo "restore test ok (temporary database removed)."
EOF_RT
}

wait_healthy() {
  local i
  for i in $(seq 1 20); do
    if systemctl is-active --quiet "$SVC_NAME" && grep -q "shopbots started" "$LOG_DIR/shopbots.log" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

run_migrations() {
  runuser -u "$SVC_USER" -- env $(grep -v '^PYTHONPATH' "$ENV_FILE" | xargs) PYTHONPATH="$CODE_DIR" \
    "$VENV_DIR/bin/python" -m shopbots migrate
  runuser -u "$SVC_USER" -- env $(grep -v '^PYTHONPATH' "$ENV_FILE" | xargs) PYTHONPATH="$CODE_DIR" \
    "$VENV_DIR/bin/python" -m shopbots keycheck || die "encryption key check failed (wrong or missing master key)."
}

cmd_install() {
  require_root; check_os; check_prereqs
  if [[ -f "$ENV_FILE" && -d "$CODE_DIR" ]]; then
    die "already installed. Use: sudo bash install.sh update (your data and settings are kept)."
  fi
  install_packages
  ensure_user_and_dirs
  deploy_code
  setup_venv
  ensure_db
  ensure_master_key
  prompt_central_config
  install_bin
  install_units
  run_migrations
  systemctl restart "$SVC_NAME"
  if wait_healthy; then
    log "service is running."
  else
    die "service did not start. See: sudo journalctl -u ${SVC_NAME} -n 80"
  fi
  print_next_steps
}

cmd_update() {
  require_root; check_os; check_prereqs
  [[ -f "$ENV_FILE" ]] || die "not installed yet. Run: sudo bash install.sh install"
  log "1/6 backing up database before any change…"
  "$BIN_DIR/backup.sh" || die "backup failed; update aborted, nothing changed."
  log "2/6 stopping service"
  systemctl stop "$SVC_NAME"
  log "3/6 installing new code (previous version kept as ${CODE_DIR}.prev)"
  deploy_code
  setup_venv
  install_bin
  install_units
  log "4/6 applying migrations and key check"
  if ! run_migrations; then
    warn "migration/key check failed; rolling back code"
    rollback_code
    systemctl start "$SVC_NAME" || true
    die "update rolled back. Database changes (if any) are in the pre-update backup in $BACKUP_DIR."
  fi
  log "5/6 starting service"
  systemctl start "$SVC_NAME"
  log "6/6 health check"
  if wait_healthy; then log "update complete. Settings, stores, customers and history were kept."
  else rollback_code; systemctl restart "$SVC_NAME" || true; die "health check failed; code rolled back."; fi
}

rollback_code() {
  if [[ -d "${CODE_DIR}.prev" ]]; then
    rm -rf "${CODE_DIR}.bad"; mv "$CODE_DIR" "${CODE_DIR}.bad"; mv "${CODE_DIR}.prev" "$CODE_DIR"
  fi
}

cmd_status() {
  check_os
  systemctl --no-pager --lines=0 status "$SVC_NAME" || true
  echo "last backup:"; ls -1t "$BACKUP_DIR"/shopbots-*.dump.gz.enc 2>/dev/null | head -1 || echo "  none"
  tail -n 3 "$LOG_DIR/backup.log" 2>/dev/null || true
  [[ -n "$(grep -s '^SHOPBOTS_BACKUP_REMOTE' "$ENV_FILE" || true)" ]] || warn "no off-server backup target configured (SHOPBOTS_BACKUP_REMOTE). Backups exist only on this server."
}

cmd_logs() { journalctl -u "$SVC_NAME" -n "${1:-100}" --no-pager; }
cmd_backup() { require_root; "$BIN_DIR/backup.sh"; }
cmd_test() { [[ -d "$CODE_DIR/tests" ]] || die "not installed"; (cd "$CODE_DIR" && PYTHONPATH="$CODE_DIR" "$VENV_DIR/bin/python" -m unittest tests.test_pure -v); }

cmd_restore() {
  require_root
  local file="${1:-}"
  [[ -f "$file" ]] || die "usage: install.sh restore <backup.dump.gz.enc>"
  warn "restore is never automatic. It first restores into a TEMPORARY database to verify."
  "$BIN_DIR/restore-test.sh" "$file"
  read -r -p "Type RESTORE to replace the LIVE database with this backup (old data is first saved as a backup): " ans
  [[ "$ans" == "RESTORE" ]] || die "cancelled. Nothing changed."
  "$BIN_DIR/backup.sh" >/dev/null || die "pre-restore backup failed; aborted."
  systemctl stop "$SVC_NAME"
  local work; work="$(mktemp -d)"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass file:"$SECRETS_DIR/master.key" -in "$file" | gunzip > "$work/db.dump"
  runuser -u postgres -- dropdb --if-exists "$DB_NAME"
  runuser -u postgres -- createdb -O "$DB_USER" "$DB_NAME"
  runuser -u postgres -- pg_restore --no-owner -d "$DB_NAME" "$work/db.dump"
  rm -rf "$work"
  systemctl start "$SVC_NAME"
  log "restore finished; service started."
}

print_next_steps() {
  cat <<EOF_NEXT

${GREEN}Installed.${NC}
Next:
  1. Copy ${SECRETS_DIR}/master.key to a password manager (not only this server).
  2. Open your central bot in Telegram and send /start (you must be the owner id you entered).
  3. Add a store: ➕ فروشگاه جدید, then give the store's bot token and the seller's numeric id.
  4. In the seller's report group, the owner runs /setreport, then the central admin approves it.
Operations: sudo bash install.sh status | logs | update | backup
EOF_NEXT
}

usage() { sed -n '2,12p' "$0"; }

main() {
  case "${1:-}" in
    install) cmd_install ;;
    update) cmd_update ;;
    status) cmd_status ;;
    logs) cmd_logs "${2:-100}" ;;
    backup) cmd_backup ;;
    restore) cmd_restore "${2:-}" ;;
    test) cmd_test ;;
    -h|--help|help|"") usage ;;
    *) die "unknown command: $1" ;;
  esac
}
main "$@"

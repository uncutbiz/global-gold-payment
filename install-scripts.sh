#!/usr/bin/env bash
#
#  install-scripts.sh — put the Global Gold operator scripts on this machine.
#
#      curl -fsSL https://raw.githubusercontent.com/uncutbiz/global-gold-payment/main/install-scripts.sh | sudo bash
#
#  Writes /opt/globalgold/scripts/ and links each one into /usr/local/bin, so
#  they can be run by name from anywhere. Safe to run again; it overwrites.
#
#  Any future update installs these automatically, so this file is only needed
#  to get them onto a machine running an older build.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run with sudo: curl -fsSL <url> | sudo bash" >&2; exit 1; }
install -d -m 0755 /opt/globalgold/scripts
echo "Installing:"

echo "   globalgold-autoupdate"
cat > /opt/globalgold/scripts/globalgold-autoupdate <<'GGP_EOF_GLOBALGOLD_AUTOUPDATE'
#!/usr/bin/env bash
#
#  globalgold-autoupdate — install a new build when one appears.
#
#      sudo globalgold-autoupdate           tell me if there is one (changes nothing)
#      sudo globalgold-autoupdate --apply   back up, install it, verify it
#      sudo globalgold-autoupdate --enable  run the check nightly
#      sudo globalgold-autoupdate --disable stop running it
#
#  Checking is the default and applying is opt-in, on purpose. Read this before
#  turning on unattended updates on a machine that takes payments:
#
#    Whoever controls the source URL controls this server. This pulls a tarball
#    over HTTPS and runs code out of it as root. If the GitHub account it comes
#    from is compromised, the attacker does not need to touch this machine —
#    they push a tarball and wait. That is a real trade, not a theoretical one,
#    and it is why --apply is something you choose rather than the default.
#
#  Two things make it less sharp:
#
#    GGP_PIN_SHA256 in /etc/globalgold/autoupdate pins an exact build. With it
#    set, anything else is refused — so a new build is installed only when you
#    have looked at it and changed the pin yourself.
#
#    Every apply takes a database backup first and runs globalgold-check after.
#    A failed check is reported loudly rather than left running quietly.
set -uo pipefail

CONF=/etc/globalgold/autoupdate
SOURCE_FILE=/etc/globalgold/source
VERSION_FILE=/etc/globalgold/version
LOG=/var/log/globalgold-autoupdate.log
DEFAULT_URL="https://raw.githubusercontent.com/uncutbiz/global-gold-payment/main/globalgold-source.tar.gz"

MODE="${1:---check}"

say()  { printf '%s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
good() { printf '   \033[32m%s\033[0m\n' "$*"; }
warn() { printf '   \033[33m%s\033[0m\n' "$*"; }
bad()  { printf '   \033[31m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[31m%s\033[0m\n\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "Run this with sudo:  sudo globalgold-autoupdate $MODE"

# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
SOURCE="${GGP_SOURCE_URL:-$( [ -f "$SOURCE_FILE" ] && head -1 "$SOURCE_FILE" || echo "$DEFAULT_URL" )}"
PIN="${GGP_PIN_SHA256:-}"

# ─────────────────────────────────────────────────────── turning it on and off

if [ "$MODE" = "--enable" ] || [ "$MODE" = "--disable" ]; then
  if [ "$MODE" = "--disable" ]; then
    rm -f /etc/cron.d/globalgold-autoupdate
    say "Automatic updates are off. Check by hand any time with:"
    say "   sudo globalgold-autoupdate"
    exit 0
  fi
  install -d -m 0700 /etc/globalgold
  [ -f "$CONF" ] || cat > "$CONF" <<CONFEOF
# How globalgold-autoupdate behaves. Read by the script; root-only.

# Where new builds come from. Whoever controls this URL controls this server.
GGP_SOURCE_URL="$SOURCE"

# Install automatically, or only report that something is available?
#   check  — the safe default: it tells you, you decide
#   apply  — installs unattended
GGP_MODE="check"

# Refuse anything but this exact build. Set it to the sha256 you have actually
# looked at, and automatic updates become "install the thing I approved"
# rather than "install whatever is at that address".
#   sha256sum the-tarball-you-trust.tar.gz
GGP_PIN_SHA256=""

# When to look, as a cron time. Default 04:17 daily — an odd minute, because
# everything scheduled on the hour hits the same servers at once.
GGP_CRON="17 4 * * *"
CONFEOF
  chmod 0600 "$CONF"
  # shellcheck source=/dev/null
  . "$CONF"
  printf '%s root /usr/local/bin/globalgold-autoupdate --%s >> %s 2>&1\n' \
    "${GGP_CRON:-17 4 * * *}" "${GGP_MODE:-check}" "$LOG" \
    > /etc/cron.d/globalgold-autoupdate
  chmod 0644 /etc/cron.d/globalgold-autoupdate
  say "Automatic update checks are on."
  say ""
  say "   schedule   ${GGP_CRON:-17 4 * * *}"
  say "   mode       ${GGP_MODE:-check}  (edit $CONF to change it)"
  say "   log        $LOG"
  say ""
  [ "${GGP_MODE:-check}" = "apply" ] && [ -z "${GGP_PIN_SHA256:-}" ] && {
    warn "mode is 'apply' with no pin set — this machine will install whatever"
    warn "is at that URL. Set GGP_PIN_SHA256 in $CONF unless you mean that."; }
  exit 0
fi

# ────────────────────────────────────────────────────────────── is there one?

say ""
say "Global Gold — checking for a new build  $(date -Is)"
note "source: $SOURCE"

case "$SOURCE" in http://*|https://*) ;; *) die "The source is not a URL: $SOURCE" ;; esac

TMP=$(mktemp /tmp/ggp-autoupdate-XXXXXX.tgz)
trap 'rm -f "$TMP"' EXIT
curl -fL --no-progress-meter --retry 3 --retry-delay 5 -o "$TMP" "$SOURCE" \
  || die "Could not download it. Nothing has changed on this machine."

tar -tzf "$TMP" >/dev/null 2>&1 \
  || die "What came back is not a tarball. Nothing has changed on this machine."

REMOTE=$(sha256sum "$TMP" | cut -d' ' -f1)
INSTALLED=$([ -f "$VERSION_FILE" ] && head -1 "$VERSION_FILE" || echo "unknown")
note "installed: ${INSTALLED:0:16}"
note "available: ${REMOTE:0:16}"

if [ "$REMOTE" = "$INSTALLED" ]; then
  good "already up to date — nothing to do"
  exit 0
fi

if [ -n "$PIN" ] && [ "$REMOTE" != "$PIN" ]; then
  bad "a different build is being offered than the one pinned here"
  note "pinned:    ${PIN:0:16}"
  note "offered:   ${REMOTE:0:16}"
  note "Refusing it. If this change is yours, put the new sum in $CONF."
  exit 2
fi

warn "a new build is available"

if [ "$MODE" != "--apply" ]; then
  say ""
  say "   Nothing has been changed. To install it:"
  say ""
  say "     sudo globalgold-autoupdate --apply"
  say ""
  say "   Or look at what changed first — the sum above is the whole tarball,"
  say "   so it is the thing to compare against whoever published it."
  say ""
  exit 3
fi

# ────────────────────────────────────────────────────────────────── apply it

say ""
say "== Backing up first"
# A backup before a migration is the difference between a bad update and a bad
# afternoon. If it cannot be taken, the update does not happen.
if command -v globalgold-backup >/dev/null; then
  globalgold-backup >/dev/null 2>&1 && good "database and keys backed up" \
    || die "The backup failed, so the update has been cancelled. Fix that first:
  sudo globalgold-backup"
else
  warn "globalgold-backup is not installed — going ahead without a backup"
fi

say ""
say "== Installing"
if ! globalgold-update "$TMP"; then
  bad "the update failed"
  note "The machine is still running whatever it was running before."
  note "Look at:  sudo ggp logs app    and    sudo globalgold-doctor"
  exit 1
fi

say ""
say "== Verifying"
if globalgold-check; then
  good "the new build is running"
  # The version file is written by globalgold-update from the same bytes, so
  # there is nothing to record here.
  exit 0
fi

bad "the install finished but the service is not answering as expected"
note "This needs a person. Start with:  sudo globalgold-doctor"
exit 1
GGP_EOF_GLOBALGOLD_AUTOUPDATE
chmod 0755 /opt/globalgold/scripts/globalgold-autoupdate
ln -sf /opt/globalgold/scripts/globalgold-autoupdate /usr/local/bin/globalgold-autoupdate

echo "   globalgold-backup"
cat > /opt/globalgold/scripts/globalgold-backup <<'GGP_EOF_GLOBALGOLD_BACKUP'
#!/usr/bin/env bash
#
#  globalgold-backup — a copy of the database and this machine's keys.
#
#      sudo globalgold-backup                 into /var/backups/globalgold
#      sudo globalgold-backup /mnt/somewhere  into somewhere else
#
#  Two things go in, and BOTH are needed to restore:
#
#    the database   every merchant, payment, ledger entry and invoice
#    /etc/globalgold/env   this machine's VAULT_KEY
#
#  The vault key is the part people leave out. Stored card tokens are
#  encrypted with it, so a database restored without it is a database where
#  every saved card is permanently unreadable. They are written as two files
#  rather than one so the key can be kept somewhere different — which is the
#  point, because a backup holding both is a single file that is worth as much
#  as the live system.
#
#  This is a local copy on the same disk as the thing it is backing up, so it
#  survives a bad migration and not a dead volume. Copy it off the machine.
set -uo pipefail

DEST="${1:-/var/backups/globalgold}"
KEEP="${GGP_BACKUP_KEEP:-14}"
COMPOSE=(docker compose -f /opt/globalgold/compose.yml)

die() { printf '\n\033[31m%s\033[0m\n\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "Run this with sudo:  sudo globalgold-backup"

STAMP=$(date -u +%Y%m%d-%H%M%S)
install -d -m 0700 "$DEST" || die "Could not create $DEST"

AVAIL=$(df -Pm "$DEST" | awk 'NR==2{print $4}')
[ "$AVAIL" -lt 500 ] && die "Only ${AVAIL} MB free at $DEST. Free some space first."

DB="$DEST/globalgold-$STAMP.sql.gz"
echo "== Database"
# Straight to gzip, and only renamed into place once pg_dump has exited 0 —
# a truncated dump that looks like a backup is worse than no backup.
if "${COMPOSE[@]}" exec -T db pg_dump -U globalgold -d globalgold --clean --if-exists \
     | gzip -9 > "$DB.partial"; then
  mv "$DB.partial" "$DB"
  chmod 0600 "$DB"
  echo "   $DB  ($(du -h "$DB" | cut -f1))"
else
  rm -f "$DB.partial"
  die "pg_dump failed. Is the database up?  sudo ggp status"
fi

# Verify it is readable before claiming success.
gzip -t "$DB" 2>/dev/null || die "The dump did not survive gzip -t. Not trusting it."
zcat "$DB" | head -40 | grep -q 'PostgreSQL database dump' \
  || die "That file does not look like a pg_dump. Not trusting it."
echo "   verified readable"

echo "== Keys"
KEYS="$DEST/globalgold-env-$STAMP.txt"
if [ -f /etc/globalgold/env ]; then
  cp /etc/globalgold/env "$KEYS"
  chmod 0600 "$KEYS"
  echo "   $KEYS"
  echo "   ^ holds VAULT_KEY. Without it a restored database cannot read a single"
  echo "     stored card. Keep it somewhere other than the database dump."
else
  echo "   /etc/globalgold/env not found — nothing to copy"
fi

# Prune old ones, newest kept.
echo "== Housekeeping"
ls -1t "$DEST"/globalgold-*.sql.gz 2>/dev/null | tail -n +"$((KEEP+1))" | while read -r old; do
  rm -f "$old"; echo "   removed $old"
done
ls -1t "$DEST"/globalgold-env-*.txt 2>/dev/null | tail -n +"$((KEEP+1))" | while read -r old; do
  rm -f "$old"; echo "   removed $old"
done
echo "   keeping the newest $KEEP"

cat <<DONE

  ─────────────────────────────────────────────────────────────────────
   Done. This copy is on the SAME DISK as the database, so it survives a
   bad migration and not a lost volume. Get it off the machine:

     aws s3 cp $DB s3://your-backup-bucket/
       (needs an instance role with write access to that bucket)

   To run it nightly at 03:00:

     echo '0 3 * * * root /usr/local/bin/globalgold-backup' \\
       > /etc/cron.d/globalgold-backup

   To restore, on a machine with the same VAULT_KEY in /etc/globalgold/env:

     zcat BACKUP.sql.gz | docker compose -f /opt/globalgold/compose.yml \\
       exec -T db psql -U globalgold -d globalgold
  ─────────────────────────────────────────────────────────────────────

DONE
GGP_EOF_GLOBALGOLD_BACKUP
chmod 0755 /opt/globalgold/scripts/globalgold-backup
ln -sf /opt/globalgold/scripts/globalgold-backup /usr/local/bin/globalgold-backup

echo "   globalgold-check"
cat > /opt/globalgold/scripts/globalgold-check <<'GGP_EOF_GLOBALGOLD_CHECK'
#!/usr/bin/env bash
#
#  globalgold-check — which build is actually running on this machine?
#
#  `ggp status` answers "is it up". This answers "is it the version I just
#  installed", which is a different question and the one that goes wrong: an
#  install that failed halfway, or ran against a stale tarball, leaves a
#  perfectly healthy server running last week's code.
#
#  It asks the RUNNING SERVICE, not the files on disk. Source in
#  /opt/globalgold/src proves only what was unpacked; the container may still
#  be running an image built before it.
#
#  How it tells them apart: a route that exists but needs an API key answers
#  401. A route that does not exist at all answers 404. So 401 means the
#  feature is there, 404 means it is not.
set -uo pipefail

PORT="${GGP_PORT:-8080}"
BASE="http://127.0.0.1:${PORT}"
fail=0

green() { printf '  \033[32m%-22s %s\033[0m\n' "$1" "$2"; }
red()   { printf '  \033[31m%-22s %s\033[0m\n' "$1" "$2"; fail=1; }
plain() { printf '  %-22s %s\n' "$1" "$2"; }

echo
echo "Global Gold — what is running on $(hostname)"
echo

if ! curl -sf -m 5 -o /dev/null "$BASE/health"; then
  red "service" "not answering on $BASE"
  echo
  echo "  Try:  sudo ggp status     and     sudo ggp logs app"
  exit 1
fi
green "service" "answering on $BASE"

# Each of these is a feature added after the first release. 401 = the route is
# there and wants a key; 404 = this build does not have it.
for entry in \
  "customers:Customers" \
  "subscriptions:Recurring payments" \
  "disputes:Disputes / chargebacks" \
  "invoices:Invoices" \
  "reports/summary:Reports" \
  "payment_links:Payment links"
do
  path="${entry%%:*}"; label="${entry#*:}"
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$BASE/v1/$path")
  case "$code" in
    401|403) green "$label" "present" ;;
    404)     red   "$label" "MISSING — an older build is running" ;;
    *)       plain "$label" "unexpected response $code" ;;
  esac
done

# The public pay page: no key involved, so this checks the route rather than
# the auth layer.
if curl -s -m 5 "$BASE/v1/pay/ZZZZZZZZZZ" | grep -q 'resource_missing'; then
  green "Public pay page" "present"
else
  red "Public pay page" "MISSING"
fi

# SMS reset. An unknown number must still answer 200 — that is the
# anti-enumeration behaviour, so a 404 here means the route is absent.
code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -X POST \
  -H 'content-type: application/json' -d '{"phone":"+15550000000"}' \
  "$BASE/v1/business/forgot_password")
case "$code" in
  200|429) green "SMS password reset" "present" ;;
  404)     red   "SMS password reset" "MISSING" ;;
  *)       plain "SMS password reset" "unexpected response $code" ;;
esac

echo

# Things on disk rather than in the service.
if [ -f /opt/globalgold/src/public/dashboard.html ]; then
  grep -q 'function uuid()' /opt/globalgold/src/public/dashboard.html \
    && green "Dashboard http fix" "present" \
    || red   "Dashboard http fix" "MISSING — the dashboard will fail on plain http"
fi
command -v ggp >/dev/null && {
  ggp help 2>/dev/null | grep -q 'set-password' \
    && green "ggp set-password" "present" || red "ggp set-password" "MISSING"
}

echo
if [ "$fail" = 0 ]; then
  echo "  Everything above is present — this is the current build."
else
  echo "  Something is missing. Reinstall with:   sudo globalgold-update"
fi
echo
exit "$fail"
GGP_EOF_GLOBALGOLD_CHECK
chmod 0755 /opt/globalgold/scripts/globalgold-check
ln -sf /opt/globalgold/scripts/globalgold-check /usr/local/bin/globalgold-check

echo "   globalgold-doctor"
cat > /opt/globalgold/scripts/globalgold-doctor <<'GGP_EOF_GLOBALGOLD_DOCTOR'
#!/usr/bin/env bash
#
#  globalgold-doctor — everything worth knowing when something is wrong.
#
#  Read-only. It changes nothing, so it is safe to run at any time and safe to
#  paste the output to someone helping you — every secret is masked.
#
#  The order is deliberate: the things that break most often are first, and
#  each line says what to do about it rather than only what it found.
set -uo pipefail

PORT="${GGP_PORT:-8080}"
ENV_FILE=/etc/globalgold/env

bold() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32m%-24s %s\033[0m\n' "$1" "$2"; }
bad()  { printf '   \033[31m%-24s %s\033[0m\n' "$1" "$2"; }
warn() { printf '   \033[33m%-24s %s\033[0m\n' "$1" "$2"; }
note() { printf '   %-24s %s\n' "$1" "$2"; }

[ "$(id -u)" = 0 ] || { echo "Run this with sudo:  sudo globalgold-doctor" >&2; exit 1; }

echo
echo "Global Gold — health report for $(hostname), $(date -Is)"

# ─────────────────────────────────────────────────────────────── the service
bold "Service"
systemctl is-active --quiet globalgold && ok "systemd unit" "running" || bad "systemd unit" "NOT running — sudo ggp start"
if curl -sf -m 5 -o /dev/null "http://127.0.0.1:${PORT}/health"; then
  ok "health endpoint" "answering on port ${PORT}"
else
  bad "health endpoint" "no answer — sudo ggp logs app"
fi
if command -v docker >/dev/null; then
  up=$(docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | sed 's/^/                            /')
  [ -n "$up" ] && { echo "   containers"; echo "$up"; } || bad "containers" "none running"
fi

# ───────────────────────────────────────────────────────────────── the disk
bold "Disk"
AVAIL=$(df -Pm / | awk 'NR==2{print $4}')
USEPCT=$(df -Pm / | awk 'NR==2{print $5}')
note "root filesystem" "$(df -h / | awk 'NR==2{print $2" total, "$4" free ("$5" used)"}')"
if [ "$AVAIL" -lt 1000 ]; then
  bad "free space" "${AVAIL} MB — too low to update, and Postgres may stop writing"
  note "" "sudo globalgold-grow-disk    or    sudo docker builder prune -af"
elif [ "$AVAIL" -lt 3000 ]; then
  warn "free space" "${AVAIL} MB — not enough to build an update (needs 3000)"
  note "" "sudo globalgold-grow-disk"
else
  ok "free space" "${AVAIL} MB"
fi
SER=$(lsblk -no SERIAL "$(lsblk -no pkname "$(findmnt -no SOURCE /)" 2>/dev/null | head -1 | tr -d ' ' | sed 's|^|/dev/|')" 2>/dev/null | head -1 | tr -d ' ')
case "$SER" in vol-*) note "EBS volume" "$SER" ;; vol?*) note "EBS volume" "vol-${SER#vol}" ;; esac

# ─────────────────────────────────────────────────────────────────── memory
bold "Memory"
note "RAM" "$(free -h | awk '/^Mem:/{print $2" total, "$7" available"}')"
SW=$(free -m | awk '/^Swap:/{print $2}')
[ "${SW:-0}" -gt 0 ] && note "swap" "${SW} MB" || note "swap" "none (the build may run out of memory on a small instance)"

# ───────────────────────────────────────────────────────────────── database
bold "Database"
if docker compose -f /opt/globalgold/compose.yml exec -T db pg_isready -U globalgold >/dev/null 2>&1; then
  ok "postgres" "accepting connections"
  SIZE=$(docker compose -f /opt/globalgold/compose.yml exec -T db \
    psql -qAtX -U globalgold -d globalgold -c "SELECT pg_size_pretty(pg_database_size('globalgold'))" 2>/dev/null | tr -d '\r')
  [ -n "$SIZE" ] && note "size" "$SIZE"
  for t in merchants payment_intents customers invoices disputes subscriptions; do
    n=$(docker compose -f /opt/globalgold/compose.yml exec -T db \
      psql -qAtX -U globalgold -d globalgold -c "SELECT count(*) FROM $t" 2>/dev/null | tr -d '\r')
    [ -n "$n" ] && note "  $t" "$n rows" || warn "  $t" "no such table — migrations may not have run"
  done
else
  bad "postgres" "not answering — sudo ggp logs db"
fi

# ──────────────────────────────────────────────────────────── configuration
bold "Configuration"
if [ -f "$ENV_FILE" ]; then
  get() { sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | tail -1; }
  set_or_not() { [ -n "$(get "$1")" ] && echo "set" || echo "not set"; }
  note "public URL" "$(get PUBLIC_URL)"
  note "domain" "$(get GGP_DOMAIN || echo '(none — plain http)')"
  note "bound to" "$(get GGP_BIND)"
  note "payment providers" "$(get PAYMENT_PROVIDERS || echo 'simulated (test network)')"
  note "Square secret" "$(set_or_not SQUARE_APP_SECRET)"
  note "Stripe secret" "$(set_or_not STRIPE_SECRET_KEY)"
  note "SMS provider" "$(get SMS_PROVIDER || echo 'console (codes are logged, NOT sent)')"
  note "vault key" "$(set_or_not VAULT_KEY)"
  # A bootstrap token that still exists is an owner-level credential in a file.
  [ -n "$(get ADMIN_TOKEN)" ] && warn "ADMIN_TOKEN" "still set — clear it once you have staff accounts" \
                              || ok "ADMIN_TOKEN" "cleared"
  [ "$(get GGP_DOMAIN)" = "" ] && warn "TLS" "no domain, so no certificate — restrict port ${PORT} to your own IP"
else
  bad "$ENV_FILE" "missing — has the first boot run? journalctl -u globalgold-firstboot"
fi

# ─────────────────────────────────────────────────────────── recent trouble
bold "Recent errors"
ERR=$(docker compose -f /opt/globalgold/compose.yml logs --tail 500 app 2>/dev/null \
      | grep -iE '"level":"error"|unhandled|ECONNREFUSED|FATAL' | tail -5)
[ -n "$ERR" ] && echo "$ERR" | sed 's/^/   /' || ok "app log" "nothing in the last 500 lines"

echo
echo "   Which build is running:   sudo globalgold-check"
echo "   Update it:                sudo globalgold-update"
echo
GGP_EOF_GLOBALGOLD_DOCTOR
chmod 0755 /opt/globalgold/scripts/globalgold-doctor
ln -sf /opt/globalgold/scripts/globalgold-doctor /usr/local/bin/globalgold-doctor

echo "   globalgold-grow-disk"
cat > /opt/globalgold/scripts/globalgold-grow-disk <<'GGP_EOF_GLOBALGOLD_GROW_DISK'
#!/usr/bin/env bash
#
#  Grow this machine's root disk — and, first, tell you which volume that is.
#
#      sudo bash grow-disk.sh              # to 20 GiB
#      sudo bash grow-disk.sh 40           # to 40 GiB
#      sudo bash grow-disk.sh --which      # just identify the volume, change nothing
#      sudo bash grow-disk.sh --grow-only  # skip AWS; claim space already there
#
#  Three steps, and all three are needed. Doing only the first is why a resized
#  volume so often shows no extra space at all:
#
#      1. enlarge the EBS volume          (an AWS API call, or three clicks)
#      2. move the partition boundary out (growpart)
#      3. let the filesystem use it       (resize2fs)
#
#  Steps 2 and 3 are safe on a mounted, running root filesystem and need no
#  reboot, no unmount and no credentials.
#
#  The volume id comes from the NVMe device serial, NOT from an API call. On a
#  Nitro instance the serial IS the volume id, so this works with no IAM role,
#  no credentials and no network — and it is the reliable way to answer "which
#  of these five volumes is the one my server is actually running on", which is
#  exactly the question you get wrong at 2am with a console list in front of you.
#
#  Nothing here shrinks anything. EBS volumes only grow; there is no path in
#  this script that reduces one, because shrinking is what loses filesystems.
set -uo pipefail

WANT_GB="${1:-20}"
MODE=full
case "$WANT_GB" in
  --which)     MODE=which; WANT_GB=0 ;;
  --grow-only) MODE=grow;  WANT_GB=0 ;;
  ''|*[!0-9]*) echo "Usage: sudo bash $0 [size-in-GiB | --which | --grow-only]" >&2; exit 1 ;;
esac

bold() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
good() { printf '   \033[32m%s\033[0m\n' "$*"; }
bad()  { printf '   \033[31m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[31m%s\033[0m\n\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "Run this with sudo:  sudo bash $0 $*"

# ─────────────────────────────────────────────── which disk, which volume
bold "This machine"
ROOT_SRC=$(findmnt -no SOURCE /)
ROOT_PART=$(realpath "$ROOT_SRC" 2>/dev/null || echo "$ROOT_SRC")
[ -b "$ROOT_PART" ] || die "Could not identify the root device (got '$ROOT_SRC')."

DISK=$(lsblk -no pkname "$ROOT_PART" 2>/dev/null | head -1 | tr -d ' ')
PNUM=$(cat "/sys/class/block/$(basename "$ROOT_PART")/partition" 2>/dev/null || true)
FSTYPE=$(findmnt -no FSTYPE /)

# The serial of the whole disk, not the partition.
SERIAL=$(lsblk -no SERIAL "/dev/${DISK:-$(basename "$ROOT_PART")}" 2>/dev/null | head -1 | tr -d ' ')
case "$SERIAL" in
  vol-*) VOL="$SERIAL" ;;
  vol?*) VOL="vol-${SERIAL#vol}" ;;   # nvme serials drop the hyphen
  *)     VOL="" ;;
esac

note "root filesystem   $ROOT_PART  ($FSTYPE)"
note "whole disk        /dev/${DISK:-?}   partition ${PNUM:-none}"
note "size now          $(lsblk -dno SIZE "/dev/$DISK" 2>/dev/null | tr -d ' ')"
note "free now          $(df -Pm / | awk 'NR==2{print $4}') MB"
if [ -n "$VOL" ]; then
  printf '   \033[1mEBS volume        %s\033[0m\n' "$VOL"
  note "                  ^ this is the one to modify, and no other"
else
  note "EBS volume        could not read it from the device serial"
fi

if [ "$MODE" = which ]; then
  [ -n "$VOL" ] && cat <<WHICH

  EC2 -> Volumes -> tick $VOL -> Actions -> Modify volume
  Ignore every other volume in that list; they are not attached to this machine.

WHICH
  exit 0
fi

# ───────────────────────────────────────────── claim space already there
grow_filesystem() {
  bold "Claiming the space"
  local before after
  before=$(df -Pm / | awk 'NR==2{print $4}')
  if [ -z "$DISK" ] || [ -z "$PNUM" ]; then
    note "no partition table — resizing the filesystem directly"
  else
    growpart "/dev/$DISK" "$PNUM" && good "partition grown" || note "partition already fills the disk"
  fi
  case "$FSTYPE" in
    xfs) xfs_growfs / >/dev/null 2>&1 && good "filesystem grown" || note "filesystem already fills the partition" ;;
    *)   resize2fs "$ROOT_PART" >/dev/null 2>&1 && good "filesystem grown" || note "filesystem already fills the partition" ;;
  esac
  after=$(df -Pm / | awk 'NR==2{print $4}')
  note "free: ${before} MB -> ${after} MB"
  df -h / | sed 's/^/   /'
  if [ "$after" -le "$before" ] && [ "$after" -lt 3000 ]; then
    cat <<STUCK

  Nothing changed, and there is still not enough room to build. Either the
  volume has not been enlarged yet, or the change is still in progress.
  Enlarge it, wait a minute, then run:  sudo bash $0 --grow-only
STUCK
  fi
}

if [ "$MODE" = grow ]; then
  grow_filesystem
  exit 0
fi

# ───────────────────────────────────────────────────── enlarge it by API
console_steps() {
  cat <<HELP

  Do it in the browser — three clicks, and you now know exactly which row:

     EC2 -> Volumes -> tick ${VOL:-<the volume shown above>}
     -> Actions -> Modify volume -> Size: $WANT_GB -> Modify

  Then come back here and run, which needs no credentials at all:

     sudo bash $0 --grow-only

HELP
}

bold "Enlarging to ${WANT_GB} GiB"
if [ -z "$VOL" ]; then
  bad "Without the volume id this cannot call AWS safely."
  console_steps
  exit 1
fi

TOK=$(curl -sf -m 3 -X PUT http://169.254.169.254/latest/api/token \
      -H 'X-aws-ec2-metadata-token-ttl-seconds: 120' 2>/dev/null)
REGION=$(curl -sf -m 3 -H "X-aws-ec2-metadata-token: $TOK" \
         http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null)
export PATH="$PATH:/snap/bin:/usr/local/bin"

if ! command -v aws >/dev/null 2>&1; then
  note "the AWS CLI is not installed here"
  console_steps
  exit 1
fi

if ! OUT=$(aws ec2 modify-volume --region "${REGION:-us-east-2}" \
             --volume-id "$VOL" --size "$WANT_GB" 2>&1); then
  bad "AWS would not do it:"
  printf '   %s\n' "$OUT" | head -3
  case "$OUT" in
    *Unable\ to\ locate\ credentials*|*UnauthorizedOperation*|*AccessDenied*)
      cat <<'MSG'

  This instance has no IAM role, so it cannot change its own volume. That is
  normal and not worth fixing just for this — use the console below.

  If you would rather it could: IAM -> Roles -> Create role -> AWS service ->
  EC2 -> attach AmazonEC2FullAccess and AmazonSSMManagedInstanceCore -> name it
  globalgold-ec2 -> then EC2 -> Instances -> Actions -> Security -> Modify IAM
  role. The second policy also gives you a browser shell instead of PuTTY.
MSG
      ;;
    *VolumeModificationRateExceeded*)
      echo
      echo "  A volume can only be modified once every six hours. If you already"
      echo "  resized it, run:  sudo bash $0 --grow-only"
      ;;
  esac
  console_steps
  exit 1
fi
good "AWS accepted it"

bold "Waiting for the new size"
for i in $(seq 1 60); do
  STATE=$(aws ec2 describe-volumes-modifications --region "${REGION:-us-east-2}" \
    --volume-ids "$VOL" --query 'VolumesModifications[0].ModificationState' --output text 2>/dev/null)
  case "$STATE" in
    optimizing|completed) good "state: $STATE"; break ;;
    failed) die "AWS reported the modification failed. Check the console." ;;
    *) printf '   %s (%ds)\r' "${STATE:-starting}" "$((i*5))"; sleep 5 ;;
  esac
done
echo
partprobe "/dev/$DISK" >/dev/null 2>&1 || true
sleep 2
grow_filesystem

cat <<DONE

  ─────────────────────────────────────────────────────────────────────
   Done. Now run the install:

     sudo bash /tmp/go.sh /tmp/ggp.tgz

   A volume can only be modified once every six hours, so ${WANT_GB} GiB is
   what you have until then.
  ─────────────────────────────────────────────────────────────────────

DONE
GGP_EOF_GLOBALGOLD_GROW_DISK
chmod 0755 /opt/globalgold/scripts/globalgold-grow-disk
ln -sf /opt/globalgold/scripts/globalgold-grow-disk /usr/local/bin/globalgold-grow-disk

echo "   globalgold-update"
cat > /opt/globalgold/scripts/globalgold-update <<'GGP_EOF_GLOBALGOLD_UPDATE'
#!/usr/bin/env bash
#
#  globalgold-update — fetch the latest code and install it.
#
#      sudo globalgold-update                    from the configured source
#      sudo globalgold-update <url>              from somewhere else
#      sudo globalgold-update /tmp/build.tgz     from a file already here
#
#  This is the whole update in one word, so nobody has to remember a URL with
#  a version suffix in it at the moment something is broken.
#
#  The source lives in /etc/globalgold/source, written on the first successful
#  update, so the next one needs no argument at all. Change it by passing a new
#  one — it is remembered.
set -uo pipefail

SOURCE_FILE=/etc/globalgold/source
DEFAULT_URL="https://raw.githubusercontent.com/uncutbiz/global-gold-payment/main/globalgold-source.tar.gz"

bold() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
good() { printf '   \033[32m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[31m%s\033[0m\n\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "Run this with sudo:  sudo globalgold-update $*"

SOURCE="${1:-}"
if [ -z "$SOURCE" ] && [ -f "$SOURCE_FILE" ]; then SOURCE=$(head -1 "$SOURCE_FILE"); fi
[ -n "$SOURCE" ] || SOURCE="$DEFAULT_URL"

bold "Source"
note "$SOURCE"

TGZ=/tmp/globalgold-update.tgz
case "$SOURCE" in
  http://*|https://*)
    # -f so an error page is a failure rather than a 200-byte "tarball".
    curl -fL --no-progress-meter --retry 3 --retry-delay 2 -o "$TGZ" "$SOURCE" \
      || die "Could not download it.
  Check the address opens in a browser. If the file name has a suffix like
  _2 on it, pass the full URL:  sudo globalgold-update \"<url>\"" ;;
  *)
    [ -f "$SOURCE" ] || die "Not a URL and not a file: $SOURCE"
    cp -f "$SOURCE" "$TGZ" ;;
esac

BYTES=$(stat -c %s "$TGZ" 2>/dev/null || echo 0)
note "got ${BYTES} bytes"
tar -tzf "$TGZ" >/dev/null 2>&1 \
  || die "That is not a gzipped tarball — ${BYTES} bytes.
  An expired link or an access-denied page is what this usually is.
  Look at it with:  head -c 300 $TGZ"

WORK=/tmp/globalgold-update-src
rm -rf "$WORK"; mkdir -p "$WORK"
tar -xzf "$TGZ" -C "$WORK"
[ -f "$WORK/infra/ami/quickstart.sh" ] \
  || die "The archive unpacked but has no infra/ami/quickstart.sh in it. Wrong file?"
good "unpacked"

# Remember it only once it has proved to be a real archive, so a typo does not
# become the permanent default.
install -d -m 0700 /etc/globalgold
printf '%s\n' "$SOURCE" > "$SOURCE_FILE"
chmod 0600 "$SOURCE_FILE"

# Record what is being installed, so globalgold-autoupdate can tell whether
# the remote has moved without downloading and unpacking it every time.
SUM=$(sha256sum "$TGZ" | cut -d' ' -f1)

bold "Installing"
note "ten to fifteen minutes, most of it npm ci"
bash "$WORK/infra/ami/quickstart.sh" || die "The install failed. The output above says where."

printf '%s\n' "$SUM" > /etc/globalgold/version
chmod 0644 /etc/globalgold/version

bold "Checking what is now running"
sleep 3
if command -v globalgold-check >/dev/null; then
  globalgold-check || die "The install finished but the new build is not running. Try: sudo ggp logs app"
fi

cat <<DONE

  ─────────────────────────────────────────────────────────────────────
   Updated. Worth doing now:

     sudo ggp status                        where it is answering
     sudo ggp set-password you@example.com  rotate your admin password
  ─────────────────────────────────────────────────────────────────────

DONE
GGP_EOF_GLOBALGOLD_UPDATE
chmod 0755 /opt/globalgold/scripts/globalgold-update
ln -sf /opt/globalgold/scripts/globalgold-update /usr/local/bin/globalgold-update

cat <<"DONE"

Installed into /opt/globalgold/scripts, and on PATH:

   globalgold-check        which build is actually running
   globalgold-doctor       full health report, safe to paste to anyone
   globalgold-update       fetch the latest code and install it
   globalgold-autoupdate   check for a new build; --apply to install it
   globalgold-grow-disk    enlarge the EBS volume and claim the space
   globalgold-backup       database + vault key, verified before it counts

Start with:   sudo globalgold-check

DONE

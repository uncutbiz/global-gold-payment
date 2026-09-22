#!/usr/bin/env bash
#
#  Global Gold Payment — one command to install it on this machine.
#
#      sudo bash go.sh                 # source from the GitHub repository below
#      sudo bash go.sh "<any URL>"     # or from a link you give it
#      sudo bash go.sh /path/to.tgz    # or from a file already on this machine
#
#  It does the whole job and reports what it finds as it goes:
#
#      1. grows the filesystem, if the disk was enlarged but the partition was not
#      2. adds swap, if the instance is too small for the build without it
#      3. fetches the source
#      4. hands over to quickstart.sh, which installs Docker and starts everything
#
#  Nothing here is destructive and it is safe to run again: a second run reinstalls
#  the service files and rebuilds the image, leaving the database and this
#  machine's generated keys alone.
#
#  Deliberately NOT `set -e`. When a step fails, the point is to say which one and
#  what to do about it, not to disappear without a word.
set -uo pipefail

# Where the source comes from when you give this script no argument.
#
# A raw.githubusercontent.com link because it is the one kind of address that
# does not go stale: no expiry like a presigned URL, no credentials like an S3
# URI, nothing to attach to the instance. Fetching it is an ordinary HTTPS GET,
# which is the one thing every machine here can already do.
DEFAULT_URL="https://raw.githubusercontent.com/uncutbiz/global-gold-payment/main/globalgold-source.tar.gz"

SOURCE="${1:-${GGP_URL:-$DEFAULT_URL}}"
# An s3:// URI still works if you would rather use an instance role.
SOURCE_URI="${GGP_S3_URI:-}"
WORK=/tmp/ggp
TGZ=/tmp/ggp.tgz
# What the image build needs free, in MB. The swap sizing below respects it.
NEED_MB=3000

bold()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note()  { printf '   %s\n' "$*"; }
good()  { printf '   \033[32m%s\033[0m\n' "$*"; }
bad()   { printf '   \033[31m%s\033[0m\n' "$*"; }
die()   { printf '\n\033[31m%s\033[0m\n\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "Run this with sudo:  sudo bash $0"

# ─────────────────────────────────────────────────────────── 1. filesystem
bold "Disk"
ROOT_PART=$(realpath "$(findmnt -no SOURCE / 2>/dev/null)" 2>/dev/null || true)
if [ -n "$ROOT_PART" ] && [ -b "$ROOT_PART" ]; then
  DISK=$(lsblk -no pkname "$ROOT_PART" 2>/dev/null | head -1 | tr -d ' ')
  PNUM=$(cat "/sys/class/block/$(basename "$ROOT_PART")/partition" 2>/dev/null || true)
  if [ -n "$DISK" ] && [ -n "$PNUM" ]; then
    # If the EBS volume was enlarged in the console, the partition still ends
    # where it used to. growpart moves that boundary; resize2fs then lets the
    # filesystem use it. Both are no-ops when there is nothing to claim, and
    # both are safe on a mounted root filesystem.
    note "root is $ROOT_PART on /dev/$DISK partition $PNUM"
    growpart "/dev/$DISK" "$PNUM" >/dev/null 2>&1 && good "partition grown" || note "partition already fills the disk"
    resize2fs "$ROOT_PART"        >/dev/null 2>&1 && good "filesystem grown"  || note "filesystem already fills the partition"
  else
    note "root is $ROOT_PART with no partition table — nothing to grow"
  fi
else
  note "could not identify the root device; skipping the grow"
fi

AVAIL_MB=$(df -Pm / | awk 'NR==2{print $4}')
note "${AVAIL_MB} MB free on /"

# Short of space with a swapfile sitting there? That swapfile is a file on this
# same disk, and an earlier run of this script may well have been what put it
# there. Reclaim what can be spared rather than sending someone off to resize a
# volume: shrink it to the smallest useful size and take the difference back.
if [ "$AVAIL_MB" -lt "$NEED_MB" ] && [ -f /swapfile ]; then
  SWAP_NOW_MB=$(( $(stat -c %s /swapfile) / 1024 / 1024 ))
  note "a ${SWAP_NOW_MB} MB swapfile is using space the build needs"
  for shrink_to in 512 0; do
    if [ $(( AVAIL_MB + SWAP_NOW_MB - shrink_to )) -ge "$NEED_MB" ]; then
      if [ "$shrink_to" = 0 ]; then
        note "removing it entirely to free ${SWAP_NOW_MB} MB"
      else
        note "shrinking it to ${shrink_to} MB to free $(( SWAP_NOW_MB - shrink_to )) MB"
      fi
      swapoff /swapfile 2>/dev/null
      rm -f /swapfile
      sed -i '/^\/swapfile /d' /etc/fstab
      if [ "$shrink_to" -gt 0 ]; then
        fallocate -l "${shrink_to}M" /swapfile 2>/dev/null \
          || dd if=/dev/zero of=/swapfile bs=1M count="$shrink_to" status=none
        chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
      fi
      AVAIL_MB=$(df -Pm / | awk 'NR==2{print $4}')
      good "${AVAIL_MB} MB free now"
      break
    fi
  done
fi

# Still short, and Docker is here? The most likely reason is a previous run of
# this very script: a build leaves its cache and the layers of the image it
# replaced behind, and on an 8 GiB root volume that is enough to make the NEXT
# update impossible. Reclaim it rather than sending someone to resize a volume
# over rubbish we left there.
#
# Deliberately NOT `docker system prune --volumes`. The database lives in a
# Docker volume, and that one flag is the difference between freeing disk and
# destroying every payment on the machine. Build cache and dangling layers only.
if [ "$AVAIL_MB" -lt "$NEED_MB" ] && command -v docker >/dev/null 2>&1; then
  note "reclaiming Docker build cache and untagged layers"
  docker builder prune -af >/dev/null 2>&1 || true
  docker image prune -f    >/dev/null 2>&1 || true
  AVAIL_MB=$(df -Pm / | awk 'NR==2{print $4}')
  good "${AVAIL_MB} MB free now"
fi

if [ "$AVAIL_MB" -lt "$NEED_MB" ]; then
  die "Not enough disk to build: ${AVAIL_MB} MB free, ${NEED_MB} MB needed.
  I already reclaimed what Docker could spare, so this needs a bigger volume:
  EC2 -> Instances -> your instance -> Storage tab -> click the Volume ID
  -> Actions -> Modify volume -> 20 GiB. Then run this again; it grows the
  filesystem for you.

  If you would rather free space by hand first, this goes further and is still
  safe — it removes images no running container needs:
      sudo docker system prune -af
  Never add --volumes to that. Your database is in a Docker volume."
fi
[ "$AVAIL_MB" -lt 6000 ] && note "that is tight but workable; enlarge the volume to 20 GiB before real data lands here"

# ─────────────────────────────────────────────────────────────── 2. swap
bold "Memory"
MEM_MB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
note "${MEM_MB} MB of RAM"
# npm ci and tsc want more than a small instance has, and without swap the build
# is killed by the OOM reaper and surfaces as a baffling npm error. But a
# swapfile is a FILE: it competes for the same disk the build needs. Sizing it
# without checking that leaves the machine unable to build for lack of the space
# the swap just consumed — so take only what can be spared.
if [ "$MEM_MB" -ge 1900 ]; then
  note "enough RAM; no swap needed"
elif [ -f /swapfile ]; then
  note "swapfile already present"
else
  SWAP_MB=0
  for want in 2048 1024 512; do
    if [ $(( AVAIL_MB - want )) -ge "$NEED_MB" ]; then SWAP_MB=$want; break; fi
  done
  if [ "$SWAP_MB" = 0 ]; then
    note "skipping swap: only ${AVAIL_MB} MB free and the build needs ${NEED_MB} MB"
    note "the build may run short of memory — enlarge the volume to 20 GiB and run this again"
  else
    note "adding a ${SWAP_MB} MB swapfile (leaves $(( AVAIL_MB - SWAP_MB )) MB for the build)"
    fallocate -l "${SWAP_MB}M" /swapfile 2>/dev/null \
      || dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=none
    chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile && good "swap on"
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    AVAIL_MB=$(df -Pm / | awk 'NR==2{print $4}')
    note "${AVAIL_MB} MB free on / after that"
  fi
fi

# ───────────────────────────────────────────────────────────── 3. the source
bold "Source"
# Download to a scratch name and only replace what is already here once the new
# copy has arrived intact. Wiping first means a failed fetch — an expired link,
# a missing IAM role — destroys a perfectly good copy from a previous run and
# sends you back for another link. Learned the hard way.
TGZ_NEW="$TGZ.new"
rm -f "$TGZ_NEW"

fetch_with_url() {
  curl -fL --no-progress-meter --retry 3 --retry-delay 2 -o "$TGZ_NEW" "$1"
}

fetch_from_file() {
  cp -f "$1" "$TGZ_NEW"
}

fetch_with_role() {
  if ! command -v aws >/dev/null 2>&1; then
    note "installing the AWS CLI"
    # Ubuntu 24.04 dropped the awscli package, so snap first, then Amazon's
    # own installer. One of the two works on every image we care about.
    snap install aws-cli --classic >/dev/null 2>&1 && good "installed with snap" || {
      note "snap did not work; using Amazon's installer"
      command -v unzip >/dev/null 2>&1 || {
        (command -v apt-get >/dev/null && apt-get install -y -qq unzip) \
          || (command -v dnf >/dev/null && dnf -y -q install unzip)
      } >/dev/null 2>&1
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip \
        && unzip -qo /tmp/awscliv2.zip -d /tmp && /tmp/aws/install --update >/dev/null 2>&1 \
        && good "installed"
    }
    export PATH="$PATH:/snap/bin:/usr/local/bin"
  fi
  command -v aws >/dev/null 2>&1 || { bad "the AWS CLI would not install"; return 1; }

  # The region comes from the instance itself, so the URI needs none in it.
  local tok region
  tok=$(curl -sf -m 3 -X PUT http://169.254.169.254/latest/api/token \
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null)
  region=$(curl -sf -m 3 -H "X-aws-ec2-metadata-token: $tok" \
           http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null)
  note "reading $SOURCE_URI as this instance"
  aws s3 cp "$SOURCE_URI" "$TGZ_NEW" ${region:+--region "$region"} 2>&1 | tail -2
  [ -s "$TGZ_NEW" ]
}

case "$SOURCE" in
  s3://*)
    SOURCE_URI="$SOURCE"
    note "reading $SOURCE_URI with this instance's IAM role"
    fetch_with_role || die "Could not read $SOURCE_URI.

  This instance has no IAM role with read access to that bucket. Attach one:
       IAM -> Roles -> Create role -> AWS service -> EC2
       -> attach AmazonS3ReadOnlyAccess
       -> name it globalgold-ec2
       EC2 -> Instances -> your instance -> Actions -> Security
       -> Modify IAM role -> globalgold-ec2
  Or drop S3 altogether and run this script with no argument at all, which
  reads the source over plain HTTPS and needs no credentials."
    ;;
  http://*|https://*)
    note "downloading $SOURCE"
    fetch_with_url "$SOURCE" || die "That download did not work: $SOURCE

  If that is the built-in GitHub address, the repository or the file is not
  there yet — the file has to be called exactly globalgold-source.tar.gz and
  sit at the top level of the repository's main branch, and the repository has
  to be public for a machine with no login to read it.

  Check what the address actually returns with:
       curl -sSI \"$SOURCE\" | head -3

  A 404 means the name is wrong or the repository is private."
    ;;
  *)
    [ -f "$SOURCE" ] || die "Not a URL and not a file on this machine: $SOURCE"
    note "using the file already here: $SOURCE"
    fetch_from_file "$SOURCE" || die "Could not read $SOURCE."
    ;;
esac

BYTES=$(stat -c %s "$TGZ_NEW" 2>/dev/null || echo 0)
note "got ${BYTES} bytes"
# Check it really is an archive before letting it replace anything.
tar -tzf "$TGZ_NEW" >/dev/null 2>&1 \
  || die "That file is not a gzipped tarball — $BYTES bytes.
  An expired link or a denied request returns an error page, and this is where
  it shows up. Check it with:  head -c 300 $TGZ_NEW
  Whatever was here before has been left alone."
rm -rf "$WORK" "$TGZ"
mv "$TGZ_NEW" "$TGZ"
mkdir -p "$WORK"
tar -xzf "$TGZ" -C "$WORK" || die "Could not unpack $TGZ."
[ -f "$WORK/infra/ami/quickstart.sh" ] \
  || die "The archive unpacked but does not contain infra/ami/quickstart.sh.
  Wrong file uploaded to the bucket?"
good "source ready in $WORK"

# ──────────────────────────────────────────────────────────── 4. the install
bold "Installing"
note "this takes ten to fifteen minutes, most of it npm ci"
note "everything below is also written to /var/log/globalgold-install.log"
exec bash "$WORK/infra/ami/quickstart.sh"

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

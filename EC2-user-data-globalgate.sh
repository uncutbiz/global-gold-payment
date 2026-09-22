#!/usr/bin/env bash
# Paste this into EC2's "User data" box when launching an instance, and the
# machine installs and starts Global Gold Payment by itself. Nothing to type at
# a terminal afterwards.
#
# Works on Amazon Linux 2023 and Ubuntu 22.04/24.04, x86_64 or arm64.
#
# ─────────────────────────────────────────────────────────────────────────────
# SET GGP_SOURCE BELOW. Everything else is optional.
# ─────────────────────────────────────────────────────────────────────────────
#
# The instance needs:
#   - outbound internet (a public subnet with a public IP, or a NAT gateway)
#   - about 20 GB of root volume, so the image build has room
#   - for an s3:// source, an IAM role with read access to that bucket
#     (EC2 → Actions → Security → Modify IAM role)
#
# It logs everything to /var/log/globalgold-install.log, and cloud-init's own
# copy is in /var/log/cloud-init-output.log. Watch it with:
#
#     sudo tail -f /var/log/globalgold-install.log
#
# When it finishes, /root/globalgold-first-boot.txt holds the URL and what to do
# next, and `sudo ggp status` works.

set -euo pipefail
exec > >(tee -a /var/log/globalgold-install.log) 2>&1

# Where to get the source. Either an S3 URI (needs the instance role above) or
# any HTTPS URL that serves the tarball, including a presigned S3 link.
#   s3://my-bucket/globalgold-source.tar.gz
#   https://my-bucket.s3.us-east-2.amazonaws.com/globalgold-source.tar.gz?X-Amz-...
GGP_SOURCE="s3://globalgate/globalgold-source.tar.gz"

# Optional: a domain already pointing at this instance. Set it and the machine
# comes up on HTTPS with a real Let's Encrypt certificate instead of port 8080.
# Ports 80 and 443 have to be open in the security group for that to work.
GGP_DOMAIN=""

echo "=== Global Gold Payment install starting $(date -Is)"
echo "    source: $GGP_SOURCE"
[ "$GGP_SOURCE" != "REPLACE_ME" ] \
  || { echo "!! Set GGP_SOURCE at the top of the user-data script."; exit 1; }

# ------------------------------------------------------------------ packages
if command -v dnf >/dev/null 2>&1; then
  dnf -y install tar gzip curl
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends tar gzip curl ca-certificates
fi

# A domain set here is picked up by firstboot when it writes this machine's
# configuration, so the very first start is already on HTTPS.
if [ -n "$GGP_DOMAIN" ]; then
  install -d -m 0700 /etc/globalgold
  echo "$GGP_DOMAIN" > /etc/globalgold/domain
  echo "    domain: $GGP_DOMAIN"
fi

# -------------------------------------------------------------------- source
rm -rf /tmp/ggp /tmp/ggp.tgz
case "$GGP_SOURCE" in
  s3://*)
    echo "=== Fetching from S3 with this instance's IAM role"
    if ! command -v aws >/dev/null 2>&1; then
      # Amazon Linux ships the CLI; Ubuntu does not.
      command -v snap >/dev/null 2>&1 && snap install aws-cli --classic \
        || { apt-get install -y awscli || dnf -y install awscli; }
    fi
    # The region comes from the instance itself, so the URI needs no region in it.
    REGION=$(curl -sf -m 3 -H "X-aws-ec2-metadata-token: $(curl -sf -m 3 -X PUT \
      http://169.254.169.254/latest/api/token \
      -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" \
      http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo '')
    aws s3 cp "$GGP_SOURCE" /tmp/ggp.tgz ${REGION:+--region "$REGION"} \
      || { echo "!! Could not read $GGP_SOURCE.
    Attach an IAM role to this instance with read access to that bucket:
    EC2 → Instances → Actions → Security → Modify IAM role."; exit 1; }
    ;;
  http://*|https://*)
    echo "=== Downloading the source"
    curl -fL -o /tmp/ggp.tgz "$GGP_SOURCE" \
      || { echo "!! Download failed. A presigned URL may have expired — they are
    short-lived by design. Generate a fresh one and relaunch."; exit 1; }
    ;;
  *)
    echo "!! GGP_SOURCE must be an s3:// URI or an http(s):// URL."; exit 1 ;;
esac

ls -l /tmp/ggp.tgz
mkdir -p /tmp/ggp
tar -xzf /tmp/ggp.tgz -C /tmp/ggp \
  || { echo "!! That file is not a gzipped tarball. If the download returned an
    access-denied page instead of the file, this is where it shows up."; exit 1; }
[ -f /tmp/ggp/infra/ami/quickstart.sh ] \
  || { echo "!! The tarball does not contain infra/ami/quickstart.sh."; exit 1; }

# ------------------------------------------------------------------- install
# quickstart.sh does the real work and is the same script you would run by hand,
# so there is one implementation to keep correct rather than two.
echo "=== Handing over to quickstart.sh"
bash /tmp/ggp/infra/ami/quickstart.sh

rm -rf /tmp/ggp /tmp/ggp.tgz
echo "=== Finished $(date -Is)"

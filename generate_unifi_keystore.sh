#!/usr/bin/env bash

# This script creates a valid keystore file to be used by UniFi Controller from 
# letsencrypt generated certificates. Useful when you're not running UC behind
# a forward proxy (such as nginx), but still want to use signed certificates.

# You can run this script from the command line by specifying the directory that
# contains the letsencrypt certificate, and the directory you want the keystore
# file to be created. See usage below.

# You can also drop this script into /etc/cron.monthly and it will update your
# keystore when it detects a new certificate, and then restart the UniFi Controller.
# If you want to use cron then you will need to set the variables for your system
# in the CRON section below.

# When run from cron, all output is directed to syslog.

set -euo pipefail

usage() {
cat <<EOF

Usage:
  $0 /etc/letsencrypt/live/domain/ [ /var/lib/unifi/ ]

Requirements in LE directory:
  cert.pem
  fullchain.pem
  privkey.pem

EOF
}

# Detect interactive mode
if [[ -t 1 ]]; then
    [[ $# -lt 1 ]] && { usage; exit 1; }

    letsencrypt_cert_dir="$1"
    unifi_keystore_dir="${2:-$PWD}"
else

# -------------------------------------------------------------------
# CRON CONFIG
# -------------------------------------------------------------------

letsencrypt_cert_dir="/etc/letsencrypt/live/host.domain.tld"
unifi_keystore_dir="/var/lib/unifi"

OWNER="unifi"
MODE="640"

restart_uc="docker restart unifi-controller"
# restart_uc="systemctl restart unifi"

# -------------------------------------------------------------------

exec 1> >(logger -s -t "$(basename "$0")") 2>&1
fi

keystore_pass="aircontrolenterprise"

# Requirements
command -v keytool >/dev/null 2>&1 || {
    echo "Error: keytool not installed"
    exit 1
}

command -v openssl >/dev/null 2>&1 || {
    echo "Error: openssl not installed"
    exit 1
}

# Validate LE files
for f in cert.pem fullchain.pem privkey.pem; do
    [[ -f "$letsencrypt_cert_dir/$f" ]] || {
        echo "Error: Missing $f in $letsencrypt_cert_dir"
        exit 1
    }
done

get_letsencrypt_cert_print() {
    openssl x509 \
        -in "$letsencrypt_cert_dir/cert.pem" \
        -noout \
        -fingerprint \
        -sha256 \
    | cut -d= -f2
}

get_keystore_cert_print() {
    [[ -f "$unifi_keystore_dir/keystore" ]] || return 1

    keytool \
        -list \
        -v \
        -keystore "$unifi_keystore_dir/keystore" \
        -alias unifi \
        -storepass "$keystore_pass" 2>/dev/null \
    | awk -F': ' '/SHA256:/ {print $2; exit}'
}

compare_certs() {
    local le_fp ks_fp

    le_fp="$(get_letsencrypt_cert_print)"
    ks_fp="$(get_keystore_cert_print || true)"

    [[ "$le_fp" == "$ks_fp" ]]
}

generate_keystore() {
    local tmpfile

    tmpfile="$(mktemp)"
    trap 'rm -f "$tmpfile"' EXIT

    echo "Generating PKCS12 bundle..."

    openssl pkcs12 \
        -export \
        -inkey "$letsencrypt_cert_dir/privkey.pem" \
        -in "$letsencrypt_cert_dir/cert.pem" \
        -certfile "$letsencrypt_cert_dir/fullchain.pem" \
        -name unifi \
        -out "$tmpfile" \
        -password "pass:$keystore_pass"

    chmod 600 "$tmpfile"

    echo "Importing into Java keystore..."

    keytool \
        -importkeystore \
        -deststorepass "$keystore_pass" \
        -destkeypass "$keystore_pass" \
        -destkeystore "$unifi_keystore_dir/keystore" \
        -srckeystore "$tmpfile" \
        -srcstoretype PKCS12 \
        -srcstorepass "$keystore_pass" \
        -alias unifi \
        -noprompt

    echo "Success: Generated new UniFi keystore"
}

# Compare existing cert
if compare_certs; then
    [[ -t 1 ]] && echo "Nothing to do. Keystore already current."
    exit 0
fi

# Validate output dir
[[ -d "$unifi_keystore_dir" ]] || {
    echo "Error: '$unifi_keystore_dir' is not a directory"
    exit 1
}

[[ -w "$unifi_keystore_dir" ]] || {
    echo "Error: '$unifi_keystore_dir' is not writable"
    exit 1
}

# Backup existing keystore
if [[ -f "$unifi_keystore_dir/keystore" ]]; then
    rm -f "$unifi_keystore_dir/keystore.bck"
    mv "$unifi_keystore_dir/keystore" \
       "$unifi_keystore_dir/keystore.bck"
fi

generate_keystore

# Cron mode actions
if [[ ! -t 1 ]]; then
    chown "$OWNER:$OWNER" "$unifi_keystore_dir/keystore"
    chmod "$MODE" "$unifi_keystore_dir/keystore"

    if eval "$restart_uc" >/dev/null 2>&1; then
        echo "Success: UniFi Controller restarted"
    else
        echo "Error: Failed to restart UniFi Controller"
        exit 1
    fi
fi

exit 0

#!/bin/bash
set -euo pipefail

REALM="EXAMPLE.LOCALHOST"
KDC_DB_DIR="/var/lib/krb5kdc"
KEYTAB_DIR="/keytabs"
MASTER_PW="${KDC_MASTER_PASSWORD:-masterpassword}"
ADMIN_PW="${KDC_ADMIN_PASSWORD:-adminpassword}"
CLIENT_PW="${KDC_CLIENT_PASSWORD:-clientpassword}"

mkdir -p "${KEYTAB_DIR}"

STASH_FILE="${KDC_DB_DIR}/.k5.${REALM}"

# A previous run can be interrupted mid-bootstrap (e.g. the compose stack
# was torn down while kdb5_util was running), leaving the principal DB file
# present but the master-key stash missing, or vice versa. That half-state
# makes krb5kdc/kadmind fail forever on every subsequent start ("cannot
# fetch master key"). Detect that and wipe it so we bootstrap cleanly again.
if [ -e "${KDC_DB_DIR}/principal" ] && [ ! -f "${STASH_FILE}" ]; then
    echo "[kdc] Found an incomplete database (missing master key stash)."
    echo "[kdc] Wiping ${KDC_DB_DIR} to bootstrap cleanly..."
    find "${KDC_DB_DIR}" -mindepth 1 -delete
fi

if [ ! -f "${KDC_DB_DIR}/principal" ]; then
    echo "[kdc] No existing database found. Bootstrapping realm ${REALM}..."

    kdb5_util create -s -r "${REALM}" -P "${MASTER_PW}"

    # Admin principal, used for remote kadmin administration if ever needed.
    kadmin.local -q "addprinc -pw ${ADMIN_PW} admin/admin@${REALM}"

    # Kafka broker service principal + keytab.
    # Hostname MUST match the broker's advertised hostname (kafka.example.localhost).
    kadmin.local -q "addprinc -randkey kafka/kafka.example.localhost@${REALM}"
    kadmin.local -q "ktadd -norandkey -k ${KEYTAB_DIR}/kafka.keytab kafka/kafka.example.localhost@${REALM}"

    # A sample client principal for testing producers/consumers, both as a
    # keytab (for non-interactive use) and a password (for interactive kinit).
    kadmin.local -q "addprinc -pw ${CLIENT_PW} client@${REALM}"
    kadmin.local -q "ktadd -norandkey -k ${KEYTAB_DIR}/client.keytab client@${REALM}"

    chmod 644 "${KEYTAB_DIR}"/*.keytab
    echo "[kdc] Realm bootstrap complete."
    echo "[kdc]   kafka principal: kafka/kafka.example.localhost@${REALM}"
    echo "[kdc]   client principal: client@${REALM} (password: ${CLIENT_PW})"
else
    echo "[kdc] Existing database found, skipping bootstrap."
fi

echo "[kdc] Starting krb5kdc and kadmind..."
krb5kdc -n &
kadmind -nofork &

wait -n

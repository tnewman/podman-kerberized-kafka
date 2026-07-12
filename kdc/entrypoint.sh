#!/bin/bash
set -euo pipefail

REALM="EXAMPLE.COM"
KDC_DB_DIR="/var/lib/krb5kdc"
KEYTAB_DIR="/keytabs"
MASTER_PW="${KDC_MASTER_PASSWORD:-masterpassword}"
ADMIN_PW="${KDC_ADMIN_PASSWORD:-adminpassword}"
CLIENT_PW="${KDC_CLIENT_PASSWORD:-clientpassword}"

mkdir -p "${KEYTAB_DIR}"

if [ ! -f "${KDC_DB_DIR}/principal" ]; then
    echo "[kdc] No existing database found. Bootstrapping realm ${REALM}..."

    kdb5_util create -s -r "${REALM}" -P "${MASTER_PW}"

    # Admin principal, used for remote kadmin administration if ever needed.
    kadmin.local -q "addprinc -pw ${ADMIN_PW} admin/admin@${REALM}"

    # Kafka broker service principal + keytab.
    # Hostname MUST match the broker's advertised hostname (kafka.example.com).
    kadmin.local -q "addprinc -randkey kafka/kafka.example.com@${REALM}"
    kadmin.local -q "ktadd -norandkey -k ${KEYTAB_DIR}/kafka.keytab kafka/kafka.example.com@${REALM}"

    # A sample client principal for testing producers/consumers, both as a
    # keytab (for non-interactive use) and a password (for interactive kinit).
    kadmin.local -q "addprinc -pw ${CLIENT_PW} client@${REALM}"
    kadmin.local -q "ktadd -norandkey -k ${KEYTAB_DIR}/client.keytab client@${REALM}"

    chmod 644 "${KEYTAB_DIR}"/*.keytab
    echo "[kdc] Realm bootstrap complete."
    echo "[kdc]   kafka principal: kafka/kafka.example.com@${REALM}"
    echo "[kdc]   client principal: client@${REALM} (password: ${CLIENT_PW})"
else
    echo "[kdc] Existing database found, skipping bootstrap."
fi

echo "[kdc] Starting krb5kdc and kadmind..."
krb5kdc -n &
kadmind -nofork &

wait -n

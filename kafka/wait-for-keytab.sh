#!/bin/bash
set -e

KEYTAB="/etc/kafka/secrets/kafka.keytab"

echo "[kafka] Waiting for Kerberos keytab at ${KEYTAB}..."
until [ -s "${KEYTAB}" ]; do
    sleep 2
done
echo "[kafka] Keytab found. Starting Kafka..."

exec /etc/confluent/docker/run

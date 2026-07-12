FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Pre-seed debconf so the krb5 packages install non-interactively.
# We still fully control realm creation ourselves in entrypoint.sh.
RUN echo "krb5-config krb5-config/default_realm string EXAMPLE.COM" | debconf-set-selections \
    && echo "krb5-config krb5-config/kerberos_servers string kdc.example.com" | debconf-set-selections \
    && echo "krb5-config krb5-config/admin_server string kdc.example.com" | debconf-set-selections \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        krb5-kdc \
        krb5-admin-server \
        krb5-user \
    && rm -rf /var/lib/apt/lists/*

COPY krb5.conf /etc/krb5.conf
COPY kdc.conf /etc/krb5kdc/kdc.conf
COPY kadm5.acl /etc/krb5kdc/kadm5.acl
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
    && mkdir -p /var/lib/krb5kdc /keytabs

# 88 = KDC (UDP+TCP), 749 = kadmin/admin server
EXPOSE 88/udp 88/tcp 749/tcp

ENTRYPOINT ["/entrypoint.sh"]

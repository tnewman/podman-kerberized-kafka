# Kerberized Kafka on Podman Compose

A single-node Kafka broker (KRaft mode, no Zookeeper) secured with Kerberos
(SASL/GSSAPI), plus its own MIT Kerberos KDC — all managed with Podman
Compose.

## Layout

```
kerberized-kafka/
├── docker-compose.yml        # the whole stack
├── kdc/                      # KDC image: realm, kdc.conf, entrypoint
├── kafka/                    # Kafka broker image: krb5.conf + JAAS baked in
├── test-client/              # test-client image: krb5.conf + client.properties baked in
└── client/                   # files for connecting from outside the stack
```

**Realm:** `EXAMPLE.COM`
**KDC hostname:** `kdc.example.com`
**Kafka hostname:** `kafka.example.com`
**Kafka service principal:** `kafka/kafka.example.com@EXAMPLE.COM`
**Test client principal:** `client@EXAMPLE.COM` (password `clientpassword`, and a keytab)

## How it works

1. `kdc` builds a small Debian image running `krb5kdc` + `kadmind`. On first
   boot it creates the `EXAMPLE.COM` realm and generates two keytabs into a
   shared volume: one for the Kafka broker, one for a test client.
2. `kafka` builds on top of Confluent's `cp-kafka` image with `krb5.conf` and
   the broker's JAAS config copied in at build time (they're static, so
   there's no reason to bind-mount them — that also sidesteps SELinux
   labeling headaches on rootless Podman entirely). Its entrypoint is
   overridden with an inline wait loop (in `docker-compose.yml`) that blocks
   until the KDC has written `kafka.keytab` — which *does* have to be a
   runtime volume, since it's generated dynamically — then hands off to
   Kafka's normal startup script. The broker runs KRaft mode
   (broker+controller combined) with a single listener, `SASL_PLAINTEXT`,
   authenticated via GSSAPI.
3. `test-client` similarly builds on `cp-kafka` with `krb5.conf` and
   `client.properties` copied in at build time, plus the client keytab
   mounted at runtime from the same shared volume. `exec` into it to run
   Kafka CLI tools immediately without installing anything on your host.

## Running it

```bash
cd kerberized-kafka
podman-compose up -d --build
podman-compose logs -f kdc kafka   # watch it come up
```

The KDC needs a few seconds to initialize before Kafka's keytab appears, so
the broker will sit in "Waiting for Kerberos keytab..." briefly — that's
expected.

Since `krb5.conf` and the JAAS configs are now baked into the `kafka` and
`test-client` images at build time, if you edit them you'll need to rebuild:
`podman-compose up -d --build`.

## Quick smoke test (using the bundled test-client container)

```bash
podman-compose exec test-client bash

# Inside the container:
kafka-topics --bootstrap-server kafka.example.com:9092 \
  --command-config /etc/kafka/client.properties \
  --create --topic demo --partitions 1 --replication-factor 1

kafka-console-producer --bootstrap-server kafka.example.com:9092 \
  --producer.config /etc/kafka/client.properties \
  --topic demo
# type a few lines, Ctrl-D to end

kafka-console-consumer --bootstrap-server kafka.example.com:9092 \
  --consumer.config /etc/kafka/client.properties \
  --topic demo --from-beginning
```

## Connecting from your host machine (or another app)

1. **Resolve the hostnames.** The stack uses `kdc.example.com` and
   `kafka.example.com` internally, and your client needs to resolve them too.
   Since the KDC and Kafka ports are published to `localhost`, add to your
   `/etc/hosts`:

   ```
   127.0.0.1  kdc.example.com kafka.example.com
   ```

2. **Get the `krb5.conf`.** Use `client/krb5.conf` from this project — note
   it points at the KDC's unprivileged published ports (10088/10749), not
   the standard 88/749 — or point your app at it via the `KRB5_CONFIG`
   environment variable instead of overwriting `/etc/krb5.conf` system-wide:

   ```bash
   export KRB5_CONFIG=/path/to/kerberized-kafka/client/krb5.conf
   ```

3. **Get the client keytab.** It was generated inside the shared volume;
   copy it out via the KDC container:

   ```bash
   podman cp kdc:/keytabs/client.keytab ./client/client.keytab
   ```

4. **Authenticate**, either with the keytab directly (see `sasl.jaas.config`
   in `client/client.properties`) or interactively:

   ```bash
   kinit -kt client/client.keytab client@EXAMPLE.COM
   klist   # confirm you have a ticket
   ```

5. **Connect** using any Kafka client with `client/client.properties` as
   its security config, e.g. with a local Kafka install:

   ```bash
   kafka-console-producer.sh --bootstrap-server localhost:9092 \
     --producer.config client/client.properties --topic demo
   ```

## Creating additional principals

Exec into the KDC and use `kadmin.local`:

```bash
podman-compose exec kdc kadmin.local -q "addprinc -pw somepassword alice@EXAMPLE.COM"
podman-compose exec kdc kadmin.local -q "ktadd -norandkey -k /keytabs/alice.keytab alice@EXAMPLE.COM"
```

Keytabs land in the `kafka-keytabs` volume, which is also mounted at
`/etc/kafka/secrets` in the Kafka and test-client containers.

## Persistence / resetting

The realm database, Kafka log data, and keytabs live in named volumes
(`kdc-data`, `kafka-data`, `kafka-keytabs`), so they survive `podman-compose
down`. To start completely fresh:

```bash
podman-compose down -v
```

## Troubleshooting

- **Kafka stuck on "Waiting for Kerberos keytab..."** — check `podman-compose
  logs kdc`; the realm bootstrap may have failed. Delete the `kdc-data`
  volume and retry if the database was left in a bad state.
- **`kadmind: Can not fetch master key ... No such file or directory`** —
  the KDC database is in a half-initialized state, usually because an
  earlier run was interrupted mid-bootstrap. `kdc/entrypoint.sh` detects and
  self-heals this on the next start, but if you're still stuck, force a
  clean slate: `podman-compose down -v` (this wipes all volumes, including
  the realm database and keytabs) then `podman-compose up -d --build`.
- **SELinux / rootless Podman and bind mounts** — the static config files
  (`krb5.conf`, JAAS config, `client.properties`) are copied into the images
  at build time rather than bind-mounted, specifically to avoid SELinux
  labeling issues on Fedora/RHEL-family rootless Podman hosts. If you add
  your own bind mounts later, remember: read-only mounts still need
  relabeling (`:Z` for a file used by one container, lowercase `:z` if the
  same host file is mounted into more than one container — mixing this up
  causes one container to silently lose read access to the file).
- **`GSSException: No valid credentials provided`** — usually a clock skew
  (Kerberos tickets are time-sensitive) or the client's `krb5.conf`/keytab
  principal not matching exactly. Run `klist -kt` on the keytab to confirm
  the principal name.
- **Hostname mismatch errors** — Kerberos service principals are
  hostname-specific. If you change `KAFKA_ADVERTISED_LISTENERS`, the
  principal created in `kdc/entrypoint.sh` (`kafka/kafka.example.com`) must
  match the new hostname exactly.
- **Running as non-root / rootless Podman** — rootless Podman can't publish
  host ports below 1024 without extra privileges, so this compose file
  already maps the KDC's standard ports (88, 749) to unprivileged host ports
  10088 and 10749 (`kdc:88 -> host:10088`, etc). The container itself still
  listens on the standard ports internally, so container-to-container
  traffic (e.g. Kafka reaching the KDC) is unaffected — only external
  clients need the remapped ports, which `client/krb5.conf` already reflects.
  If you'd rather use the real ports 88/749, either run as root, or add
  `net.ipv4.ip_unprivileged_port_start=88` to `/etc/sysctl.conf` on the host
  and change the port mappings back in `docker-compose.yml` and
  `client/krb5.conf`.

## Notes on the image choice

This uses `confluentinc/cp-kafka:7.6.1`, which bundles the Kafka CLI tools
and supports KRaft mode with SASL/GSSAPI out of the box via environment
variables. If you'd rather use vanilla Apache Kafka images, the same
`KAFKA_OPTS`, JAAS file, and `server.properties`-equivalent settings apply —
you'd just set them via a mounted `server.properties` instead of `KAFKA_*`
env vars.

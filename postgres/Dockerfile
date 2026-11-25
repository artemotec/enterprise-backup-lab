FROM postgres:16-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    pgbackrest \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/log/pgbackrest /var/spool/pgbackrest /etc/pgbackrest \
    && chown -R postgres:postgres /var/log/pgbackrest /var/spool/pgbackrest /etc/pgbackrest

COPY init-pgbackrest.sh /docker-entrypoint-initdb.d/01-init-pgbackrest.sh
RUN chmod +x /docker-entrypoint-initdb.d/01-init-pgbackrest.sh

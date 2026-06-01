# Client tools (pg_dump) match the Postgres server major version.
ARG POSTGRES_BASE_IMAGE=postgres:15
FROM ${POSTGRES_BASE_IMAGE}

USER root

COPY requirements.txt /tmp/backup-requirements.txt
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-venv \
    && python3 -m venv /opt/xwiki-backup-venv \
    && /opt/xwiki-backup-venv/bin/pip install --no-cache-dir -r /tmp/backup-requirements.txt \
    && rm -rf /var/lib/apt/lists/* /tmp/backup-requirements.txt

ENV PATH="/opt/xwiki-backup-venv/bin:${PATH}"

USER postgres

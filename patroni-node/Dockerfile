FROM postgres:17.5-bullseye
USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3-pip jq curl locales && \
    pip install --no-cache-dir 'patroni[etcd3]==3.3.2' 'psycopg[binary]' && \
    rm -rf /var/lib/apt/lists/*

RUN localedef -i en_US -f UTF-8 en_US.UTF-8 || true
ENV LANG=en_US.UTF-8

# Create config dir and set ownership explicitly
RUN mkdir -p /etc/patroni && chown postgres:postgres /etc/patroni

COPY patroni-entrypoint.sh /usr/local/bin/patroni-entrypoint.sh
COPY patroni.yml.template /etc/patroni/patroni.yml.template

RUN chown postgres:postgres /etc/patroni/patroni.yml.template && chmod +x /usr/local/bin/patroni-entrypoint.sh

EXPOSE 5432 8008

ENTRYPOINT ["/usr/local/bin/patroni-entrypoint.sh"]

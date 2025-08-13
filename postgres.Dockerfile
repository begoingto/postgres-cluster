FROM postgres:17.5-bullseye

RUN apt update && \
    apt -y install python3-pip python3-dev libpq-dev && \
    pip install --upgrade pip && \
    pip install patroni python-etcd psycopg2

FROM postgres:17.5-bullseye

RUN apt update && \
    apt install -y etcd

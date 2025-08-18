# PostgreSQL High-Availability Cluster with Patroni and etcd3

This project provides a Docker Compose setup for a high-availability (HA) PostgreSQL cluster using [Patroni](https://patroni.readthedocs.io/) and [etcd3](https://etcd.io/) for distributed consensus. The cluster consists of three PostgreSQL nodes managed by Patroni for automatic failover and replication, with etcd3 ensuring leader election and configuration synchronization. A GitHub Actions workflow is included to build and push the Docker image to the GitHub Container Registry (GHCR) when specific paths change or on manual trigger.

## Features

- **High Availability**: Automatic failover and leader election using Patroni and etcd3.
- **Multi-Node Cluster**: Three PostgreSQL nodes with streaming replication.
- **Docker Compose**: Simplified deployment with container orchestration.
- **GitHub Actions**: Automated Docker image building and pushing to GHCR with registry-based caching.
- **Path-Based Triggers**: Builds trigger on changes to `partonic-node`, `primary`, `share`, or `Dockerfile`.
- **Manual Trigger**: Supports manual workflow execution via GitHub Actions.
- **Custom Tags**: Images tagged with `node`, `cache-node`, branch, tag, and SHA.

## Prerequisites

- **Docker**: Version 27.2.0 or later.
- **Docker Compose**: Version v1.29.2 or later.
- **Git**: Any recent version.
- **GitHub Repository**: Access to push to GHCR with `packages: write` permission.
- **Free Ports**: 5432 (PostgreSQL), 8008-8010 (Patroni REST API), 2379-2381 (etcd3).
- **Hardware**: At least 4GB RAM and 8 CPU cores for a 3-node setup.

## Directory Structure
```shell
.
├── connect.sh
├── docker-compose.yml
├── haproxy
│   └── haproxy.cfg
├── patroni-node
│   ├── Dockerfile
│   ├── patroni-entrypoint.sh
│   └── patroni.yml.template
├── primary
│   ├── init
│   │   └── init-primary.sql
│   └── postgresql.primary.conf
├── README.MD
├── sample.env
└── shared
    └── archive
        └── replica-entrypoint.sh
```

- `Dockerfile`: Defines the PostgreSQL-Patroni image.
- `docker-compose.yml`: Orchestrates the PostgreSQL, Patroni, and etcd3 services.
- `partonic-node/`, `primary/`, `share/`: Application code directories triggering builds.
- `.github/workflows/docker-publish.yml`: GitHub Actions workflow for building and pushing images.

## Setup Instructions

### Step 1: Clone the Repository

```bash
git clone https://github.com/<user>/<repo>.git
cd <repo>
```
### Step 2: Configure Environment Variable
```shell
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=postgres
PATRONI_SCOPE=patroni-cluster
PATRONI_NAME=node1
```
### Step 3: Docker compose execute up Postresql Cluster
```shell
docker-compose up -d
```
### Step 4: Check Patroni Cluster Status

```shell
docker exec pg-node1 patronictl -c /etc/patroni/patroni.yml list
```
Expected output:
```
+ Cluster: pgcluster (7539919637780119581) -+----+-----------+
| Member   | Host     | Role    | State     | TL | Lag in MB |
+----------+----------+---------+-----------+----+-----------+
| pg-node1 | pg-node1 | Leader  | running   |  4 |           |
| pg-node2 | pg-node2 | Replica | streaming |  4 |         0 |
| pg-node3 | pg-node3 | Replica | streaming |  4 |         0 |
+----------+----------+---------+-----------+----+-----------+
```
### Step 5: Connect to cluster Writer
```shell
./connect.sh --env-file sample.env --mode rw
```
Exepected Output:
```
psql (14.18 (Ubuntu 14.18-0ubuntu0.22.04.1), server 17.5 (Debian 17.5-1.pgdg110+1))
WARNING: psql major version 14, server major version 17.
         Some psql features might not work.
Type "help" for help.

postgres=#
```
# Congratulations🚀⚡🎊🎉🌟

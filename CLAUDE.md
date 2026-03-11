# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Real-time financial transaction processing PoC: Producer generates synthetic transactions → Kafka → Consumer enriches with fraud logic (amount >= 4000 → SUSPICIOUS) and persists to Oracle DB → FastAPI serves paginated/cached results → Nginx-served SPA dashboard with auto-refresh.

## Tech Stack

- **Kafka**: Confluent 7.8.0, KRaft mode (no Zookeeper), topic: `financial.transactions`
- **Database**: Oracle 21c XE (`gvenzl/oracle-xe:21-slim`), schema in `init.sql`
- **Producer/Consumer**: Python 3.11 (`app/producer.py`, `app/consumer.py`) — confluent-kafka, oracledb, tenacity
- **API**: Python 3.12, FastAPI (`api/main.py`) — oracledb, pymemcache
- **Cache**: Memcached 1.6 (TTL configurable via `CACHE_TTL`, default 120s)
- **Frontend**: Vanilla HTML/CSS/JS SPA (`frontend/index.html`) served by Nginx
- **Monitoring**: Confluent Control Center on port 9021

## Build & Run

```bash
cp .env.example .env          # defaults work fine
docker compose up -d --build  # start full stack
docker compose down -v        # stop and remove volumes
```

**Access points:**
- Dashboard: `http://localhost:8080`
- API docs: `http://localhost:8080/api/docs`
- Control Center: `http://localhost:9021`

**Logs:** `docker compose logs -f <service>` where service is `producer`, `consumer`, `api`, `frontend`, `broker`, `oracle`

## Linting & Security

```bash
ruff check .            # lint (config in .ruff.toml: line-length 88, target py311)
ruff check --fix .      # auto-fix
ruff format .           # format
bandit -r . -ll         # SAST (high severity)
```

Ruff rules: E, W, F, I (isort), B (bugbear), C4, UP (pyupgrade), S (bandit). Tests directory allows asserts (`S101` ignored).

## CI/CD

- **`.github/workflows/security.yml`**: Ruff, Bandit, Safety SCA, Trivy (IaC + container scans, CRITICAL/HIGH)
- **`.github/workflows/docker-build-push.yml`**: Builds & pushes to Docker Hub on main push. Images: `juamsv/kafka-labs:{component}-{sha}` and `:{component}-latest`

## Architecture

```
Producer → Kafka (financial.transactions) → Consumer → Oracle DB → API (+ Memcached) → Frontend
```

- **Producer** (`app/producer.py`): Generates random transactions at `MSG_PER_SEC` rate. Supports AWS MSK IAM auth (SASL_SSL/OAUTHBEARER) in production.
- **Consumer** (`app/consumer.py`): Enriches with fraud status, inserts to `transactions` table. Retries DB connection via tenacity (10 attempts, 3s intervals).
- **API** (`api/main.py`): `GET /transactions` with query params: `page`, `per_page`, `sort_by`, `sort_order`, `status`, `date_from`, `date_to`. Memcached caching with key-per-query-combination.
- **Frontend** (`frontend/index.html`): Dark-themed dashboard. Auto-refresh every 5s (toggleable). Highlights suspicious transactions.

## Kubernetes (Helm)

Deployment is managed via a Helm chart in `helm/kafka-lab/`. The chart packages all resources (deployments, services, configmap, secrets, jobs, KEDA) into a single parameterized chart.

```bash
ic-poc-eks                    # configure kubeconfig for the EKS cluster (run first)

# Lint the chart
helm lint helm/kafka-lab/

# Render templates locally (dry-run)
helm template my-release helm/kafka-lab/ \
  --set database.password=CHANGEME \
  --set database.dsn=host:1521/ORCL \
  --set kafka.brokers=broker:9098 \
  --set cache.host=memcached

# Install
helm install kafka-lab helm/kafka-lab/ \
  --set database.password=CHANGEME \
  --set database.dsn=host:1521/ORCL \
  --set kafka.brokers=b-1.msk:9098,b-2.msk:9098 \
  --set cache.host=memcached.endpoint

# Upgrade
helm upgrade kafka-lab helm/kafka-lab/ -f values-prod.yaml

# Uninstall
helm uninstall kafka-lab
```

Key values to provide at deploy time (empty defaults): `kafka.brokers`, `database.password`, `database.dsn`, `cache.host`. See `helm/kafka-lab/values.yaml` for all options.

Legacy raw manifests remain in `k8s/` (gitignored) for reference.

## Key Conventions

- Environment variables in `.env` (see `.env.example`); never commit `.env` or credentials
- Always create feature branches for changes
- Docker images use non-root users (`appuser` for Python, `nginx` for frontend)
- Keep `.env.example` in sync when adding new environment variables
- Oracle connection: `oracle:1521/XEPDB1` (container), `localhost:1521/XEPDB1` (host)
- No automated tests yet — validate manually via logs and dashboard

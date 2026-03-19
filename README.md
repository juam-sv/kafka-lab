# Kafka Lab

A high-performance Proof of Concept (PoC) demonstrating a real-time data pipeline for financial transactions using Apache Kafka, Python, and PostgreSQL.

## Architecture
- **Kafka (KRaft Mode):** Message broker handling transaction streams.
- **Python Producer:** Simulates real-time financial traffic with configurable throughput.
- **Python Consumer:** Processes transactions, applies fraud logic (flags amounts > 4000), and persists to DB.
- **PostgreSQL:** Reliable storage for processed financial records.
- **FastAPI Backend:** Provides real-time transaction data via JSON API.
- **Memcached:** Caches API responses to reduce DB load.
- **Frontend Dashboard:** Simple dashboard for monitoring processed transactions.
- **Confluent Control Center:** Visual monitoring of topics and message flow.

## Requirements
- Docker & Docker Compose
- OrbStack (for automatic local domains)

## Setup & Run
1. Create and configure your environment variables:
   ```bash
   cp .env.example .env
   ```
   *Edit `.env` if you need to change default credentials or Kafka settings.*

2. Build and start the containers:
   ```bash
   docker compose up -d --build
   ```

3. Access the components:
   - **Frontend Dashboard:** [http://localhost:8080](http://localhost:8080)
   - **Kafka Control Center:** [http://control-center.kafka-poc.orb.local](http://control-center.kafka-poc.orb.local) or [http://localhost:9021](http://localhost:9021)
   - **API Docs:** [http://localhost:8080/api/docs](http://localhost:8080/api/docs)

4. View Real-time processing:
   ```bash
   docker compose logs -f consumer
   ```

## Stress Testing
To increase the load, modify the `MSG_PER_SEC` variable in your `.env` file and restart the producer:
```bash
# Update MSG_PER_SEC in .env
docker compose up -d producer
```

## API Examples

The API serves transactions at `/api/transactions` with pagination, filtering, and sorting.

### Docker Compose (local)

```bash
# List transactions (default: page 1, 20 per page, sorted by created_at desc)
curl http://localhost:8080/api/transactions

# Pagination
curl "http://localhost:8080/api/transactions?page=2&per_page=10"

# Filter by status
curl "http://localhost:8080/api/transactions?status=SUSPICIOUS"
curl "http://localhost:8080/api/transactions?status=COMPLETED"

# Filter by date range
curl "http://localhost:8080/api/transactions?date_from=2026-03-01&date_to=2026-03-19"

# Sort by amount ascending
curl "http://localhost:8080/api/transactions?sort_by=amount&sort_order=asc"

# Combine filters
curl "http://localhost:8080/api/transactions?status=SUSPICIOUS&sort_by=amount&sort_order=desc&per_page=5"

# OpenAPI docs
curl http://localhost:8080/api/docs
```

### Cloud (EKS / ALB)

Replace the hostname with your environment's domain:

```bash
# List transactions
curl https://app.getorlo.info/api/transactions

# Filter suspicious transactions sorted by amount
curl "https://app.getorlo.info/api/transactions?status=SUSPICIOUS&sort_by=amount&sort_order=desc"

# Paginate
curl "https://app.getorlo.info/api/transactions?page=3&per_page=50"

# OpenAPI docs
curl https://app.getorlo.info/api/docs
```

### Query Parameters

| Parameter    | Default      | Description                                      |
|-------------|-------------|--------------------------------------------------|
| `page`       | `1`          | Page number (>= 1)                               |
| `per_page`   | `20`         | Results per page (1–100)                          |
| `status`     | —            | Filter by status (`COMPLETED`, `SUSPICIOUS`)      |
| `date_from`  | —            | Start date filter (`YYYY-MM-DD`)                  |
| `date_to`    | —            | End date filter (`YYYY-MM-DD`)                    |
| `sort_by`    | `created_at` | Sort column (`amount`, `created_at`, `status`, `txn_type`, `currency`) |
| `sort_order` | `desc`       | Sort direction (`asc`, `desc`)                    |

## Database Queries
Check transaction statuses in PostgreSQL:
```bash
# Using credentials from .env
docker compose exec postgres psql -U user -d finance_db -c "SELECT status, count(*) FROM transactions GROUP BY status;"
```

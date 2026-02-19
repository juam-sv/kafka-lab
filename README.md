# Kafka Financial Transaction PoC

A high-performance Proof of Concept (PoC) demonstrating a real-time data pipeline for financial transactions using Apache Kafka, Python, and PostgreSQL.

## Architecture
- **Kafka (KRaft Mode):** Message broker handling transaction streams.
- **Python Producer:** Simulates real-time financial traffic with configurable throughput.
- **Python Consumer:** Processes transactions, applies fraud logic (flags amounts > 4000), and persists to DB.
- **PostgreSQL:** Reliable storage for processed financial records.
- **Confluent Control Center:** Visual monitoring of topics and message flow.

## Requirements
- Docker & Docker Compose
- OrbStack (for automatic local domains)

## Setup & Run
1. Build and start the containers:
   ```bash
   docker compose up -d --build
   ```

2. Access the Monitoring UI:
   - URL: [http://control-center.kafka-poc.orb.local](http://control-center.kafka-poc.orb.local)

3. View Real-time processing:
   ```bash
   docker compose logs -f consumer
   ```

## Stress Testing
To increase the load, modify the `MSG_PER_SEC` variable in `docker-compose.yml` for the producer service and restart:
```bash
docker compose up -d producer
```

## Database Queries
Check transaction statuses in PostgreSQL:
```bash
docker compose exec postgres psql -U user -d finance_db -c "SELECT status, count(*) FROM transactions GROUP BY status;"
```

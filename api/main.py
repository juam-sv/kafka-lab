import json
import logging
import math
import os
import time
import uuid
from datetime import UTC, datetime
from decimal import Decimal

import oracledb
import redis
from confluent_kafka import Producer
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from otel_setup import init_tracer
from pydantic import BaseModel, Field

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("api")

app = FastAPI(root_path="/api")
tracer = init_tracer(app)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def log_requests(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    elapsed_ms = (time.perf_counter() - start) * 1000
    logger.info(
        "%s %s %d %.1fms",
        request.method,
        request.url.path,
        response.status_code,
        elapsed_ms,
    )
    return response

DB_USER = os.getenv("DB_USER", "finance_user")
DB_PASSWORD = os.getenv("DB_PASSWORD", "Finance123")
DB_DSN = os.getenv("DB_DSN", "oracle:1521/XEPDB1")
CACHE_HOST = os.getenv("CACHE_HOST", os.getenv("MEMCACHED_HOST", "valkey"))
CACHE_PORT = int(os.getenv("CACHE_PORT", os.getenv("MEMCACHED_PORT", "6379")))
CACHE_TLS = os.getenv("CACHE_TLS", "false").lower() == "true"
CACHE_PASSWORD = os.getenv("CACHE_PASSWORD", None)
CACHE_TTL = int(os.getenv("CACHE_TTL", "120"))
CACHE_COUNT_TTL = int(os.getenv("CACHE_COUNT_TTL", "300"))

KAFKA_BROKER = os.getenv("KAFKA_BROKER", "broker:9092")
KAFKA_USE_MSK = os.getenv("KAFKA_USE_MSK", "false").lower() == "true"
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")

VALID_SORT_COLUMNS = {"amount", "created_at", "status", "txn_type", "currency"}

pool = None
kafka_producer = None


class TransactionCreate(BaseModel):
    source_account: str = Field(..., min_length=1, max_length=100)
    target_account: str = Field(..., min_length=1, max_length=100)
    amount: float = Field(..., gt=0)
    currency: str = Field(..., pattern=r"^(USD|BRL|EUR)$")
    txn_type: str = Field(..., pattern=r"^(TRANSFER|PAYMENT|WITHDRAWAL|DEPOSIT)$")


def _create_kafka_producer():
    """Create Kafka producer."""
    try:
        kafka_conf = {"bootstrap.servers": KAFKA_BROKER}
        if KAFKA_USE_MSK:
            from aws_msk_iam_sasl_signer import MSKAuthTokenProvider

            def oauth_cb(config):  # noqa: ARG001
                token, expiry_ms = MSKAuthTokenProvider.generate_auth_token(
                    AWS_REGION,
                )
                return token, expiry_ms / 1000

            kafka_conf.update({
                "security.protocol": "SASL_SSL",
                "sasl.mechanism": "OAUTHBEARER",
                "oauth_cb": oauth_cb,
            })
        producer = Producer(kafka_conf)
        logger.info(
            "Kafka producer created — broker=%s msk=%s",
            KAFKA_BROKER, KAFKA_USE_MSK,
        )
        return producer
    except Exception:
        logger.exception("Failed to create Kafka producer")
        return None


def _create_pool():
    """Create Oracle connection pool."""
    try:
        p = oracledb.create_pool(
            user=DB_USER, password=DB_PASSWORD, dsn=DB_DSN,
            min=2, max=10, increment=1,
        )
        logger.info("Oracle connection pool created — min=2 max=10")
        return p
    except oracledb.Error:
        logger.exception("Failed to create Oracle connection pool")
        return None


def _connect_cache():
    """Create Redis/Valkey connection. Returns client or None."""
    logger.info("Connecting to cache — host=%s port=%s tls=%s auth=%s",
                CACHE_HOST, CACHE_PORT, CACHE_TLS, bool(CACHE_PASSWORD))
    try:
        kwargs = {
            "host": CACHE_HOST,
            "port": CACHE_PORT,
            "socket_timeout": 5,
            "socket_connect_timeout": 5,
            "decode_responses": True,
        }
        if CACHE_PASSWORD:
            kwargs["password"] = CACHE_PASSWORD
        if CACHE_TLS:
            kwargs["ssl"] = True
            kwargs["ssl_cert_reqs"] = "none"
        client = redis.Redis(**kwargs)
        client.ping()
        logger.info(
            "Cache connected — host=%s port=%s tls=%s",
            CACHE_HOST, CACHE_PORT, CACHE_TLS,
        )
        return client
    except Exception:
        logger.exception(
            "Cache connection failed — host=%s port=%s tls=%s",
            CACHE_HOST, CACHE_PORT, CACHE_TLS,
        )
        return None


cache = _connect_cache()


def rows_to_dicts(cursor, rows):
    cols = [d[0].lower() for d in cursor.description]
    return [dict(zip(cols, row, strict=True)) for row in rows]


@app.on_event("startup")
def on_startup():
    global cache, pool, kafka_producer
    if cache is None:
        logger.info("Retrying cache connection at startup...")
        cache = _connect_cache()
    pool = _create_pool()
    kafka_producer = _create_kafka_producer()
    logger.info(
        "API started — DSN=%s CACHE=%s:%s TLS=%s TTL=%ds "
        "COUNT_TTL=%ds pool=%s cache=%s kafka=%s",
        DB_DSN, CACHE_HOST, CACHE_PORT, CACHE_TLS,
        CACHE_TTL, CACHE_COUNT_TTL,
        "active" if pool else "none",
        "connected" if cache else "disconnected",
        "connected" if kafka_producer else "disconnected",
    )


@app.on_event("shutdown")
def on_shutdown():
    global pool, kafka_producer
    if kafka_producer:
        kafka_producer.flush(timeout=5)
        logger.info("Kafka producer flushed")
        kafka_producer = None
    if pool:
        pool.close()
        logger.info("Oracle connection pool closed")
        pool = None


@app.get("/health")
def health():
    """Liveness probe — app process is running."""
    return {"status": "ok"}


@app.get("/ready")
def ready():
    """Readiness probe — checks DB pool and cache connectivity."""
    checks = {}
    healthy = True

    if pool:
        try:
            conn = pool.acquire()
            conn.ping()
            pool.release(conn)
            checks["database"] = "ok"
        except Exception as e:
            checks["database"] = str(e)
            healthy = False
    else:
        checks["database"] = "pool not initialized"
        healthy = False

    if cache:
        try:
            cache.ping()
            checks["cache"] = "ok"
        except Exception as e:
            checks["cache"] = str(e)
            healthy = False
    else:
        checks["cache"] = "not connected"

    if kafka_producer:
        checks["kafka"] = "ok"
    else:
        checks["kafka"] = "producer not initialized"
        healthy = False

    if not healthy:
        raise HTTPException(status_code=503, detail=checks)
    return {"status": "ok", "checks": checks}


@app.get("/cache-status")
def cache_status():
    """Diagnostic endpoint for cache connectivity."""
    status = {
        "host": CACHE_HOST,
        "port": CACHE_PORT,
        "tls": CACHE_TLS,
        "ttl": CACHE_TTL,
        "count_ttl": CACHE_COUNT_TTL,
    }
    if cache is None:
        status["connected"] = False
        status["error"] = "cache client is None (connection failed at startup)"
        return status
    try:
        cache.ping()
        info = cache.info(section="server")
        status["connected"] = True
        status["redis_version"] = info.get("redis_version", "unknown")
        status["uptime_seconds"] = info.get("uptime_in_seconds", "unknown")
    except Exception as e:
        status["connected"] = False
        status["error"] = str(e)
    return status


@app.get("/transactions")
def list_transactions(
    page: int = Query(1, ge=1),
    per_page: int = Query(20, ge=1, le=100),
    status: str | None = Query(None),
    date_from: str | None = Query(None),
    date_to: str | None = Query(None),
    sort_by: str = Query("created_at"),
    sort_order: str = Query("desc"),
):
    request_start = time.perf_counter()

    if sort_by not in VALID_SORT_COLUMNS:
        sort_by = "created_at"
    if sort_order not in ("asc", "desc"):
        sort_order = "desc"

    cache_key = (
        f"txns:{page}:{per_page}:{status}:{date_from}:{date_to}:"
        f"{sort_by}:{sort_order}"
    )
    count_cache_key = f"txns:count:{status}:{date_from}:{date_to}"

    if cache:
        try:
            cached = cache.get(cache_key)
            if cached:
                logger.info(f"Cache HIT for key: {cache_key}")
                data = json.loads(cached)
                data["cached"] = True
                data["source"] = "cache"
                elapsed = time.perf_counter() - request_start
                data["response_time_ms"] = round(elapsed * 1000, 1)
                return data
            logger.info(f"Cache MISS for key: {cache_key}")
        except Exception as e:
            logger.error(f"Cache retrieval error: {e}")

    conditions = []
    params = {}

    if status:
        conditions.append("status = :status")
        params["status"] = status
    if date_from:
        conditions.append(
            "created_at >= TO_TIMESTAMP_TZ("
            ":date_from, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3\"Z\"')"
        )
        params["date_from"] = date_from
    if date_to:
        conditions.append(
            "created_at <= TO_TIMESTAMP_TZ("
            ":date_to, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3\"Z\"')"
        )
        params["date_to"] = date_to

    where = ("WHERE " + " AND ".join(conditions)) if conditions else ""

    offset = (page - 1) * per_page
    page_params = {**params, "per_page": per_page, "offset": offset}

    if pool:
        conn = pool.acquire()
    else:
        conn = oracledb.connect(
            user=DB_USER, password=DB_PASSWORD, dsn=DB_DSN,
        )

    try:
        cur = conn.cursor()
        db_start = time.perf_counter()

        # Try to get count from cache (longer TTL)
        total = None
        if cache:
            try:
                cached_count = cache.get(count_cache_key)
                if cached_count is not None:
                    total = int(cached_count)
                    logger.info(f"Count cache HIT: {total}")
            except Exception as e:
                logger.error(f"Count cache retrieval error: {e}")

        with tracer.start_as_current_span("db.query_transactions", attributes={
            "db.system": "oracle",
            "db.operation": "SELECT",
            "db.sql.table": "transactions",
            "api.page": page,
            "api.per_page": per_page,
            "server.address": DB_DSN.split(":")[0],
        }) as span:
            if total is None:
                cur.execute(f"SELECT COUNT(*) FROM transactions {where}", params)  # noqa: S608  # nosec B608
                total = cur.fetchone()[0]
                if cache:
                    try:
                        cache.set(count_cache_key, str(total), ex=CACHE_COUNT_TTL)
                        logger.info(
                            "Count cache SET: %s (TTL: %ds)", total, CACHE_COUNT_TTL,
                        )
                    except Exception as e:
                        logger.error(f"Count cache storage error: {e}")

            cur.execute(
                f"SELECT * FROM transactions {where} "  # noqa: S608  # nosec B608
                f"ORDER BY {sort_by} {sort_order} "
                f"OFFSET :offset ROWS FETCH NEXT :per_page ROWS ONLY",
                page_params,
            )
            rows = rows_to_dicts(cur, cur.fetchall())
            span.set_attribute("db.row_count", len(rows))
        db_ms = (time.perf_counter() - db_start) * 1000
        logger.info("DB query: %d rows, %d total, %.1fms", len(rows), total, db_ms)
    except oracledb.Error:
        logger.exception("DB query failed")
        raise
    finally:
        if pool:
            pool.release(conn)
        else:
            conn.close()

    for r in rows:
        for k, v in r.items():
            if isinstance(v, datetime):
                r[k] = v.isoformat()
            elif isinstance(v, Decimal):
                r[k] = float(v)

    now = datetime.now(UTC).isoformat()
    result = {
        "data": rows,
        "total": total,
        "page": page,
        "per_page": per_page,
        "pages": math.ceil(total / per_page) if per_page else 1,
        "cached": False,
        "cached_at": now,
        "source": "database",
        "response_time_ms": round((time.perf_counter() - request_start) * 1000, 1),
    }

    # Lower TTL for page 1 default sort (hottest query) for freshness
    is_hot_query = page == 1 and sort_by == "created_at" and sort_order == "desc"
    data_ttl = 60 if is_hot_query else CACHE_TTL

    if cache:
        try:
            cache.set(cache_key, json.dumps(result), ex=data_ttl)
            logger.info(f"Cache SET for key: {cache_key} (TTL: {data_ttl}s)")
        except Exception as e:
            logger.error(f"Cache storage error: {e}")

    return result


@app.post("/transactions")
def create_transaction(txn: TransactionCreate):
    if kafka_producer is None:
        raise HTTPException(status_code=503, detail="Kafka producer not available")

    transaction_id = str(uuid.uuid4())
    message = {
        "transaction_id": transaction_id,
        "source_account": txn.source_account,
        "target_account": txn.target_account,
        "amount": txn.amount,
        "currency": txn.currency,
        "txn_type": txn.txn_type,
        "timestamp": datetime.now(UTC).isoformat(),
    }

    try:
        kafka_producer.produce(
            "financial.transactions",
            json.dumps(message).encode("utf-8"),
        )
        kafka_producer.poll(0)
        logger.info("Transaction submitted to Kafka: %s", transaction_id)
    except Exception as exc:
        logger.exception("Failed to produce message to Kafka")
        raise HTTPException(
            status_code=500, detail="Failed to submit transaction",
        ) from exc

    return {"transaction_id": transaction_id, "status": "submitted"}


SEARCH_FIELDS = {"transaction_id", "source_account", "target_account"}


@app.get("/transactions/search")
def search_transactions(
    field: str = Query(...),
    value: str = Query(..., min_length=1),
):
    if field not in SEARCH_FIELDS:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid field. Must be one of: {', '.join(sorted(SEARCH_FIELDS))}",
        )

    if pool:
        conn = pool.acquire()
    else:
        conn = oracledb.connect(user=DB_USER, password=DB_PASSWORD, dsn=DB_DSN)

    try:
        cur = conn.cursor()
        with tracer.start_as_current_span("db.search_transactions", attributes={
            "db.system": "oracle",
            "db.operation": "SELECT",
            "db.sql.table": "transactions",
            "server.address": DB_DSN.split(":")[0],
        }):
            cur.execute(
                f"SELECT * FROM transactions WHERE {field} = :val",  # noqa: S608  # nosec B608
                {"val": value},
            )
            rows = rows_to_dicts(cur, cur.fetchall())
    except oracledb.Error:
        logger.exception("Search query failed for %s=%s", field, value)
        raise
    finally:
        if pool:
            pool.release(conn)
        else:
            conn.close()

    for r in rows:
        for k, v in r.items():
            if isinstance(v, datetime):
                r[k] = v.isoformat()
            elif isinstance(v, Decimal):
                r[k] = float(v)

    return {"data": rows}


@app.get("/transactions/{transaction_id}")
def get_transaction(transaction_id: str):
    cache_key = f"txn:{transaction_id}"

    if cache:
        try:
            cached = cache.get(cache_key)
            if cached:
                logger.info("Cache HIT for txn: %s", transaction_id)
                data = json.loads(cached)
                data["cached"] = True
                data["source"] = "cache"
                return data
        except Exception as e:
            logger.error("Cache retrieval error for txn %s: %s", transaction_id, e)

    if pool:
        conn = pool.acquire()
    else:
        conn = oracledb.connect(user=DB_USER, password=DB_PASSWORD, dsn=DB_DSN)

    try:
        cur = conn.cursor()
        with tracer.start_as_current_span("db.query_transaction", attributes={
            "db.system": "oracle",
            "db.operation": "SELECT",
            "db.sql.table": "transactions",
            "server.address": DB_DSN.split(":")[0],
        }):
            cur.execute(
                "SELECT * FROM transactions WHERE transaction_id = :txn_id",
                {"txn_id": transaction_id},
            )
            row = cur.fetchone()
            if not row:
                raise HTTPException(
                    status_code=404,
                    detail="Transaction not found — it may still be processing",
                )
            result = rows_to_dicts(cur, [row])[0]
    except HTTPException:
        raise
    except oracledb.Error:
        logger.exception("DB query failed for txn: %s", transaction_id)
        raise
    finally:
        if pool:
            pool.release(conn)
        else:
            conn.close()

    for k, v in result.items():
        if isinstance(v, datetime):
            result[k] = v.isoformat()
        elif isinstance(v, Decimal):
            result[k] = float(v)

    result["cached"] = False
    result["source"] = "database"

    if cache:
        try:
            cache.set(cache_key, json.dumps(result), ex=CACHE_TTL)
            logger.info("Cache SET for txn: %s (TTL: %ds)", transaction_id, CACHE_TTL)
        except Exception as e:
            logger.error("Cache storage error for txn %s: %s", transaction_id, e)

    return result

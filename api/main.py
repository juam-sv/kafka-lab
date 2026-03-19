import json
import logging
import math
import os
import time
from datetime import UTC, datetime
from decimal import Decimal

import oracledb
import redis
from fastapi import FastAPI, Query, Request
from fastapi.middleware.cors import CORSMiddleware

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("api")

app = FastAPI(root_path="/api")
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
CACHE_TTL = int(os.getenv("CACHE_TTL", "120"))

VALID_SORT_COLUMNS = {"amount", "created_at", "status", "txn_type", "currency"}


def get_db():
    return oracledb.connect(user=DB_USER, password=DB_PASSWORD, dsn=DB_DSN)


try:
    cache = redis.Redis(
        host=CACHE_HOST, port=CACHE_PORT,
        socket_timeout=2, socket_connect_timeout=2,
        ssl=CACHE_TLS, decode_responses=True,
    )
    cache.ping()
    logger.info("Cache connected — host=%s port=%s tls=%s", CACHE_HOST, CACHE_PORT, CACHE_TLS)
except Exception as e:
    logger.warning("Cache unavailable (%s:%s): %s", CACHE_HOST, CACHE_PORT, e)
    cache = None


def rows_to_dicts(cursor, rows):
    cols = [d[0].lower() for d in cursor.description]
    return [dict(zip(cols, row, strict=True)) for row in rows]


@app.on_event("startup")
def log_startup():
    logger.info("API started — DB_DSN=%s CACHE=%s:%s CACHE_TTL=%ds",
                DB_DSN, CACHE_HOST, CACHE_PORT, CACHE_TTL)


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

    if cache:
        try:
            cached = cache.get(cache_key)
            if cached:
                logger.info(f"Cache HIT for key: {cache_key}")
                data = json.loads(cached)
                data["cached"] = True
                data["source"] = "cache"
                data["response_time_ms"] = round((time.perf_counter() - request_start) * 1000, 1)
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
        conditions.append("created_at >= TO_TIMESTAMP_TZ(:date_from, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3\"Z\"')")
        params["date_from"] = date_from
    if date_to:
        conditions.append("created_at <= TO_TIMESTAMP_TZ(:date_to, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3\"Z\"')")
        params["date_to"] = date_to

    where = ("WHERE " + " AND ".join(conditions)) if conditions else ""

    offset = (page - 1) * per_page
    page_params = {**params, "per_page": per_page, "offset": offset}

    try:
        conn = get_db()
    except oracledb.Error:
        logger.exception("Failed to connect to Oracle")
        raise

    try:
        cur = conn.cursor()
        db_start = time.perf_counter()

        cur.execute(f"SELECT COUNT(*) FROM transactions {where}", params)  # noqa: S608  # nosec B608
        total = cur.fetchone()[0]

        cur.execute(
            f"SELECT * FROM transactions {where} "  # noqa: S608  # nosec B608
            f"ORDER BY {sort_by} {sort_order} "
            f"OFFSET :offset ROWS FETCH NEXT :per_page ROWS ONLY",
            page_params,
        )
        rows = rows_to_dicts(cur, cur.fetchall())
        db_ms = (time.perf_counter() - db_start) * 1000
        logger.info("DB query: %d rows, %d total, %.1fms", len(rows), total, db_ms)
    except oracledb.Error:
        logger.exception("DB query failed")
        raise
    finally:
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

    if cache:
        try:
            cache.set(cache_key, json.dumps(result), ex=CACHE_TTL)
            logger.info(f"Cache SET for key: {cache_key} (TTL: {CACHE_TTL}s)")
        except Exception as e:
            logger.error(f"Cache storage error: {e}")

    return result

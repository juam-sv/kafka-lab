import json
import logging
import math
import os
from datetime import UTC, datetime

import psycopg2
import psycopg2.extras
from fastapi import FastAPI, Query
from fastapi.middleware.cors import CORSMiddleware
from psycopg2 import sql
from pymemcache.client.base import Client as MemcacheClient

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

DB_URL = os.getenv("DATABASE_URL", "postgres://user:password@postgres:5432/finance_db")
MEMCACHED_HOST = os.getenv("MEMCACHED_HOST", "memcached")
MEMCACHED_PORT = int(os.getenv("MEMCACHED_PORT", "11211"))
CACHE_TTL = int(os.getenv("CACHE_TTL", "120"))

VALID_SORT_COLUMNS = {"amount", "created_at", "status", "txn_type", "currency"}


def get_db():
    return psycopg2.connect(DB_URL)


def get_cache():
    try:
        return MemcacheClient(
            (MEMCACHED_HOST, MEMCACHED_PORT),
            connect_timeout=1,
            timeout=1,
        )
    except Exception as e:
        logger.warning(f"Failed to connect to Memcached: {e}")
        return None


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
    if sort_by not in VALID_SORT_COLUMNS:
        sort_by = "created_at"
    if sort_order not in ("asc", "desc"):
        sort_order = "desc"

    cache_key = (
        f"txns:{page}:{per_page}:{status}:{date_from}:{date_to}:"
        f"{sort_by}:{sort_order}"
    )

    mc = get_cache()
    if mc:
        try:
            cached = mc.get(cache_key)
            if cached:
                logger.info(f"Cache HIT for key: {cache_key}")
                data = json.loads(cached)
                data["cached"] = True
                data["cached_at"] = data.get("cached_at")
                return data
            logger.info(f"Cache MISS for key: {cache_key}")
        except Exception as e:
            logger.error(f"Cache retrieval error: {e}")

    conditions = []
    params = []

    if status:
        conditions.append(sql.SQL("status = %s"))
        params.append(status)
    if date_from:
        conditions.append(sql.SQL("created_at >= %s"))
        params.append(date_from)
    if date_to:
        conditions.append(sql.SQL("created_at <= %s"))
        params.append(date_to)

    where = sql.SQL("")
    if conditions:
        where = sql.SQL("WHERE ") + sql.SQL(" AND ").join(conditions)

    conn = get_db()
    try:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        count_query = sql.SQL("SELECT COUNT(*) as cnt FROM transactions {}").format(
            where
        )
        cur.execute(count_query, params)
        total = cur.fetchone()["cnt"]

        offset = (page - 1) * per_page
        select_query = sql.SQL(
            "SELECT * FROM transactions {} ORDER BY {} {} LIMIT %s OFFSET %s"
        ).format(
            where,
            sql.Identifier(sort_by),
            sql.SQL(sort_order),
        )
        cur.execute(select_query, params + [per_page, offset])
        rows = cur.fetchall()
    finally:
        conn.close()

    for r in rows:
        for k, v in r.items():
            if isinstance(v, datetime):
                r[k] = v.isoformat()
            elif hasattr(v, "as_tuple"):
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
    }

    if mc:
        try:
            mc.set(cache_key, json.dumps(result), expire=CACHE_TTL)
            logger.info(f"Cache SET for key: {cache_key} (TTL: {CACHE_TTL}s)")
        except Exception as e:
            logger.error(f"Cache storage error: {e}")

    return result

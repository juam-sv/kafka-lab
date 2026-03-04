import os
import json
import math
from datetime import datetime

import psycopg2
import psycopg2.extras
from fastapi import FastAPI, Query
from fastapi.middleware.cors import CORSMiddleware
from pymemcache.client.base import Client as MemcacheClient

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

DB_URL = os.getenv("DATABASE_URL", "postgres://user:password@postgres:5432/finance_db")
MEMCACHED_HOST = os.getenv("MEMCACHED_HOST", "memcached")
MEMCACHED_PORT = int(os.getenv("MEMCACHED_PORT", "11211"))
CACHE_TTL = int(os.getenv("CACHE_TTL", "120"))

VALID_SORT_COLUMNS = {"amount", "created_at", "status", "txn_type", "currency"}


def get_db():
    return psycopg2.connect(DB_URL)


def get_cache():
    try:
        return MemcacheClient((MEMCACHED_HOST, MEMCACHED_PORT), connect_timeout=1, timeout=1)
    except Exception:
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

    cache_key = f"txns:{page}:{per_page}:{status}:{date_from}:{date_to}:{sort_by}:{sort_order}"

    mc = get_cache()
    if mc:
        try:
            cached = mc.get(cache_key)
            if cached:
                return json.loads(cached)
        except Exception:
            pass

    conditions = []
    params = []

    if status:
        conditions.append("status = %s")
        params.append(status)
    if date_from:
        conditions.append("created_at >= %s")
        params.append(date_from)
    if date_to:
        conditions.append("created_at <= %s")
        params.append(date_to)

    where = ""
    if conditions:
        where = "WHERE " + " AND ".join(conditions)

    conn = get_db()
    try:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        cur.execute(f"SELECT COUNT(*) as cnt FROM transactions {where}", params)
        total = cur.fetchone()["cnt"]

        offset = (page - 1) * per_page
        cur.execute(
            f"SELECT * FROM transactions {where} ORDER BY {sort_by} {sort_order} LIMIT %s OFFSET %s",
            params + [per_page, offset],
        )
        rows = cur.fetchall()
    finally:
        conn.close()

    for r in rows:
        for k, v in r.items():
            if isinstance(v, datetime):
                r[k] = v.isoformat()
            elif hasattr(v, "as_tuple"):
                r[k] = float(v)

    result = {
        "data": rows,
        "total": total,
        "page": page,
        "per_page": per_page,
        "pages": math.ceil(total / per_page) if per_page else 1,
        "cached": False,
    }

    if mc:
        try:
            mc.set(cache_key, json.dumps(result), expire=CACHE_TTL)
        except Exception:
            pass

    result["cached"] = False
    return result

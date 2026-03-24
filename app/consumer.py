import json
import logging
import os
import time

import oracledb
from confluent_kafka import Consumer
from tenacity import before_sleep_log, retry, stop_after_attempt, wait_fixed

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

KAFKA_BROKER = os.getenv("KAFKA_BROKER", "broker:9092")
KAFKA_USE_MSK = os.getenv("KAFKA_USE_MSK", "false").lower() == "true"
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
CONSUMER_GROUP = os.getenv("CONSUMER_GROUP", "finance-group")
MAX_MSG_PER_SEC = int(os.getenv("MAX_MSG_PER_SEC", "0"))
DB_USER = os.getenv("DB_USER")
DB_PASSWORD = os.getenv("DB_PASSWORD")
DB_DSN = os.getenv("DB_DSN")


class TokenBucket:
    """Per-pod token bucket rate limiter. rate=0 means unlimited."""

    def __init__(self, rate: float):
        self.rate = rate
        self.tokens = rate
        self._last_refill = time.monotonic()

    def consume(self):
        if self.rate <= 0:
            return
        self._refill()
        if self.tokens < 1:
            sleep_time = (1 - self.tokens) / self.rate
            time.sleep(sleep_time)
            self._refill()
        self.tokens -= 1

    def _refill(self):
        now = time.monotonic()
        elapsed = now - self._last_refill
        self.tokens = min(self.rate, self.tokens + elapsed * self.rate)
        self._last_refill = now


@retry(
    stop=stop_after_attempt(20),
    wait=wait_fixed(5),
    before_sleep=before_sleep_log(logger, logging.WARNING),
)
def get_db_conn():
    logger.info("Connecting to Oracle — DSN=%s user=%s", DB_DSN, DB_USER)
    start = time.perf_counter()
    conn = oracledb.connect(user=DB_USER, password=DB_PASSWORD, dsn=DB_DSN)
    elapsed_ms = (time.perf_counter() - start) * 1000
    logger.info("Oracle connected — DSN=%s elapsed=%.0fms", DB_DSN, elapsed_ms)
    return conn


conf = {
    "bootstrap.servers": KAFKA_BROKER,
    "group.id": CONSUMER_GROUP,
    "auto.offset.reset": "earliest",
}

if KAFKA_USE_MSK:
    from aws_msk_iam_sasl_signer import MSKAuthTokenProvider

    def oauth_cb(config):
        token, expiry_ms = MSKAuthTokenProvider.generate_auth_token(AWS_REGION)
        return token, expiry_ms / 1000

    conf.update({
        "security.protocol": "SASL_SSL",
        "sasl.mechanism": "OAUTHBEARER",
        "oauth_cb": oauth_cb,
    })

c = Consumer(conf)
c.subscribe(["financial.transactions"])
logger.info(
    "Kafka consumer subscribed — broker=%s msk=%s group=%s",
    KAFKA_BROKER, KAFKA_USE_MSK, CONSUMER_GROUP,
)
conn = get_db_conn()
cursor = conn.cursor()

rate_limiter = TokenBucket(rate=MAX_MSG_PER_SEC)
if MAX_MSG_PER_SEC > 0:
    logger.info("Rate limiting: %d msg/sec (per pod)", MAX_MSG_PER_SEC)
else:
    logger.info("Rate limiting: DISABLED (unlimited)")

logger.info("Finance Consumer started — polling for messages")

_msg_count = 0
_last_stats_time = time.monotonic()
_stats_interval = 30

try:
    while True:
        msg = c.poll(1.0)
        if msg is None:
            continue
        if msg.error():
            logger.warning("Kafka error: %s", msg.error())
            continue

        rate_limiter.consume()

        raw = msg.value()
        if not raw:
            logger.warning("Empty message at offset %s, skipping", msg.offset())
            continue

        try:
            data = json.loads(raw.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            logger.warning(
                "Malformed message at offset %s, skipping: %s",
                msg.offset(), e,
            )
            continue

        status = "APPROVED" if data["amount"] < 4000 else "SUSPICIOUS"

        logger.info(
            "Processed %s | Amount: %s | Status: %s",
            data["transaction_id"], data["amount"], status,
        )

        cursor.execute(
            """MERGE INTO transactions t
               USING (SELECT :1 AS transaction_id FROM dual) s
               ON (t.transaction_id = s.transaction_id)
               WHEN NOT MATCHED THEN
                 INSERT (transaction_id, source_account, target_account,
                         amount, currency, txn_type, status)
                 VALUES (:1, :2, :3, :4, :5, :6, :7)""",
            (
                data["transaction_id"],
                data["transaction_id"],
                data["source_account"],
                data["target_account"],
                data["amount"],
                data["currency"],
                data["txn_type"],
                status,
            ),
        )
        conn.commit()

        _msg_count += 1
        _now = time.monotonic()
        if _now - _last_stats_time >= _stats_interval:
            _elapsed = _now - _last_stats_time
            _actual_rate = _msg_count / _elapsed if _elapsed > 0 else 0
            logger.info(
                "Throughput: %.1f msg/sec (limit: %s) | Messages: %d in %.0fs",
                _actual_rate,
                f"{MAX_MSG_PER_SEC}/s" if MAX_MSG_PER_SEC > 0 else "unlimited",
                _msg_count,
                _elapsed,
            )
            _msg_count = 0
            _last_stats_time = _now
finally:
    c.close()
    conn.close()


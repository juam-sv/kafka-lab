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
DB_USER = os.getenv("DB_USER")
DB_PASSWORD = os.getenv("DB_PASSWORD")
DB_DSN = os.getenv("DB_DSN")


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
    "group.id": "finance-group",
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
logger.info("Kafka consumer subscribed — broker=%s msk=%s", KAFKA_BROKER, KAFKA_USE_MSK)
conn = get_db_conn()
cursor = conn.cursor()

logger.info("Finance Consumer started — polling for messages")

try:
    while True:
        msg = c.poll(1.0)
        if msg is None:
            continue
        if msg.error():
            logger.warning("Kafka error: %s", msg.error())
            continue

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
            "INSERT INTO transactions (transaction_id, source_account, target_account, "
            "amount, currency, txn_type, status) VALUES "
            "(:1, :2, :3, :4, :5, :6, :7)",
            (
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
finally:
    c.close()
    conn.close()


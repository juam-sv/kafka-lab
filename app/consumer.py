import json
import logging
import os

import oracledb
from confluent_kafka import Consumer
from tenacity import before_sleep_log, retry, stop_after_attempt, wait_fixed

logging.basicConfig(level=logging.INFO)
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
    logger.info(f"Connecting to Oracle DSN: {DB_DSN} as {DB_USER}")
    return oracledb.connect(user=DB_USER, password=DB_PASSWORD, dsn=DB_DSN)


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
conn = get_db_conn()
cursor = conn.cursor()

print("Finance Consumer started...")

try:
    while True:
        msg = c.poll(1.0)
        if msg is None:
            continue

        data = json.loads(msg.value().decode("utf-8"))
        status = "APPROVED" if data["amount"] < 4000 else "SUSPICIOUS"

        print(
            f"Processed {data['transaction_id']} | "
            f"Amount: {data['amount']} | Status: {status}"
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

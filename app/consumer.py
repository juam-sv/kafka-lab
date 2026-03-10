import json
import os

import oracledb
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
from confluent_kafka import Consumer
from tenacity import retry, stop_after_attempt, wait_fixed

KAFKA_BROKER = os.getenv("KAFKA_BROKER", "broker:9092")
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
DB_USER = os.getenv("DB_USER")
DB_PASSWORD = os.getenv("DB_PASSWORD")
DB_DSN = os.getenv("DB_DSN")


def oauth_cb(config):
    token, expiry_ms = MSKAuthTokenProvider.generate_auth_token(AWS_REGION)
    return token, expiry_ms / 1000


@retry(stop=stop_after_attempt(10), wait=wait_fixed(3))
def get_db_conn():
    return oracledb.connect(user=DB_USER, password=DB_PASSWORD, dsn=DB_DSN)


conf = {
    "bootstrap.servers": KAFKA_BROKER,
    "group.id": "finance-group",
    "auto.offset.reset": "earliest",
    "security.protocol": "SASL_SSL",
    "sasl.mechanism": "OAUTHBEARER",
    "oauth_cb": oauth_cb,
}

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

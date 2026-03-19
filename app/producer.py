import json
import os
import random
import time
import uuid
from datetime import UTC, datetime

from confluent_kafka import Producer

KAFKA_BROKER = os.getenv("KAFKA_BROKER", "broker:9092")
KAFKA_USE_MSK = os.getenv("KAFKA_USE_MSK", "false").lower() == "true"
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
MSG_PER_SEC = int(os.getenv("MSG_PER_SEC", "5"))

kafka_conf = {"bootstrap.servers": KAFKA_BROKER}

if KAFKA_USE_MSK:
    from aws_msk_iam_sasl_signer import MSKAuthTokenProvider

    def oauth_cb(config):
        token, expiry_ms = MSKAuthTokenProvider.generate_auth_token(AWS_REGION)
        return token, expiry_ms / 1000

    kafka_conf.update({
        "security.protocol": "SASL_SSL",
        "sasl.mechanism": "OAUTHBEARER",
        "oauth_cb": oauth_cb,
    })

p = Producer(kafka_conf)
crypto_random = random.SystemRandom()


def delivery_report(err, msg):
    if err is not None:
        print(f"Delivery failed: {err}")
    else:
        print(f"Sent Txn: {msg.value().decode('utf-8')}")


txn_types = ["TRANSFER", "PAYMENT", "WITHDRAWAL", "DEPOSIT"]
currencies = ["USD", "BRL", "EUR"]

while True:
    data = {
        "transaction_id": str(uuid.uuid4()),
        "source_account": f"ACC-{crypto_random.randint(1000, 9999)}",
        "target_account": f"ACC-{crypto_random.randint(1000, 9999)}",
        "amount": round(crypto_random.uniform(10.0, 5000.0), 2),
        "currency": crypto_random.choice(currencies),
        "txn_type": crypto_random.choice(txn_types),
        "timestamp": datetime.now(UTC).isoformat(),
    }
    p.produce(
        "financial.transactions",
        json.dumps(data).encode("utf-8"),
        callback=delivery_report,
    )
    p.poll(0)
    time.sleep(1 / MSG_PER_SEC)

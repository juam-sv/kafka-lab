import json
import os
import pathlib
import random
import time
import uuid
from datetime import UTC, datetime

from confluent_kafka import Producer
from opentelemetry.instrumentation.confluent_kafka import ConfluentKafkaInstrumentor

from otel_setup import init_tracer

tracer = init_tracer("producer")

KAFKA_BROKER = os.getenv("KAFKA_BROKER", "broker:9092")
KAFKA_USE_MSK = os.getenv("KAFKA_USE_MSK", "false").lower() == "true"
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
MSG_PER_SEC = int(os.getenv("MSG_PER_SEC", "5"))
USE_MESSAGE_KEY = os.getenv("USE_MESSAGE_KEY", "false").lower() == "true"

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

p = ConfluentKafkaInstrumentor().instrument_producer(Producer(kafka_conf))
crypto_random = random.SystemRandom()


def delivery_report(err, msg):
    if err is not None:
        print(f"Delivery failed: {err}")
    else:
        print(f"Sent Txn: {msg.value().decode('utf-8')}")


HEALTH_FILE = pathlib.Path("/tmp/healthy")  # noqa: S108  # nosec B108
txn_types = ["TRANSFER", "PAYMENT", "WITHDRAWAL", "DEPOSIT"]
currencies = ["USD", "BRL", "EUR"]

while True:
    HEALTH_FILE.touch()
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
        key=data["source_account"].encode("utf-8") if USE_MESSAGE_KEY else None,
        callback=delivery_report,
    )
    p.poll(0)
    time.sleep(1 / MSG_PER_SEC)


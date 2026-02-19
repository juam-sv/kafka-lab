import json
import time
import os
import random
import uuid
from datetime import datetime
from confluent_kafka import Producer

KAFKA_BROKER = os.getenv('KAFKA_BROKER', 'broker:9092')
MSG_PER_SEC = int(os.getenv('MSG_PER_SEC', '5'))

p = Producer({'bootstrap.servers': KAFKA_BROKER})

def delivery_report(err, msg):
    if err is not None:
        print(f"Delivery failed: {err}")
    else:
        print(f"Sent Txn: {msg.value().decode('utf-8')}")

txn_types = ['TRANSFER', 'PAYMENT', 'WITHDRAWAL', 'DEPOSIT']
currencies = ['USD', 'BRL', 'EUR']

while True:
    data = {
        "transaction_id": str(uuid.uuid4()),
        "source_account": f"ACC-{random.randint(1000, 9999)}",
        "target_account": f"ACC-{random.randint(1000, 9999)}",
        "amount": round(random.uniform(10.0, 5000.0), 2),
        "currency": random.choice(currencies),
        "txn_type": random.choice(txn_types),
        "timestamp": datetime.utcnow().isoformat()
    }
    p.produce('financial.transactions', json.dumps(data).encode('utf-8'), callback=delivery_report)
    p.poll(0)
    time.sleep(1 / MSG_PER_SEC)

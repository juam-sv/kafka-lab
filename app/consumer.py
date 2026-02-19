import os
import json
import psycopg2
from confluent_kafka import Consumer
from tenacity import retry, stop_after_attempt, wait_fixed

KAFKA_BROKER = os.getenv('KAFKA_BROKER', 'broker:9092')
DB_URL = os.getenv('DATABASE_URL')

@retry(stop=stop_after_attempt(10), wait=wait_fixed(3))
def get_db_conn():
    return psycopg2.connect(DB_URL)

conf = {
    'bootstrap.servers': KAFKA_BROKER,
    'group.id': 'finance-group',
    'auto.offset.reset': 'earliest'
}

c = Consumer(conf)
c.subscribe(['financial.transactions'])
conn = get_db_conn()
cursor = conn.cursor()

print("Finance Consumer started...")

try:
    while True:
        msg = c.poll(1.0)
        if msg is None: continue
        
        data = json.loads(msg.value().decode('utf-8'))
        status = 'APPROVED' if data['amount'] < 4000 else 'SUSPICIOUS'

        print(f"Processed {data['transaction_id']} | Amount: {data['amount']} | Status: {status}")
        
        cursor.execute(
            "INSERT INTO transactions (transaction_id, source_account, target_account, amount, currency, txn_type, status) VALUES (%s, %s, %s, %s, %s, %s, %s)",
            (data['transaction_id'], data['source_account'], data['target_account'], data['amount'], data['currency'], data['txn_type'], status)
        )
        conn.commit()
finally:
    c.close()
    conn.close()

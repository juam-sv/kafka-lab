CREATE TABLE transactions (
    id             NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id VARCHAR2(100) NOT NULL,
    source_account VARCHAR2(100) NOT NULL,
    target_account VARCHAR2(100) NOT NULL,
    amount         NUMBER(12,2)  NOT NULL,
    currency       VARCHAR2(10)  NOT NULL,
    txn_type       VARCHAR2(50)  NOT NULL,
    status         VARCHAR2(20)  NOT NULL,
    created_at     TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP
);

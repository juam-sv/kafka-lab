ALTER SESSION SET CONTAINER = XEPDB1;

CREATE TABLE finance_user.transactions (
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

CREATE INDEX idx_txn_created_at ON finance_user.transactions (created_at DESC);
CREATE INDEX idx_txn_status_date ON finance_user.transactions (status, created_at DESC);
CREATE INDEX idx_txn_amount ON finance_user.transactions (amount);
CREATE UNIQUE INDEX idx_txn_transaction_id ON finance_user.transactions (transaction_id);

export interface Transaction {
  id: number;
  transaction_id: string;
  source_account: string;
  target_account: string;
  amount: number;
  currency: string;
  txn_type: string;
  status: string;
  created_at: string;
}

export interface TransactionsResponse {
  data: Transaction[];
  total: number;
  page: number;
  per_page: number;
  pages: number;
  cached: boolean;
  cached_at?: string;
  source: string;
  response_time_ms: number;
}

export interface TransactionDetail extends Transaction {
  cached: boolean;
  source: string;
}

export interface TransactionCreatePayload {
  source_account: string;
  target_account: string;
  amount: number;
  currency: string;
  txn_type: string;
}

export interface TransactionCreateResponse {
  transaction_id: string;
  status: string;
}

export type SortColumn = "amount" | "created_at" | "status" | "txn_type" | "currency";
export type SortOrder = "asc" | "desc";

export interface TransactionFilters {
  page: number;
  perPage: number;
  status: string;
  dateFrom: string;
  dateTo: string;
  sortBy: SortColumn;
  sortOrder: SortOrder;
}

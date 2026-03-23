import type {
  SearchField,
  TransactionCreatePayload,
  TransactionCreateResponse,
  TransactionDetail,
  TransactionFilters,
  TransactionSearchResponse,
  TransactionsResponse,
} from "../types";
import { apiFetch } from "./client";

export function getTransactions(
  filters: TransactionFilters,
  signal?: AbortSignal,
): Promise<TransactionsResponse> {
  const params = new URLSearchParams({
    page: String(filters.page),
    per_page: String(filters.perPage),
    sort_by: filters.sortBy,
    sort_order: filters.sortOrder,
  });
  if (filters.status) params.set("status", filters.status);
  if (filters.dateFrom)
    params.set("date_from", new Date(filters.dateFrom).toISOString());
  if (filters.dateTo)
    params.set("date_to", new Date(filters.dateTo).toISOString());

  return apiFetch<TransactionsResponse>(`/transactions?${params}`, { signal });
}

export function getTransactionById(
  transactionId: string,
  signal?: AbortSignal,
): Promise<TransactionDetail> {
  return apiFetch<TransactionDetail>(`/transactions/${transactionId}`, {
    signal,
  });
}

export function searchTransactions(
  field: SearchField,
  value: string,
  signal?: AbortSignal,
): Promise<TransactionSearchResponse> {
  const params = new URLSearchParams({ field, value });
  return apiFetch<TransactionSearchResponse>(`/transactions/search?${params}`, {
    signal,
  });
}

export function postTransaction(
  payload: TransactionCreatePayload,
): Promise<TransactionCreateResponse> {
  return apiFetch<TransactionCreateResponse>("/transactions", {
    method: "POST",
    body: JSON.stringify(payload),
  });
}

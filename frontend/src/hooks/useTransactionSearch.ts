import { useCallback, useRef, useState } from "react";
import { searchTransactions } from "../api/transactions";
import { ApiError } from "../api/client";
import type { SearchField, Transaction } from "../types";

export function useTransactionSearch() {
  const [query, setQuery] = useState("");
  const [field, setField] = useState<SearchField>("transaction_id");
  const [results, setResults] = useState<Transaction[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const search = useCallback(
    async (value: string, searchField?: SearchField) => {
      const trimmed = value.trim();
      if (!trimmed) return;

      abortRef.current?.abort();
      const controller = new AbortController();
      abortRef.current = controller;

      setLoading(true);
      setError(null);
      setResults([]);

      try {
        const data = await searchTransactions(
          searchField ?? field,
          trimmed,
          controller.signal,
        );
        if (data.data.length === 0) {
          setError("No transactions found.");
        } else {
          setResults(data.data);
        }
      } catch (e: unknown) {
        if (e instanceof Error && e.name === "AbortError") return;
        if (e instanceof ApiError && e.status === 404) {
          setError("Transaction not found — it may still be processing.");
        } else {
          setError(e instanceof Error ? e.message : "Search failed");
        }
      } finally {
        setLoading(false);
      }
    },
    [field],
  );

  return { query, setQuery, field, setField, results, loading, error, search };
}

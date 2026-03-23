import { useCallback, useRef, useState } from "react";
import { getTransactionById } from "../api/transactions";
import { ApiError } from "../api/client";
import type { TransactionDetail } from "../types";

export function useTransactionSearch() {
  const [query, setQuery] = useState("");
  const [result, setResult] = useState<TransactionDetail | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const search = useCallback(async (transactionId: string) => {
    const trimmed = transactionId.trim();
    if (!trimmed) return;

    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;

    setLoading(true);
    setError(null);
    setResult(null);

    try {
      const data = await getTransactionById(trimmed, controller.signal);
      setResult(data);
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
  }, []);

  return { query, setQuery, result, loading, error, search };
}

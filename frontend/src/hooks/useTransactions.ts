import { useCallback, useEffect, useRef, useState } from "react";
import { getTransactions } from "../api/transactions";
import type { TransactionFilters, TransactionsResponse } from "../types";

function defaultDateFrom(): string {
  const d = new Date();
  d.setDate(d.getDate() - 1);
  return d.toISOString().slice(0, 16);
}

const DEFAULT_FILTERS: TransactionFilters = {
  page: 1,
  perPage: 20,
  status: "",
  dateFrom: defaultDateFrom(),
  dateTo: "",
  sortBy: "created_at",
  sortOrder: "desc",
};

export function useTransactions(active: boolean) {
  const [filters, setFilters] = useState<TransactionFilters>(DEFAULT_FILTERS);
  const [data, setData] = useState<TransactionsResponse | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [autoRefresh, setAutoRefresh] = useState(true);
  const abortRef = useRef<AbortController | null>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const fetchData = useCallback(
    async (f: TransactionFilters) => {
      abortRef.current?.abort();
      const controller = new AbortController();
      abortRef.current = controller;

      setLoading(true);
      setError(null);
      try {
        const result = await getTransactions(f, controller.signal);
        setData(result);
      } catch (e: unknown) {
        if (e instanceof Error && e.name === "AbortError") return;
        setError(e instanceof Error ? e.message : "Failed to load");
      } finally {
        setLoading(false);
      }
    },
    [],
  );

  // Fetch on filter change (debounced)
  useEffect(() => {
    if (!active) return;
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => fetchData(filters), 300);
    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
  }, [filters, active, fetchData]);

  // Auto-refresh
  useEffect(() => {
    if (!active || !autoRefresh) return;
    const interval = setInterval(() => fetchData(filters), 15_000);
    return () => clearInterval(interval);
  }, [active, autoRefresh, filters, fetchData]);

  // Abort on unmount
  useEffect(() => {
    return () => abortRef.current?.abort();
  }, []);

  const updateFilters = useCallback(
    (patch: Partial<TransactionFilters>) => {
      setFilters((prev) => ({ ...prev, ...patch }));
    },
    [],
  );

  const setPage = useCallback((page: number) => {
    setFilters((prev) => ({ ...prev, page }));
  }, []);

  const toggleSort = useCallback((column: TransactionFilters["sortBy"]) => {
    setFilters((prev) => ({
      ...prev,
      sortBy: column,
      sortOrder:
        prev.sortBy === column
          ? prev.sortOrder === "asc"
            ? "desc"
            : "asc"
          : "asc",
      page: 1,
    }));
  }, []);

  return {
    filters,
    data,
    loading,
    error,
    autoRefresh,
    setAutoRefresh,
    updateFilters,
    setPage,
    toggleSort,
  };
}

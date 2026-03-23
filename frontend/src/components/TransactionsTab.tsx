import { useTransactions } from "../hooks/useTransactions";
import CacheBadge from "./CacheBadge";
import Pagination from "./Pagination";
import Toolbar from "./Toolbar";
import TransactionTable from "./TransactionTable";

interface Props {
  active: boolean;
}

export default function TransactionsTab({ active }: Props) {
  const {
    filters,
    data,
    loading,
    error,
    autoRefresh,
    setAutoRefresh,
    updateFilters,
    setPage,
    toggleSort,
  } = useTransactions(active);

  return (
    <div>
      <Toolbar
        filters={filters}
        autoRefresh={autoRefresh}
        onUpdate={updateFilters}
        onAutoRefreshChange={setAutoRefresh}
      />

      <div className="mb-2.5 flex items-center justify-between text-xs text-text-secondary">
        <span>
          {loading && (
            <span className="mr-1.5 inline-block h-3.5 w-3.5 animate-spin rounded-full border-2 border-border-secondary border-t-accent-blue align-middle" />
          )}
          {data
            ? `${data.total} transactions — page ${data.page} of ${data.pages || 1}`
            : error ?? "Loading..."}
        </span>
        {data && <CacheBadge cached={data.cached} cachedAt={data.cached_at} />}
      </div>

      {data && (
        <>
          <TransactionTable
            rows={data.data}
            cached={data.cached}
            sortBy={filters.sortBy}
            sortOrder={filters.sortOrder}
            onSort={toggleSort}
            loading={loading}
          />
          <Pagination
            current={data.page}
            total={data.pages}
            onPage={setPage}
          />
        </>
      )}

      {error && !data && (
        <div className="rounded-lg bg-bg-secondary px-4 py-10 text-center text-text-secondary">
          {error}
        </div>
      )}
    </div>
  );
}

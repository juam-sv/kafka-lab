import type { TransactionFilters } from "../types";

interface Props {
  filters: TransactionFilters;
  autoRefresh: boolean;
  onUpdate: (patch: Partial<TransactionFilters>) => void;
  onAutoRefreshChange: (on: boolean) => void;
}

export default function Toolbar({
  filters,
  autoRefresh,
  onUpdate,
  onAutoRefreshChange,
}: Props) {
  return (
    <div className="mb-5 flex flex-wrap items-center gap-3">
      <div>
        <label className="mr-1 text-xs text-text-secondary">Status</label>
        <select
          value={filters.status}
          onChange={(e) => onUpdate({ status: e.target.value, page: 1 })}
          className="rounded-md border border-border-secondary bg-bg-secondary px-2.5 py-1.5 text-sm text-text-primary focus:border-accent-blue focus:outline-none"
        >
          <option value="">All</option>
          <option value="APPROVED">Approved</option>
          <option value="SUSPICIOUS">Suspicious</option>
        </select>
      </div>
      <div>
        <label className="mr-1 text-xs text-text-secondary">From</label>
        <input
          type="datetime-local"
          value={filters.dateFrom}
          onChange={(e) => onUpdate({ dateFrom: e.target.value, page: 1 })}
          className="rounded-md border border-border-secondary bg-bg-secondary px-2.5 py-1.5 text-sm text-text-primary focus:border-accent-blue focus:outline-none"
        />
      </div>
      <div>
        <label className="mr-1 text-xs text-text-secondary">To</label>
        <input
          type="datetime-local"
          value={filters.dateTo}
          onChange={(e) => onUpdate({ dateTo: e.target.value, page: 1 })}
          className="rounded-md border border-border-secondary bg-bg-secondary px-2.5 py-1.5 text-sm text-text-primary focus:border-accent-blue focus:outline-none"
        />
      </div>
      <div>
        <label className="mr-1 text-xs text-text-secondary">Per page</label>
        <select
          value={filters.perPage}
          onChange={(e) =>
            onUpdate({ perPage: Number(e.target.value), page: 1 })
          }
          className="rounded-md border border-border-secondary bg-bg-secondary px-2.5 py-1.5 text-sm text-text-primary focus:border-accent-blue focus:outline-none"
        >
          <option value={20}>20</option>
          <option value={50}>50</option>
          <option value={100}>100</option>
        </select>
      </div>
      <div className="ml-auto flex items-center gap-1.5">
        <label className="text-xs text-text-secondary">Auto-refresh</label>
        <label className="relative inline-block h-[22px] w-10 cursor-pointer">
          <input
            type="checkbox"
            checked={autoRefresh}
            onChange={(e) => onAutoRefreshChange(e.target.checked)}
            className="peer h-0 w-0 opacity-0"
          />
          <span className="absolute inset-0 rounded-full bg-border-secondary transition-colors peer-checked:bg-accent-green" />
          <span className="absolute left-[3px] top-[3px] h-4 w-4 rounded-full bg-text-secondary transition-transform peer-checked:translate-x-[18px] peer-checked:bg-white" />
        </label>
      </div>
    </div>
  );
}

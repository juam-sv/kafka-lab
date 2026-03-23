import { useTransactionSearch } from "../hooks/useTransactionSearch";
import type { SearchField, Transaction } from "../types";
import StatusBadge from "./StatusBadge";

interface Props {
  initialQuery?: string;
}

const FIELD_OPTIONS: { value: SearchField; label: string; placeholder: string }[] = [
  { value: "transaction_id", label: "Transaction ID", placeholder: "Enter transaction UUID..." },
  { value: "source_account", label: "Source Account", placeholder: "Enter source account..." },
  { value: "target_account", label: "Target Account", placeholder: "Enter target account..." },
];

function TransactionCard({ txn }: { txn: Transaction }) {
  return (
    <div className="rounded-lg bg-bg-secondary p-5">
      <div className="mb-3 flex items-center justify-between">
        <h3 className="text-sm font-semibold text-text-primary">
          Transaction Detail
        </h3>
        <StatusBadge status={txn.status} />
      </div>

      <dl className="space-y-2 text-sm">
        {[
          ["Transaction ID", txn.transaction_id],
          ["Source", txn.source_account],
          ["Target", txn.target_account],
          [
            "Amount",
            `${txn.amount.toLocaleString("en", { minimumFractionDigits: 2 })} ${txn.currency}`,
          ],
          ["Type", txn.txn_type],
          ["Date", new Date(txn.created_at).toLocaleString()],
        ].map(([label, value]) => (
          <div key={label} className="flex justify-between">
            <dt className="text-text-secondary">{label}</dt>
            <dd
              className={`text-text-primary ${
                label === "Amount" && txn.amount >= 4000
                  ? "text-accent-orange"
                  : ""
              }`}
            >
              {value}
            </dd>
          </div>
        ))}
      </dl>
    </div>
  );
}

export default function SearchTab({ initialQuery }: Props) {
  const { query, setQuery, field, setField, results, loading, error, search } =
    useTransactionSearch();

  // Set initial query from parent (e.g. from InsertTab)
  const hasSetInitial = initialQuery && query === "" && results.length === 0 && !loading;
  if (hasSetInitial) {
    setTimeout(() => {
      setQuery(initialQuery);
      search(initialQuery, "transaction_id");
    }, 0);
  }

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    search(query);
  };

  const currentOption = FIELD_OPTIONS.find((o) => o.value === field)!;

  return (
    <div className="mx-auto max-w-lg">
      <h2 className="mb-4 text-lg font-semibold">Search Transactions</h2>

      <form onSubmit={handleSubmit} className="flex flex-col gap-3">
        <div className="flex gap-3">
          <select
            value={field}
            onChange={(e) => setField(e.target.value as SearchField)}
            className="rounded-md border border-border-secondary bg-bg-secondary px-3 py-2 text-sm text-text-primary focus:border-accent-blue focus:outline-none"
          >
            {FIELD_OPTIONS.map((opt) => (
              <option key={opt.value} value={opt.value}>
                {opt.label}
              </option>
            ))}
          </select>
          <input
            type="text"
            placeholder={currentOption.placeholder}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            className="flex-1 rounded-md border border-border-secondary bg-bg-secondary px-3 py-2 text-sm text-text-primary placeholder:text-text-secondary focus:border-accent-blue focus:outline-none"
          />
          <button
            type="submit"
            disabled={loading || !query.trim()}
            className="rounded-md bg-accent-blue px-4 py-2 text-sm font-medium text-white hover:brightness-110 disabled:opacity-50"
          >
            {loading ? "Searching..." : "Search"}
          </button>
        </div>
      </form>

      {error && (
        <div className="mt-4 rounded-lg border border-badge-orange-bg bg-badge-orange-bg/30 px-4 py-3 text-sm text-accent-orange">
          {error}
        </div>
      )}

      {results.length > 0 && (
        <div className="mt-4 space-y-3">
          {results.length > 1 && (
            <p className="text-sm text-text-secondary">
              {results.length} transactions found
            </p>
          )}
          {results.map((txn) => (
            <TransactionCard key={txn.id} txn={txn} />
          ))}
        </div>
      )}
    </div>
  );
}

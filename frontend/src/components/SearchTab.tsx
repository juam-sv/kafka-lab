import { useTransactionSearch } from "../hooks/useTransactionSearch";
import StatusBadge from "./StatusBadge";

interface Props {
  initialQuery?: string;
}

export default function SearchTab({ initialQuery }: Props) {
  const { query, setQuery, result, loading, error, search } =
    useTransactionSearch();

  // Set initial query from parent (e.g. from InsertTab)
  const hasSetInitial = initialQuery && query === "" && !result && !loading;
  if (hasSetInitial) {
    // Trigger search on next render
    setTimeout(() => {
      setQuery(initialQuery);
      search(initialQuery);
    }, 0);
  }

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    search(query);
  };

  return (
    <div className="mx-auto max-w-lg">
      <h2 className="mb-4 text-lg font-semibold">Search by Transaction ID</h2>

      <form onSubmit={handleSubmit} className="flex gap-3">
        <input
          type="text"
          placeholder="Enter transaction UUID..."
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
      </form>

      {error && (
        <div className="mt-4 rounded-lg border border-badge-orange-bg bg-badge-orange-bg/30 px-4 py-3 text-sm text-accent-orange">
          {error}
        </div>
      )}

      {result && (
        <div className="mt-4 rounded-lg bg-bg-secondary p-5">
          <div className="mb-3 flex items-center justify-between">
            <h3 className="text-sm font-semibold text-text-primary">
              Transaction Detail
            </h3>
            <StatusBadge status={result.status} />
          </div>

          <dl className="space-y-2 text-sm">
            {[
              ["Transaction ID", result.transaction_id],
              ["Source", result.source_account],
              ["Target", result.target_account],
              [
                "Amount",
                `${result.amount.toLocaleString("en", { minimumFractionDigits: 2 })} ${result.currency}`,
              ],
              ["Type", result.txn_type],
              ["Date", new Date(result.created_at).toLocaleString()],
              ["Source", result.source === "cache" ? "Cache" : "Database"],
            ].map(([label, value]) => (
              <div key={label} className="flex justify-between">
                <dt className="text-text-secondary">{label}</dt>
                <dd
                  className={`text-text-primary ${
                    label === "Amount" && result.amount >= 4000
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
      )}
    </div>
  );
}

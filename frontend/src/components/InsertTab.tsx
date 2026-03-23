import { useInsertTransaction } from "../hooks/useInsertTransaction";

interface Props {
  onSearchTransaction: (id: string) => void;
}

export default function InsertTab({ onSearchTransaction }: Props) {
  const { form, submitting, result, error, updateField, submit, reset } =
    useInsertTransaction();

  return (
    <div className="mx-auto max-w-lg">
      <h2 className="mb-4 text-lg font-semibold">Insert Transaction</h2>

      <div className="space-y-4 rounded-lg bg-bg-secondary p-6">
        <div>
          <label className="mb-1 block text-xs text-text-secondary">
            Source Account
          </label>
          <input
            type="text"
            placeholder="ACC-1234"
            value={form.source_account}
            onChange={(e) => updateField("source_account", e.target.value)}
            className="w-full rounded-md border border-border-secondary bg-bg-primary px-3 py-2 text-sm text-text-primary focus:border-accent-blue focus:outline-none"
          />
        </div>

        <div>
          <label className="mb-1 block text-xs text-text-secondary">
            Target Account
          </label>
          <input
            type="text"
            placeholder="ACC-5678"
            value={form.target_account}
            onChange={(e) => updateField("target_account", e.target.value)}
            className="w-full rounded-md border border-border-secondary bg-bg-primary px-3 py-2 text-sm text-text-primary focus:border-accent-blue focus:outline-none"
          />
        </div>

        <div>
          <label className="mb-1 block text-xs text-text-secondary">
            Amount
          </label>
          <input
            type="number"
            min="0.01"
            step="0.01"
            value={form.amount || ""}
            onChange={(e) => updateField("amount", Number(e.target.value))}
            className="w-full rounded-md border border-border-secondary bg-bg-primary px-3 py-2 text-sm text-text-primary focus:border-accent-blue focus:outline-none"
          />
        </div>

        <div className="flex gap-4">
          <div className="flex-1">
            <label className="mb-1 block text-xs text-text-secondary">
              Currency
            </label>
            <select
              value={form.currency}
              onChange={(e) => updateField("currency", e.target.value)}
              className="w-full rounded-md border border-border-secondary bg-bg-primary px-3 py-2 text-sm text-text-primary focus:border-accent-blue focus:outline-none"
            >
              <option value="USD">USD</option>
              <option value="BRL">BRL</option>
              <option value="EUR">EUR</option>
            </select>
          </div>

          <div className="flex-1">
            <label className="mb-1 block text-xs text-text-secondary">
              Type
            </label>
            <select
              value={form.txn_type}
              onChange={(e) => updateField("txn_type", e.target.value)}
              className="w-full rounded-md border border-border-secondary bg-bg-primary px-3 py-2 text-sm text-text-primary focus:border-accent-blue focus:outline-none"
            >
              <option value="TRANSFER">Transfer</option>
              <option value="PAYMENT">Payment</option>
              <option value="WITHDRAWAL">Withdrawal</option>
              <option value="DEPOSIT">Deposit</option>
            </select>
          </div>
        </div>

        <div className="flex gap-3 pt-2">
          <button
            onClick={submit}
            disabled={submitting}
            className="rounded-md bg-accent-green px-4 py-2 text-sm font-medium text-white hover:brightness-110 disabled:opacity-50"
          >
            {submitting ? "Submitting..." : "Submit Transaction"}
          </button>
          <button
            onClick={reset}
            className="rounded-md border border-border-secondary px-4 py-2 text-sm text-text-secondary hover:text-text-primary"
          >
            Reset
          </button>
        </div>
      </div>

      {error && (
        <div className="mt-4 rounded-lg border border-badge-orange-bg bg-badge-orange-bg/30 px-4 py-3 text-sm text-accent-orange">
          {error}
        </div>
      )}

      {result && (
        <div className="mt-4 rounded-lg border border-badge-green-bg bg-badge-green-bg/30 px-4 py-3 text-sm">
          <p className="text-accent-green-text">Transaction submitted!</p>
          <p className="mt-1 text-text-secondary">
            ID:{" "}
            <code className="text-text-primary">{result.transaction_id}</code>
          </p>
          <button
            onClick={() => onSearchTransaction(result.transaction_id)}
            className="mt-2 text-sm text-accent-blue hover:underline"
          >
            Search for this transaction &rarr;
          </button>
        </div>
      )}
    </div>
  );
}

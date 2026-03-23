import { useState } from "react";
import type { SortColumn, SortOrder, Transaction } from "../types";
import StatusBadge from "./StatusBadge";

interface Props {
  rows: Transaction[];
  cached: boolean;
  sortBy: SortColumn;
  sortOrder: SortOrder;
  onSort: (column: SortColumn) => void;
  loading: boolean;
}

const COLUMNS: { key: string; label: string; sortable: boolean }[] = [
  { key: "id", label: "ID", sortable: false },
  { key: "transaction_id", label: "Txn ID", sortable: false },
  { key: "source_account", label: "Source", sortable: false },
  { key: "target_account", label: "Target", sortable: false },
  { key: "amount", label: "Amount", sortable: true },
  { key: "currency", label: "Currency", sortable: true },
  { key: "txn_type", label: "Type", sortable: true },
  { key: "status", label: "Status", sortable: true },
  { key: "created_at", label: "Date", sortable: true },
];

export default function TransactionTable({
  rows,
  cached,
  sortBy,
  sortOrder,
  onSort,
  loading,
}: Props) {
  const [expandedIds, setExpandedIds] = useState<Set<number>>(new Set());

  const toggleExpand = (id: number) => {
    setExpandedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  return (
    <div
      className={`overflow-hidden rounded-lg transition-opacity ${loading ? "pointer-events-none opacity-50" : ""}`}
    >
      <table className="w-full border-collapse bg-bg-secondary">
        <thead>
          <tr>
            {COLUMNS.map((col) => (
              <th
                key={col.key}
                onClick={
                  col.sortable
                    ? () => onSort(col.key as SortColumn)
                    : undefined
                }
                className={`border-b border-border-primary bg-bg-tertiary px-3.5 py-2.5 text-left text-[0.72rem] font-semibold uppercase tracking-wide text-text-secondary ${
                  col.sortable
                    ? "cursor-pointer select-none whitespace-nowrap hover:text-accent-blue"
                    : ""
                }`}
              >
                {col.label}
                {col.sortable && sortBy === col.key && (
                  <span className="ml-1 text-[0.65rem]">
                    {sortOrder === "asc" ? "▲" : "▼"}
                  </span>
                )}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.length === 0 ? (
            <tr>
              <td
                colSpan={9}
                className="px-4 py-10 text-center text-text-secondary"
              >
                No transactions found
              </td>
            </tr>
          ) : (
            rows.map((r) => (
              <tr
                key={r.id}
                className={`hover:bg-bg-tertiary ${cached ? "border-l-2 border-l-accent-green" : ""}`}
              >
                <td className="border-b border-border-primary px-3.5 py-2.5 text-[0.83rem]">
                  {r.id}
                </td>
                <td
                  className="border-b border-border-primary px-3.5 py-2.5 text-[0.83rem] cursor-pointer select-none"
                  title={expandedIds.has(r.id) ? undefined : r.transaction_id}
                  onClick={() => toggleExpand(r.id)}
                >
                  {expandedIds.has(r.id) ? (
                    <span className="font-mono text-[0.78rem]">{r.transaction_id}</span>
                  ) : (
                    <>{r.transaction_id.slice(0, 8)}&hellip;</>
                  )}
                </td>
                <td className="border-b border-border-primary px-3.5 py-2.5 text-[0.83rem]">
                  {r.source_account}
                </td>
                <td className="border-b border-border-primary px-3.5 py-2.5 text-[0.83rem]">
                  {r.target_account}
                </td>
                <td
                  className={`border-b border-border-primary px-3.5 py-2.5 text-[0.83rem] tabular-nums ${
                    r.amount >= 4000 ? "text-accent-orange" : ""
                  }`}
                >
                  {r.amount.toLocaleString("en", {
                    minimumFractionDigits: 2,
                  })}{" "}
                  {r.currency}
                </td>
                <td className="border-b border-border-primary px-3.5 py-2.5 text-[0.83rem]">
                  {r.currency}
                </td>
                <td className="border-b border-border-primary px-3.5 py-2.5 text-[0.83rem]">
                  {r.txn_type}
                </td>
                <td className="border-b border-border-primary px-3.5 py-2.5 text-[0.83rem]">
                  <StatusBadge status={r.status} />
                </td>
                <td className="border-b border-border-primary px-3.5 py-2.5 text-[0.83rem]">
                  {new Date(r.created_at).toLocaleString()}
                </td>
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  );
}

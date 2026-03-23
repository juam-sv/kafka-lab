interface Props {
  status: string;
}

export default function StatusBadge({ status }: Props) {
  const isApproved = status === "APPROVED";
  return (
    <span
      className={`inline-block rounded-xl px-2.5 py-0.5 text-xs font-semibold ${
        isApproved
          ? "bg-badge-green-bg text-accent-green-text"
          : "bg-badge-orange-bg text-accent-orange"
      }`}
    >
      {status}
    </span>
  );
}

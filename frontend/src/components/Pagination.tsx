interface Props {
  current: number;
  total: number;
  onPage: (page: number) => void;
}

export default function Pagination({ current, total, onPage }: Props) {
  if (total <= 1) return null;

  const pages: (number | "...")[] = [];
  if (total <= 7) {
    for (let i = 1; i <= total; i++) pages.push(i);
  } else {
    pages.push(1);
    if (current > 3) pages.push("...");
    for (
      let i = Math.max(2, current - 1);
      i <= Math.min(total - 1, current + 1);
      i++
    )
      pages.push(i);
    if (current < total - 2) pages.push("...");
    pages.push(total);
  }

  const btn =
    "bg-bg-tertiary border border-border-secondary text-text-primary px-3 py-1.5 rounded-md text-sm cursor-pointer hover:border-accent-blue hover:text-accent-blue disabled:opacity-40 disabled:cursor-default";

  return (
    <div className="mt-4 flex items-center justify-center gap-1.5">
      <button
        className={btn}
        disabled={current === 1}
        onClick={() => onPage(current - 1)}
      >
        &larr; Prev
      </button>
      {pages.map((p, i) =>
        p === "..." ? (
          <span key={`e${i}`} className="text-sm text-text-secondary">
            &hellip;
          </span>
        ) : (
          <button
            key={p}
            className={`${btn} ${p === current ? "!bg-accent-green !border-accent-green" : ""}`}
            onClick={() => onPage(p)}
          >
            {p}
          </button>
        ),
      )}
      <button
        className={btn}
        disabled={current === total}
        onClick={() => onPage(current + 1)}
      >
        Next &rarr;
      </button>
    </div>
  );
}

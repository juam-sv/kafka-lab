interface Props {
  cached: boolean;
  cachedAt?: string;
}

export default function CacheBadge({ cached, cachedAt }: Props) {
  return (
    <span className="flex items-center gap-2">
      <span
        className={`rounded-xl px-2 py-0.5 text-[0.7rem] font-semibold ${
          cached
            ? "bg-badge-green-bg text-accent-green-text"
            : "bg-badge-orange-bg text-accent-orange"
        }`}
      >
        {cached ? "CACHE HIT" : "CACHE MISS"}
      </span>
      {cached && cachedAt && (
        <span className="text-[0.7rem] text-text-secondary">
          snapshot from {new Date(cachedAt).toLocaleTimeString()}
        </span>
      )}
    </span>
  );
}

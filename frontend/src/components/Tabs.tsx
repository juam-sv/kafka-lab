interface Props {
  tabs: string[];
  active: number;
  onChange: (index: number) => void;
}

export default function Tabs({ tabs, active, onChange }: Props) {
  return (
    <div className="mb-6 flex gap-1 border-b border-border-primary">
      {tabs.map((label, i) => (
        <button
          key={label}
          onClick={() => onChange(i)}
          className={`px-4 py-2 text-sm font-medium transition-colors ${
            i === active
              ? "border-b-2 border-accent-blue text-accent-blue"
              : "text-text-secondary hover:text-text-primary"
          }`}
        >
          {label}
        </button>
      ))}
    </div>
  );
}

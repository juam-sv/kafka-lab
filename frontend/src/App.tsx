import { useState } from "react";
import Tabs from "./components/Tabs";
import TransactionsTab from "./components/TransactionsTab";
import InsertTab from "./components/InsertTab";
import SearchTab from "./components/SearchTab";

const TAB_LABELS = ["Transactions", "Insert", "Search"];

export default function App() {
  const [activeTab, setActiveTab] = useState(0);
  const [searchQuery, setSearchQuery] = useState("");

  const handleSearchTransaction = (id: string) => {
    setSearchQuery(id);
    setActiveTab(2);
  };

  return (
    <div className="mx-auto max-w-[1200px] px-6 py-6">
      <h1 className="mb-5 text-2xl font-semibold text-white">
        Financial Transactions
      </h1>

      <Tabs tabs={TAB_LABELS} active={activeTab} onChange={setActiveTab} />

      {activeTab === 0 && <TransactionsTab active={activeTab === 0} />}
      {activeTab === 1 && (
        <InsertTab onSearchTransaction={handleSearchTransaction} />
      )}
      {activeTab === 2 && (
        <SearchTab
          key={searchQuery}
          initialQuery={searchQuery}
        />
      )}
    </div>
  );
}

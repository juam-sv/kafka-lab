import { useCallback, useState } from "react";
import { postTransaction } from "../api/transactions";
import type {
  TransactionCreatePayload,
  TransactionCreateResponse,
} from "../types";

const INITIAL: TransactionCreatePayload = {
  source_account: "",
  target_account: "",
  amount: 0,
  currency: "USD",
  txn_type: "TRANSFER",
};

export function useInsertTransaction() {
  const [form, setForm] = useState<TransactionCreatePayload>(INITIAL);
  const [submitting, setSubmitting] = useState(false);
  const [result, setResult] = useState<TransactionCreateResponse | null>(null);
  const [error, setError] = useState<string | null>(null);

  const updateField = useCallback(
    <K extends keyof TransactionCreatePayload>(
      key: K,
      value: TransactionCreatePayload[K],
    ) => {
      setForm((prev) => ({ ...prev, [key]: value }));
      setResult(null);
      setError(null);
    },
    [],
  );

  const submit = useCallback(async () => {
    if (!form.source_account || !form.target_account || form.amount <= 0) {
      setError("Please fill all required fields with valid values.");
      return;
    }

    setSubmitting(true);
    setError(null);
    setResult(null);

    try {
      const res = await postTransaction(form);
      setResult(res);
      setForm(INITIAL);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Submission failed");
    } finally {
      setSubmitting(false);
    }
  }, [form]);

  const reset = useCallback(() => {
    setForm(INITIAL);
    setResult(null);
    setError(null);
  }, []);

  return { form, submitting, result, error, updateField, submit, reset };
}

import { Dashboard } from "@/components/dashboard";

/**
 * A server component that renders one client tree. Nothing here reads the URL,
 * so no Suspense boundary is owed; `metadata` lives in `layout.tsx`, which is
 * the other reason this file stays a server component.
 */
export default function Page() {
  return <Dashboard />;
}

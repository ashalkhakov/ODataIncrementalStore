import { createFileRoute } from "@tanstack/react-router";
import { Workbench } from "@/components/workbench";

export const Route = createFileRoute("/workbench")({ component: WorkbenchPage });

function WorkbenchPage() {
  return (
    <main>
      <Workbench />
    </main>
  );
}

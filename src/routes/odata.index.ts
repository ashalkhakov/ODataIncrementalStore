import { createFileRoute } from "@tanstack/react-router";
import { handleODataRequest } from "@/lib/odata/http";

export const Route = createFileRoute("/odata/")({
  server: {
    handlers: {
      GET: ({ request }) => handleODataRequest(request),
    },
  },
});

import { createFileRoute } from "@tanstack/react-router";
import { handleODataRequest } from "@/lib/odata/http";

export const Route = createFileRoute("/odata/$")({
  server: {
    handlers: {
      GET: ({ request }) => handleODataRequest(request),
      POST: ({ request }) => handleODataRequest(request),
      PATCH: ({ request }) => handleODataRequest(request),
      PUT: ({ request }) => handleODataRequest(request),
      DELETE: ({ request }) => handleODataRequest(request),
    },
  },
});

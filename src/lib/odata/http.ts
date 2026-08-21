import { getSharedEngine } from "./engine";

export async function handleODataRequest(request: Request): Promise<Response> {
  const url = new URL(request.url);
  let body: unknown;
  if (request.method !== "GET" && request.method !== "HEAD" && request.method !== "OPTIONS") {
    const text = await request.text();
    if (text) {
      try {
        body = JSON.parse(text);
      } catch {
        body = text;
      }
    }
  }
  const headers: Record<string, string> = {};
  request.headers.forEach((value, key) => {
    headers[key] = value;
  });
  const result = getSharedEngine().handle({
    method: request.method,
    path: url.pathname,
    query: url.searchParams,
    body,
    headers,
    serviceRoot: "/odata",
  });
  const responseHeaders = new Headers();
  for (const [k, v] of Object.entries(result.headers)) {
    responseHeaders.set(k, v);
  }
  if (result.status === 204) {
    return new Response(null, { status: 204, headers: responseHeaders });
  }
  if (typeof result.text === "string" && result.headers["content-type"]?.includes("xml")) {
    return new Response(result.text, { status: result.status, headers: responseHeaders });
  }
  if (typeof result.text === "string" && result.headers["content-type"]?.includes("text/plain")) {
    return new Response(result.text, { status: result.status, headers: responseHeaders });
  }
  return Response.json(result.body, { status: result.status, headers: responseHeaders });
}

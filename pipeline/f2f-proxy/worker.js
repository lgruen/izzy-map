// Minimal CORS pass-through for the From Forest to Fjaeldmark chapter PDFs.
// nre.tas.gov.au (SharePoint) sends no CORS headers, so the app cannot fetch
// the PDFs directly; this Worker relays the request and adds them. It is a
// transparent pipe: nothing is stored or rewritten, and only the known F2F
// chapter files are allowed (see docs/LICENSING.md for why we must not host
// copies ourselves).
const ORIGIN = "https://nre.tas.gov.au/Documents/";
const ALLOWED = /^f2f_[a-z_-]+\.pdf$/;

export default {
  async fetch(request) {
    const name = new URL(request.url).pathname.replace(/^\/+/, "");
    if (!ALLOWED.test(name)) return new Response("not found", { status: 404 });
    const upstream = await fetch(ORIGIN + name, {
      headers: { Range: request.headers.get("Range") ?? "" },
      cf: { cacheTtl: 86400, cacheEverything: true },
    });
    const headers = new Headers(upstream.headers);
    headers.set("Access-Control-Allow-Origin", "*");
    headers.set("Access-Control-Expose-Headers", "Content-Length, Content-Range");
    return new Response(upstream.body, { status: upstream.status, headers });
  },
};

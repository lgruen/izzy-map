// CORS relay for the From Forest to Fjaeldmark chapter PDFs.
// nre.tas.gov.au (SharePoint) sends no CORS headers, so the app cannot fetch
// the PDFs directly; this Worker relays the request and adds them.
//
// LICENSING (see docs/LICENSING.md): the PDFs are © all rights reserved, so
// this must remain a TRANSPARENT, NON-CACHING pipe — `cache: "no-store"`
// upstream, `Cache-Control: no-store` downstream, nothing persisted at the
// edge — and it only answers the app's own origins for the exact known
// chapter files.
const ORIGIN = "https://nre.tas.gov.au/Documents/";
const ALLOWED_FILES = new Set([
  "f2f_dry_eucalypt.pdf",
  "f2f_wet_eucalypt.pdf",
  "f2f_non-eucalypt.pdf",
  "f2f_rainforest.pdf",
  "f2f_scrub.pdf",
  "f2f_moorland_sedgeland.pdf",
  "f2f_native_grassland.pdf",
  "f2f_highland_treeless.pdf",
  "f2f_saltmarsh.pdf",
  "f2f_other_natural.pdf",
  "f2f_modified_land.pdf",
]);
const ALLOWED_ORIGINS = new Set([
  "https://lgruen.github.io",
  "http://localhost:5199",
  "http://localhost:5200",
  "http://localhost:4173",
]);

export default {
  async fetch(request) {
    const reqOrigin = request.headers.get("Origin") ?? "";
    if (!ALLOWED_ORIGINS.has(reqOrigin)) return new Response("forbidden", { status: 403 });
    if (request.method !== "GET" && request.method !== "HEAD")
      return new Response("method not allowed", { status: 405 });
    const name = new URL(request.url).pathname.replace(/^\/+/, "");
    if (!ALLOWED_FILES.has(name)) return new Response("not found", { status: 404 });

    const range = request.headers.get("Range");
    const upstream = await fetch(ORIGIN + name, {
      method: request.method,
      headers: range ? { Range: range } : {},
      cache: "no-store",
    });
    const headers = new Headers(upstream.headers);
    headers.set("Access-Control-Allow-Origin", reqOrigin);
    headers.set("Access-Control-Expose-Headers", "Content-Length, Content-Range");
    headers.set("Cache-Control", "no-store");
    return new Response(upstream.body, { status: upstream.status, headers });
  },
};

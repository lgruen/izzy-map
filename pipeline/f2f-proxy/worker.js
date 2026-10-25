// CORS relay for the From Forest to Fjaeldmark chapter PDFs and for
// Understorey Network Tasmania plant photos.
// nre.tas.gov.au (SharePoint) sends no CORS headers, so the app cannot fetch
// the PDFs directly; this Worker relays the request and adds them. The
// Understorey Network WordPress site doesn't either: an <img> can show its
// photos, but the app can only READ the bytes (to keep them in OPFS for
// offline use) through a CORS-enabled response — the second, separate
// allow-list below.
//
// LICENSING (see docs/LICENSING.md): the PDFs are © all rights reserved and
// the photos © their photographers, so this must remain a TRANSPARENT,
// NON-CACHING pipe — `cache: "no-store"` upstream, `Cache-Control: no-store`
// downstream, nothing persisted at the edge — and it only answers the app's
// own origins for the exact known chapter files / photo-file shapes.
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

// Understorey Network photos: `/un/YYYY/MM/<file>.<ext>` relays
// `${UN_UPLOADS}YYYY/MM/<file>.<ext>` — WordPress media uploads only (one
// directory level per year and month, a plain file name that includes any
// size suffix such as -768x576 / -rotated / -scaled, an image extension),
// never pages, the API or anything else on that host. Image content-types
// only, both ways.
const UN_UPLOADS = "https://database.understorey-network.org.au/wp-content/uploads/";
const UN_PHOTO = /^un\/((?:19|20)\d\d\/(?:0[1-9]|1[0-2])\/[A-Za-z0-9_-][A-Za-z0-9_.-]{0,199}\.(?:jpe?g|jpe|png|webp|gif))$/i;
const IMAGE_TYPES = /^image\/(?:jpeg|png|webp|gif)\b/i;

async function relayPhoto(request, path, reqOrigin) {
  const cors = {
    "Access-Control-Allow-Origin": reqOrigin,
    "Access-Control-Expose-Headers": "Content-Length",
    "Cache-Control": "no-store",
  };
  // no Range, no cookies, no client headers forwarded: a plain GET/HEAD.
  // Redirects are NOT followed (a 3xx below becomes a 502): the allow-list
  // must bound what is fetched, not just what is asked for.
  const upstream = await fetch(UN_UPLOADS + path, { method: request.method, cache: "no-store", redirect: "manual" });
  // a missing photo is a readable 404 (the app files it as "no longer
  // published" and moves on); the relay's own refusals above carry no CORS
  // headers, so the app can tell the two apart
  if (upstream.status === 404 || upstream.status === 410)
    return new Response(null, { status: upstream.status, headers: cors });
  const type = upstream.headers.get("Content-Type") ?? "";
  if (upstream.status !== 200 || !IMAGE_TYPES.test(type))
    return new Response(null, { status: 502, headers: cors });
  const headers = new Headers(cors);
  headers.set("Content-Type", type);
  const length = upstream.headers.get("Content-Length");
  if (length) headers.set("Content-Length", length);
  return new Response(upstream.body, { status: 200, headers });
}

export default {
  async fetch(request) {
    const reqOrigin = request.headers.get("Origin") ?? "";
    if (!ALLOWED_ORIGINS.has(reqOrigin)) return new Response("forbidden", { status: 403 });
    if (request.method !== "GET" && request.method !== "HEAD")
      return new Response("method not allowed", { status: 405 });
    const name = new URL(request.url).pathname.replace(/^\/+/, "");
    const photo = UN_PHOTO.exec(name);
    if (photo && !photo[1].includes("..")) return relayPhoto(request, photo[1], reqOrigin);
    if (!ALLOWED_FILES.has(name)) return new Response("not found", { status: 404 });

    const range = request.headers.get("Range");
    const upstream = await fetch(ORIGIN + name, {
      method: request.method,
      headers: range ? { Range: range } : {},
      cache: "no-store",
      // never follow a redirect off the allow-listed files (nre.tas.gov.au
      // answered the chapter URLs 200 directly, checked 2026-10-25)
      redirect: "manual",
    });
    if (upstream.status >= 300 && upstream.status < 400) return new Response("bad gateway", { status: 502 });
    const headers = new Headers(upstream.headers);
    headers.set("Access-Control-Allow-Origin", reqOrigin);
    headers.set("Access-Control-Expose-Headers", "Content-Length, Content-Range");
    headers.set("Cache-Control", "no-store");
    return new Response(upstream.body, { status: upstream.status, headers });
  },
};

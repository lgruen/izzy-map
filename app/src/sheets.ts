// Hobart significant-tree data sheets: City of Hobart PDFs hosted as ArcGIS
// Online items, fetched by the device on demand (tap) or in bulk (Offline
// maps) and kept in OPFS under trees/<id>.pdf. Shared by details.ts and
// ui.ts (neither may import the other).
import { TREE_SHEET_DIR, treeSheetUrl } from "./config";
import { writeFile } from "./storage";
import { TREES } from "./style";

/** OPFS path of a sheet. */
export const sheetPath = (id: string): string => `${TREE_SHEET_DIR}/${id}.pdf`;
/** Every sheet id, sorted — the bulk download order. */
export const SHEET_IDS: readonly string[] = Object.keys(TREES.sheets).sort();
/** Σ declared sheet sizes (~446 MB). */
export const SHEETS_TOTAL_BYTES: number = SHEET_IDS.reduce((a, id) => a + TREES.sheets[id].bytes, 0);
/** One decimal — sheets run 0.1–7 MB, so whole megabytes would read "0 MB". */
export const fmtSheetMB = (b: number): string => `${(b / 1e6).toFixed(1)} MB`;

const PAUSED = "paused — tap the button to continue";

/** Why a fetch failed. Callers word the consequence differently: the bulk
 * download skips a `gone`/`notpdf` sheet and carries on, a tap tells the
 * user how to get the sheet for `offline`, and a dismissed card says
 * nothing at all for its own `aborted`. */
export type SheetErrorKind = "offline" | "aborted" | "timeout" | "gone" | "notpdf" | "failed";
export class SheetError extends Error {
  constructor(
    message: string,
    readonly kind: SheetErrorKind,
    readonly status?: number,
  ) {
    super(message);
    this.name = "SheetError";
  }
}

// ---- "no longer published" memory ----
// ArcGIS answers a REMOVED item with HTTP 400 + an HTML page (verified live
// 2026-09-12), not 404. Without this the bulk download would re-fail on the
// same sheet forever (sorted order), so the batch records withdrawn ids here
// ({id: isoDate}) and counts the rest as complete. A tap still tries such an
// id once (items get republished); any successful fetch forgets it.
const GONE_KEY = "treeSheetsGone";
export function goneSheets(): Record<string, string> {
  try {
    const v = JSON.parse(localStorage.getItem(GONE_KEY) ?? "{}") as unknown;
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, string>) : {};
  } catch {
    return {};
  }
}
export function markSheetGone(id: string, gone: boolean): void {
  const set = goneSheets();
  if (gone === (id in set)) return;
  if (gone) set[id] = new Date().toISOString();
  else delete set[id];
  try {
    if (Object.keys(set).length) localStorage.setItem(GONE_KEY, JSON.stringify(set));
    else localStorage.removeItem(GONE_KEY);
  } catch {
    /* private mode */
  }
}
/** Forget every withdrawn id — a fresh bulk download re-checks them all. */
export function clearGoneSheets(): void {
  try {
    localStorage.removeItem(GONE_KEY);
  } catch {
    /* private mode */
  }
}

// One fetch per id at a time: a tap while the batch is on the same sheet
// joins it instead of racing for `<id>.pdf.tmp` (the loser would surface a
// raw NotFoundError). The joiner's own signal is ignored — the fetch belongs
// to whoever started it.
const inflight = new Map<string, Promise<void>>();

/** Fetch one sheet from arcgis.com and store it. A plain GET with no custom
 * headers is a CORS "simple request": the browser follows the 302 to the
 * signed S3 URL without a preflight (whose allow-list lacks Range — hence
 * not storage.download()). Rejects with a SheetError carrying a user-facing
 * message; an abort via `signal` rejects with the storage.ts "paused"
 * wording (kind "aborted"), a TimeoutError reason with kind "timeout". */
export function fetchSheet(id: string, signal?: AbortSignal): Promise<void> {
  const existing = inflight.get(id);
  if (existing) return existing;
  const p = fetchSheetInner(id, signal).finally(() => inflight.delete(id));
  inflight.set(id, p);
  return p;
}

async function fetchSheetInner(id: string, signal?: AbortSignal): Promise<void> {
  if (!TREES.sheets[id]) throw new SheetError("Unknown data sheet", "failed");
  let buf: ArrayBuffer;
  let status: number;
  try {
    const res = await fetch(treeSheetUrl(id), { signal });
    status = res.status;
    if (!res.ok) {
      // a removed item is a 400 with an HTML body (not 404) — any 4xx says
      // "this id will not come back by retrying"; 5xx may
      throw status >= 400 && status < 500
        ? new SheetError("This data sheet is no longer published by the council", "gone", status)
        : new SheetError(`Couldn't download (HTTP ${status}) — try again on Wi-Fi`, "failed", status);
    }
    buf = await res.arrayBuffer();
  } catch (e) {
    if (signal?.aborted) {
      const reason = signal.reason as { name?: string } | undefined;
      throw reason?.name === "TimeoutError"
        ? new SheetError("Fetching the data sheet took too long — try again on Wi-Fi", "timeout")
        : new SheetError(PAUSED, "aborted");
    }
    // fetch() itself rejects only on network/CORS failure — a TypeError
    if (e instanceof TypeError) throw new SheetError("Couldn't reach arcgis.com — needs reception", "offline");
    throw e;
  }
  // A captive-portal login page answers 200 with HTML: not a sheet.
  const head = String.fromCharCode(...new Uint8Array(buf, 0, Math.min(4, buf.byteLength)));
  if (head !== "%PDF") {
    throw new SheetError("The download wasn't a PDF — a Wi-Fi login page may be in the way", "notpdf", status);
  }
  await writeFile(sheetPath(id), buf);
  markSheetGone(id, false);
}

// Offline place / street / address search. Two committed JSON indexes
// (app/public/search/, built by pipeline/build_gazetteer.py, precached by
// the service worker as app shell) are fetched once and pre-tokenised;
// queries are word-prefix scored synchronously — a few ms for ~32k names on
// a phone — so no Worker, no library, no OPFS/manifest machinery.
import { Marker, type Map as MlMap } from "maplibre-gl";
import { ATTRIBUTION_ADDRESSES, ATTRIBUTION_NAMES } from "./config";
import { closePanel, onPanelClose, openPanel } from "./ui";

// ---------- data contract (version 1) ----------

type BBoxDelta = [number, number, number, number];
/** [name, typeIdx, placeIdx, muniIdx, lat5, lon5, bboxDelta?] — 1e-5° ints;
 * bbox = [w−lon5, s−lat5, e−lon5, n−lat5]. Rows sorted by normalised name. */
type GazRow = [string, number, number, number, number, number, BBoxDelta?];
export interface Gazetteer {
  version: number;
  built: string;
  attribution: string;
  types: string[];
  groups: string[];
  typeGroup: number[];
  places: string[];
  munis: string[];
  rows: GazRow[];
}
/** [street, locality, lon0_5, lat0_5, numbers[], dlon[], dlat[]] — numbers
 * sorted ascending (strings like "15A" carry a suffix); coordinate i is the
 * cumulative sum of the deltas from (lon0, lat0), first delta 0. */
type StreetRow = [string, string, number, number, (number | string)[], number[], number[]];
export interface Addresses {
  version: number;
  built: string;
  attribution: string;
  streets: StreetRow[];
}

export interface Entry {
  name: string;
  type: string;
  group: string;
  place: string;
  muni: string;
  lat: number;
  lon: number;
  bbox?: [number, number, number, number];
  norm: string;
  /** normalise(place) — precomputed once per distinct place */
  placeNorm: string;
  nameTokens: string[];
  ctxTokens: string[];
}
export interface Index {
  entries: Entry[];
}
interface Street {
  name: string;
  locality: string;
  norm: string;
  locNorm: string;
  nameTokens: string[];
  ctxTokens: string[];
  lon: number;
  lat: number;
  row: StreetRow;
  /** lon,lat pairs in degrees — decoded on the first hit, never up front */
  coords?: Float64Array;
}
export interface AddrIndex {
  streets: Street[];
}
export interface Hit {
  name: string;
  type: string;
  group: string;
  /** "Road · North Hobart, Hobart" / "Address · Hobart · nearest: 14" */
  meta: string;
  lat: number;
  lon: number;
  bbox?: [number, number, number, number];
  score: number;
  km: number | null;
}

// ---------- text ----------

/** NFD → strip marks → lower → drop apostrophes → non-alphanumerics to
 * single spaces → trim. Apostrophes vanish rather than split (both sides go
 * through here): "obriens" finds O'Briens, "dentrecasteaux" D'Entrecasteaux. */
export function normalise(s: string): string {
  return s
    .normalize("NFD")
    .replace(/\p{M}+/gu, "")
    .toLowerCase()
    .replace(/['’]/g, "")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}
const words = (norm: string): string[] => (norm ? norm.split(" ") : []);
export const tokenise = (s: string): string[] => words(normalise(s));

/** Query-side abbreviations. Prefix forms (st, ave, cres, pl, dr, esp, gr)
 * need no entry: "st" prefix-matches "street" and exactly matches the "St"
 * of "St Helens". Both the expansion and the literal are tried, so a typed
 * "pt" still finds a name that really contains "Pt". */
const ABBREV: Record<string, string> = {
  rd: "road", mt: "mount", ck: "creek", crk: "creek", pt: "point", hwy: "highway", ct: "court",
  ln: "lane", tce: "terrace", blvd: "boulevard", hts: "heights", pde: "parade", cct: "circuit",
  sq: "square", rv: "river", pk: "peak", trk: "track", tk: "track", hbr: "harbour", lk: "lake",
  nth: "north", sth: "south", saint: "st",
};
const forms = (t: string): string[] => {
  const x = ABBREV[t];
  return x && x !== t ? [x, t] : [t];
};
/** Typing one of these means "I want the street": roads then compete on
 * equal terms instead of ranking below the suburb/hill of the same name. */
const STREET_WORDS = new Set([
  "street", "st", "road", "rd", "avenue", "ave", "av", "court", "ct", "crescent", "cres", "cr",
  "place", "pl", "drive", "dr", "lane", "ln", "terrace", "tce", "highway", "hwy", "parade", "pde",
  "circuit", "cct", "boulevard", "blvd", "close", "cl", "way", "esplanade", "esp", "grove", "gr",
  "rise", "square", "sq", "mews", "alley", "walk", "row", "loop", "link", "bypass", "promenade",
  "quay", "wharf", "freeway", "fwy",
]);
const HOUSE_RE = /^\d+[a-z]?$/;
const BARE_RE = /^\d+$/;
/** "7 mile beach" is Seven Mile Beach: a split-off house number is also
 * tried spelt out (the numbers that start Tasmanian names). */
const NUMBER_WORDS: Record<string, string> = {
  1: "one", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven", 8: "eight", 9: "nine",
  10: "ten", 11: "eleven", 12: "twelve", 13: "thirteen", 14: "fourteen", 15: "fifteen", 16: "sixteen",
  17: "seventeen", 18: "eighteen", 19: "nineteen", 20: "twenty", 30: "thirty", 40: "forty", 50: "fifty",
};

/** Every query token must hit a name token (exact 3 / prefix 2, +1 when the
 * first typed word hits the first name word) or, failing that, a context
 * token (locality / council, prefix, 1). 0 = no match. `out.ctx` reports
 * whether any token was carried by the context alone. */
function scoreTokens(qs: string[][], nameTokens: string[], ctxTokens: string[], out?: { ctx: boolean }): number {
  let total = 0;
  if (out) out.ctx = false;
  for (let qi = 0; qi < qs.length; qi++) {
    const cands = qs[qi];
    let best = 0;
    for (let ni = 0; ni < nameTokens.length; ni++) {
      const n = nameTokens[ni];
      for (const c of cands) {
        let s = n === c ? 3 : n.startsWith(c) ? 2 : 0;
        if (!s) continue;
        if (qi === 0 && ni === 0) s += 1;
        if (s > best) best = s;
      }
    }
    if (!best) {
      for (const x of ctxTokens) {
        if (cands.some((c) => x.startsWith(c))) {
          best = 1;
          if (out) out.ctx = true;
          break;
        }
      }
      if (!best) return 0;
    }
    total += best;
  }
  return total;
}

/** Equirectangular distance in km — plenty at Tasmanian scales. */
function kmBetween(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const dx = (lon2 - lon1) * Math.cos((((lat1 + lat2) / 2) * Math.PI) / 180) * 111.32;
  const dy = (lat2 - lat1) * 110.57;
  return Math.hypot(dx, dy);
}
const fmtKm = (km: number): string =>
  km < 0.95 ? `${Math.max(50, Math.round(km * 20) * 50)} m` : km < 10 ? `${km.toFixed(1)} km` : `${Math.round(km)} km`;

// ---------- indexes ----------

export function buildIndex(g: Gazetteer): Index {
  const placeNorms = g.places.map(normalise);
  const entries = g.rows.map(([name, ti, pi, mi, lat5, lon5, d]) => {
    const place = g.places[pi] ?? "";
    const muni = g.munis[mi] ?? "";
    const norm = normalise(name);
    const e: Entry = {
      name,
      type: g.types[ti] ?? "",
      group: g.groups[g.typeGroup[ti]] ?? "",
      place,
      muni,
      lat: lat5 / 1e5,
      lon: lon5 / 1e5,
      norm,
      placeNorm: placeNorms[pi] ?? "",
      nameTokens: words(norm),
      ctxTokens: [...new Set(tokenise(place + " " + muni))],
    };
    if (d) e.bbox = [(lon5 + d[0]) / 1e5, (lat5 + d[1]) / 1e5, (lon5 + d[2]) / 1e5, (lat5 + d[3]) / 1e5];
    return e;
  });
  return { entries };
}

export function buildAddrIndex(a: Addresses): AddrIndex {
  return {
    streets: a.streets.map((row) => {
      const norm = normalise(row[0]);
      const locNorm = normalise(row[1]);
      return {
        name: row[0],
        locality: row[1],
        norm,
        locNorm,
        nameTokens: words(norm),
        ctxTokens: words(locNorm),
        lon: row[2] / 1e5,
        lat: row[3] / 1e5,
        row,
      };
    }),
  };
}

function coordAt(st: Street, i: number): [number, number] {
  if (!st.coords) {
    const [, , lon0, lat0, nums, dlon, dlat] = st.row;
    const c = new Float64Array(nums.length * 2);
    let lon = lon0;
    let lat = lat0;
    for (let k = 0; k < nums.length; k++) {
      lon += dlon[k] ?? 0;
      lat += dlat[k] ?? 0;
      c[2 * k] = lon / 1e5;
      c[2 * k + 1] = lat / 1e5;
    }
    st.coords = c;
  }
  return [st.coords[2 * i], st.coords[2 * i + 1]];
}

/** An address-file street as a Road row (the register lists a road once,
 * under one place; the address file has it per suburb): pinned at its
 * middle house number — always on the street — and framed by the extent of
 * all its numbers when there is more than one. */
function streetHit(st: Street, score: number, km: Km): Hit {
  const n = st.row[4].length;
  const [lon, lat] = coordAt(st, n >> 1);
  const h: Hit = { name: st.name, type: "Road", group: "Transport", meta: `Road · ${st.locality}`, lat, lon, score, km: km(lat, lon) };
  if (n > 1) {
    const c = st.coords!;
    let w = Infinity, s = Infinity, e = -Infinity, nn = -Infinity;
    for (let k = 0; k < n; k++) {
      const x = c[2 * k], y = c[2 * k + 1];
      if (x < w) w = x;
      if (x > e) e = x;
      if (y < s) s = y;
      if (y > nn) nn = y;
    }
    h.bbox = [w, s, e, nn];
  }
  return h;
}

function metaOf(e: Entry): string {
  // MUNY is verbatim and 149 values are multi-council lists ("Glenorchy,
  // Hobart, Kingborough"): show the first so a row stays one line (all of
  // them still match as context tokens). Omit the place when empty or
  // equal to the council ("Suburb · Hobart", not "Suburb · Hobart, Hobart").
  const muni = e.muni.split(", ")[0];
  const ctx = e.place && e.place !== muni ? [e.place, muni].filter(Boolean).join(", ") : muni || e.place;
  return ctx ? `${e.type} · ${ctx}` : e.type;
}

// ---------- query ----------

type Km = (lat: number, lon: number) => number | null;

/** "1/12 Smith St" → "12 Smith St" (unit / number), "2-4 Smith St" → "2 Smith
 * St" (range): on the raw text, because normalise() turns both separators
 * into a space, after which the two forms cannot be told apart. */
function stripUnitAndRange(q: string): string {
  return q
    .replace(/^\s*\d+[a-z]?\s*\/\s*(\d+[a-z]?)\b/i, "$1")
    .replace(/^\s*(\d+[a-z]?)\s*[-–—]\s*\d+[a-z]?\b/i, "$1");
}

/** A leading (or trailing) "12" / "15a" is a house number; two leading bare
 * numbers ("1 12 …", also what "1/12" becomes after normalising) are unit
 * then number. Returns the number, the remaining name words (any stray bare
 * numbers dropped) and where the number stood. */
function splitHouseNumber(tokens: string[]): [string | null, string[], "start" | "end"] {
  let num: string | null = null;
  let rest = tokens;
  let at: "start" | "end" = "start";
  if (tokens.length > 2 && BARE_RE.test(tokens[0]) && HOUSE_RE.test(tokens[1])) {
    num = tokens[1];
    rest = tokens.slice(2);
  } else if (tokens.length > 1 && HOUSE_RE.test(tokens[0])) {
    num = tokens[0];
    rest = tokens.slice(1);
  } else if (tokens.length > 1 && HOUSE_RE.test(tokens[tokens.length - 1])) {
    num = tokens[tokens.length - 1];
    rest = tokens.slice(0, -1);
    at = "end";
  }
  if (num) rest = rest.filter((t) => !BARE_RE.test(t));
  return num && rest.length ? [num, rest, at] : [null, tokens, at];
}

function addressHits(addr: AddrIndex, num: string, rest: string[], km: Km, limit: number): Hit[] {
  const qs = rest.map(forms);
  const scored: { st: Street; s: number; km: number | null }[] = [];
  for (const st of addr.streets) {
    const s = scoreTokens(qs, st.nameTokens, st.ctxTokens);
    if (s) scored.push({ st, s, km: km(st.lat, st.lon) });
  }
  scored.sort((a, b) => b.s - a.s || (a.km ?? 0) - (b.km ?? 0));
  const want = parseInt(num, 10);
  const out: Hit[] = [];
  for (const { st, s } of scored.slice(0, limit)) {
    const nums = st.row[4];
    let i = nums.findIndex((n) => String(n).toLowerCase() === num);
    const exact = i >= 0;
    if (!exact) {
      // nearest by numeric part; ties → the plain number, then the lower one
      let best = Infinity;
      for (let j = 0; j < nums.length; j++) {
        const d = Math.abs(parseInt(String(nums[j]), 10) - want);
        if (d < best || (d === best && typeof nums[j] === "number" && typeof nums[i] !== "number")) {
          best = d;
          i = j;
        }
      }
    }
    if (i < 0) continue;
    const [lon, lat] = coordAt(st, i);
    // A typed house number is the strongest intent signal: +4 outranks the
    // gazetteer's whole-name-exact bonus (+3) for the same street. An exact
    // number adds 1; a stand-in loses ground with its distance in house
    // numbers — "nearest: 14" for a typed 12 is a fair answer, the
    // "nearest: 249" of the same street's next suburb is not, whatever the
    // map centre says.
    const off = exact ? 0 : Math.min(0.9, Math.abs(parseInt(String(nums[i]), 10) - want) / 100);
    out.push({
      name: `${num.toUpperCase()} ${st.name}`,
      type: "Address",
      group: "Address",
      meta: `Address · ${st.locality}${exact ? "" : ` · nearest: ${nums[i]}`}`,
      lat,
      lon,
      score: s + 4 + (exact ? 1 : -off),
      km: km(lat, lon),
    });
  }
  return out;
}

export function search(
  idx: Index,
  addr: AddrIndex | null,
  query: string,
  centre?: { lng: number; lat: number } | null,
  limit = 30,
): Hit[] {
  const norm = normalise(stripUnitAndRange(query));
  if (norm.length < 2) return [];
  const all = words(norm);
  const km: Km = centre ? (lat, lon) => kmBetween(centre.lat, centre.lng, lat, lon) : () => null;
  const hits: Hit[] = [];

  // "12 elizabeth st hobart": the number picks an address on the streets the
  // other words match; those words still run against the gazetteer below.
  const [num, tokens, numAt] = splitHouseNumber(all);
  if (num && addr) hits.push(...addressHits(addr, num, tokens, km, limit));

  // Name-index query variants: the words without the number and, for
  // "7 mile beach", the number spelt out where it stood — "seven" earns
  // Seven Mile Beach the first-word and whole-name bonuses that the address
  // "7 Seven Mile Beach Road" (+4) would otherwise beat.
  const variants = [tokens];
  const word = num && NUMBER_WORDS[num];
  if (word) variants.push(numAt === "end" ? [...tokens, word] : [word, ...tokens]);
  const scorers = variants.map((v) => ({
    qs: v.map(forms),
    expanded: v.map((t) => ABBREV[t] ?? t).join(" "),
    joined: v.join(" "),
  }));
  const streetWord = tokens.some((t) => STREET_WORDS.has(t));
  const flag = { ctx: false };
  /** Best variant for one name: raw token score, whether it is the whole
   * name exactly, whether context alone carried a token. false = no match. */
  const r = { s: 0, whole: false, ctx: false };
  const best = (n: string, nameTokens: string[], ctxTokens: string[]): boolean => {
    r.s = 0;
    r.whole = false;
    r.ctx = false;
    for (const v of scorers) {
      const s = scoreTokens(v.qs, nameTokens, ctxTokens, flag);
      if (!s) continue;
      const whole = n === v.expanded || n === v.joined;
      if (s + (whole ? 3 : 0) > r.s + (r.whole ? 3 : 0)) {
        r.s = s;
        r.whole = whole;
        r.ctx = flag.ctx;
      }
    }
    return r.s > 0;
  };
  // "name|place" (normalised) of every register / street row in the result
  // and of each Property row: a Property twinning a register row is dropped
  // before the final sort (below)
  const shownKeys = new Set<string>();
  const propertyKey = new Map<Hit, string>();
  const toHit = (e: Entry, score: number): Hit => {
    const h: Hit = {
      name: e.name, type: e.type, group: e.group, meta: metaOf(e), lat: e.lat, lon: e.lon, bbox: e.bbox,
      score, km: km(e.lat, e.lon),
    };
    const key = e.norm + "|" + e.placeNorm;
    if (e.group === "Property") propertyKey.set(h, key);
    else shownKeys.add(key);
    return h;
  };

  const matched = new Set<Entry>();
  const streetScan = !!addr && !num;
  const roadNames = new Set<string>(); // normalised names of matched register roads…
  const roadKeys = new Set<string>(); // …and "name|place" of each such row
  let official = false; // any non-Property row matched
  for (const e of idx.entries) {
    if (!best(e.norm, e.nameTokens, e.ctxTokens)) continue;
    let s = r.s;
    if (e.group === "Property") {
      // property names rank below official names, and a property that
      // merely IS the typed word ("Salamanca", a farm) must not outrank the
      // Salamanca Square everyone means: a token whole-name bonus only
      s += (r.whole ? 1 : 0) - 0.5;
    } else {
      if (r.whole) s += 3; // the whole name, exactly
      official = true;
      if (e.group === "Transport") {
        // a road shares its name with the suburb / hill / bay it is named
        // after — the place ranks first unless the user typed a street word,
        // which then puts the ROAD ahead of the pier (Transport too) or park
        // of that name
        s += streetWord ? (e.type === "Road" ? 1 : 0) : -1;
        if (streetScan) {
          roadNames.add(e.norm);
          roadKeys.add(e.norm + "|" + e.placeNorm);
        }
      }
    }
    matched.add(e);
    hits.push(toHit(e, s));
  }

  // Suburb-qualified streets ("elizabeth st north hobart"): the register
  // holds a road once, under one place, so the address file's per-suburb
  // rows fill in — only where a typed word named the suburb, or the register
  // has no such road at all (plain "elizabeth st" must not grow twenty
  // duplicate rows); a row the register already has is dropped, the
  // register's bbox being the better frame. Ties go to the register.
  if (addr && streetScan) {
    const cands: { st: Street; s: number; km: number | null }[] = [];
    for (const st of addr.streets) {
      if (!best(st.norm, st.nameTokens, st.ctxTokens)) continue;
      if (roadKeys.has(st.norm + "|" + st.locNorm)) continue;
      if (!r.ctx && roadNames.has(st.norm)) continue;
      cands.push({ st, s: r.s + (r.whole ? 3 : 0) + (streetWord ? 1 : -1) - 0.25, km: km(st.lat, st.lon) });
    }
    if (cands.length) official = true;
    cands.sort((a, b) => b.s - a.s || (a.km ?? 0) - (b.km ?? 0));
    for (const c of cands.slice(0, limit)) {
      hits.push(streetHit(c.st, c.s, km)); // decodes only these
      shownKeys.add(c.st.norm + "|" + c.st.locNorm);
    }
  }

  // substring tier (mid-word typos, "ellington"): only when the prefix tier
  // left room and a token is long enough to mean something
  if (hits.length < limit && tokens.some((t) => t.length >= 3)) {
    const { qs } = scorers[0];
    for (const e of idx.entries) {
      if (matched.has(e)) continue;
      if (qs.every((cands) => cands.some((c) => e.norm.includes(c)))) hits.push(toHit(e, 0.5));
    }
  }
  // properties trail whenever anything official answered the query
  if (official) for (const h of hits) if (h.group === "Property") h.score -= 2;
  // Some 430 register names (2026-09) recur as a Property row of the same
  // name and place ("Elizabeth Street Pier": Pier and Property, both Hobart;
  // most are parks and cemeteries) — the register row alone is shown.
  // Address rows (house number + street) are not keyed: nothing twins them.
  const out = propertyKey.size
    ? hits.filter((h) => h.group !== "Property" || !shownKeys.has(propertyKey.get(h)!))
    : hits;
  out.sort((a, b) => b.score - a.score || (a.km ?? 0) - (b.km ?? 0) || a.name.localeCompare(b.name));
  return out.slice(0, limit);
}

// ---------- loading ----------

let gaz: Index | null = null;
let addr: AddrIndex | null = null;
let loading: Promise<void> | null = null;

/** Fetch + index both files once (relative URL: dev server and the Pages
 * base both work; offline the service worker's precache answers). The
 * promise resets on failure so a later attempt can succeed; a version
 * mismatch throws Error("version"). */
export function loadIndexes(): Promise<void> {
  if (gaz) return Promise.resolve();
  if (!loading) {
    loading = (async () => {
      const [g, a] = await Promise.all([fetch("search/gazetteer.json"), fetch("search/addresses.json")]);
      if (!g.ok || !a.ok) throw new Error(`search index HTTP ${g.ok ? a.status : g.status}`);
      const gj = (await g.json()) as Gazetteer;
      const aj = (await a.json()) as Addresses;
      if (gj.version !== 1 || aj.version !== 1) throw new Error("version");
      gaz = buildIndex(gj);
      addr = buildAddrIndex(aj);
    })();
    // network failures may succeed next time; a version mismatch is this
    // build's for good — re-fetching 6 MB per keystroke would not fix it
    loading.catch((e: Error) => {
      if (e.message !== "version") loading = null;
    });
  }
  return loading;
}

// ---------- map: pin + pill ----------

let map: MlMap | null = null;
let marker: Marker | null = null;
let pinned: Hit | null = null;

/** Zoom for point results (bbox results use fitBounds). */
const ZOOM_BY_TYPE: Record<string, number> = {
  Town: 13, "Suburb/Locality": 14, "Unbounded Locality": 13, Mountain: 13, Mountains: 11, Hill: 13.5,
  Stream: 13, "Water Body": 13, Bay: 13, Beach: 14, Island: 13, Promontory: 14, Waterfall: 15, Cave: 15,
  Track: 14, Route: 11, "Recreational Park": 14, "Conservation Area": 12, Property: 16, Address: 17.5,
  Road: 16, // an address-file street with a single number (register roads carry a bbox)
};

function goTo(h: Hit): void {
  if (!map) return;
  if (h.bbox) {
    map.fitBounds([[h.bbox[0], h.bbox[1]], [h.bbox[2], h.bbox[3]]], {
      padding: 56,
      maxZoom: h.group === "Transport" ? 16 : 14.5,
      duration: 900,
    });
  } else {
    map.flyTo({ center: [h.lon, h.lat], zoom: ZOOM_BY_TYPE[h.type] ?? 14, duration: 900 });
  }
}

function setPin(h: Hit): void {
  if (!map) return;
  marker?.remove();
  // a DOM marker: no sprite, no glyph range to worry about offline
  marker = new Marker({ color: "#1e4434", className: "search-pin" }).setLngLat([h.lon, h.lat]).addTo(map);
  pinned = h;
  const pill = document.getElementById("search-pill");
  const name = document.getElementById("search-pill-name");
  if (pill && name) {
    name.textContent = h.name;
    pill.hidden = false;
  }
}

export function isSearchPinShown(): boolean {
  return pinned !== null;
}
export function clearSearchPin(): void {
  marker?.remove();
  marker = null;
  pinned = null;
  const pill = document.getElementById("search-pill");
  if (pill) pill.hidden = true;
}

/** Keep the map for camera moves; wire the pill's two buttons. */
export function wireSearch(m: MlMap): void {
  map = m;
  const name = document.getElementById("search-pill-name");
  const x = document.getElementById("search-pill-x");
  if (name) name.onclick = () => pinned && goTo(pinned);
  if (x) x.onclick = clearSearchPin;
}

// ---------- panel ----------

const esc = (s: string) =>
  s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
const I = (paths: string) =>
  `<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths}</svg>`;
/** One glyph per nomenclature group (plus addresses). */
const GLYPH: Record<string, string> = {
  Transport: I('<path d="M6 21 9.5 3M18 21 14.5 3"/><path d="M12 6v2.5M12 11.5v2.5M12 17v2.5"/>'),
  "Natural Feature": I('<path d="M3 19 9 8l3.5 6L15 10l6 9Z"/>'),
  Cultural: I('<path d="M4 20V10l8-6 8 6v10Z"/><path d="M10 20v-6h4v6"/>'),
  Reserve: I('<path d="M12 3 6 12h3.5L6 18h12l-3.5-6H18Z"/><path d="M12 18v3"/>'),
  Recreation: I('<path d="M6 21V4"/><path d="M6 4h11l-2 4 2 4H6"/>'),
  Infrastructure: I('<path d="M8 21 12 3l4 18"/><path d="M9.5 14h5M8.5 18h7M6 21h12"/>'),
  Property: I('<path d="M4 11 12 4l8 7"/><path d="M6 10v10h12V10"/><path d="M10 20v-5h4v5"/>'),
  Address: I('<path d="M12 21s-6-5.5-6-11a6 6 0 0 1 12 0c0 5.5-6 11-6 11Z"/><circle cx="12" cy="10" r="2"/>'),
};
const HINT = "Type at least two letters — try ‘eliz st hob’, ‘kunanyi’ or ‘12 elizabeth st’";

const rowHtml = (h: Hit, i: number) =>
  `<button type="button" class="sr-row" role="option" id="sr-opt-${i}" data-i="${i}" aria-selected="false">${
    GLYPH[h.group] ?? GLYPH.Address
  }<span class="sr-text"><b>${esc(h.name)}</b><small>${esc(h.meta)}</small></span>${
    h.km == null ? "" : `<span class="sr-km">${fmtKm(h.km)}</span>`
  }</button>`;

// Reopening restores the last query and its hits.
let lastQuery = "";
let lastNorm: string | null = null;

/** Called synchronously from the toolbar tap: iOS raises the keyboard only
 * for a focus() inside the gesture's own task — never await before it. */
export function openSearch(): void {
  const el = openPanel(
    `<form class="sr-form" role="search"><input id="sr-input" type="search" placeholder="Place, street or address…" enterkeyhint="search" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" aria-label="Search place names" aria-controls="sr-list" aria-autocomplete="list"></form>
    <div id="sr-list" role="listbox" aria-label="Matches"></div>
    <p class="sr-foot muted" title="${esc(ATTRIBUTION_NAMES)}; ${esc(ATTRIBUTION_ADDRESSES)}">Names and addresses from theLIST © State of Tasmania (CC BY 3.0 AU)</p>`,
    "search",
  );
  const inner = el.querySelector<HTMLElement>(".panel-inner")!;
  const form = el.querySelector<HTMLFormElement>(".sr-form")!;
  const input = el.querySelector<HTMLInputElement>("#sr-input")!;
  const list = el.querySelector<HTMLElement>("#sr-list")!;
  input.value = lastQuery;
  input.focus();

  let hits: Hit[] = [];
  let active = -1;
  let timer = 0;
  let closed = false;
  let waiting = false; // one load waiter per open, however many keystrokes

  const message = (text: string) => {
    hits = [];
    active = -1;
    input.removeAttribute("aria-activedescendant");
    list.innerHTML = `<p class="sr-empty muted">${esc(text)}</p>`;
  };
  const setActive = (i: number) => {
    active = i;
    const rows = list.querySelectorAll<HTMLElement>(".sr-row");
    rows.forEach((r, j) => {
      r.classList.toggle("on", j === i);
      r.setAttribute("aria-selected", String(j === i));
    });
    const row = rows[i];
    if (row) {
      input.setAttribute("aria-activedescendant", row.id);
      row.scrollIntoView({ block: "nearest" });
    }
  };
  const show = (h: Hit[]) => {
    hits = h;
    if (!h.length) {
      message(`Nothing matches “${input.value.trim()}”`);
      return;
    }
    list.innerHTML = h.map(rowHtml).join("");
    setActive(0);
  };
  const failed = (e: unknown) =>
    message(
      e instanceof Error && e.message === "version"
        ? "Update the app to search"
        : "Place names aren’t available — open the app once while online",
    );
  /** Re-run for the current text. Skips an unchanged normalised query
   * unless forced (reopening: the map centre, hence the distances, moved). */
  const run = (force = false) => {
    // Safari clears a type=search field on Escape and fires `input` after
    // the Escape handler has already closed the panel: never let a late
    // event overwrite the remembered query
    if (closed) return;
    const q = input.value;
    const norm = normalise(q);
    lastQuery = q;
    if (norm.length < 2) {
      lastNorm = null;
      message(HINT);
      return;
    }
    if (!gaz) {
      message("Loading place names…");
      if (!waiting) {
        waiting = true;
        loadIndexes().then(
          () => {
            waiting = false;
            run(true);
          },
          (e) => {
            waiting = false;
            if (!closed) failed(e);
          },
        );
      }
      return;
    }
    if (!force && norm === lastNorm) return;
    lastNorm = norm;
    show(search(gaz, addr, q, map?.getCenter() ?? null));
  };
  const pick = (h: Hit) => {
    closePanel();
    goTo(h);
    setPin(h);
  };

  input.addEventListener("input", () => {
    if (closed) return;
    clearTimeout(timer);
    timer = window.setTimeout(() => run(), 120);
  });
  input.addEventListener("keydown", (e) => {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    e.preventDefault();
    if (hits.length) setActive((active + (e.key === "ArrowDown" ? 1 : -1) + hits.length) % hits.length);
  });
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    clearTimeout(timer);
    run(); // a fast Enter must act on what was typed, not the debounced view
    const h = hits[active] ?? hits[0];
    if (h) pick(h);
  });
  list.addEventListener("click", (e) => {
    const row = (e.target as HTMLElement).closest<HTMLElement>(".sr-row");
    const h = row && hits[Number(row.dataset.i)];
    if (h) pick(h);
  });
  // Phones: the sheet is the full layout viewport, which iOS does not shrink
  // for the keyboard — follow the visual viewport so the list never hides
  // under it (enhancement only; the top-anchored input works regardless).
  // Wide layouts keep the CSS card height unless an on-screen keyboard (an
  // iPad without its keyboard case: visual viewport well short of the
  // layout viewport) would otherwise cover the 60vh list.
  const vv = window.visualViewport;
  if (vv) {
    const fit = () => {
      const keyboard = window.innerHeight - vv.height > 120;
      if (!matchMedia("(min-width: 700px)").matches) inner.style.height = `${vv.height}px`;
      else if (keyboard) inner.style.height = `${vv.height - inner.getBoundingClientRect().top - 10}px`;
      else inner.style.height = "";
    };
    vv.addEventListener("resize", fit);
    onPanelClose(() => vv.removeEventListener("resize", fit));
  }
  onPanelClose(() => {
    closed = true;
    clearTimeout(timer);
  });
  run(true);
}

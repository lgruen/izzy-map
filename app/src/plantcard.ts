// The Plants section of a TASVEG community card and the plant sheet it
// opens (both inside #sheet; details.ts does the navigation). Plant names
// may hold non-Latin-1 characters — fine here (DOM), never in MapLibre text.
import { ATTRIBUTION_PLANTS, ATTRIBUTION_RECORDS, UN_BASE } from "./config";
import { type Entry, type Group, type Nearby, type Plant, loadPlantData, noPhotoBox, photoBox } from "./plants";

/** First letter up for a common name used as a headline (UN spells them
 * lowercase, the Tasmanian convention — list rows keep it that way). */
const headline = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

/** What a list entry was tapped in: the community and the point. */
export interface PlantCtx {
  code: string;
  near: Nearby | null;
  /** species key -> recorded sites inside the community */
  inCommunity: Map<string, number>;
}

const esc = (s: string) =>
  s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

/** Plants section expanded (remembered for the session, not persisted). */
let expanded = false;
/** Entries shown before "Show all (n)". */
const FIRST = 6;
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

/** A scientific name in italics, with the rank words (subsp., var., f.,
 * the hybrid sign) upright as botanical convention has it. */
export function sciName(name: string): string {
  return name
    .split(/(\s+(?:subsp\.|var\.|f\.|ssp\.|×|x)\s+)/)
    .map((part, i) => (i % 2 ? esc(part) : `<i>${esc(part)}</i>`))
    .join("");
}

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls: string, html = ""): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (html) e.innerHTML = html;
  return e;
}

const subline = (p: Plant) => [p.common, p.forms.join(", ")].filter(Boolean).join(" · ");

function row(e: Entry, open: (e: Entry, from: HTMLElement) => void): HTMLElement {
  const b = el("button", "pl-row");
  b.type = "button";
  b.dataset.key = e.key;
  const ph = e.plant.photos[0];
  if (ph) b.append(photoBox(ph, "thumb", ""));
  else b.append(noPhotoBox());
  if (e.group) {
    // a broad-sense name: one entry that opens the list of its species
    b.classList.add("pl-group");
    const g = e.group;
    b.append(el("span", "pl-text", `<span class="pl-sci">${g.common ? esc(g.common) : sciName(g.key)}</span><small>${
      sciName(g.key)} (broad sense) · <span class="nw">${g.size} species</span></small>`));
    b.append(el("span", "pl-chev", "›"));
  } else
    b.append(el("span", "pl-text", `<span class="pl-sci">${sciName(e.key)}</span>${
      subline(e.plant) ? `<small>${esc(subline(e.plant))}</small>` : ""
    }`));
  if (e.sites != null) {
    const n = el("span", "pl-n", String(e.sites));
    n.title = `${e.sites} site${e.sites === 1 ? "" : "s"} with a record`;
    b.append(n);
  }
  b.onclick = () => open(e, b);
  return b;
}

function list(kind: string, title: string, sub: string, entries: Entry[], open: (e: Entry, from: HTMLElement) => void): HTMLElement {
  const box = el("div", "pl-list");
  box.dataset.list = kind;
  box.append(el("h4", "pl-h4", esc(title)), el("p", "pl-sub", sub));
  const rows = el("div", "pl-rows");
  for (const e of entries.slice(0, FIRST)) rows.append(row(e, open));
  box.append(rows);
  if (entries.length > FIRST) {
    const more = el("button", "pl-more", `Show all (${entries.length})`);
    more.type = "button";
    more.onclick = () => {
      for (const e of entries.slice(FIRST)) rows.append(row(e, open));
      more.remove();
    };
    box.append(more);
  }
  return box;
}

/** Fill the (initially hidden) Plants section of a community card. The
 * card is on screen already; the data arrives from a lazy chunk, by which
 * time the card may have been replaced — then nothing happens. A code with
 * no entries at all (water, urban, …) keeps the section hidden. */
export async function fillPlants(
  section: HTMLElement,
  code: string,
  at: { lng: number; lat: number } | null,
  open: (e: Entry, ctx: PlantCtx, from: HTMLElement) => void,
): Promise<void> {
  let data;
  try {
    data = await loadPlantData();
  } catch {
    if (!section.isConnected) return;
    section.innerHTML = `<h3 class="pl-h">Plants</h3><p class="pl-sub">The plant lists couldn't load —
      close IzzyMap completely and open it again.</p>`;
    section.dataset.state = "error";
    section.hidden = false;
    return;
  }
  if (!section.isConnected) return;
  const named = data.named(code);
  const often = data.often(code);
  // The grid (2 MB) may still be loading: the named + recorded lists render
  // now, the nearby list joins when it resolves (or says it couldn't load).
  type NearResult = { near: Nearby | null; failed: boolean };
  const nearP: Promise<NearResult> | null = at
    ? data.nearby(at.lng, at.lat).then(
        (near) => ({ near, failed: false }),
        () => ({ near: null, failed: true }), // the next card tries the grid again
      )
    : null;
  let early: NearResult | null = null;
  if (!named.length && !often.entries.length) {
    // nothing else to show: whether a section appears at all depends on it
    early = nearP ? await nearP : null;
    if (!section.isConnected) return;
    if (!early?.near?.entries.length && !early?.failed) {
      section.dataset.state = "empty";
      return;
    }
  }
  const ctx: PlantCtx = { code, near: null, inCommunity: data.communitySites(code) };
  const go = (e: Entry, from: HTMLElement) => open(e, ctx, from);
  const body = el("div", "pl-body");
  if (named.length)
    body.append(list("named", "Named in the description", "Species the <i>From Forest to Fjaeldmark</i> account of this community mentions.", named, go));
  if (often.entries.length) {
    const n = often.sites;
    const sitesText = n != null ? `${n.toLocaleString()} site${n === 1 ? "" : "s"}` : null;
    // few records (< 30 sites): a plain tally of everything recorded there,
    // not an indicator ranking — say so, but show it (rare communities are
    // the interesting ones)
    body.append(often.tally
      ? list("often", "Recorded in this community",
          `<span class="pl-few">few records${sitesText ? ` (${sitesText})` : ""}</span> — every species with an Atlas of Living Australia record inside mapped ${esc(code)}, most sites first.`,
          often.entries, go)
      : list("often", "Often recorded in this community",
          `Species with Atlas of Living Australia records inside mapped ${esc(code)} across the state${sitesText ? ` (${sitesText} recorded)` : ""}, most characteristic first. The number counts ~100 m sites with a record.`,
          often.entries, go));
  }
  const credit = el("p", "pl-credit", `${esc(ATTRIBUTION_PLANTS)}. ${esc(ATTRIBUTION_RECORDS)}.
    “Named” lists from <i>From Forest to Fjaeldmark</i>.`);
  body.append(credit);
  // One summary row that expands in place: the card stays a compact label,
  // so the map beside/above it stays tappable (comparing communities is the
  // core gesture). Once opened, later cards this session open expanded.
  const parts = [named.length ? `${named.length} named` : "", often.entries.length ? `${often.entries.length} in records` : ""];
  const toggle = el("button", "pl-toggle", `<span class="pl-h">Plants</span><small></small><span class="pl-chev" aria-hidden="true">›</span>`);
  toggle.type = "button";
  const summary = (nearPart: string) => {
    toggle.querySelector("small")!.textContent = [...parts, nearPart].filter(Boolean).join(" · ");
  };
  summary(nearP ? "nearby…" : "");
  const setOpen = (on: boolean) => {
    expanded = on;
    body.hidden = !on;
    toggle.setAttribute("aria-expanded", String(on));
    section.classList.toggle("open", on);
    section.closest("#sheet")?.classList.toggle("plants-open", on); // ≥ 700 px: the card grows
  };
  toggle.onclick = () => setOpen(!expanded);
  section.replaceChildren(toggle, body);
  setOpen(expanded);
  section.hidden = false;

  const addNear = ({ near, failed }: NearResult) => {
    if (!section.isConnected) return;
    ctx.near = near;
    if (near?.entries.length) {
      // only species with a profile: the count matches the rows
      body.insertBefore(list("near", "Recorded near here",
        `${near.entries.length.toLocaleString()} species, ${near.shownTotal.toLocaleString()} site records within roughly 1–1.5 km — what people happened to record, not a full survey.`,
        near.entries, go), credit);
      summary(`${near.entries.length} nearby`);
    } else if (failed) {
      const box = el("div", "pl-list", `<h4 class="pl-h4">Recorded near here</h4>
        <p class="pl-sub">Couldn't load the nearby records — tap the map again to retry.</p>`);
      box.dataset.list = "near-failed";
      body.insertBefore(box, credit);
      summary("nearby unavailable");
    } else summary("");
    section.dataset.state = "ready";
  };
  if (early) addNear(early);
  else if (nearP) addNear(await nearP);
  else section.dataset.state = "ready";
}

/** Sticky Back / × bar of a view stacked on the community card. */
function topBar(o: { back: string; onBack: () => void; onClose: () => void }): HTMLElement {
  const top = el("div", "pl-top");
  const back = el("button", "pl-back", `<span aria-hidden="true">‹</span> ${esc(o.back)}`);
  back.type = "button";
  back.onclick = o.onBack;
  const close = el("button", "pl-close", "×");
  close.type = "button";
  close.setAttribute("aria-label", "Close");
  close.onclick = o.onClose;
  top.append(back, close);
  return top;
}

/** A group (broad-sense name) opened from the card: its species as normal
 * entries, ordered by local evidence — recorded in this community, then
 * recorded near the tapped point, then the rest alphabetically — under
 * headings that carry the site counts, so the order explains itself. */
export function groupView(
  g: Group,
  ctx: PlantCtx,
  o: { back: string; onOpen: (e: Entry, from: HTMLElement) => void; onBack: () => void; onClose: () => void },
): HTMLElement {
  const v = el("div", "group-view");
  v.dataset.group = g.key;
  v.append(topBar(o));
  const head = el("div", "pl-head");
  head.append(el("div", "pl-name", g.common ? esc(headline(g.common)) : sciName(g.key)));
  head.append(el("div", "pl-common", `<span>${sciName(g.key)} (broad sense) · <span class="nw">${g.size} species</span></span>`));
  v.append(head);
  const here: Entry[] = [];
  const near: Entry[] = [];
  const rest: Entry[] = [];
  for (const m of g.members) {
    const c = ctx.inCommunity.get(m.key);
    const n = ctx.near?.sites.get(m.key);
    if (c) here.push({ ...m, sites: c });
    else if (n) near.push({ ...m, sites: n });
    else rest.push({ ...m, sites: undefined });
  }
  here.sort((a, b) => b.sites! - a.sites! || a.key.localeCompare(b.key));
  near.sort((a, b) => b.sites! - a.sites! || a.key.localeCompare(b.key));
  rest.sort((a, b) => a.key.localeCompare(b.key));
  if (here.length)
    v.append(list("g-here", `Recorded in ${ctx.code}`, "Sites (~100 m) with a record inside this community.", here, o.onOpen));
  if (near.length)
    v.append(list("g-near", "Recorded near here", "Sites with a record within roughly 1–1.5 km.", near, o.onOpen));
  if (rest.length)
    v.append(list("g-rest", here.length || near.length ? "Other species in the group" : "Species in the group",
      "No records in this community or nearby.", rest, o.onOpen));
  v.insertAdjacentHTML(
    "beforeend",
    `<p class="pl-credit">The description names the group as a whole; the Understorey Network profiles its species separately.</p>`,
  );
  return v;
}

/** The plant sheet: photos, names, facts, flowering months, habitats and a
 * link to the profile on the Understorey Network site. */
export function plantView(
  plant: Plant,
  o: { back: string; nearbySites?: number; onBack: () => void; onClose: () => void },
): HTMLElement {
  const v = el("div", "plant-view");
  v.dataset.plant = String(plant.id);
  v.append(topBar(o));

  if (plant.photos.length) {
    const strip = el("div", `pl-photos${plant.photos.length > 1 ? " multi" : ""}`);
    for (const ph of plant.photos) {
      const fig = el("figure", "pl-fig");
      fig.append(photoBox(ph, "large", plant.name));
      fig.append(el("figcaption", "", `Photo: ${ph.credit ? esc(ph.credit) + " · " : ""}Understorey Network`));
      strip.append(fig);
    }
    v.append(strip);
    if (plant.photos.length > 1) v.append(el("p", "pl-swipe", `${plant.photos.length} photos — swipe`));
  }

  const head = el("div", "pl-head");
  head.append(el("div", "pl-name", sciName(plant.name)));
  const common = [
    plant.common ? `<span>${esc(headline(plant.common))}</span>` : "",
    plant.status ? `<span class="pl-status" data-status="${esc(plant.status.toLowerCase())}">${esc(plant.status)}</span>` : "",
  ].join(" ");
  if (common.trim()) head.append(el("div", "pl-common", common));
  v.append(head);

  const kv = (k: string, val: string | null | undefined) =>
    val && val.trim() ? `<div class="kv"><span>${esc(k)}</span><span>${esc(val)}</span></div>` : "";
  v.insertAdjacentHTML(
    "beforeend",
    kv("Family", plant.family) +
      kv("Growth form", plant.forms.join(", ")) +
      kv("Height", plant.height ? `${plant.height} m` : null) +
      kv("Recorded near here", o.nearbySites ? `${o.nearbySites} site${o.nearbySites === 1 ? "" : "s"}` : null),
  );

  if (plant.flowering.length) {
    const on = new Set(plant.flowering);
    const label = `Flowers in ${plant.flowering.map((m) => MONTHS[m - 1]).filter(Boolean).join(", ")}`;
    v.insertAdjacentHTML(
      "beforeend",
      `<div class="pl-flowering"><span class="pl-label">Flowering</span><div class="pl-months" role="img" aria-label="${esc(label)}">${MONTHS.map(
        (m, i) => `<span class="${on.has(i + 1) ? "on" : ""}">${m[0]}</span>`,
      ).join("")}</div></div>`,
    );
  }

  const facts = (
    [
      ["Form", plant.form],
      ["Flowers", plant.flowers],
      ["Fruit", plant.fruit],
      ["Habitat", plant.habitat],
      ["Notes", plant.notes],
    ] as const
  ).filter(([, t]) => t && t.trim());
  if (facts.length)
    v.insertAdjacentHTML(
      "beforeend",
      `<dl class="pl-facts">${facts.map(([k, t]) => `<dt>${k}</dt><dd>${esc(t!)}</dd>`).join("")}</dl>`,
    );
  if (plant.habitats.length)
    v.insertAdjacentHTML(
      "beforeend",
      `<div class="pl-tags" aria-label="Habitats">${plant.habitats.map((h) => `<span>${esc(h)}</span>`).join("")}</div>`,
    );
  v.insertAdjacentHTML(
    "beforeend",
    `<a class="pl-link" href="${esc(`${UN_BASE}/plant/${encodeURIComponent(plant.slug)}`)}" target="_blank" rel="noopener">Understorey Network page ↗</a>
     <p class="pl-credit">${esc(ATTRIBUTION_PLANTS)}.</p>`,
  );
  return v;
}

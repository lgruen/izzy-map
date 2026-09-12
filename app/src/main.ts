import {
  GeolocateControl,
  type GeolocateErrorEvent,
  Map as MlMap,
  NavigationControl,
  ScaleControl,
  setWorkerUrl,
} from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";
// MapLibre 6 is ESM-only and spawns its worker from a URL it derives from
// import.meta.url at runtime — inside a Vite bundle that resolves to a file
// that does not exist, so the map silently gets no worker (vector tiles
// never render) while the dev-server tests pass. `?worker&url` makes Vite
// bundle the worker with its sibling maplibre-gl-shared.mjs and emit it as
// a hashed asset, which the service worker precaches for offline use.
// scripts/check-dist.mjs asserts the asset is in the build.
import maplibreWorkerUrl from "maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url";
import "./app.css";

setWorkerUrl(maplibreWorkerUrl);
import { HOME, RASTER_KEYS, SEASON_KEYS, seasonLabel } from "./config";
import { bindMap, registerProtocols, refreshArchives, status } from "./protocol";
import {
  BASES,
  DEFAULT_STATE,
  OVERLAYS,
  STRENGTHS,
  applyLayerState,
  buildStyle,
  type LayerState,
  type OverlayMode,
} from "./style";
import { clearDetails, wireDetails } from "./details";
import { wireCoordReadout } from "./mga";
import {
  closePanel,
  isPanelOpen,
  openAbout,
  openDownloads,
  openLayers,
  openLegend,
  setLayerAccess,
  showPill,
} from "./ui";
import { closePdfViewer, isPdfOpen } from "./viewer";
import { ensurePersistence } from "./storage";
import { clearSearchPin, isSearchPinShown, loadIndexes, openSearch, wireSearch } from "./search";

/** Restore the Layers-sheet state; migrate the pre-sheet keys once. */
function loadState(): LayerState {
  const s: LayerState = { ...DEFAULT_STATE };
  try {
    const raw = localStorage.getItem("layerState");
    if (raw) {
      const p = JSON.parse(raw) as Partial<LayerState>;
      if (BASES.includes(p.base as never)) s.base = p.base!;
      if (typeof p.cutoff === "number")
        s.cutoff = Math.max(0, Math.min(SEASON_KEYS.length - 1, Math.round(p.cutoff)));
      if (OVERLAYS.includes(p.overlay as never)) s.overlay = p.overlay!;
      if (STRENGTHS.includes(p.strength as never)) s.strength = p.strength!;
      if (typeof p.trees === "boolean") s.trees = p.trees;
      return s;
    }
    const mode = localStorage.getItem("overlayMode");
    if (OVERLAYS.includes(mode as never)) s.overlay = mode as OverlayMode;
    if (localStorage.getItem("overlayOpacity") === "0.25") s.strength = "light";
  } catch {
    /* private mode — defaults */
  }
  return s;
}

/** Human name of what a state shows, for the transient pill. */
export function describeBase(s: LayerState): string {
  return s.base === "topo" ? "Topographic map"
    : s.base === "tasmap" ? "Paper map"
    : s.base === "aerial" ? "Aerial photos"
    : `Aerial photos up to ${seasonLabel(s.cutoff)}`;
}
export function describeOverlay(o: OverlayMode): string {
  return o === "veg" ? "Vegetation" : o === "pre" ? "Pre-1750 vegetation" : o === "geo" ? "Geology" : "Overlay hidden";
}

async function boot(): Promise<void> {
  void ensurePersistence();
  registerProtocols();
  await refreshArchives();

  const state = loadState();
  const saveState = () => {
    try {
      localStorage.setItem("layerState", JSON.stringify(state));
    } catch {
      /* private mode */
    }
  };

  // ?pixels=1: keep the WebGL buffer readable so tests can assert what the
  // base rasters actually painted (costs a little GPU memory; off by default)
  const pixels = new URLSearchParams(location.search).has("pixels");
  const map = new MlMap({
    container: "map",
    style: buildStyle(state, status.rasterLocal),
    center: HOME.center,
    zoom: HOME.zoom,
    maxBounds: [
      [140.0, -46.5],
      [152.0, -37.5],
    ],
    attributionControl: { compact: true },
    canvasContextAttributes: { preserveDrawingBuffer: pixels },
  });

  map.addControl(new NavigationControl({ showCompass: true }), "top-right");
  const geolocate = new GeolocateControl({
    positionOptions: { enableHighAccuracy: true },
    trackUserLocation: true,
    showAccuracyCircle: true,
  });
  map.addControl(geolocate, "top-right");
  map.addControl(new ScaleControl({ unit: "metric" }));

  bindMap(map);

  // Open straight at the GPS position (core requirement). trigger() is a
  // silent no-op until the control's async permission query resolves, so
  // retry until it reports success.
  let locating = false;
  geolocate.on("trackuserlocationstart", () => (locating = true));
  map.on("load", () => {
    const tryTrigger = (n: number) => {
      // stop as soon as tracking is on (a user tap counts — never toggle it off)
      if (locating) return;
      if (!geolocate.trigger() && n < 20) setTimeout(() => tryTrigger(n + 1), 250);
    };
    tryTrigger(0);
  });

  wireDetails(map);
  wireSearch(map);
  wireCoordReadout(map);
  window.__map = map;

  // The compact attribution starts expanded and covers the scale/coords;
  // collapse it once the map settles (CC BY text stays one tap away).
  map.once("idle", () => {
    document
      .querySelector(".maplibregl-ctrl-attrib.maplibregl-compact-show")
      ?.classList.remove("maplibregl-compact-show");
    // warm the search indexes once the map is quiet (the panel retries) —
    // only under a service worker: an uncontrolled first load is precaching
    // them already (double download), and the first search loads on demand
    if (navigator.serviceWorker?.controller) loadIndexes().catch(() => {});
  });

  // Keep the screen awake only while actively following GPS (iOS 18.4+
  // home-screen apps). Unconditional wake lock would flatten the battery on
  // an all-day hike; the geolocate control's tracking state is the natural
  // scope.
  let wakeLock: WakeLockSentinel | null = null;
  let tracking = false;
  let acquiring = false;
  const syncWakeLock = async () => {
    if (acquiring) return;
    acquiring = true;
    try {
      if (tracking && document.visibilityState === "visible" && !wakeLock) {
        wakeLock = await navigator.wakeLock?.request("screen") ?? null;
        wakeLock?.addEventListener("release", () => (wakeLock = null));
      } else if (!tracking && wakeLock) {
        await wakeLock.release();
        wakeLock = null;
      }
    } catch {
      /* not critical */
    } finally {
      acquiring = false;
    }
  };
  geolocate.on("trackuserlocationstart", () => {
    tracking = true;
    void syncWakeLock();
  });
  geolocate.on("trackuserlocationend", () => {
    tracking = false;
    void syncWakeLock();
  });
  document.addEventListener("visibilitychange", () => void syncWakeLock());
  // A failed fix must say so: the control just turns grey, which on a
  // Wi-Fi-only iPad (no GNSS chip) looks like a hang. Permission denials
  // get their own wording. Only a denial (code 1) ends tracking (MapLibre
  // sets the watch OFF without firing trackuserlocationend); a transient
  // "position unavailable" keeps the watch alive and recovers silently, so
  // the wake lock must survive it (review finding: one blip in a gully
  // otherwise let the screen sleep for the rest of the hike). One pill per
  // tracking session — a flaky fix would repaint it every few seconds.
  let gpsPillShown = false;
  geolocate.on("trackuserlocationstart", () => (gpsPillShown = false));
  geolocate.on("error", (e: GeolocateErrorEvent) => {
    if (e.code === 1) {
      tracking = false;
      void syncWakeLock();
    }
    if (gpsPillShown) return;
    gpsPillShown = true;
    showPill(
      e.code === 1
        ? "Location is off for this app — allow it in Settings to follow GPS"
        : "No location fix — the map still works. Wi-Fi-only iPads have no GPS.",
      7000,
    );
  });

  // Layer state -> map. isStyleLoaded() is false during ordinary tile
  // streaming too — the only real precondition is that the style's layers
  // exist. Before first load, defer to the load event; after that, always
  // apply (review H1: bailing here silently dropped taps made while tiles
  // were loading).
  const apply = () => {
    if (!map.getLayer("tasveg-fill")) {
      map.once("load", apply);
      return;
    }
    applyLayerState(map, state, status.rasterLocal);
  };
  map.on("load", apply);

  const ARCHIVE_OF = { veg: "tasveg", pre: "pre1750", geo: "geology" } as const;
  const overlayMissing = () => state.overlay !== "off" && !status.vectorLocal[ARCHIVE_OF[state.overlay]];
  // "Missing" means not on the device — regardless of whether it streams
  // right now (navigator.onLine lies on iOS; the point is the next offline
  // launch). The style keeps the topo map under a non-local base so the
  // screen is never a flat ocean colour, but the user must still be told.
  const baseMissing = () =>
    state.base === "seasons"
      ? !SEASON_KEYS.some((k) => status.rasterLocal[k])
      : !status.rasterLocal[state.base];
  // A restored selection whose archive isn't on the device must announce
  // itself at boot: otherwise an offline launch renders a silently blank
  // layer under a confident label (streams fine while online; the
  // downloads panel fixes it). `status` is the live object refreshArchives
  // mutates, so this stays current after downloads/deletes.
  map.once("load", () => {
    const missing = [
      ...(overlayMissing() ? [describeOverlay(state.overlay)] : []),
      ...(baseMissing() ? [describeBase(state)] : []),
    ];
    if (missing.length) showPill(`${missing.join(" + ")} — not downloaded yet`, 3000);
  });

  setLayerAccess({
    map,
    get: () => state,
    reapply: apply,
    set: (patch) => {
      const overlayChanged = patch.overlay !== undefined && patch.overlay !== state.overlay;
      const treesChanged = patch.trees !== undefined && patch.trees !== state.trees;
      Object.assign(state, patch);
      // a veg answer over a geology map (or vice versa) lies; a tree card
      // must not outlive its dots either — but neither change may take the
      // OTHER kind's card away (details.ts stamps data-kind on #sheet)
      const kind = document.getElementById("sheet")?.dataset.kind;
      if ((overlayChanged && kind !== "tree") || (treesChanged && kind === "tree")) clearDetails();
      saveState();
      apply();
    },
  });

  // Toolbar buttons
  const byId = (id: string) => document.getElementById(id)!;
  byId("btn-search").onclick = () => openSearch(); // synchronous: iOS keyboard needs the gesture
  byId("btn-layers").onclick = () => void openLayers();
  byId("btn-legend").onclick = () => void openLegend();
  byId("btn-downloads").onclick = () => void openDownloads();
  byId("btn-about").onclick = () => void openAbout();
  byId("panel").onclick = (e) => {
    if (e.target === byId("panel")) closePanel();
  };
  // Hardware keyboards (iPad): Escape dismisses the top-most surface.
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    if (!byId("areabar").hidden) byId("areabar-cancel").click();
    else if (isPdfOpen()) closePdfViewer();
    else if (isPanelOpen()) closePanel();
    else if (!byId("sheet").hidden) clearDetails();
    else if (isSearchPinShown()) clearSearchPin();
  });

  // Regaining reception should restore a missing overlay without a relaunch
  // (the explicit re-kick clears remote sources MapLibre marked errored).
  window.addEventListener("online", () => void refreshArchives(true));

  // First-run state: no offline data downloaded yet. Shown regardless of
  // navigator.onLine — a fresh offline launch would otherwise be a blank,
  // unexplained map (and onLine lies on iOS anyway).
  if (!status.vectorLocal.tasveg && !RASTER_KEYS.some((k) => status.rasterLocal[k])) {
    const nudge = byId("nudge");
    nudge.hidden = false;
    byId("nudge-text").textContent = navigator.onLine
      ? "Download maps for offline use"
      : "No maps on this device yet — connect to Wi-Fi, then tap here";
    nudge.onclick = () => {
      nudge.hidden = true;
      void openDownloads();
    };
  }
}

void boot();

// Test hook (harmless in prod): expose map for Playwright checks.
declare global {
  interface Window { __map?: MlMap }
}

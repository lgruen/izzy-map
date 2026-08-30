import maplibregl from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";
import "./app.css";
import { HOME } from "./config";
import { bindMap, registerProtocols, refreshArchives } from "./protocol";
import { buildStyle, type OverlayMode } from "./style";
import { clearDetails, wireDetails } from "./details";
import { wireCoordReadout } from "./mga";
import { openAbout, openDownloads, openLegend, closePanel, setOverlayAccess } from "./ui";
import { ensurePersistence } from "./storage";

async function boot(): Promise<void> {
  void ensurePersistence();
  registerProtocols();
  const status = await refreshArchives();

  // Overlay switcher: Vegetation -> Pre-1750 -> Geology -> Off. Opacity
  // (Full/Light) lives in the legend panel.
  const MODES = ["veg", "pre", "geo", "off"] as const;
  const storedMode = localStorage.getItem("overlayMode");
  let mode: OverlayMode = (MODES as readonly string[]).includes(storedMode ?? "")
    ? (storedMode as OverlayMode)
    : "veg";
  let opacity = Number(localStorage.getItem("overlayOpacity")) === 0.25 ? 0.25 : 0.5;

  const map = new maplibregl.Map({
    container: "map",
    style: buildStyle(mode, opacity),
    center: HOME.center,
    zoom: HOME.zoom,
    maxBounds: [
      [140.0, -46.5],
      [152.0, -37.5],
    ],
    attributionControl: { compact: true },
  });

  map.addControl(new maplibregl.NavigationControl({ showCompass: true }), "top-right");
  const geolocate = new maplibregl.GeolocateControl({
    positionOptions: { enableHighAccuracy: true },
    trackUserLocation: true,
    showAccuracyCircle: true,
  });
  map.addControl(geolocate, "top-right");
  map.addControl(new maplibregl.ScaleControl({ unit: "metric" }));

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
  wireCoordReadout(map);
  window.__map = map;

  // The compact attribution starts expanded and covers the scale/coords;
  // collapse it once the map settles (CC BY text stays one tap away).
  map.once("idle", () => {
    document
      .querySelector(".maplibregl-ctrl-attrib.maplibregl-compact-show")
      ?.classList.remove("maplibregl-compact-show");
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

  // Toolbar buttons
  const byId = (id: string) => document.getElementById(id)!;
  const applyOverlay = () => {
    byId("btn-veg").classList.toggle("off", mode === "off");
    // mode -> icon, keyed by OverlayMode so adding a mode without an icon
    // is a compile error; exactly one icon shows per mode
    const ICON: Record<OverlayMode, string> = {
      veg: ".icon-veg",
      pre: ".icon-pre",
      geo: ".icon-geo",
      off: ".icon-veg",
    };
    for (const sel of new Set(Object.values(ICON)))
      byId("btn-veg").querySelector(sel)!.toggleAttribute("hidden", sel !== ICON[mode]);
    byId("btn-veg").setAttribute(
      "aria-label",
      mode === "veg" ? "Overlay: vegetation — tap for pre-1750 vegetation"
        : mode === "pre" ? "Overlay: pre-1750 vegetation — tap for geology"
        : mode === "geo" ? "Overlay: geology — tap to hide overlays"
        : "Overlays hidden — tap for vegetation",
    );
    // isStyleLoaded() is false during ordinary tile streaming too — the only
    // real precondition is that the style's layers exist. Before first load,
    // defer to the load event; after that, always apply (review H1: bailing
    // here silently dropped switcher taps made while tiles were loading).
    if (!map.getLayer("tasveg-fill")) {
      map.once("load", applyOverlay);
      return;
    }
    for (const l of ["tasveg-fill", "tasveg-outline", "tasveg-label"])
      map.setLayoutProperty(l, "visibility", mode === "veg" ? "visible" : "none");
    for (const l of ["geology-fill", "geology-outline"])
      map.setLayoutProperty(l, "visibility", mode === "geo" ? "visible" : "none");
    map.setLayoutProperty("pre1750-fill", "visibility", mode === "pre" ? "visible" : "none");
    if (mode === "veg") map.setPaintProperty("tasveg-fill", "fill-opacity", opacity);
    if (mode === "geo") map.setPaintProperty("geology-fill", "fill-opacity", opacity);
    if (mode === "pre") map.setPaintProperty("pre1750-fill", "fill-opacity", opacity);
  };
  // Transient pill naming the mode — the icon alone is ambiguous. When the
  // mode's archive isn't on the phone, say so: otherwise an offline switch
  // (or a restored mode at boot) renders a silently blank overlay under a
  // confident label (streams fine while online; the downloads panel fixes
  // it). `status` is the live object refreshArchives mutates, so this stays
  // current after downloads/deletes.
  const ARCHIVE_OF = { veg: "tasveg", pre: "pre1750", geo: "geology" } as const;
  const showModePill = () => {
    const base =
      mode === "veg" ? "Vegetation"
        : mode === "pre" ? "Pre-1750 vegetation"
        : mode === "geo" ? "Geology"
        : "Overlay hidden";
    const pill = byId("mode-pill");
    pill.textContent =
      mode !== "off" && !status.vectorLocal[ARCHIVE_OF[mode]]
        ? `${base} — not downloaded yet`
        : base;
    pill.classList.remove("show");
    void pill.offsetWidth; // restart the animation
    pill.classList.add("show");
  };
  byId("btn-veg").onclick = () => {
    mode = MODES[(MODES.indexOf(mode) + 1) % MODES.length];
    localStorage.setItem("overlayMode", mode);
    clearDetails(); // a veg answer over a geology map (or vice versa) lies
    applyOverlay();
    showModePill();
  };
  map.on("load", applyOverlay);
  // a mode restored from localStorage with no local archive must announce
  // itself at boot too, not only on tap
  if (mode !== "off" && !status.vectorLocal[ARCHIVE_OF[mode]])
    map.once("load", showModePill);
  setOverlayAccess({
    getMode: () => mode,
    getOpacity: () => opacity,
    setOpacity: (v: number) => {
      opacity = v;
      localStorage.setItem("overlayOpacity", String(v));
      applyOverlay();
    },
  });
  byId("btn-legend").onclick = () => void openLegend();
  byId("btn-downloads").onclick = () => void openDownloads();
  byId("btn-about").onclick = () => void openAbout();
  byId("panel").onclick = (e) => {
    if (e.target === byId("panel")) closePanel();
  };

  // Regaining reception should restore a missing overlay without a relaunch
  // (the explicit re-kick clears remote sources MapLibre marked errored).
  window.addEventListener("online", () => void refreshArchives(true));

  // First-run state: no offline data downloaded yet. Shown regardless of
  // navigator.onLine — a fresh offline launch would otherwise be a blank,
  // unexplained map (and onLine lies on iOS anyway).
  if (!status.vectorLocal.tasveg && !status.topoLocal) {
    const nudge = byId("nudge");
    nudge.hidden = false;
    byId("nudge-text").textContent = navigator.onLine
      ? "Download maps for offline use"
      : "No maps on this phone yet — connect to Wi-Fi, then tap here";
    nudge.onclick = () => {
      nudge.hidden = true;
      void openDownloads();
    };
  }
}

void boot();

// Test hook (harmless in prod): expose map for Playwright checks.
declare global {
  interface Window { __map?: maplibregl.Map }
}

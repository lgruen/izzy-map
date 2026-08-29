import maplibregl from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";
import "./app.css";
import { HOME } from "./config";
import { bindMap, registerProtocols, refreshArchives } from "./protocol";
import { buildStyle } from "./style";
import { wireDetails } from "./details";
import { wireCoordReadout } from "./mga";
import { openAbout, openDownloads, openLegend, closePanel } from "./ui";
import { ensurePersistence } from "./storage";

async function boot(): Promise<void> {
  void ensurePersistence();
  registerProtocols();
  const status = await refreshArchives();

  // Vegetation layer cycles: full (50%) -> light (25%) -> off
  const VEG_STATES = [0.5, 0.25, 0] as const;
  const storedVeg = Number(localStorage.getItem("vegState") ?? "0");
  let vegState = Number.isInteger(storedVeg) ? ((storedVeg % VEG_STATES.length) + VEG_STATES.length) % VEG_STATES.length : 0;
  const vegOpacity = VEG_STATES[vegState] || 0.5;
  const vegVisible = VEG_STATES[vegState] > 0;

  const map = new maplibregl.Map({
    container: "map",
    style: buildStyle(vegVisible, vegOpacity),
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
  const applyVegState = () => {
    if (!map.isStyleLoaded() && !map.loaded()) return; // applied again on load
    const opacity = VEG_STATES[vegState];
    const visible = opacity > 0;
    for (const l of ["tasveg-fill", "tasveg-outline", "tasveg-label"])
      map.setLayoutProperty(l, "visibility", visible ? "visible" : "none");
    if (visible) map.setPaintProperty("tasveg-fill", "fill-opacity", opacity);
    byId("btn-veg").classList.toggle("off", !visible);
    byId("btn-veg").classList.toggle("light", opacity === 0.25);
    byId("btn-veg").setAttribute("aria-label",
      opacity === 0.5 ? "Vegetation: full — tap for light" :
      opacity === 0.25 ? "Vegetation: light — tap to hide" :
      "Vegetation: hidden — tap to show");
  };
  byId("btn-veg").onclick = () => {
    vegState = (vegState + 1) % VEG_STATES.length;
    localStorage.setItem("vegState", String(vegState));
    applyVegState();
  };
  map.on("load", applyVegState);
  byId("btn-legend").onclick = () => void openLegend();
  byId("btn-downloads").onclick = () => void openDownloads();
  byId("btn-about").onclick = () => void openAbout();
  byId("panel").onclick = (e) => {
    if (e.target === byId("panel")) closePanel();
  };

  // Regaining reception should restore a missing veg overlay without a
  // relaunch (setUrl re-kick clears the errored source).
  window.addEventListener("online", () => void refreshArchives());

  // First-run state: no offline data downloaded yet. Shown regardless of
  // navigator.onLine — a fresh offline launch would otherwise be a blank,
  // unexplained map (and onLine lies on iOS anyway).
  if (!status.tasvegLocal && !status.topoLocal) {
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

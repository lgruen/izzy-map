import maplibregl from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";
import "./app.css";
import { HOME } from "./config";
import { registerProtocols, refreshArchives } from "./protocol";
import { buildStyle } from "./style";
import { wireDetails } from "./details";
import { wireCoordReadout } from "./mga";
import { openAbout, openDownloads, openLegend, closePanel } from "./ui";
import { ensurePersistence } from "./storage";

async function boot(): Promise<void> {
  void ensurePersistence();
  registerProtocols();
  const status = await refreshArchives();

  const vegOpacity = Number(localStorage.getItem("vegOpacity") ?? "0.5");
  let vegVisible = localStorage.getItem("vegVisible") !== "0";

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

  // Open straight at the GPS position (core requirement).
  map.on("load", () => geolocate.trigger());

  wireDetails(map);
  wireCoordReadout(map);
  window.__map = map;

  // Keep the screen awake while navigating (iOS 18.4+ home-screen apps).
  const requestWakeLock = async () => {
    try {
      await navigator.wakeLock?.request("screen");
    } catch {
      /* not critical */
    }
  };
  void requestWakeLock();
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") void requestWakeLock();
  });

  // Toolbar buttons
  const byId = (id: string) => document.getElementById(id)!;
  byId("btn-veg").onclick = () => {
    vegVisible = !vegVisible;
    localStorage.setItem("vegVisible", vegVisible ? "1" : "0");
    for (const l of ["tasveg-fill", "tasveg-outline", "tasveg-label"])
      map.setLayoutProperty(l, "visibility", vegVisible ? "visible" : "none");
    byId("btn-veg").classList.toggle("off", !vegVisible);
  };
  byId("btn-veg").classList.toggle("off", !vegVisible);
  byId("btn-legend").onclick = () => void openLegend();
  byId("btn-downloads").onclick = () => void openDownloads();
  byId("btn-about").onclick = () => void openAbout();
  byId("panel").onclick = (e) => {
    if (e.target === byId("panel")) closePanel();
  };

  // First-run nudge: no offline data yet and we're online -> point at ⬇.
  if (!status.tasvegLocal && !status.topoLocal && navigator.onLine) {
    const nudge = byId("nudge");
    nudge.hidden = false;
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

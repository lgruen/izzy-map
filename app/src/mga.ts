// GDA94 / MGA zone 55 (EPSG:28355) coordinate readout, matching LISTmap's
// status line. Display-only formatting — everything is stored/rendered in
// Web Mercator; this is a pure function of the map centre.
import proj4 from "proj4";
import type { Map } from "maplibre-gl";

proj4.defs(
  "EPSG:28355",
  "+proj=utm +zone=55 +south +ellps=GRS80 +towgs84=0,0,0,0,0,0,0 +units=m +no_defs",
);

export function wireCoordReadout(map: Map): void {
  const el = document.getElementById("coords")!;
  let showMga = true;
  const update = () => {
    const c = map.getCenter();
    if (showMga) {
      const [e, n] = proj4("EPSG:4326", "EPSG:28355", [c.lng, c.lat]);
      el.textContent = `MGA55 ${Math.round(e)}E ${Math.round(n)}N`;
    } else {
      el.textContent = `${c.lat.toFixed(5)}, ${c.lng.toFixed(5)}`;
    }
  };
  map.on("move", update);
  el.onclick = () => {
    showMga = !showMga;
    update();
  };
  update();
}

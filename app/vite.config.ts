import { createReadStream, statSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { defineConfig, type Plugin } from "vite";
import { VitePWA } from "vite-plugin-pwa";

// Dev-only: serve ../data (pipeline output, gitignored) under /dev-data with
// HTTP Range support, so the pmtiles FetchSource works against local builds.
function devData(): Plugin {
  const dataDir = resolve(__dirname, "../data");
  return {
    name: "izzy-dev-data",
    configureServer(server) {
      server.middlewares.use("/dev-data", (req, res, next) => {
        const file = resolve(dataDir, (req.url ?? "/").replace(/^\/+/, "").split("?")[0]);
        if (!file.startsWith(dataDir) || !existsSync(file)) return next();
        const { size } = statSync(file);
        const range = /bytes=(\d+)-(\d*)/.exec(req.headers.range ?? "");
        res.setHeader("Accept-Ranges", "bytes");
        if (range) {
          const start = Number(range[1]);
          const end = range[2] ? Math.min(Number(range[2]), size - 1) : size - 1;
          res.writeHead(206, {
            "Content-Range": `bytes ${start}-${end}/${size}`,
            "Content-Length": end - start + 1,
          });
          createReadStream(file, { start, end }).pipe(res);
        } else {
          res.writeHead(200, { "Content-Length": size });
          createReadStream(file).pipe(res);
        }
      });
    },
  };
}

// Served from https://lgruen.github.io/izzy-map/ — relative base keeps
// dev/preview/Pages all working.
export default defineConfig({
  base: "./",
  build: { target: "es2022", sourcemap: true },
  plugins: [
    devData(),
    VitePWA({
      registerType: "autoUpdate",
      // Precache the app shell + glyphs only. Map data (PMTiles archives,
      // F2F PDFs) lives in OPFS and must NEVER go through the SW cache.
      workbox: {
        globPatterns: ["**/*.{js,css,html,png,svg,pbf,woff2}"],
        navigateFallback: "index.html",
        // tile/archive requests bypass the SW entirely
        runtimeCaching: [],
      },
      manifest: {
        name: "IzzyMap",
        short_name: "IzzyMap",
        description: "Offline Tasmania vegetation + topo map",
        display: "standalone",
        orientation: "portrait",
        theme_color: "#2d5f3f",
        background_color: "#f5f2ea",
        icons: [
          { src: "icons/icon-192.png", sizes: "192x192", type: "image/png" },
          { src: "icons/icon-512.png", sizes: "512x512", type: "image/png" },
          { src: "icons/maskable-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
        ],
      },
    }),
  ],
});

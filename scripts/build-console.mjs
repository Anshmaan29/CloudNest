import { build } from "esbuild";
import { mkdir, copyFile, rm } from "node:fs/promises";
await rm("web/dist", { recursive: true, force: true });
await Promise.all([
  mkdir("web/dist", { recursive: true }),
  mkdir("build", { recursive: true }),
]);
await Promise.all([
  build({
    entryPoints: ["web/console/console.ts"],
    outdir: "web/dist",
    entryNames: "console",
    chunkNames: "chunks/[name]-[hash]",
    bundle: true,
    splitting: true,
    format: "esm",
    target: ["safari17", "chrome120"],
    minify: true,
    legalComments: "linked",
    metafile: true,
  }).then(async (result) => {
    const { writeFile } = await import("node:fs/promises");
    await writeFile(
      "build/console-manifest.json",
      JSON.stringify(result.metafile, null, 2),
    );
  }),
  copyFile("web/console/index.html", "web/dist/index.html"),
  copyFile("web/console/console.css", "web/dist/console.css"),
]);
console.log(
  "Built the self-hosted Brain console. Three.js is a separate lazy-loaded chunk.",
);

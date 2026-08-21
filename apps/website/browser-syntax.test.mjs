import assert from "node:assert/strict";
import { readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import test from "node:test";

test("production browser modules use valid JavaScript syntax", () => {
  const directory = new URL(".", import.meta.url);
  const modulePaths = readdirSync(directory, { withFileTypes: true })
    .filter((entry) =>
      entry.isFile() &&
      (entry.name.endsWith(".js") || entry.name.endsWith(".mjs")) &&
      !entry.name.endsWith(".test.mjs"))
    .map((entry) => fileURLToPath(new URL(entry.name, directory)));
  const parser = `
    import { readFileSync } from "node:fs";
    import { SourceTextModule } from "node:vm";
    for (const modulePath of ${JSON.stringify(modulePaths)}) {
      new SourceTextModule(readFileSync(modulePath, "utf8"), { identifier: modulePath });
    }
  `;
  const result = spawnSync(
    process.execPath,
    ["--experimental-vm-modules", "--input-type=module", "--eval", parser],
    { encoding: "utf8" },
  );

  assert.equal(result.status, 0, result.stderr || result.stdout);
});

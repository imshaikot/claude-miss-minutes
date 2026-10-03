import { strict as assert } from "node:assert";
import { mkdirSync, mkdtempSync as mkdtempRaw, existsSync, realpathSync, writeFileSync, chmodSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { chunks, encodePCM, npmCommand, pruneForeignBinaries } from "../miss-minutes-voice.mjs";

// macOS temp folders sit behind a /var → /private/var symlink.
const mkdtempSync = (prefix) => realpathSync(mkdtempRaw(prefix));

test("short sentences are read whole", () => {
  assert.deepEqual(chunks("  Well hey   there, sugar!  "), ["Well hey there, sugar!"]);
  assert.deepEqual(chunks(""), []);
});

test("long sentences split at the most natural break", () => {
  const text = "First we wind the clock, then we set the hands, and finally we listen to it tick. " +
    "After that, the whole timeline is ours to keep tidy for as long as anyone needs it to be.";
  const pieces = chunks(text, 100);
  assert.ok(pieces.every((p) => p.length <= 100), pieces.join(" | "));
  assert.equal(pieces[0], "First we wind the clock, then we set the hands, and finally we listen to it tick.");
  assert.equal(pieces.join(" "), text);
});

test("text with no breaks at all is still cut", () => {
  const pieces = chunks("x".repeat(250), 100);
  assert.deepEqual(pieces.map((p) => p.length), [100, 100, 50]);
});

test("PCM goes out as little-endian float32", () => {
  const samples = new Float32Array([0, 0.5, -1]);
  const bytes = Buffer.from(encodePCM(samples), "base64");
  assert.equal(bytes.length, 12);
  assert.equal(bytes.readFloatLE(4), 0.5);
  assert.equal(bytes.readFloatLE(8), -1);
});

test("npm runs through this node when it is a node script", () => {
  const dir = mkdtempSync(join(tmpdir(), "mm-npm-"));
  const cli = join(dir, "npm-cli.js");
  writeFileSync(cli, "#!/usr/bin/env node\nrequire('x')\n");
  symlinkSync(cli, join(dir, "npm"));
  assert.deepEqual(npmCommand(join(dir, "node"), ""), [join(dir, "node"), [cli]]);

  const shim = mkdtempSync(join(tmpdir(), "mm-shim-"));
  writeFileSync(join(shim, "npm"), "\x7fELF-ish binary");
  chmodSync(join(shim, "npm"), 0o755);
  assert.deepEqual(npmCommand("/nowhere/node", shim), [join(shim, "npm"), []]);
  assert.deepEqual(npmCommand("/nowhere/node", ""), ["npm", []]);
});

test("only this machine's ONNX Runtime binaries are kept", () => {
  const home = mkdtempSync(join(tmpdir(), "mm-prune-"));
  const bin = join(home, "node_modules", "onnxruntime-node", "bin", "napi-v3");
  for (const dir of ["darwin/arm64", "darwin/x64", "linux/x64", "win32/x64"]) mkdirSync(join(bin, dir), { recursive: true });
  pruneForeignBinaries(home, "darwin", "arm64");
  assert.ok(existsSync(join(bin, "darwin/arm64")));
  assert.ok(!existsSync(join(bin, "darwin/x64")));
  assert.ok(!existsSync(join(bin, "linux")));
  assert.ok(!existsSync(join(bin, "win32")));
  pruneForeignBinaries(mkdtempSync(join(tmpdir(), "mm-empty-"))); // nothing installed: no-op
});

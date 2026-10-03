#!/usr/bin/env node
// Miss Minutes' neural voice: Kokoro-82M (Apache-2.0) running on this Mac
// through kokoro-js and ONNX Runtime. Nothing is bundled with the app: the
// packages and the model are downloaded once, on request, into a folder the
// app chooses. After that it runs offline.
//
//   node miss-minutes-voice.mjs install --home DIR
//     npm packages + model into DIR. Progress on stdout as JSON lines:
//     {"type":"progress","stage":"packages"|"model","fraction":0..1}, then
//     {"type":"installed"} or {"type":"error","message"}.
//
//   node miss-minutes-voice.mjs serve --home DIR
//     stdin, one JSON object per line:
//       {"type":"speak","id":7,"text":"…","voice":"af_heart","speed":1.05}
//       {"type":"cancel"}                       drop everything not yet spoken
//     stdout, one JSON object per line:
//       {"type":"ready"}
//       {"type":"audio","id":7,"rate":24000,"pcm":"<base64 float32 LE mono>"}
//       {"type":"done","id":7}
//       {"type":"error","id":7,"message":"…"}   (no id: fatal, the process exits)

import { spawn } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, openSync, readFileSync, readSync, closeSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { delimiter, dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath, pathToFileURL } from "node:url";

export const MODEL = "onnx-community/Kokoro-82M-v1.0-ONNX";
export const DTYPE = "q8";
/// Bump when an existing install must be redone (new packages or model).
export const SETUP_VERSION = 1;
const HERE = dirname(fileURLToPath(import.meta.url));
const SAMPLE_RATE = 24000;

/// Resolves once the line is handed to the pipe. Inference keeps the event loop
/// too busy to flush large writes on its own, so audio is awaited before the
/// next sentence starts.
function send(message) {
  return new Promise((resolve) => process.stdout.write(JSON.stringify(message) + "\n", resolve));
}

// stdout carries the protocol; libraries' chatter goes to stderr.
for (const name of ["log", "info", "debug", "table"]) console[name] = (...args) => console.error(...args);

// MARK: Text

/// Kokoro reads at most ~510 phonemes at once, and its memory grows with the
/// longest piece it has read, so long sentences are split at the most natural
/// break that keeps each piece under `max` characters.
export function chunks(text, max = 160) {
  const pieces = [];
  let rest = text.replace(/\s+/g, " ").trim();
  while (rest.length > max) {
    const window = rest.slice(0, max);
    let cut = -1;
    for (const pattern of [/[.!?;:…](?=\s)/g, /[,—–)](?=\s)/g, /\s/g]) {
      for (const match of window.matchAll(pattern)) if (match.index > max / 3) cut = match.index + 1;
      if (cut > 0) break;
    }
    if (cut <= 0) cut = max;
    pieces.push(rest.slice(0, cut).trim());
    rest = rest.slice(cut).trim();
  }
  if (rest) pieces.push(rest);
  return pieces;
}

export function encodePCM(samples) {
  return Buffer.from(samples.buffer, samples.byteOffset, samples.byteLength).toString("base64");
}

// MARK: Install

/// npm's own CLI script next to this node, run with this node, so a GUI app's
/// thin PATH doesn't matter. Falls back to whatever `npm` is on PATH.
export function npmCommand(execPath = process.execPath, path = process.env.PATH ?? "") {
  const dirs = [dirname(execPath), ...path.split(delimiter)].filter(Boolean);
  for (const dir of dirs) {
    const candidate = join(dir, "npm");
    if (!existsSync(candidate)) continue;
    const real = realpathSync(candidate);
    return isNodeScript(real) ? [execPath, [real]] : [real, []];
  }
  return ["npm", []];
}

function isNodeScript(file) {
  try {
    const fd = openSync(file, "r");
    const head = Buffer.alloc(64);
    readSync(fd, head, 0, 64, 0);
    closeSync(fd);
    const line = head.toString("utf8").split("\n")[0];
    return line.startsWith("#!") && line.includes("node");
  } catch {
    return false;
  }
}

let installer = null;

function run(command, args, cwd) {
  // Packages' install scripts call `node` through `sh`; a GUI app's PATH may not have it.
  const PATH = [dirname(process.execPath), process.env.PATH].filter(Boolean).join(delimiter);
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, env: { ...process.env, PATH }, stdio: ["ignore", "ignore", "pipe"] });
    installer = child;
    let tail = "";
    child.stderr.on("data", (d) => { tail = (tail + d).slice(-2000); });
    child.on("error", reject);
    child.on("exit", (code) => code === 0 ? resolve() : reject(new Error(`npm failed (exit ${code}): ${tail.trim().split("\n").slice(-3).join(" ")}`)));
  });
}

/// ONNX Runtime ships native binaries for every OS and CPU; keep only ours.
export function pruneForeignBinaries(home, platform = process.platform, arch = process.arch) {
  const root = join(home, "node_modules", "onnxruntime-node", "bin");
  if (!existsSync(root)) return;
  for (const napi of readdirSync(root)) {
    for (const os of readdirSync(join(root, napi))) {
      const osDir = join(root, napi, os);
      if (os !== platform) { rmSync(osDir, { recursive: true, force: true }); continue; }
      for (const cpu of readdirSync(osDir)) if (cpu !== arch) rmSync(join(osDir, cpu), { recursive: true, force: true });
    }
  }
}

async function install(home) {
  // Cancelled from the app: take npm down too, or it keeps writing into a
  // folder the app is deleting. Then die by the signal itself, which skips
  // ONNX Runtime's native teardown (see serve).
  process.once("SIGTERM", () => {
    installer?.kill("SIGTERM");
    process.kill(process.pid, "SIGTERM");
  });
  mkdirSync(home, { recursive: true });
  rmSync(join(home, "installed.json"), { force: true });
  for (const file of ["package.json", "package-lock.json"]) copyFileSync(join(HERE, file), join(home, file));
  send({ type: "progress", stage: "packages", fraction: null });
  const [npm, prefix] = npmCommand();
  await run(npm, [...prefix, "ci", "--omit=dev", "--no-audit", "--no-fund", "--loglevel=error"], home);
  pruneForeignBinaries(home);

  // Loading the model once downloads and caches it.
  const { KokoroTTS } = await loadKokoro(home);
  let last = -1;
  const tts = await KokoroTTS.from_pretrained(MODEL, {
    dtype: DTYPE,
    device: "cpu",
    progress_callback: (p) => {
      if (p.status !== "progress" || !String(p.file).endsWith(".onnx") || !p.total) return;
      const fraction = Math.round((p.loaded / p.total) * 100) / 100;
      if (fraction !== last) { last = fraction; send({ type: "progress", stage: "model", fraction }); }
    },
  });
  await tts.generate("Ready.", { voice: "af_heart" });
  writeFileSync(join(home, "installed.json"), JSON.stringify({ version: SETUP_VERSION, model: MODEL, dtype: DTYPE }) + "\n");
  send({ type: "installed" });
}

// MARK: Serve

/// kokoro-js lives in `home`, not next to this script, so import it through a
/// one-line module there; that also gives us transformers.js' `env`.
async function loadKokoro(home) {
  const entry = join(home, "kokoro-entry.mjs");
  writeFileSync(entry, 'export { KokoroTTS } from "kokoro-js";\nexport { env } from "@huggingface/transformers";\n');
  return import(pathToFileURL(entry).href);
}

async function serve(home) {
  let installed;
  try { installed = JSON.parse(readFileSync(join(home, "installed.json"), "utf8")); } catch { installed = null; }
  if (installed?.version !== SETUP_VERSION) throw new Error("The neural voice isn't installed (or is out of date). Download it again in Settings ▸ Voice.");

  const { KokoroTTS, env } = await loadKokoro(home);
  env.allowRemoteModels = false; // installed: never touch the network again
  const tts = await KokoroTTS.from_pretrained(MODEL, { dtype: DTYPE, device: "cpu" });
  await tts.generate("Hi.", { voice: "af_heart" }); // the first run is the slow one
  send({ type: "ready" });

  const queue = [];
  let epoch = 0;
  let working = false;

  async function work() {
    if (working) return;
    working = true;
    while (queue.length) {
      const job = queue.shift();
      try {
        for (const piece of chunks(job.text)) {
          if (job.epoch !== epoch) break;
          const audio = await tts.generate(piece, { voice: job.voice, speed: job.speed });
          if (job.epoch !== epoch) break;
          await send({ type: "audio", id: job.id, rate: audio.sampling_rate ?? SAMPLE_RATE, pcm: encodePCM(audio.audio) });
        }
        if (job.epoch === epoch) await send({ type: "done", id: job.id });
      } catch (error) {
        await send({ type: "error", id: job.id, message: String(error?.message ?? error) });
      }
    }
    working = false;
  }

  const lines = createInterface({ input: process.stdin });
  lines.on("line", (line) => {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    if (message.type === "cancel") {
      epoch += 1;
      queue.length = 0;
    } else if (message.type === "speak" && typeof message.text === "string") {
      const voice = tts.voices[message.voice] ? message.voice : "af_heart";
      const speed = Math.min(Math.max(Number(message.speed) || 1, 0.5), 2);
      queue.push({ id: message.id, text: message.text, voice, speed, epoch });
      work();
    }
  });
  // The app went away. A normal exit races ONNX Runtime's native teardown and
  // aborts (leaving a crash report); SIGTERM ends the process without it.
  lines.on("close", () => process.kill(process.pid, "SIGTERM"));
}

// MARK: Main

async function main(argv) {
  const [mode] = argv;
  const homeIndex = argv.indexOf("--home");
  const home = homeIndex >= 0 ? argv[homeIndex + 1] : null;
  if (!home || !["install", "serve"].includes(mode)) {
    process.stderr.write("usage: miss-minutes-voice.mjs install|serve --home DIR\n");
    process.exit(2);
  }
  try {
    await (mode === "install" ? install(home) : serve(home));
  } catch (error) {
    await send({ type: "error", message: String(error?.message ?? error) });
    process.exit(1);
  }
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2));
}

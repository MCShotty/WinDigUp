const { chromium } = require("playwright");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
(async () => {
  const browser = await chromium.launch({ executablePath: process.env.DIGUP_CHROME || "/usr/bin/google-chrome",
    headless: true, args: ["--no-sandbox", "--disable-dev-shm-usage"] });
  try {
    const page = await browser.newPage({ viewport: { width: 720, height: 850 } });
    const errors = []; page.on("pageerror", error => errors.push(error.message));
    await page.addInitScript(() => {
      window.calls = []; window.complete = false; window.preparation = { phase: "idle" }; window.probeHold = false;
      const info = { acceleration: { backend: "amd-vulkan", gpu: "", python: "", models: "" },
        hotkey: "Ctrl+Shift+Space", shortcut: { method: "grab", command: "" },
        folders: [], skipped: [], skipTypes: [], code: { folders: [], skipped: [], editors: [], editor: "default" },
        state: { model: { state: "ready" } }, indexHours: { on: false, start: 60, end: 420 },
        storage: { index: "C:\\Index", models: "C:\\Models", indexBytes: 0 }, version: "fixture", updateChecks: false };
      const status = args => {
        const gpu = args.acceleration.backend === "openvino-gpu";
        return { schemaVersion: 1, probeOnly: true, runtimeReady: true, runtimeVersion: "fixture",
          python: "C:\\DigUp\\helper\\openvino\\python\\python.exe", models: args.acceleration.models,
          modelMessage: args.acceleration.models ? "Exported model verified." : "Choose or prepare an exported model bundle.",
          bundleReady: !!args.acceleration.models, preparation: window.preparation, backends: [],
          devices: [{ id: gpu ? "GPU.0" : "NPU", stableID: gpu ? "OV-GPU-fixture" : "OV-NPU-fixture",
            name: gpu ? "Intel Arc 140V" : "Intel AI Boost", backend: args.acceleration.backend, available: true }] };
      };
      window.__TAURI__ = { core: { invoke: async (command, args) => {
        window.calls.push({ command, args });
        if (command === "settings_info") return info;
        if (command === "accelerator_devices") return { schemaVersion: 1, devices: [], backends: [] };
        if (command === "openvino_status") {
          if (window.probeHold && args.acceleration.backend === "openvino-gpu") return new Promise(resolve => window.releaseProbe = () => resolve(status(args)));
          return status(args);
        }
        if (command === "download_openvino" || command === "prepare_openvino") {
          window.preparation = { phase: "exporting", message: "Preparing the 512-token text profile." };
          return window.preparation;
        }
        if (command === "openvino_preparation") {
          if (window.complete) window.preparation = { phase: "ready", bundle: "C:\\Index\\prepared", message: "Model prepared." };
          return window.preparation;
        }
        if (command === "cancel_openvino_preparation") {
          window.preparation = { phase: "cancelled", message: "Model preparation cancelled." }; return window.preparation;
        }
        if (command === "pick_openvino_path") return "C:\\snapshots\\" + "a".repeat(40);
        if (command === "set_acceleration") throw "Intel driver cannot compile a required graph; CPU fallback is disabled.";
        if (command === "ask") return {};
        return null;
      } }, event: { listen: async () => () => {} } };
    });
    await page.goto((process.env.DIGUP_UI_URL || "http://127.0.0.1:8765") + "/settings.html");
    assert.equal(await page.title(), "DigUp Settings");
    await page.waitForFunction(() => document.querySelector("#accelerator").value === "amd-vulkan");
    await page.selectOption("#accelerator", "openvino-gpu");
    await page.waitForFunction(() => document.querySelector("#openvino-runtime").textContent.includes("is ready"));
    assert.equal(await page.locator("#gpu-options").isVisible(), false);
    assert.equal(await page.locator("#gpu-jobs-control").isVisible(), false);
    assert.match(await page.locator("#openvino-device-status").textContent(), /Intel Arc 140V/);
    await page.click("#apply-accelerator");
    assert.match(await page.locator("#accelerator-problem").textContent(), /Choose or prepare/);
    assert.equal(await page.evaluate(() => window.calls.some(call => call.command === "set_acceleration")), false);
    await page.selectOption("#openvino-device", "OV-GPU-fixture");
    await page.locator("#openvino-access summary").click();
    await page.fill("#openvino-access-token", "hf_fixture_token");
    await page.click("#openvino-download");
    assert.equal(await page.locator("#openvino-access-token").inputValue(), "");
    assert.equal(await page.evaluate(() => window.calls.find(call => call.command === "download_openvino").args.accessToken), "hf_fixture_token");
    await page.locator("#openvino-access summary").click();
    await page.fill("#npu-models", "C:\\Manual\\bundle");
    await page.evaluate(() => window.complete = true);
    await page.waitForFunction(() => !document.querySelector("#openvino-use-prepared").hidden);
    assert.equal(await page.locator("#npu-models").inputValue(), "C:\\Manual\\bundle");
    await page.click("#openvino-use-prepared");
    assert.equal(await page.locator("#npu-models").inputValue(), "C:\\Index\\prepared");
    await page.selectOption("#accelerator", "openvino-npu");
    await page.waitForFunction(() => document.querySelector("#openvino-device-status").textContent.includes("Intel AI Boost"));
    await page.selectOption("#openvino-device", "OV-NPU-fixture");
    await page.click("#apply-accelerator");
    assert.match(await page.locator("#accelerator-problem").textContent(), /Intel driver cannot compile/);
    assert.equal(await page.locator("#apply-accelerator").isEnabled(), true);
    assert.equal(await page.locator("#accelerator").inputValue(), "openvino-npu");
    await page.evaluate(() => window.probeHold = true);
    await page.selectOption("#accelerator", "openvino-gpu");
    await page.waitForFunction(() => typeof window.releaseProbe === "function");
    assert.equal(await page.locator("#gpu-device").inputValue(), "OV-GPU-fixture");
    await page.selectOption("#accelerator", "openvino-npu");
    await page.waitForFunction(() => document.querySelector("#openvino-device-status").textContent.includes("Intel AI Boost"));
    await page.evaluate(() => window.releaseProbe());
    await page.waitForTimeout(30);
    assert.match(await page.locator("#openvino-device-status").textContent(), /Intel AI Boost/);
    await page.locator("#openvino-prepare-details summary").click();
    await page.click("#openvino-choose-source");
    assert.equal(await page.locator("#openvino-revision").inputValue(), "a".repeat(40));
    await page.evaluate(() => { window.complete = false; window.preparation = { phase: "idle" }; });
    await page.click("#openvino-prepare");
    await page.click("#openvino-cancel");
    assert.match(await page.locator("#openvino-preparation-status").textContent(), /cancelled/);
    await page.evaluate(() => window.dispatchEvent(new Event("focus")));
    assert.equal(await page.locator("#npu-models").inputValue(), "C:\\Index\\prepared");
    assert.equal(await page.locator("#accelerator").inputValue(), "openvino-npu");
    assert.equal(await page.evaluate(() => window.calls.filter(call => call.command === "set_acceleration").some(call => JSON.stringify(call.args).includes("hf_fixture_token"))), false);
    if (process.env.DIGUP_OPENVINO_SCREENSHOTS) {
      fs.mkdirSync(process.env.DIGUP_OPENVINO_SCREENSHOTS, { recursive: true });
      for (const theme of ["light", "dark"]) {
        await page.emulateMedia({ colorScheme: theme });
        for (const width of [720, 420]) {
          await page.setViewportSize({ width, height: 850 });
          await page.locator("#npu-options").scrollIntoViewIfNeeded();
          const file = path.join(process.env.DIGUP_OPENVINO_SCREENSHOTS, theme + "-" + width + ".png");
          const png = await page.screenshot({ path: file });
          if (process.env.DIGUP_OPENVINO_SCREENSHOT_LOG) console.log("OPENVINO_SCREENSHOT " + theme + "-" + width + " " + png.toString("base64"));
        }
      }
    }
    assert.deepEqual(errors, []);
    console.log("PASS: Intel setup, explicit download, model-path drafts, cancellation, backend pins, stale probes, inline Apply failures, themes and narrow layouts. Native boundary is synthetic; no inference performed.");
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exit(1); });

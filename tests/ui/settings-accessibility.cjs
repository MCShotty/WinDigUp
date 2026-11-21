"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");
const { setup, renderedContrast } = require("./application-fixtures.cjs");

const base = process.env.DIGUP_UI_URL || "http://127.0.0.1:8765";
const screenshots = process.env.DIGUP_REPAIR_SCREENSHOTS;

async function capture(page, name) {
  if (!screenshots) return;
  fs.mkdirSync(screenshots, { recursive: true });
  await page.screenshot({ path: path.join(screenshots, name + ".png") });
}

async function run(browser) {
  const page = await browser.newPage({ viewport: { width: 660, height: 620 } });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await setup(page);
  await page.addInitScript(() => {
    const invoke = window.__TAURI__.core.invoke;
    const drive = {
      version: 2, supported: true, catalogEnabled: true, running: false,
      options: { enabled: true, paused: false, volumes: ["ssd"], revision: 1 },
      volumes: [{ id: "ssd", paths: ["C:\\"], name: "Fixture SSD", filesystem: "NTFS", available: true }],
      volumeCatalog: { state: "ready", revision: 1 },
      byVolume: { ssd: { phase: "watching", records: 23, candidates: 10, accepted: 5 } },
    };
    const saved = {
      skipTypes: ["jpg"], indexHours: { on: true, start: 60, end: 420 }, codeEditor: "default",
    };
    window.rejectSettingsSave = new Set(["set_acceleration", "set_skip_types", "set_index_hours", "set_code_editor"]);
    window.__TAURI__.core.invoke = async (command, args = {}) => {
      if (command === "settings_info") {
        const original = await invoke(command, args);
        const snapshot = { ...original, discovery: drive, skipTypes: saved.skipTypes, indexHours: saved.indexHours, canChooseTrayClick: true,
          code: { ...original.code, editor: saved.codeEditor, editors: [{ id: "vscode", name: "Visual Studio Code" }] } };
        if (window.holdRefresh) {
          await new Promise(resolve => { window.releaseRefresh = resolve; });
          window.holdRefresh = false;
        }
        return snapshot;
      }
      if (command === "refresh_discovery_volumes") return drive;
      if (command === "activity_snapshot") return { ...await invoke(command, args), discovery: drive };
      if (command === "accelerator_devices") return { schemaVersion: 1, devices: [], backends: [] };
      if (["set_acceleration", "set_skip_types", "set_index_hours", "set_code_editor"].includes(command)) {
        calls.push({ command, args });
        if (command === "set_index_hours" && window.holdHours) {
          await new Promise((_, reject) => { window.rejectOldHours = reject; });
        }
        if (window.rejectSettingsSave.has(command)) throw "Could not save " + command;
        if (command === "set_skip_types") {
          saved.skipTypes = args.types.split(",").map(type => type.trim().replace(/^\./, "").toLowerCase());
          return saved.skipTypes;
        }
        if (command === "set_index_hours") saved.indexHours = args;
        if (command === "set_code_editor") saved.codeEditor = args.editor;
        return null;
      }
      return invoke(command, args);
    };
  });
  await page.goto(base + "/settings.html");
  assert.equal(await page.title(), "DigUp Settings");
  const tab = name => page.getByRole("tab", { name, exact: true });
  await page.waitForFunction(() => document.querySelector('[data-tab="general"]').getAttribute("aria-selected") === "true");
  const tray = page.getByRole("radiogroup", { name: "Clicking DigUp's tray icon" });
  assert.equal(await tray.getByRole("radio").count(), 2);
  assert.ok(await tab("Storage").evaluate(node => node.getBoundingClientRect().right <= innerWidth),
    "The native-size Settings tab bar clipped Storage");
  await tab("General").press("ArrowDown");
  assert.equal(await tab("Activity").getAttribute("aria-selected"), "true");
  await tab("Activity").press("ArrowUp");
  assert.ok(await tab("General").evaluate(node => document.activeElement === node));
  const main = page.locator("main.settings");
  const scrollTop = () => main.evaluate(node => node.scrollTop);
  await main.evaluate(node => { node.scrollTop = node.scrollHeight; });
  const generalBottom = await scrollTop();
  assert.ok(generalBottom > 0);
  await tab("Apps").click();
  assert.equal(await scrollTop(), 0, "The Apps tab inherited General's scroll position");
  const includeApps = page.getByRole("checkbox", { name: /Include installed applications/ });
  assert.ok(await includeApps.evaluate(node => node.getBoundingClientRect().top > 0));
  await tab("General").click();
  assert.equal(await scrollTop(), generalBottom);
  await page.evaluate(() => emit("settings-tab", "general"));
  const accelerationTitle = page.getByRole("heading", { name: "Model acceleration" });
  assert.ok(await accelerationTitle.evaluate(node => node === document.activeElement), "Acceleration deep link lost its target");

  const refresh = async () => {
    const before = await page.evaluate(() => calls.filter(call => call.command === "settings_info").length);
    await page.evaluate(() => window.dispatchEvent(new Event("focus")));
    await page.waitForFunction(count => calls.filter(call => call.command === "settings_info").length > count, before);
  };
  const lastSave = command => page.evaluate(cmd => calls.filter(call => call.command === cmd).at(-1)?.args, command);
  const retry = name => page.getByRole("button", { name, exact: true });
  const gpu = page.getByLabel("GPU device (optional)");
  await page.evaluate(() => AppearanceUI.apply("dark"));
  const gpuPrompt = await renderedContrast(gpu, "::placeholder");
  assert.ok(gpuPrompt >= 4.5, "Dark Settings hides the GPU placeholder");
  await page.evaluate(() => AppearanceUI.apply("system"));
  await gpu.fill("fixture gpu");
  await page.getByRole("button", { name: "Apply and Restart DigUp" }).click();
  const accelerationError = page.locator("#acceleration-feedback").getByRole("alert");
  const retryAcceleration = retry("Retry applying acceleration settings");
  await retryAcceleration.waitFor();
  assert.equal(await page.locator("#problem").textContent(), "Could not save set_acceleration");
  assert.match(await accelerationError.ariaSnapshot(), /Could not save set_acceleration/);
  assert.ok(await retryAcceleration.evaluate(node => {
    const r = node.getBoundingClientRect();
    return node.contains(document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2));
  }), "Retry remained off screen after a rejected Apply");
  await capture(page, "settings-accelerator-error");
  await refresh();
  assert.equal(await gpu.inputValue(), "fixture gpu");
  await gpu.fill("fixture gpu corrected");
  await page.evaluate(() => rejectSettingsSave.delete("set_acceleration"));
  await retryAcceleration.click();
  assert.equal((await lastSave("set_acceleration")).acceleration.gpu, "fixture gpu corrected");
  assert.equal(await page.locator("#problem").isVisible(), false);

  await tab("Folders").click();
  const folderName = page.locator("#folder-rows .text .name").first();
  await folderName.waitFor();
  assert.ok(await folderName.evaluate(node => node.clientWidth > 100), "Settings folder text should retain its column");
  const types = page.getByRole("textbox", { name: "Skip these file types" });
  const hours = page.getByRole("group", { name: "Scheduled indexing hours" });
  const start = hours.getByLabel("Start time", { exact: true });
  const end = hours.getByLabel("End time", { exact: true });
  assert.equal(await start.inputValue(), "01:00");
  assert.equal(await end.inputValue(), "07:00");
  assert.equal(await start.evaluate(node => !!node.closest("label")), false);
  await types.fill(".HEIC, .TXT");
  await types.press("Enter");
  const retryTypes = retry("Retry saving file types");
  await retryTypes.waitFor();
  await refresh();
  assert.equal(await types.inputValue(), ".HEIC, .TXT");
  await types.fill(".HEIC, .PDF");
  await page.evaluate(() => rejectSettingsSave.delete("set_skip_types"));
  await retryTypes.click();
  await page.waitForFunction(() => document.querySelector("#types").value === "heic, pdf");
  assert.deepEqual(await lastSave("set_skip_types"), { types: ".HEIC, .PDF" });
  await start.fill("02:30");
  const retryHours = retry("Retry saving indexing hours");
  await retryHours.waitFor();
  assert.match(await page.locator("#hours-feedback").getByRole("alert").ariaSnapshot(), /Could not save set_index_hours/);
  await refresh();
  assert.equal(await start.inputValue(), "02:30");
  assert.equal(await end.inputValue(), "07:00");
  await capture(page, "settings-schedule-error");
  await page.evaluate(() => rejectSettingsSave.delete("set_index_hours"));
  await retryHours.click();
  assert.deepEqual(await lastSave("set_index_hours"), { on: true, start: 150, end: 420 });

  await page.evaluate(() => { window.holdHours = true; });
  await start.fill("03:00");
  await page.waitForFunction(() => typeof window.rejectOldHours === "function");
  await end.fill("06:30");
  assert.equal((await lastSave("set_index_hours")).end, 420, "The previous hours save was still in flight");
  await page.evaluate(() => { window.holdHours = false; window.rejectOldHours("Previous schedule failed"); });
  await page.waitForFunction(() => calls.filter(call => call.command === "set_index_hours").at(-1).args.end === 390);
  assert.equal(await retryHours.isVisible(), false, "A stale hours response triggered an alert");
  assert.deepEqual(await lastSave("set_index_hours"), { on: true, start: 180, end: 390 });

  await tab("Code").click();
  const editor = page.getByRole("combobox", { name: "Open code in" });
  await editor.selectOption("vscode");
  const retryEditor = retry("Retry saving the code editor");
  await retryEditor.waitFor();
  await refresh();
  assert.equal(await editor.inputValue(), "vscode", "A refresh discarded the rejected editor draft");
  await page.evaluate(() => {
    window.holdRefresh = true;
    rejectSettingsSave.delete("set_code_editor");
    window.dispatchEvent(new Event("focus"));
  });
  await page.waitForFunction(() => typeof window.releaseRefresh === "function");
  await retryEditor.click();
  assert.deepEqual(await lastSave("set_code_editor"), { editor: "vscode" });
  await page.evaluate(async () => {
    window.releaseRefresh();
    await new Promise(requestAnimationFrame);
  });
  assert.equal(await editor.inputValue(), "vscode", "A delayed settings snapshot reset a successfully saved editor");

  await tab("Drives").click();
  await page.locator("#drive-measurements > summary").click();
  await page.getByRole("heading", { name: /Fixture SSD/, level: 3 }).waitFor();
  assert.equal(await page.getByRole("heading", { name: "Drives", level: 2 }).count(), 1);
  const note = await page.locator("#drive-install + .note").evaluate(node => ({
    size: parseFloat(getComputedStyle(node).fontSize), width: node.getBoundingClientRect().width,
    available: node.parentElement.clientWidth,
  }));
  assert.ok(note.size >= 12 && note.width <= note.available);
  const viewActivity = page.getByRole("button", { name: /View activity for .*Fixture SSD/ });
  for (const colorScheme of ["light", "dark"]) {
    await page.emulateMedia({ colorScheme });
    for (const theme of ["system", "light", "dark"]) {
      await page.evaluate(value => AppearanceUI.apply(value), theme);
      assert.ok(await renderedContrast(viewActivity) >= 4.5, `Drive action contrast in ${colorScheme}/${theme}`);
    }
  }
  await capture(page, "settings-drives");
  await viewActivity.click();
  await page.waitForFunction(() => document.activeElement.classList.contains("pipeline-drive-name"));
  assert.match(await page.locator("#activity").getByRole("heading", { name: /Fixture SSD/, level: 4 }).textContent(), /Fixture SSD/);
  await page.setViewportSize({ width: 360, height: 560 });
  const section = page.getByRole("combobox", { name: "Settings section" });
  assert.equal(await section.inputValue(), "activity");
  assert.equal(await page.getByRole("tablist", { name: "Settings sections" }).count(), 0);
  await section.selectOption("executable-review");
  await page.getByRole("heading", { name: "Review discovered apps" }).waitFor();
  await page.getByRole("button", { name: "Drive choices and scan status" }).click();
  assert.equal(await section.inputValue(), "drives");
  assert.ok(await section.evaluate(node => node === document.activeElement));
  assert.deepEqual(errors, []);
  console.log("Dark GPU placeholder contrast:", gpuPrompt.toFixed(2));
  console.log("PASS: field names, operation alerts and retries, draft and stale-reply protection, tab scroll, deep links, drive headings and link contrast");
}

(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.DIGUP_CHROME || "/usr/bin/chromium",
    headless: true, args: ["--no-sandbox", "--disable-dev-shm-usage"],
  });
  try { await run(browser); } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });

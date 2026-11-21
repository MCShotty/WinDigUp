"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");
const { setup, renderedContrast } = require("./application-fixtures.cjs");

const base = process.env.DIGUP_UI_URL || "http://127.0.0.1:8765";
const screenshots = process.env.DIGUP_REPAIR_SCREENSHOTS;
const gpuError = "Re-select your GPU in Settings after the NVIDIA CUDA upgrade.";

async function capture(page, name) {
  if (!screenshots) return;
  fs.mkdirSync(screenshots, { recursive: true });
  await page.screenshot({ path: path.join(screenshots, name + ".png") });
}

async function fixture(browser, errors, platform = "Win32", route = "") {
  const page = await browser.newPage({ viewport: { width: 720, height: 600 } });
  page.on("pageerror", error => errors.push(error.message));
  await setup(page, platform);
  await page.addInitScript(({ gpuError, platform }) => {
    const invoke = window.__TAURI__.core.invoke;
    const model = { state: "failed", message: gpuError };
    Object.assign(window.setupInfo, {
      offered: ["C:/Documents"], chosen: ["C:/Documents"], model, state: { model }, applicationsSupported: platform === "Win32",
    });
    window.__TAURI__.core.invoke = async (command, args = {}) => {
      if (command === "open_settings" && window.rejectRepair) {
        calls.push({ command, args });
        throw "Settings window could not open";
      }
      return invoke(command, args);
    };
  }, { gpuError, platform });
  await page.goto(base + "/setup.html" + route);
  assert.equal(await page.title(), "Set Up DigUp");
  return page;
}

async function visibleFooter(page) {
  const result = await page.locator("footer").evaluate(footer => {
    const actions = [...footer.querySelectorAll("button:not([hidden])")].map(node => {
      const rect = node.getBoundingClientRect();
      const top = document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2);
      return { name: node.textContent, within: rect.left >= 0 && rect.top >= 0 && rect.right <= innerWidth && rect.bottom <= innerHeight,
        hittable: top && node.contains(top) };
    });
    return { actions, width: innerWidth, scrollWidth: document.documentElement.scrollWidth };
  });
  assert.equal(result.scrollWidth, result.width);
  assert.ok(result.actions.length > 0);
  for (const action of result.actions) {
    assert.ok(action.within && action.hittable, `${action.name} is clipped at the supported setup window size`);
  }
}

async function run(browser) {
  const errors = [];
  const page = await fixture(browser, errors);
  await page.getByRole("button", { name: "Open app launcher now" }).waitFor();
  const next = page.locator("#next");
  await next.click();
  await page.getByRole("heading", { name: "Choose folders to search" }).waitFor();
  assert.equal(await page.locator("#setup-step").textContent(), "Step 2 of 4");
  const documents = page.getByRole("checkbox", { name: /Documents/ });
  assert.equal(await documents.isChecked(), true);
  await documents.press("Space");
  assert.equal(await documents.isChecked(), false);
  assert.ok(await documents.evaluate(node => document.activeElement === node));
  await documents.press("Space");
  assert.equal(await documents.isChecked(), true);
  assert.equal(await page.locator("#model").textContent(), gpuError);
  await visibleFooter(page);
  const addFolder = page.getByRole("button", { name: "Add Folder…" });
  for (const colorScheme of ["light", "dark"]) {
    await page.emulateMedia({ colorScheme });
    for (const theme of ["system", "light", "dark"]) {
      await page.evaluate(value => AppearanceUI.apply(value), theme);
      assert.ok(await renderedContrast(addFolder) >= 4.5, `Add Folder contrast in ${colorScheme}/${theme}`);
      assert.ok(await renderedContrast(next) >= 4.5, `Continue contrast in ${colorScheme}/${theme}`);
    }
  }
  await capture(page, "setup-error-footer");
  await page.evaluate(() => {
    const elements = [...document.querySelectorAll("body *")];
    const fontSizes = elements.map(node => parseFloat(getComputedStyle(node).fontSize));
    elements.forEach((node, index) => { node.style.fontSize = fontSizes[index] * 2 + "px"; });
  });
  await visibleFooter(page);
  await capture(page, "setup-error-footer-text-200");
  // Use the original viewport and styles for the completion and recovery flow.
  await page.reload();
  await page.getByRole("button", { name: "Open app launcher now" }).waitFor();
  for (const title of ["Choose folders to search", "Quick search shortcut", "App search is ready"]) {
    await next.click();
    const heading = page.getByRole("heading", { name: title });
    await heading.waitFor();
    assert.ok(await heading.evaluate(node => node === document.activeElement), `${title} should receive focus`);
  }
  const meter = page.locator("#bar");
  const repair = page.getByRole("button", { name: "Open acceleration settings" });
  assert.equal(await page.locator("#progress-note").textContent(), gpuError);
  assert.equal(await meter.isVisible(), false);
  await page.evaluate(() => { window.rejectRepair = true; });
  await repair.click();
  await page.getByRole("status").filter({ hasText: "Settings window could not open" }).waitFor();
  await page.evaluate(() => { window.rejectRepair = false; });
  await repair.click();
  assert.deepEqual(await page.evaluate(() => calls.filter(c => c.command === "open_settings").at(-1).args), { tab: "general" });
  assert.equal(await page.evaluate(() => calls.some(c => c.command === "finish_setup")), false, "Opening recovery closed setup");
  assert.deepEqual(await page.evaluate(() => calls.filter(c => c.command === "apply_setup_folders").map(c => c.args.folders)),
    [["C:\\Documents"]], "Opening acceleration settings changed the folder selection");
  await capture(page, "setup-model-recovery");

  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.evaluate(() => emit("model", { state: "waiting" }));
  const fill = page.locator("#bar-fill");
  await meter.waitFor();
  assert.match(await page.locator("#progress-what").textContent(), /Waiting for the network/);
  assert.equal(await fill.evaluate(node => getComputedStyle(node).animationName), "none");
  assert.ok(await fill.evaluate(node => {
    const fill = node.getBoundingClientRect(), bar = node.parentElement.getBoundingClientRect();
    return Math.abs((fill.left + fill.right) / 2 - (bar.left + bar.right) / 2) < 1;
  }), "The reduced-motion activity indicator isn't visible in the center of its track");
  await capture(page, "setup-reduced-motion");
  await page.evaluate(() => emit("model", { state: "downloading", bytes: 400, total: 800 }));
  assert.equal(await page.getByRole("progressbar", { name: "Downloading the model" }).getAttribute("aria-valuenow"), "50");
  assert.equal(await page.locator("#progress-what").getAttribute("role"), "status");
  assert.match(await page.locator("#progress-left").textContent(), /^50%/);
  assert.ok(await fill.evaluate(node => {
    const fill = node.getBoundingClientRect(), bar = node.parentElement.getBoundingClientRect();
    return Math.abs(fill.width - bar.width / 2) < 1 && bar.height === 6 && getComputedStyle(node).transitionDuration === "0s";
  }), "Reduced motion lost determinate progress");
  await page.evaluate(() => {
    emit("model", { state: "ready" });
    emit("state", { activity: "idle", searchable: 32 });
  });
  await page.getByRole("heading", { name: "File search is ready" }).waitFor();
  assert.equal(await page.locator("#setup-step").textContent(), "Step 4 of 4");
  assert.deepEqual(await page.locator("#ready-keys kbd").allTextContents(), ["Ctrl", "Shift", "Space"]);
  assert.equal(await repair.isVisible(), false);
  await visibleFooter(page);
  await next.click();
  assert.deepEqual(await page.evaluate(() => calls.filter(c => c.command === "finish_setup").map(c => c.args)), [{}]);

  const apps = await fixture(browser, errors);
  await apps.getByRole("button", { name: "Open app launcher now" }).click();
  assert.deepEqual(await apps.evaluate(() => calls.find(c => c.command === "finish_setup")?.args), { launchApps: true });

  const linux = await fixture(browser, errors, "Linux x86_64", "?page=ready");
  await linux.getByRole("heading", { name: "File search needs attention" }).waitFor();
  assert.equal(await linux.getByRole("button", { name: "Open app launcher now" }).count(), 0);
  assert.equal(await linux.locator("#progress-note").textContent(), gpuError);
  assert.deepEqual(errors, []);
  console.log("PASS: setup footer and text scaling, all themes, accurate capability states, repair action and static progress");
}

(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.DIGUP_CHROME || "/usr/bin/chromium",
    headless: true, args: ["--no-sandbox", "--disable-dev-shm-usage"],
  });
  try { await run(browser); } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });

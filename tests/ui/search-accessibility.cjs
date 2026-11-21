"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");
const { setup, renderedContrast: contrast } = require("./application-fixtures.cjs");

const base = process.env.DIGUP_UI_URL || "http://127.0.0.1:8765";
const screenshots = process.env.DIGUP_REPAIR_SCREENSHOTS;

async function capture(page, name) {
  if (!screenshots) return;
  fs.mkdirSync(screenshots, { recursive: true });
  await page.screenshot({ path: path.join(screenshots, name + ".png") });
}

async function assertSelected(page, expectedName) {
  const query = page.getByRole("combobox", { name: "Search files, apps and settings" });
  const { id, name, role, validGrid, selected } = await query.evaluate(input => {
    const id = input.getAttribute("aria-activedescendant");
    const row = document.getElementById(id);
    const grid = document.getElementById(input.getAttribute("aria-controls"));
    return {
      id, name: row?.getAttribute("aria-label"), role: row?.getAttribute("role"),
      validGrid: grid.getAttribute("role") === "grid" && grid.getAttribute("aria-owns")?.split(" ")
        .includes(row?.closest('[role="rowgroup"]')?.id),
      selected: row?.getAttribute("aria-selected"),
    };
  });
  assert.ok(id && validGrid, "The query must refer to a row in its results grid");
  assert.match(name, expectedName);
  assert.equal(role, "row");
  assert.equal(selected, "true");
  assert.equal(await query.getAttribute("aria-expanded"), "true");
  assert.equal(await page.locator('#search-sections [role="option"]').count(), 0);
  return id;
}

async function run(browser) {
  const page = await browser.newPage({ viewport: { width: 820, height: 520 } });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await setup(page);
  await page.addInitScript(() => {
    const invoke = window.__TAURI__.core.invoke;
    const note = (name, id) => ({
      path: "C:/Documents/" + name + ".txt", kind: "doc", segment: "chunk", segment_id: id,
      score: 5, keyword_rank: id, size: 200, info: {}, excerpt: "Preview text for this synthetic file",
    });
    const notes = [note("Field notes", 1), note("Travel notes", 2)];
    const catalog = { supported: true, enabled: true, semanticEnabled: false, ordinarySearches: true, revision: "fixture" };
    window.__TAURI__.core.invoke = async (command, args = {}) => {
      if (command === "window_info") {
        return { ...await invoke(command, args), windowsSettings: catalog };
      }
      if (command === "search_windows_settings") {
        const hits = args.q === "display" ? [{
          id: "setting:display", name: "Display", resultType: "windows_setting", kind: "windows_setting",
          reason: "exact", description: "Open Windows display settings",
        }] : [];
        return { generation: args.generation, hits, total: hits.length, catalog, semantic: { state: "disabled" } };
      }
      if (command === "ask" && args.request.op === "search") {
        if (window.rejectFileSearch) throw "File helper unavailable";
        const { q, code, meaning, generation } = args.request;
        if (q === "notes" && meaning && window.holdMeaning) {
          await new Promise(resolve => { window.releaseMeaning = resolve; });
        }
        const hits = q === "no-word-matches" ? [] : code
          ? [{ ...note("source", 3), path: "C:/Projects/source.swift", kind: "code", loc: 10 }]
          : meaning ? [...notes].reverse() : notes;
        return { generation, hits, strong: hits.length, meaning: meaning && q !== "no-word-matches" };
      }
      if (command === "activity_snapshot") {
        const snapshot = await invoke(command, args);
        snapshot.files = { ...snapshot.files, phase: "indexing", knownFiles: 108, searchable: 8, pending: 100, done: 8, total: 108 };
        return snapshot;
      }
      return invoke(command, args);
    };
  });
  await page.goto(base + "/window.html");
  assert.equal(await page.title(), "DigUp");
  const query = page.locator("#query");
  const dialog = page.getByRole("dialog", { name: /notes\.txt/ });
  const focus = () => page.evaluate(() => document.activeElement.id || document.activeElement.textContent.trim());
  const help = page.getByRole("dialog", { name: "Search help" });
  await query.press("F1");
  await help.waitFor();
  assert.equal(await focus(), "Close");
  assert.ok(await help.getByRole("region").evaluate(node => node.scrollHeight <= node.clientHeight + 1),
    "The guide needs scrolling at the supported full-search minimum");
  await page.keyboard.press("Tab");
  assert.ok(await help.getByRole("region").evaluate(node => document.activeElement === node));
  await page.keyboard.press("Escape");
  await help.waitFor({ state: "hidden" });
  assert.equal(await focus(), "query");
  await query.press("F1");
  await help.getByRole("button", { name: "settings: display", exact: true }).press("Enter");
  await help.waitFor({ state: "hidden" });
  assert.equal(await query.inputValue(), "settings: display");
  assert.equal(await focus(), "query");
  await page.waitForSelector('.windows-settings-group [data-result-key="setting:display"]');
  await page.evaluate(() => { window.holdMeaning = true; });
  await query.fill("notes");
  await page.waitForFunction(() => typeof window.releaseMeaning === "function");
  assert.match(await page.locator('#results-status').textContent(), /2 results shown/);
  await query.press("ArrowDown");
  const chosen = await assertSelected(page, /Travel notes/);
  await page.evaluate(() => {
    window.holdMeaning = false;
    window.releaseMeaning();
  });
  await page.waitForFunction(() => state.finalGeneration === state.generation);
  assert.equal(await assertSelected(page, /Travel notes/), chosen, "Refinement changed the active result ID");
  await query.press("Enter");
  const pathOpened = await page.evaluate(() => calls.filter(call => call.command === "open_path").at(-1)?.args.path);
  assert.equal(pathOpened, "C:/Documents/Travel notes.txt");

  await query.press("Space");
  await dialog.waitFor();
  assert.ok(await dialog.evaluate(node => node.matches(":modal")));
  const close = dialog.getByRole("button", { name: "Close preview" });
  assert.ok(await close.evaluate(node => node === document.activeElement));
  await page.keyboard.press("Tab");
  assert.ok(await dialog.getByRole("region", { name: "File content" }).evaluate(node => node === document.activeElement));
  await page.keyboard.press("Tab");
  assert.equal(await focus(), "Open");
  await page.keyboard.press("Shift+Tab");
  assert.ok(await dialog.getByRole("region", { name: "File content" }).evaluate(node => node === document.activeElement));
  await capture(page, "search-preview");
  await close.press("Escape");
  await dialog.waitFor({ state: "hidden" });
  assert.equal(await focus(), "query");
  assert.equal(await query.inputValue(), "notes");

  const more = page.getByRole("button", { name: "More", exact: true });
  const menu = page.getByRole("menu", { name: "More actions" });
  await more.press("Enter");
  assert.equal(await more.getAttribute("aria-expanded"), "true");
  assert.match(await focus(), /Activity and Diagnostics/);
  await page.keyboard.press("ArrowDown");
  assert.match(await focus(), /Choose Folders/);
  await page.keyboard.press("End");
  assert.equal(await focus(), "Quit DigUp");
  await page.keyboard.press("Home");
  await page.keyboard.press("Escape");
  await menu.waitFor({ state: "hidden" });
  assert.equal(await focus(), "more");
  await more.press("ArrowUp");
  assert.equal(await focus(), "Quit DigUp");
  await page.keyboard.press("Tab");
  await menu.waitFor({ state: "hidden" });
  assert.match(await focus(), /^(?:All|[0-9]+ results shown)$/, "Tab must advance from More");
  await more.click();
  await more.click();
  await menu.waitFor({ state: "hidden" });
  assert.equal(await more.getAttribute("aria-expanded"), "false");

  const fileTypes = page.locator("#file-types");
  const typeMenu = page.getByRole("menu", { name: "File types" });
  await fileTypes.press("ArrowDown");
  await typeMenu.getByRole("menuitemradio", { name: /^Documents\b/ }).click();
  await page.waitForFunction(() => state.finalGeneration === state.generation);
  await assertSelected(page, /Field notes|Travel notes/);
  assert.match(await fileTypes.textContent(), /Documents/);
  await fileTypes.press("Enter");
  const checkedType = typeMenu.getByRole("menuitemradio", { checked: true });
  assert.ok(await checkedType.evaluate(node => node === document.activeElement));
  await page.keyboard.press("Escape");
  assert.equal(await fileTypes.getAttribute("aria-expanded"), "false");
  assert.equal(await focus(), "file-types");
  await query.fill("code: open a file");
  await page.waitForSelector(".code-list .row");
  await assertSelected(page, /source\.swift/);
  await query.fill("settings: display");
  await page.waitForSelector('.windows-settings-group [data-result-key="setting:display"]');
  await assertSelected(page, /Display/);
  await query.fill("apps: photo");
  await page.waitForSelector(".app-row.selected");
  await assertSelected(page, /Photo Studio/);

  const themeRatios = {};
  for (const colorScheme of ["light", "dark"]) {
    await page.emulateMedia({ colorScheme });
    for (const theme of ["system", "light", "dark"]) {
      await page.evaluate(value => AppearanceUI.apply(value), theme);
      const dark = (theme === "system" ? colorScheme : theme) === "dark";
      const icon = page.locator(".app-row.selected .app-generic");
      assert.equal(await icon.evaluate(node => getComputedStyle(node).filter !== "none"), dark,
        "Fallback icon follows the effective DigUp theme");
      const chip = page.locator('.chip[aria-pressed="true"]');
      const launch = page.locator(".app-row.selected .app-launch");
      await more.press("Enter");
      await page.keyboard.press("End");
      const pairs = [await contrast(chip), await contrast(launch), await contrast(menu.getByRole("menuitem", { name: "Quit DigUp" }))];
      assert.ok(pairs.every(ratio => ratio >= 4.5), `Insufficient contrast in ${colorScheme}/${theme}: ${pairs}`);
      themeRatios[`${colorScheme}/${theme}`] = Math.min(...pairs).toFixed(2);
      await page.keyboard.press("Escape");
    }
  }
  await page.emulateMedia({ colorScheme: "dark" });
  await page.evaluate(() => AppearanceUI.apply("dark"));
  await page.locator('[data-title="All"]').click();
  await query.fill("notes");
  await page.waitForFunction(() => state.finalGeneration === state.generation);
  await query.press("ArrowDown");
  const openInPane = page.locator("#side .actions .primary");
  assert.ok(await contrast(openInPane) >= 4.5);
  assert.equal(await page.locator("#side .facts .details").evaluate(node => getComputedStyle(node).fontSize), "12px");
  await query.press("Space");
  await dialog.waitFor();
  const previewRatio = await contrast(dialog.getByRole("button", { name: "Open", exact: true }));
  assert.ok(previewRatio >= 4.5);
  await capture(page, "search-preview-dark");
  await page.keyboard.press("Escape");

  await query.fill("apps: photo");
  await page.waitForSelector(".app-row.selected");
  await page.emulateMedia({ forcedColors: "active" });
  const forcedRow = page.locator(".app-row.selected");
  for (const selector of [".app-name", ".app-description", ".app-launch"]) {
    assert.ok(await contrast(forcedRow.locator(selector)) >= 4.5, `Forced colors hide ${selector}`);
  }
  assert.equal(await forcedRow.evaluate(node => getComputedStyle(node).outlineStyle), "solid");
  await query.focus();
  assert.equal(await page.locator("#field").evaluate(node => getComputedStyle(node).outlineStyle), "solid");
  await capture(page, "search-forced-colors");

  await page.emulateMedia({ forcedColors: "none", colorScheme: "light" });
  await page.evaluate(() => AppearanceUI.apply("system"));
  await page.locator("#status-line").click();
  await page.waitForFunction(() => document.querySelector('[data-key="first-value"]')?.textContent === "8");
  assert.equal(await query.getAttribute("aria-expanded"), "false");
  assert.equal(await query.getAttribute("aria-activedescendant"), null);
  for (const key of ["phase", "first-value", "second-value", "pause"]) {
    const onScreen = await page.locator(`[data-key="${key}"]`).evaluate(node => {
      const bounds = node.getBoundingClientRect(), pane = node.closest(".activity-view").getBoundingClientRect();
      return bounds.top >= pane.top && bounds.bottom <= pane.bottom;
    });
    assert.ok(onScreen, `Activity ${key} needs scrolling at 820×520`);
  }
  await capture(page, "search-activity-compact");
  await page.getByRole("button", { name: "Pause indexing" }).click();
  assert.ok(await page.evaluate(() => calls.some(call => call.command === "pause_indexing" && call.args.paused)));
  await page.getByRole("tab", { name: "Diagnostics", exact: true }).click();
  assert.equal(await page.getByRole("tab", { name: "Diagnostics" }).getAttribute("aria-selected"), "true");
  await page.getByRole("button", { name: "Close", exact: true }).click();
  await assertSelected(page, /Photo Studio/);

  const launchCount = () => page.evaluate(() => calls.filter(call => call.command === "launch_app").length);
  const launchesBeforeActivity = await launchCount();
  await page.locator("#status-line").click();
  await query.focus();
  await query.press("Enter");
  assert.equal(await launchCount(), launchesBeforeActivity, "Enter launched a result hidden behind Activity");
  await query.click();
  await page.locator("#content").waitFor();
  await assertSelected(page, /Photo Studio/);
  await query.press("Enter");
  assert.equal(await launchCount(), launchesBeforeActivity + 1);

  await page.locator("#status-line").click();
  await query.fill("notes");
  await page.locator("#content").waitFor();
  await page.waitForFunction(() => state.finalGeneration === state.generation);
  await assertSelected(page, /Field notes|Travel notes/);
  await page.evaluate(() => { window.rejectFileSearch = true; });
  await query.fill("photo");
  const retryFiles = page.getByRole("button", { name: "Retry file search", exact: true });
  await retryFiles.waitFor();
  await page.locator("#search-sections .app-row").first().waitFor();
  assert.ok(await retryFiles.evaluate(node => {
    const r = node.getBoundingClientRect();
    return node.contains(document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2));
  }), "Mixed results pushed file recovery below the viewport");
  await capture(page, "search-file-recovery");
  await page.evaluate(() => { window.rejectFileSearch = false; });
  await retryFiles.click();
  assert.equal(await focus(), "query");
  await retryFiles.waitFor({ state: "hidden" });
  await page.locator('[data-title="All"]').click();
  await query.fill("no-word-matches");
  await page.getByText(/Try a filename or words you remember/).waitFor();
  assert.equal(await query.getAttribute("aria-expanded"), "false");
  assert.equal(await query.getAttribute("aria-activedescendant"), null);

  await page.setViewportSize({ width: 440, height: 560 });
  await query.fill("apps: photo");
  await page.locator(".app-row.selected").waitFor();
  assert.equal(await page.locator("#side").isVisible(), false);
  assert.ok(await page.locator(".top").evaluate(node => node.getBoundingClientRect().height < 150));
  const details = page.getByRole("button", { name: "Result details" });
  await details.click();
  assert.equal(await details.getAttribute("aria-pressed"), "true");
  assert.ok(await page.locator("#side .app-name").isVisible());

  await page.setViewportSize({ width: 720, height: 620 });
  await page.goto(base + "/index.html");
  await page.waitForFunction(() => document.querySelector("#panel").offsetHeight === 120);
  const keyHelp = page.getByRole("button", { name: "Help", exact: true });
  await keyHelp.click();
  await help.waitFor();
  assert.match(await help.textContent(), /Open this search in the full window/);
  await page.waitForFunction(() => document.querySelector("#panel").offsetHeight > 120);
  await page.keyboard.press("Escape");
  assert.equal(await focus(), "search-help-button");
  await page.waitForFunction(() => document.querySelector("#panel").offsetHeight === 120);
  assert.ok(await page.getByRole("navigation", { name: "Pinned and recent applications" }).isVisible());
  await query.fill("no-word-matches");
  await page.getByText(/Try a filename or words you remember/).waitFor();
  assert.deepEqual(errors, []);
  console.log("Search contrast minima by OS/app theme:", themeRatios, "dark preview:", previewRatio.toFixed(2));
  console.log("PASS: active results, modal focus, menu navigation, effective themes, forced colors, compact Activity and words-only guidance");
}

(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.DIGUP_CHROME || "/usr/bin/chromium",
    headless: true, args: ["--no-sandbox", "--disable-dev-shm-usage"],
  });
  try { await run(browser); } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });

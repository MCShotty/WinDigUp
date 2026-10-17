"use strict";
const {chromium} = require("playwright");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {setup} = require("./application-fixtures.cjs");
const base = process.env.DIGUP_UI_URL || "http://127.0.0.1:8765";
let browser;
(async () => {
  browser = await chromium.launch({executablePath: process.env.DIGUP_CHROME || "/usr/bin/chromium",
    headless: true, args: ["--no-sandbox", "--disable-dev-shm-usage"]});
  for (const view of ["window.html", "index.html"]) {
    const page = await browser.newPage({viewport: {width: 1120, height: 800}}), errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await setup(page);
    await page.addInitScript(() => {
      const old = window.__TAURI__.core.invoke;
      const file = (name, kind = "doc", score = 4) => ({path: "C:/docs/" + name, kind, score, keyword_rank: 1,
        segment: kind === "pdf" ? "page" : "chunk", segment_id: name.length, loc: 2,
        size: 100, modified: 1, info: {}, excerpt: "Synthetic search fixture"});
      const app = (id, name, reason = "exact") => ({id: "app:" + id, name, reason, resultType: "application",
        kind: "app", aliases: [], publisher: "Fixture application", description: "Synthetic catalog result"});
      const setting = (id, name, reason = "exact") => ({id: "setting:" + id, name, reason, resultType: "windows_setting",
        kind: "windows_setting", aliases: [], publisher: "Windows", description: "Open this Windows settings page"});
      window.mixedPreference = "smart"; window.fileFailure = false; window.blockFiles = false; window.fileWaits = [];
      window.releaseFiles = () => {window.blockFiles = false; window.fileWaits.splice(0).forEach(resolve => resolve());};
      window.cases = {
        bluetooth: {files: [file("Bluetooth notes.txt")], settings: [setting("bluetooth", "Bluetooth")]},
        sound: {files: [file("waves.mp3", "audio", 900)], settings: [setting("sound", "Sound")]},
        photos: {files: [file("Holiday.jpg", "image", 900)], apps: [app("photos", "Photos")]},
        "budget.pdf": {files: [file("Holiday.jpg", "image", 900), file("Budget.pdf", "pdf", 1)], strong: 1},
        studio: {files: [file("Studio.txt")], apps: [app("studio-a", "Studio"), app("studio-b", "Studio")],
          settings: [setting("studio", "Studio")]},
        vscode: {files: [file("Code notes.txt")], apps: [{...app("code", "Visual Studio Code"), aliases: ["vscode"]}]},
        "بلوتوث": {files: [file("Bluetooth notes.txt")], settings: [{...setting("bluetooth", "Bluetooth"), aliases: ["بلوتوث"]}]},
        forest: {files: ["1.jpg", "2.mp4", "3.txt", "4.jpg", "5.txt", "6.mp4", "7.pdf"].map((name, i) =>
          file(name, ["image", "video", "doc", "image", "doc", "video", "pdf"][i], 20 - i))},
        display: {files: Array.from({length: 8}, (_, i) => file("Alpha Display " + i + ".txt")),
          settings: [setting("z-one", "Zed Display One", "prefix"), setting("z-two", "Zed Display Two", "prefix")],
          apps: [app("tool", "Display Utility", "semantic")]},
        "warm screen": {files: [], settings: [setting("night-light", "Night light", "semantic")]},
        "": {files: [], apps: [app("alpha", "Alpha App"), app("zebra", "Zebra App")],
          settings: [setting("bluetooth", "Bluetooth"), setting("sound", "Sound")]},
      };
      const catalog = () => ({supported: true, enabled: true, semanticEnabled: true, ordinarySearches: true,
        mixedSearch: window.mixedPreference, revision: "ordering-fixture", count: 20, refreshing: false});
      window.__TAURI__.core.invoke = async (command, args = {}) => {
        if (command === "window_info") return {...await old(command, args), applications: catalog(), windowsSettings: catalog()};
        if (command === "search_apps" || command === "search_windows_settings") {
          window.calls.push({command, args});
          const data = window.cases[args.q.toLowerCase()] || {};
          const hits = (command === "search_apps" ? data.apps : data.settings) || [];
          const visible = hits.filter(hit => args.meaning || hit.reason !== "semantic");
          return {hits: visible.slice(args.offset || 0, (args.offset || 0) + args.limit), total: visible.length,
            generation: args.generation, catalog: catalog(), semantic: {state: "ready", encoder: "ready"}};
        }
        if (command === "open_windows_setting" || command === "cancel_windows_settings_search") {
          window.calls.push({command, args}); return {accepted: true};
        }
        if (command === "ask" && args.request.op === "search") {
          window.calls.push({command, args});
          if (window.blockFiles) await new Promise(resolve => window.fileWaits.push(resolve));
          if (window.fileFailure) throw new Error("Fixture file helper unavailable");
          const data = window.cases[args.request.q.toLowerCase()] || {};
          const files = data.files || [];
          return {hits: files, strong: data.strong ?? files.length, meaning: args.request.meaning,
            generation: args.request.generation, facets: {}, count_scope: "ranked_candidates"};
        }
        return old(command, args);
      };
    });
    await page.goto(base + "/" + view);
    const root = view === "window.html" ? "#content" : "#list";
    const firstKey = () => page.locator(root + " [data-result-key]").first().getAttribute("data-result-key");
    const query = async (text, key) => {
      await page.fill("#query", text);
      await page.waitForSelector(root + ' [data-result-key="' + key + '"]');
      await page.waitForFunction(() => state.lexicalReady || state.error || state.fileError || state.isApps || state.isSettings
        || (typeof isAppsMode === "function" && (isAppsMode() || isSettingsMode())));
    };
    await page.evaluate(() => {window.blockFiles = true;});
    await page.fill("#query", "Bluetooth");
    await page.waitForSelector('.best-matches [data-result-key="setting:bluetooth"]');
    assert.equal(await firstKey(), "setting:bluetooth");
    await page.press("#query", "Enter");
    assert.equal(await page.evaluate(() => window.calls.filter(call => call.command === "open_windows_setting").at(-1).args.settingId), "setting:bluetooth");
    await page.evaluate(() => window.releaseFiles());
    await page.waitForFunction(() => state.lexicalReady);
    assert.equal(await page.locator(root + ' .selected').first().getAttribute("data-result-key"), "setting:bluetooth");
    await query("Sound", "setting:sound"); assert.equal(await firstKey(), "setting:sound");
    await query("Photos", "app:photos"); assert.equal(await firstKey(), "app:photos");
    await query("Budget.pdf", "file:C:/docs/Budget.pdf");
    assert.equal(await firstKey(), "file:C:/docs/Budget.pdf", "An exact filename was hidden as a weaker semantic match");
    await page.press("#query", "Enter");
    assert.equal(await page.evaluate(() => window.calls.filter(call => call.command === "open_path").at(-1).args.page), 2);
    await query("Studio", "setting:studio");
    assert.equal(await page.locator(".best-matches [data-result-key]").count(), 4);
    const collisionKeys = await page.locator(root + " [data-result-key]").evaluateAll(nodes => nodes.map(node => node.dataset.resultKey));
    assert.equal(new Set(collisionKeys).size, collisionKeys.length);
    await query("vscode", "app:code"); assert.equal(await firstKey(), "app:code");
    await query("بلوتوث", "setting:bluetooth"); assert.equal(await firstKey(), "setting:bluetooth");
    await query("forest", "file:C:/docs/7.pdf");
    assert.deepEqual(await page.locator(root + " [data-result-key]").evaluateAll(nodes => nodes.map(node => node.dataset.resultKey)),
      ["1.jpg", "2.mp4", "3.txt", "4.jpg", "5.txt", "6.mp4", "7.pdf"].map(name => "file:C:/docs/" + name),
      "File kinds changed the provider's relevance order");
    await page.locator(root + ' [data-result-key="file:C:/docs/2.mp4"]').click();
    await page.evaluate(() => {window.savedFile = document.querySelector('[data-result-key="file:C:/docs/2.mp4"]');
      window.emit("applications-progress", {state: "preparing", embedded: 2, total: 5});});
    await page.waitForTimeout(100);
    assert.equal(await page.evaluate(() => window.savedFile === document.querySelector('[data-result-key="file:C:/docs/2.mp4"]')), true);
    await page.press("#query", "Enter");
    assert.equal(await page.evaluate(() => window.calls.filter(call => call.command === "open_path").at(-1).args.path), "C:/docs/2.mp4");
    await query("display", "setting:z-one");
    if (view === "window.html") {
      await page.waitForSelector(".app-group:not(.best-matches):not(.windows-settings-group) .app-row");
      assert.ok(await page.evaluate(() => document.querySelector(".windows-settings-group")
        .compareDocumentPosition(document.querySelector(".app-group:not(.best-matches):not(.windows-settings-group)")) & Node.DOCUMENT_POSITION_FOLLOWING));
    }
    await page.evaluate(() => {window.fileFailure = true;});
    await query("warm screen", "setting:night-light");
    assert.match(await page.locator('[data-result-key="setting:night-light"]').textContent(), /Purpose match/);
    await page.press("#query", "Enter");
    assert.equal(await page.evaluate(() => window.calls.filter(call => call.command === "open_windows_setting").at(-1).args.settingId), "setting:night-light");
    await page.evaluate(() => {window.fileFailure = false; window.mixedPreference = "files-first";
      window.emit("applications", {supported: true, enabled: true, mixedSearch: "files-first", revision: "ordering-fixture"});});
    await query("Photos", "app:photos");
    assert.equal(await firstKey(), "file:C:/docs/Holiday.jpg");
    await page.evaluate(() => {window.mixedPreference = "apps-only";
      window.emit("applications", {supported: true, enabled: true, mixedSearch: "apps-only", revision: "ordering-fixture"});});
    await page.waitForFunction(() => !document.querySelector('[data-result-key="app:photos"]'));
    await query("Sound", "setting:sound"); assert.equal(await firstKey(), "setting:sound");
    await page.fill("#query", "apps:"); await page.waitForSelector('[data-result-key="app:alpha"]');
    assert.equal(await page.locator(root + " [data-result-key]").count(), 2);
    await page.fill("#query", "settings:"); await page.waitForSelector('[data-result-key="setting:bluetooth"]');
    assert.equal(await page.locator(root + " [data-result-key]").count(), 2);
    await page.evaluate(() => {window.mixedPreference = "smart";
      window.emit("applications", {supported: true, enabled: true, mixedSearch: "smart", revision: "ordering-fixture"});});
    await query("Sound", "setting:sound");
    if (view === "window.html") {
      await page.press("#query", "Control+4");
      await page.waitForFunction(() => state.filter === "documents");
      assert.equal(await page.locator(".app-row").count(), 0);
      await page.press("#query", "Control+1"); await page.waitForSelector('[data-result-key="setting:sound"]');
    }
    await page.evaluate(() => {
      const label = document.createElement("div"); label.textContent = "UI fixture · Synthetic search results";
      label.style.cssText = "position:fixed;bottom:2px;right:4px;font:12px Segoe UI;color:var(--text);background:var(--surface);z-index:100";
      document.body.append(label);
    });
    for (const [theme, width, height] of [["light", 1120, 800], ["dark", 760, 720], ["light", 520, 720]]) {
      await page.emulateMedia({colorScheme: theme}); await page.setViewportSize({width, height});
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), "Page overflow at " + width);
      assert.ok(await page.evaluate(() => [...document.querySelectorAll(".best-matches [data-result-key]")].every(node =>
        node.getBoundingClientRect().right <= innerWidth + 1)), "Best match overflow");
      await page.press("#query", "ArrowDown"); await page.press("#query", "ArrowUp");
      if (process.env.DIGUP_SEARCH_SCREENSHOTS) {
        fs.mkdirSync(process.env.DIGUP_SEARCH_SCREENSHOTS, {recursive: true});
        await page.screenshot({path: path.join(process.env.DIGUP_SEARCH_SCREENSHOTS, view + "-" + theme + "-" + width + ".png")});
      }
      if (process.env.DIGUP_ORDER_SCREENSHOT_LOG && theme === "light" && width === 1120)
        console.log("MIXED_SCREENSHOT_BASE64=" + (await page.screenshot({type: "jpeg", quality: 70})).toString("base64"));
    }
    assert.deepEqual(errors, []);
    await page.close();
  }
  await browser.close();
  console.log("PASS: both views, immediate settings under blocked files, exact weak filenames, ambiguous exact matches, aliases, Unicode, file order, source-local semantics, preferences, scopes, stable selection/DOM, native activation, themes and scaling");
})().catch(async error => {console.error(error); if (browser) await browser.close(); process.exit(1);});

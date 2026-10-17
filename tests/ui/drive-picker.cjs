"use strict";
const {chromium} = require("playwright"), assert = require("node:assert/strict"), fs = require("node:fs");
const {setup} = require("./application-fixtures.cjs");
const base = process.env.DIGUP_UI_URL || "http://127.0.0.1:8765";
let browser;
(async () => {
  browser = await chromium.launch({executablePath: process.env.DIGUP_CHROME || "/usr/bin/chromium", headless: true, args: ["--no-sandbox"]});
  const page = await browser.newPage({viewport: {width: 1100, height: 900}}), errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await setup(page);
  await page.addInitScript(() => {
    const old = window.__TAURI__.core.invoke;
    window.availableDrives = [{id: "volume-a", paths: ["C:\\"], name: "Fixture SSD", filesystem: "NTFS", available: true},
      {id: "volume-b", paths: ["E:\\"], name: "Fixture USB", filesystem: "exFAT", available: true}];
    window.drive = {version: 2, supported: true, catalogEnabled: false, options: {enabled: false, paused: false, revision: 1,
      volumes: [], included: ["exe:existing"], hidden: ["exe:hidden"]}, volumes: [], volumeCatalog: {state: "unavailable"},
      progress: {phase: "disabled"}, byVolume: {}};
    window.fileFolders = ["C:\\Users\\Test\\Documents"]; window.inventoryBlocked = true; window.inventoryWaiters = []; window.inventoryFailure = false;
    window.releaseInventory = () => {window.inventoryBlocked = false; window.inventoryWaiters.splice(0).forEach(resolve => resolve());};
    window.__TAURI__.core.invoke = async (command, args = {}) => {
      if (command === "settings_info") return {...await old(command, args), discovery: window.drive, folders: window.fileFolders};
      if (command === "refresh_discovery_volumes") {
        window.calls.push({command, args});
        if (window.inventoryFailure) throw new Error("Fixture Windows inventory unavailable");
        window.drive.volumeCatalog = {state: "loading"};
        (async () => {
          if (window.inventoryBlocked) await new Promise(resolve => window.inventoryWaiters.push(resolve));
          window.drive = {...window.drive, volumes: structuredClone(window.availableDrives), volumeCatalog: {state: "ready"}};
          window.emit("discovery", window.drive);
        })();
        return structuredClone(window.drive);
      }
      if (command === "set_discovery_options" || command === "set_drive_choices") {
        window.calls.push({command, args});
        window.drive.options = {...args.options, revision: window.drive.options.revision + 1};
        for (const choice of args.fileChoices || []) {
          const volume = window.availableDrives.find(row => row.id === choice.volumeId);
          if (!volume) throw new Error("Fixture drive disconnected");
          if (choice.enabled && !window.fileFolders.includes(volume.paths[0])) window.fileFolders.push(volume.paths[0]);
          if (!choice.enabled) window.fileFolders = window.fileFolders.filter(folder => !volume.paths.includes(folder));
        }
        return {...structuredClone(window.drive), folders: [...window.fileFolders]};
      }
      if (command === "discovery_candidates") return {hits: [], total: 0, catalogTotal: 0, generation: args.generation};
      return old(command, args);
    };
  });
  await page.goto(base + "/settings.html");
  await page.getByRole("tab", {name: "Drives", exact: true}).waitFor({state: "visible"});
  await page.getByRole("tab", {name: "Drives", exact: true}).click();
  await page.waitForFunction(() => window.calls.some(call => call.command === "refresh_discovery_volumes"));
  assert.equal(await page.locator("#drives").isVisible(), true);
  assert.equal(await page.locator("#drive-enabled").isChecked(), false);
  assert.match(await page.locator("#drive-volumes-state").innerText(), /Checking mounted drives/);
  assert.equal(await page.locator("#drive-list-refresh").isDisabled(), true);
  await page.evaluate(() => window.releaseInventory());
  await page.waitForFunction(() => document.querySelectorAll("#drive-volumes input[data-source=applications]").length === 2);
  assert.equal(await page.locator('#drive-volumes input[data-source=applications][value="volume-a"]').isEnabled(), true, "Disabled discovery blocked drive selection");
  await page.locator('#drive-volumes input[data-source=applications][value="volume-b"]').check();
  await page.locator("#drive-save").click();
  await page.waitForFunction(() => window.calls.some(call => call.command === "set_discovery_options"));
  let saved = await page.evaluate(() => window.calls.filter(call => call.command === "set_discovery_options").at(-1).args.options);
  assert.deepEqual(saved.volumes, ["volume-b"]); assert.equal(saved.enabled, false);
  assert.deepEqual(saved.included, ["exe:existing"]); assert.deepEqual(saved.hidden, ["exe:hidden"]);
  await page.locator("#drive-enabled").check();
  await page.locator("#drive-paused").check();
  await page.locator('#drive-volumes input[data-source=applications][value="volume-a"]').check();
  await page.evaluate(() => {
    window.availableDrives[0].paths = ["D:\\"];
    window.availableDrives.push({id: "volume-c", paths: ["F:\\"], name: "Fixture new drive", filesystem: "NTFS", available: true});
  });
  await page.locator("#drive-list-refresh").click();
  await page.waitForFunction(() => document.querySelectorAll("#drive-volumes input[data-source=applications]").length === 3);
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await page.waitForTimeout(100);
  assert.equal(await page.locator("#drive-enabled").isChecked(), true);
  assert.equal(await page.locator("#drive-paused").isChecked(), true);
  assert.equal(await page.locator('#drive-volumes input[data-source=applications][value="volume-a"]').isChecked(), true);
  assert.equal(await page.locator('#drive-volumes input[data-source=applications][value="volume-b"]').isChecked(), true);
  assert.equal(await page.locator('#drive-volumes input[data-source=applications][value="volume-c"]').isChecked(), false, "A newly attached drive was selected automatically");
  assert.match(await page.locator('#drive-volumes input[data-source=applications][value="volume-a"]').locator('xpath=ancestor::div[contains(@class,"source-volume")]').innerText(), /D:/);
  await page.locator("#drive-save").click();
  await page.waitForFunction(() => !DiscoverySettings.dirty);
  saved = await page.evaluate(() => window.calls.filter(call => call.command === "set_discovery_options").at(-1).args.options);
  assert.deepEqual(saved.volumes, ["volume-a", "volume-b"]); assert.equal(saved.paused, true);
  await page.locator('#drive-volumes input[data-source=applications][value="volume-c"]').check();
  await page.evaluate(() => {window.inventoryFailure = true;});
  await page.locator("#drive-list-refresh").click();
  await page.waitForFunction(() => document.querySelector("#source-message-volumes").textContent.includes("unavailable"));
  assert.equal(await page.locator("#drive-volumes input[data-source=applications]").count(), 3);
  assert.equal(await page.locator('#drive-volumes input[data-source=applications][value="volume-c"]').isChecked(), true);
  await page.locator("#drive-revert").click();
  assert.equal(await page.locator('#drive-volumes input[data-source=applications][value="volume-c"]').isChecked(), false);
  await page.evaluate(() => {window.inventoryFailure = false; window.availableDrives = window.availableDrives.filter(drive => drive.id !== "volume-b");});
  await page.locator("#drive-list-refresh").click();
  await page.waitForFunction(() => document.querySelector('#drive-volumes input[data-source=applications][value="volume-b"]')?.closest(".source-volume").textContent.includes("Disconnected"));
  assert.equal(await page.locator('#drive-volumes input[data-source=applications][value="volume-b"]').isChecked(), true);
  await page.locator('#drive-volumes input[data-source=files][value="volume-a"]').check();
  await page.locator("#drive-save").click();
  await page.waitForFunction(() => window.calls.some(call => call.command === "set_drive_choices"));
  let both = await page.evaluate(() => window.calls.filter(call => call.command === "set_drive_choices").at(-1).args);
  assert.deepEqual(both.fileChoices, [{volumeId: "volume-a", enabled: true}]);
  assert.deepEqual(both.options.volumes, ["volume-a", "volume-b"], "File choices changed application discovery");
  assert.deepEqual(await page.evaluate(() => window.fileFolders), ["C:\\Users\\Test\\Documents", "D:\\"]);
  assert.equal(await page.locator('#drive-volumes input[data-source=files][value="volume-a"]').isChecked(), true);
  await page.locator('#drive-volumes input[data-source=files][value="volume-a"]').uncheck();
  await page.locator("#drive-save").click();
  await page.waitForFunction(() => !DiscoverySettings.dirty);
  assert.deepEqual(await page.evaluate(() => window.fileFolders), ["C:\\Users\\Test\\Documents"], "Removing a drive erased selected subfolders");
  await page.getByRole("tab", {name: "Apps", exact: true}).click();
  await page.locator("#open-drives").click(); assert.equal(await page.locator("#drives").isVisible(), true);
  for (const [theme, width] of [["light", 1100], ["dark", 760], ["light", 520]]) {
    await page.emulateMedia({colorScheme: theme}); await page.setViewportSize({width, height: 900});
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
    if (process.env.DIGUP_ACTIVITY_SCREENSHOTS) {
      fs.mkdirSync(process.env.DIGUP_ACTIVITY_SCREENSHOTS, {recursive: true});
      await page.screenshot({path: process.env.DIGUP_ACTIVITY_SCREENSHOTS + "/drive-picker-" + theme + "-" + width + ".png", fullPage: true});
    }
  }
  assert.deepEqual(errors, []);
  await browser.close();
  console.log("PASS: visible Drives tab, loading and retry, selection before enabling discovery, GUID identity, attach/detach, saved pause and review choices, unsaved drafts, Apps entry point, themes and narrow settings");
})().catch(async error => {console.error(error); if (browser) await browser.close(); process.exit(1);});

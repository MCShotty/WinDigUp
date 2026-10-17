"use strict";
const assert = require("node:assert/strict");
const order = require("../../shell/ui/mixed-results.js");
const file = (name, kind = "doc", score = 4) => ({path: "C:/docs/" + name, kind, score, keyword_rank: 1});
const app = (id, name, reason = "exact") => ({id: "app:" + id, resultType: "application", name, reason});
const setting = (id, name, reason = "exact") => ({id: "setting:" + id, resultType: "windows_setting", name, reason});
const keys = hits => hits.map(hit => order.key(hit));
const flatten = plan => [...plan.best, ...plan.sections.flatMap(section => section.hits)];

let plan = order.compose({text: "Bluetooth", files: [file("Bluetooth notes.txt")], settings: [setting("bluetooth", "Bluetooth")]});
assert.equal(plan.best[0].id, "setting:bluetooth");
plan = order.compose({text: "Sound", files: [file("audio.mp3", "audio", 900)], settings: [setting("sound", "Sound")]});
assert.equal(plan.best[0].id, "setting:sound");

const collisions = [file("Studio.txt"), app("studio-a", "Studio"), app("studio-b", "Studio"), setting("studio", "Studio")];
plan = order.compose({text: "Studio", files: [collisions[0]], apps: collisions.slice(1, 3), settings: [collisions[3]]});
assert.deepEqual(new Set(keys(plan.best)), new Set(keys(collisions)));
assert.equal(new Set(keys(flatten(plan))).size, flatten(plan).length);
plan = order.compose({text: "Studio.txt", files: [file("Studio.txt"), file("Studio notes.txt")], apps: [app("studio", "Studio", "substring")]});
assert.equal(plan.best[0].path, "C:/docs/Studio.txt");
plan = order.compose({text: "vscode", apps: [{...app("code", "Visual Studio Code"), aliases: ["vscode"]}], files: [file("Code notes.txt")]});
assert.equal(plan.best[0].id, "app:code");
assert.equal(order.compose({text: "photos", apps: [app("photos", "Photos")], files: [file("holiday.png", "image")]}).best[0].id, "app:photos");
assert.equal(order.compose({text: "CＡFÉ", files: [file("café.pdf")]}).best[0].path, "C:/docs/café.pdf");
assert.equal(order.tier(file("Straße.txt"), "STRASSE"), 0);
assert.equal(order.tier(file("Bluetooth notes.txt"), "bluetooth"), 1);
assert.equal(order.tier(file("Visual Studio.txt"), "vst"), 2);
assert.equal(order.tier(setting("display", "Display", "fuzzy"), "displai"), 3);
assert.equal(order.tier(setting("night", "Night light", "semantic"), "warm screen"), 4);
assert.equal(order.tier(setting("night", "Night light", "semantic"), "Night light"), 4);
for (const name of ["البلوتوث", "বাংলা", "日本語", "İstanbul"])
  assert.equal(order.tier(file(name + ".txt"), name), 0);

const rankedFiles = Array.from({length: 15}, (_, i) => file("result-" + i + ".txt", ["image", "doc", "video"][i % 3], 100 - i));
plan = order.compose({text: "forest", files: rankedFiles});
assert.deepEqual(keys(flatten(plan)), keys(rankedFiles), "File kinds regrouped the provider's relevance order");
const candidates = {
  text: "warm screen", files: rankedFiles,
  apps: [app("b", "Brightness Tool", "semantic")],
  settings: [setting("night", "Night light", "semantic")],
};
const first = order.compose(candidates);
const second = order.compose({...candidates, files: rankedFiles.map(hit => ({...hit, score: -1})),
  apps: candidates.apps.map(hit => ({...hit, score: 999999, cosine: 1})),
  settings: candidates.settings.map(hit => ({...hit, score: -999999, cosine: -1}))});
assert.deepEqual(keys(flatten(first)), keys(flatten(second)), "Incompatible provider scores were compared");
assert.equal(first.best.length, 5);
assert.ok(first.best.some(hit => hit.id === "setting:night"));
plan = order.compose({...candidates, preference: "files-first"});
const all = flatten(plan);
assert.ok(all.findIndex(hit => hit.id === "app:b") > Math.max(...all.map((hit, i) => order.source(hit) === "files" ? i : -1)));
assert.equal(flatten(order.compose({...candidates, preference: "apps-only"})).some(hit => order.source(hit) === "apps"), false);
for (const mode of ["apps", "settings", "files", "code"]) {
  const scoped = order.compose({...candidates, mode});
  assert.equal(scoped.best.length, 0);
  assert.ok(scoped.rows.every(hit => order.source(hit) === (mode === "code" ? "files" : mode)));
}
assert.equal(order.compose({text: "", apps: [app("1", "Photos")]}).rows.length, 0);
assert.equal(order.compose({text: "apps:", mode: "apps", apps: [app("1", "Photos")]}).rows.length, 1);
console.log("PASS: shared match classes, exact collisions, aliases, category ambiguity, Unicode, source-local semantic scores, preferences, scopes, and file relevance order");

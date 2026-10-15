"use strict";
const appDrafts = new Map();
let appSettingsGeneration = 0;
let appSettingsOffset = 0;
let appSettingsTimer;
let appSettingsInfo = {};

function renderApplications() {
  const settings = info.applications || {};
  appSettingsInfo = settings;
  document.getElementById("apps-tab").hidden = !settings.supported;
  document.getElementById("apps-enabled").checked = Boolean(settings.enabled);
  document.getElementById("apps-semantic").checked = Boolean(settings.semanticEnabled);
  document.getElementById("apps-semantic").disabled = !settings.enabled;
  const issues = Object.values(settings.sourceErrors || {});
  document.getElementById("apps-status").textContent = `${settings.count || 0} applications${settings.refreshing ? " · Refreshing…" : ""}${issues.length ? ` · Some sources could not refresh: ${issues.join("; ")}` : ""}`;
  if (settings.supported && !document.getElementById("apps").hidden && !appDrafts.size) loadApplicationSettings();
}

async function loadApplicationSettings(append = false) {
  if (!appSettingsInfo.supported) return;
  const generation = ++appSettingsGeneration;
  try {
    const reply = await invoke("search_apps", { q: document.getElementById("apps-filter").value, meaning: false,
      generation, limit: 100, offset: append ? appSettingsOffset : 0, includeHidden: true });
    if (generation !== appSettingsGeneration) return;
    const box = document.getElementById("apps-editors");
    if (!append) { box.replaceChildren(); appSettingsOffset = 0; }
    for (const hit of reply.hits) box.append(applicationEditor(hit));
    appSettingsOffset += reply.hits.length;
    document.getElementById("apps-more").hidden = appSettingsOffset >= reply.total;
  } catch (e) { fail(e?.message || e); }
}

function applicationEditor(hit) {
  const box = element("div", "app-editor");
  box.dataset.appId = hit.id;
  box.append(element("div", "app-name", hit.name));
  if (hit.publisher) box.append(element("div", "app-description", hit.publisher));
  const value = appDrafts.get(hit.id) || { aliases: hit.aliases || [], purpose: hit.purpose || "", hidden: hit.hidden || false };
  const aliases = element("textarea"); aliases.value = value.aliases.join("\n"); aliases.setAttribute("aria-label", `${hit.name} aliases`);
  const purpose = element("textarea"); purpose.value = value.purpose; purpose.maxLength = 1024; purpose.setAttribute("aria-label", `${hit.name} purpose`);
  const hidden = element("input"); hidden.type = "checkbox"; hidden.checked = value.hidden;
  const hiddenLabel = element("label", "", "Hide from search "); hiddenLabel.prepend(hidden);
  const labelA = element("label", "", "Aliases (one per line)"); labelA.append(aliases);
  const labelP = element("label", "", "What this application does (optional)"); labelP.append(purpose);
  function draft() {
    const value = { aliases: aliases.value.split("\n").map(s => s.trim()).filter(Boolean), purpose: purpose.value.trim(), hidden: hidden.checked };
    appDrafts.set(hit.id, value); return value;
  }
  aliases.oninput = purpose.oninput = hidden.onchange = draft;
  const save = element("button", "", "Save");
  const reset = element("button", "", "Reset to Windows metadata");
  async function commit(value) {
    save.disabled = reset.disabled = true;
    try {
      await invoke("set_app_override", { appId: hit.id, value }); appDrafts.delete(hit.id);
      await loadApplicationSettings();
    } catch (e) { fail(e?.message || e); save.disabled = reset.disabled = false; }
  }
  save.onclick = () => commit(draft());
  reset.onclick = () => commit({ aliases: [], purpose: "", hidden: false });
  box.append(labelA, labelP, hiddenLabel, save, reset);
  return box;
}

for (const id of ["apps-enabled", "apps-semantic"]) {
  document.getElementById(id).onchange = async () => {
    try {
      info.applications = await invoke("set_app_options", { enabled: document.getElementById("apps-enabled").checked,
        semanticEnabled: document.getElementById("apps-semantic").checked });
      renderApplications();
    } catch (e) { fail(e?.message || e); renderApplications(); }
  };
}
document.getElementById("apps-refresh").onclick = async () => {
  try { info.applications = await invoke("refresh_apps"); renderApplications(); if (!appDrafts.size) loadApplicationSettings(); }
  catch (e) { fail(e?.message || e); }
};
document.getElementById("apps-filter").oninput = () => { clearTimeout(appSettingsTimer); appSettingsTimer = setTimeout(() => loadApplicationSettings(), 120); };
document.getElementById("apps-more").onclick = () => loadApplicationSettings(true);
window.__TAURI__.event.listen("applications", ({ payload }) => { info.applications = payload; renderApplications(); });
window.__TAURI__.event.listen("applications-progress", ({ payload }) => {
  if (!appSettingsInfo.supported) return;
  document.getElementById("apps-status").textContent = payload.state === "unavailable"
    ? `App names available; purpose matching unavailable: ${payload.message || "configure your accelerator in General"}`
    : `${appSettingsInfo.count || 0} applications · Purpose matching: ${payload.embedded || 0} of ${payload.total || 0} prepared`;
});

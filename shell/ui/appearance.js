"use strict";
window.AppearanceUI = (() => {
  const themes = new Set(["system", "light", "dark"]), materials = new Set(["automatic", "solid"]);
  let selected = "system", material = "automatic", busy = false, panel = null;
  function syncControls() {
    const theme = document.getElementById("appearance"), surface = document.getElementById("panel-material");
    if (theme && !busy) theme.value = selected;
    if (surface && !busy) surface.value = material;
    const option = document.getElementById("panel-material-option");
    if (option) option.hidden = panel?.supported !== true;
    const note = document.getElementById("panel-material-note");
    if (note) note.textContent = panel?.material === "acrylic" ? "Windows transparency is active in the search panel."
      : panel?.reason || "Automatic follows Windows transparency and contrast settings.";
  }
  function apply(value) {
    selected = themes.has(value) ? value : "system";
    document.documentElement.dataset.theme = selected;
    syncControls();
  }
  function applyPanel(value) {
    panel = value || null;
    document.documentElement.dataset.panelMaterial = value?.material === "acrylic" ? "acrylic" : "solid";
    syncControls();
  }
  function snapshot(reply) {
    if (!reply || typeof reply !== "object") return;
    if (themes.has(reply.appearance)) apply(reply.appearance);
    if (materials.has(reply.panelMaterial)) material = reply.panelMaterial;
    if (reply.panel) applyPanel(reply.panel);
    syncControls();
  }
  async function save(value, type = "appearance") {
    if (busy || !(type === "appearance" ? themes : materials).has(value)) return;
    const ids = ["appearance", "panel-material"], message = document.getElementById("appearance-message");
    busy = true;
    for (const id of ids) { const input = document.getElementById(id); if (input) input.disabled = true; }
    try {
      const reply = await window.__TAURI__.core.invoke(type === "appearance" ? "set_appearance" : "set_panel_material",
        type === "appearance" ? {appearance: value} : {material: value});
      busy = false; snapshot(reply);
      if (message) message.textContent = type === "appearance" ? "Appearance saved." : "Panel appearance saved.";
    } catch (error) {
      busy = false; syncControls();
      if (message) message.textContent = error?.message || String(error);
    } finally {
      for (const id of ids) { const input = document.getElementById(id); if (input) input.disabled = false; }
    }
  }
  apply("system");
  if (window.__TAURI__) {
    window.__TAURI__.event.listen("appearance", ({payload}) => snapshot(payload));
    window.__TAURI__.event.listen("panel-appearance", ({payload}) => applyPanel(payload));
    window.__TAURI__.core.invoke("appearance").then(snapshot).catch(() => apply("system"));
  }
  document.addEventListener("DOMContentLoaded", () => {
    syncControls();
    const theme = document.getElementById("appearance"), surface = document.getElementById("panel-material");
    if (theme) theme.onchange = () => save(theme.value);
    if (surface) surface.onchange = () => save(surface.value, "material");
  });
  return {apply, applyPanel, save};
})();

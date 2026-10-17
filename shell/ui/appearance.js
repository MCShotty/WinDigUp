"use strict";
window.AppearanceUI = (() => {
  let selected = "system";
  let busy = false;
  const choices = new Set(["system", "light", "dark"]);
  function apply(value) {
    selected = choices.has(value) ? value : "system";
    document.documentElement.dataset.theme = selected;
    const control = document.getElementById("appearance");
    if (control && !busy) control.value = selected;
  }
  async function save(value) {
    if (busy || !choices.has(value)) return;
    const control = document.getElementById("appearance");
    const message = document.getElementById("appearance-message");
    busy = true; if (control) control.disabled = true;
    try {
      const reply = await window.__TAURI__.core.invoke("set_appearance", { appearance: value });
      busy = false; apply(reply.appearance);
      if (message) message.textContent = "Appearance saved.";
    } catch (error) {
      busy = false; apply(selected);
      if (message) message.textContent = error?.message || String(error);
    } finally { if (control) control.disabled = false; }
  }
  if (window.__TAURI__) {
    window.__TAURI__.event.listen("appearance", ({ payload }) => apply(payload.appearance));
    window.__TAURI__.core.invoke("appearance").then(reply => apply(reply.appearance)).catch(() => apply("system"));
  }
  document.addEventListener("DOMContentLoaded", () => {
    const control = document.getElementById("appearance");
    if (control) { control.value = selected; control.onchange = () => save(control.value); }
  });
  return { apply, save };
})();

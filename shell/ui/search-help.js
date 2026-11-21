"use strict";

window.createSearchHelp = ({ quick = false, scopes, onExample, afterClose = () => {}, afterOpen = () => {} }) => {
  const button = document.getElementById("search-help-button");
  const dialog = document.createElement("dialog");
  dialog.id = "search-help";
  dialog.className = quick ? "search-help quick-help" : "search-help";
  dialog.setAttribute("aria-labelledby", "search-help-title");
  dialog.innerHTML = `
    <header class="search-help-header">
      <h2 id="search-help-title">Search help</h2>
      <button type="button" autofocus aria-label="Close search help">Close</button>
    </header>
    <div class="search-help-content" tabindex="0" role="region" aria-label="Search tips and keyboard shortcuts">
      <section>
      <h3>Try a search</h3>
      <dl class="search-help-examples">
        <div><dt>Files by name or contents</dt><dd><button class="help-example" type="button">a receipt from the hardware store</button></dd></div>
        <div data-scope="apps"><dt>Apps by name or purpose</dt><dd><button class="help-example" type="button">apps: paint</button></dd></div>
        <div data-scope="settings"><dt>Windows settings</dt><dd><button class="help-example" type="button">settings: display</button></dd></div>
        <div data-scope="code"><dt>Code by what it does</dt><dd><button class="help-example" type="button">code: retry a failed request</button></dd></div>
      </dl>
      <p>Names and exact words can match while the model prepares. Matches by meaning need a ready model and searchable content.</p>
      </section>
      <section>
      <h3>Keyboard shortcuts</h3>
      <dl class="search-help-shortcuts">
        <div><dt><kbd class="keycap">↑</kbd> <kbd class="keycap">↓</kbd></dt><dd>Select a result</dd></div>
        <div><dt><kbd class="keycap">Enter</kbd></dt><dd>Open the selected result</dd></div>
        <div><dt><kbd class="keycap">Space</kbd></dt><dd>Preview a file after selecting it</dd></div>
        <div><dt><kbd class="keycap">${MOD}Enter</kbd></dt><dd>Show the file in ${FILE_MANAGER}</dd></div>
        <div><dt><kbd class="keycap">${MOD}${quick ? "O" : "F"}</kbd></dt><dd>${quick ? "Open this search in the full window" : "Return to the search field"}</dd></div>
        <div><dt><kbd class="keycap">Esc</kbd></dt><dd>${quick ? "Close the preview or quick search" : "Close the preview, menu or Activity"}</dd></div>
      </dl>
      </section>
    </div>`;
  document.body.append(dialog);
  button.setAttribute("aria-controls", dialog.id);
  const close = dialog.querySelector("button"), content = dialog.querySelector(".search-help-content");
  function open() {
    if (dialog.open || document.querySelector("dialog[open]")) return;
    const available = scopes();
    for (const example of dialog.querySelectorAll("[data-scope]")) example.hidden = !available[example.dataset.scope];
    dialog.showModal();
    close.focus();
    content.scrollTop = 0;
    afterOpen();
  }
  button.onclick = open;
  close.onclick = () => dialog.close();
  for (const example of content.querySelectorAll(".help-example")) {
    example.onclick = () => { dialog.close(); onExample(example.textContent); };
  }
  dialog.addEventListener("close", afterClose);
  dialog.addEventListener("keydown", event => {
    if (event.key !== "Tab") return;
    const controls = [...dialog.querySelectorAll('button, [tabindex="0"]')].filter(node => node.getClientRects().length);
    const edge = event.shiftKey ? controls[0] : controls.at(-1);
    if (document.activeElement === edge) {
      event.preventDefault();
      (event.shiftKey ? controls.at(-1) : controls[0]).focus();
    }
  });
  document.addEventListener("keydown", event => {
    if (event.key !== "F1" || event.isComposing || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
    event.preventDefault();
    open();
  });
  return dialog;
};

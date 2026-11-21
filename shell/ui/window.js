// DigUp's window on Windows and Linux (tried out on the Mac first), for the searches the panel is too small for: kind
// filters with what the query found of each kind, the results as a grid of pictures (code as a list), the selected
// one in a preview pane with why it matched, and a status bar with indexing. Before a search it shows the home:
// examples to try, what's indexed, the shortcut. The Mac app's search window (Sources/DigUpApp/SearchWindow.swift) is
// the reference; the helper (`digup search-service`) does the work, and results.js has what a result says.
"use strict";

const TYPING_PAUSE = 120;   // ms after typing before semantic search
const LIMIT = 120;
const FILTERS = [
  { key: "screenshots", title: "Screenshots", kinds: ["screenshot"] },
  { key: "images", title: "Images", kinds: ["image"] },
  { key: "documents", title: "Documents", kinds: ["pdf", "doc"] },
  { key: "video", title: "Video", kinds: ["video"] },
  { key: "audio", title: "Audio", kinds: ["audio"] },
];
const FILTER_OF_KIND = { screenshot: "screenshots", image: "images", pdf: "documents", doc: "documents", video: "video",
                         audio: "audio" };
const EXAMPLES = [
  ["a screenshot of an error message", "screenshot"],
  ["a receipt from the hardware store", "doc"],
  ["someone laughing", "audio"],
];
/// What the home counts, in this order: "136 screenshots, 104 images, 25 PDFs…"
const KIND_ORDER = ["screenshot", "image", "pdf", "doc", "audio", "video", "code"];
const COUNTED = { screenshot: ["screenshot", "screenshots"], image: ["image", "images"], pdf: ["PDF", "PDFs"],
                  doc: ["document", "documents"], audio: ["audio file", "audio files"], video: ["video", "videos"],
                  code: ["code file", "code files"] };
const SEARCH_ICON = '<svg viewBox="0 0 24 24"><circle cx="10" cy="10" r="6.5"/><path d="M15 15 L20.5 20.5"/></svg>';

const $ = (id) => document.getElementById(id);
const $query = $("query"), $content = $("content"), $side = $("side"), $kinds = $("kinds"), $menu = $("menu");
const $scopes = $("search-scopes"), $fileTypes = $("file-types");
const $results = $("search-results"), $sections = $("search-sections"), $feedback = $("search-feedback"), $big = $("big-preview");
const compactPreview = matchMedia("(max-width: 700px)");

const state = {
  query: "",
  filter: null,         // a FILTERS key, "code", or null for everything
  text: "",             // what was searched (without "code:")
  ranked: [],           // the strong results, best first
  weaker: [],           // below half the best one's score: folded
  counts: {},           // strong results of each filter for the query, whatever the filter (the chips' numbers)
  meaning: true,        // the results matched by meaning too (false: words only)
  hasResults: false,    // the results of the query in the field are in
  filesPending: false,
  codePhase: null,      // "hint": "code:" alone; "off": no code folders
  selection: null,      // a result's path
  showWeaker: false,
  showsPreview: null,
  activityOpen: false,
  navigated: false,     // the selection was moved by the arrow keys or a click since the last edit: ← → move it then
  generation: 0,
  timer: null,
  error: null,
  fileError: null,
  info: { folders: [], hotkey: null, hasCode: false },
  app: {},              // indexing and the model, from the shell (status.rs): line, progress, caveat, counts
  indexed: null,        // files indexed of each kind (the home)
};
let debugPending = false;
const activityHost = document.createElement("section");
let activityReturnFocus = null;
const activityView = new ActivityUI.View(activityHost, { onClose: closeActivity });
function showActivity(tab = "overview") {
  const opening = !state.activityOpen;
  if (opening) activityReturnFocus = document.activeElement;
  state.activityOpen = true; document.body.classList.add("activity-open");
  renderSide();
  if (opening) { $side.scrollTop = 0; activityHost.scrollTop = 0; }
  activityView.show(tab); updateActiveResult(); updatePreviewButton(); activityView.get("close").focus();
}
function closeActivity(restoreFocus = true) {
  activityView.hide(); state.activityOpen = false; document.body.classList.remove("activity-open"); renderSide(); updateActiveResult(); updatePreviewButton();
  if (restoreFocus) (activityReturnFocus?.isConnected ? activityReturnFocus : $query).focus();
  activityReturnFocus = null;
}

function activityCoversResults() { return state.activityOpen && !$content.getClientRects().length; }

function returnToSearch() {
  if (!activityCoversResults()) return;
  closeActivity(false);
  $query.focus();
}
function providerChanged(statusOnly = false) {
  state.counts.apps = applicationSearch.total;
  state.counts.settings = settingsSearch.total;
  if (statusOnly) {
    const label = $content.querySelector(".app-purpose-state");
    if (label) label.textContent = applicationSearch.purposeLabel();
    renderStatus(); return;
  }
  const shown = rows();
  if (shown.length) state.hasResults = true;
  if (!state.navigated) state.selection = shown.length ? resultKey(shown[0]) : null;
  else if (!shown.some(hit => resultKey(hit) === state.selection)) { state.selection = null; state.chosen = null; }
  render();
  if (debugPending && (isAppsMode() || isSettingsMode())) report();
}
const applicationSearch = new ApplicationSearch(providerChanged, 3, () => isAppsMode() ? state.selection : null);
const settingsSearch = new WindowsSettingsSearch(providerChanged);
const searchHelp = createSearchHelp({ onExample: tryExample, scopes: () => ({
  apps: Apps.supported && Apps.enabled,
  settings: WindowsSettings.supported && WindowsSettings.enabled,
  code: state.info.hasCode,
}) });
function isSettingsMode() { return Apps.parse(state.query, state.filter).mode === "settings"; }
let layoutCache;
function resultLayout() {
  const mode = Apps.parse(state.query, state.filter).mode;
  const apps = applicationSearch.active ? applicationSearch.hits : null;
  const settings = settingsSearch.active ? settingsSearch.hits : null;
  const inputs = [mode, state.text, state.ranked, state.weaker, apps, settings, settingsSearch.mode, Apps.mixedSearch];
  if (layoutCache && inputs.every((input, index) => input === layoutCache.inputs[index])) return layoutCache.layout;
  const layout = MixedResults.compose({
    text: state.text, mode: mode === "all" && !Apps.supported ? "files" : mode,
    files: [...state.ranked, ...state.weaker.filter(hit => mode === "all" && MixedResults.tier(hit, state.text) <= 1)], apps: apps || [],
    settings: settingsSearch.visible(), preference: Apps.mixedSearch, includeEmptyFiles: state.weaker.length > 0,
  });
  layoutCache = { inputs, layout };
  return layout;
}
function windowsSettingsGroup(hits = settingsSearch.visible(), shownCount = hits.length) {
  const box = element("section", "windows-settings-group app-group" + (isSettingsMode() ? "" : " app-group-mixed"));
  box.setAttribute("aria-label", "Windows settings");
  const heading = element("div", "app-group-heading");
  heading.append(element("h2", "app-group-title", "Windows settings"));
  if (isSettingsMode()) heading.append(element("span", "app-group-count", settingsSearch.total + (settingsSearch.total === 1 ? " page" : " pages")));
  box.append(heading);
  if (hits.length) {
    const list = resultGroup("app-results", "Matching Windows settings");
    for (const hit of hits) list.append(Apps.row(hit, state.selection === resultKey(hit), select, open, true));
    box.append(list);
  }
  if ((!hits.length && isSettingsMode()) || settingsSearch.error) box.append(element("p", "app-status", settingsSearch.status()));
  if (settingsSearch.total > shownCount) {
    const more = element("button", "app-more", isSettingsMode() ? "Show more settings" : "Show all matching Windows settings");
    more.onclick = () => isSettingsMode() ? settingsSearch.more() : setFilter("settings"); box.append(more);
  }
  return box;
}

// MARK: Searching

function isCode() {
  return Apps.parse(state.query, state.filter).code;
}
function isAppsMode() { return Apps.parse(state.query, state.filter).mode === "apps"; }
function hasQuery() { return Boolean(state.query.trim()) || isAppsMode() || isSettingsMode(); }

function run(filesOnly = false) {
  filesOnly = filesOnly === true;
  const retained = filesOnly ? {selection:state.selection,chosen:state.chosen,navigated:state.navigated,handoff:state.handoff} : null;
  const generation = ++state.generation;
  state.handoff = retained?.handoff ? {key:retained.handoff.key,generation} : state.nextSelection ? {key: state.nextSelection, generation} : null;
  state.nextSelection = null;
  SearchTiming.begin(generation);
  state.exactFilenameKnown=false;state.exactFilename=false;
  state.lexicalReady=false;state.fileWords=[];state.categoryQuery=false;state.finalGeneration=-1;
  state.fileMeaning=null;state.fileWordsReply=null;state.fileWordsRefresh=false;state.fileScopeEmpty=null;
  let lexicalRequest=0,lexicalPublished=0,meaningRequest=0,meaningPublished=0;
  clearTimeout(state.timer);
  cancelAnimationFrame(state.frame);
  state.refine=null;
  state.navigated = retained ? retained.navigated : Boolean(state.handoff);
  state.chosen = retained?.chosen || null;
  state.error = null;
  state.fileError = null;
  state.ranked = []; state.weaker = []; state.hasResults = Boolean(filesOnly && (applicationSearch.hits.length || settingsSearch.visible().length)); state.filesPending = false; state.selection = retained?.selection || null;
  if(filesOnly)state.counts={apps:applicationSearch.total,settings:settingsSearch.total};
  const typed = state.query.trim();
  const mode = Apps.parse(typed, state.filter);
  const code = mode.code;
  const text = mode.text;
  if((mode.mode==="apps"||mode.mode==="settings"||!typed||(code&&!text))&&state.filesStarted){
    state.filesStarted=false;ask({op:"cancel",generation}).catch(()=>{});
  }
  applicationSearch.limit = mode.mode === "apps" ? 100 : 3;
  if(!filesOnly){
    applicationSearch.begin(text, mode.apps && (Boolean(typed) || mode.mode === "apps"),mode.mode);
    settingsSearch.begin(text,mode.settings&&(Boolean(typed)||mode.mode==="settings"),mode.mode);
  }
  state.codePhase = null;
  if (mode.mode === "settings") {
    Object.assign(state,{ranked:[],weaker:[],counts:{},text,hasResults:true,filesPending:false,selection:null});
    render();return;
  }
  if (mode.mode === "apps") {
    Object.assign(state, { ranked: [], weaker: [], counts: {}, text, hasResults: true, filesPending: false, selection: null });
    render(); return;
  }
  if (!typed || (code && (!state.info.hasCode || !text))) {
    Object.assign(state, { ranked: [], weaker: [], counts: {}, hasResults: false, selection: null });
    if (typed) state.codePhase = state.info.hasCode ? "hint" : "off";
    render();
    return;
  }
  state.text=text;
  state.filesPending=true;
  render();
  const filter=FILTERS.find(item=>item.key===state.filter);
  const search=async (meaning,passive=false)=>{
    const request=meaning?++meaningRequest:++lexicalRequest;
    state.filesStarted=true;
    try {
      let shown=await SearchTiming.measure(meaning?"file_meaning":"file_words",()=>ask({op:"search",q:text,code,meaning,
        prefix_last:!meaning,limit:LIMIT,kinds:filter&&!code?filter.kinds:null,facets:!code,generation,passive,phase:meaning?"meaning":"words"}),passive);
      if(generation!==state.generation||request<(meaning?meaningPublished:lexicalPublished)||shown.status==="superseded"||
        (shown.generation!=null&&shown.generation!==generation))return;
      if(meaning)meaningPublished=request;else lexicalPublished=request;
      if(meaning){
        state.finalGeneration=generation;state.fileMeaning=shown;
        if(shown.scope_empty===true){state.fileWords=[];state.fileWordsReply=null;state.fileWordsRefresh=false;state.lexicalReady=true;state.exactFilenameKnown=true;state.exactFilename=false;}
        if(state.fileWordsRefresh&&state.fileWordsReply)shown=mergeFileSearchReplies(shown,state.fileWordsReply,text);
      } else {
        if(shown.scope_empty===true)state.fileMeaning=null;
        state.lexicalReady=true;state.fileWords=shown.hits||[];state.fileWordsReply=shown;state.fileWordsRefresh ||= passive;
        state.categoryQuery=shown.category_query===true;
        state.exactFilenameKnown=shown.exact_filename_known!==false;state.exactFilename=shown.exact_filename===true;
        if(state.finalGeneration===generation)shown=mergeFileSearchReplies(state.fileMeaning,shown,text);
      }
      state.filesPending=false;state.fileScopeEmpty=shown.scope_empty===true;
      if(meaning&&shown.semantic_error)state.error=shown.semantic_error;
      const hits=shown.hits||[],strong=shown.strong??hits.length;
      const counts={apps:applicationSearch.total,settings:settingsSearch.total};
      if(code)counts.code=strong;
      else if(shown.facets&&Object.keys(shown.facets).length)for(const [kind,count] of Object.entries(shown.facets)){
        const key=FILTER_OF_KIND[kind];counts[key]=(counts[key]||0)+count;
      } else for(const hit of hits.slice(0,strong)){const key=FILTER_OF_KIND[hit.kind];counts[key]=(counts[key]||0)+1;}
      Object.assign(state,{counts,countScope:shown.count_scope,text,meaning:shown.meaning,hasResults:true,showWeaker:state.navigated&&state.showWeaker,
        ranked:hits.slice(0,strong),weaker:hits.slice(strong)});
      const shownRows=rows();
      if(!state.navigated)state.selection=shownRows.length?resultKey(shownRows[0]):null;
      else if(!shownRows.some(hit=>resultKey(hit)===state.selection)){state.selection=null;state.chosen=null;}
      render();if(debugPending&&meaning)report();
    }catch(error){
      if(generation!==state.generation||request!==(meaning?meaningRequest:lexicalRequest))return;
      state.filesPending=false;state.lexicalReady=true;
      if(!state.ranked.length){state.error=String(error);state.fileError=String(error);}
      if(!state.navigated){const shown=rows();state.selection=shown.length?resultKey(shown[0]):null;}
      render();
    }
  };
  cancelAnimationFrame(state.frame);
  state.frame=requestAnimationFrame(()=>search(false));
  state.refine=(passive=false)=>search(true,passive);
  state.refreshWords=()=>search(false,true);
  state.timer=setTimeout(()=>search(true),TYPING_PAUSE);

}

function setQuery(text) {
  $query.value = text;
  queryChanged();
}

function tryExample(text) {
  state.filter = null;
  $query.focus({ preventScroll: true });
  setQuery(text);
}

function queryChanged() {
  if(state.composing)return;
  returnToSearch();
  closeBig();
  state.query = $query.value;
  $("clear").hidden = !state.query;
  run();
}

function setFilter(key) {
  returnToSearch();
  if (key === state.filter && !/^(apps|settings|code):/i.test(state.query.trim())) return;
  state.filter = key;
  if (key !== "code" && /^code:/i.test(state.query.trim())) {
    // Leaving code for files: "code:" goes from the field.
    $query.value = state.query.trim().slice(5).trim();
    state.query = $query.value;
  }
  if (key !== "apps" && /^apps:/i.test(state.query.trim()) && Apps.supported) {
    $query.value = state.query.trim().slice(5).trim(); state.query = $query.value;
  }
  if(key!=="settings"&&/^settings:/i.test(state.query.trim())&&WindowsSettings.supported){
    $query.value=state.query.trim().slice(9).trim();state.query=$query.value;
  }
  run();
}

/// Every result shown, in order: the strong ones, then the weaker ones once they're unfolded.
function rows() {
  const layout = resultLayout(), shown = [...layout.best];
  for (const section of layout.sections) {
    shown.push(...section.hits);
    if (section.source === "files" && state.showWeaker) shown.push(...weakerFiles(layout));
  }
  return shown;
}

function weakerFiles(layout = resultLayout()) {
  const shown = new Set(layout.rows.map(resultKey));
  return state.weaker.filter(hit => !shown.has(resultKey(hit)));
}

function selectedHit() {
  const shown = rows();
  const current=shown.find((hit) => resultKey(hit) === state.selection) ?? null;
  return current&&state.navigated&&state.chosen&&resultKey(state.chosen)===state.selection?state.chosen:current;
}

// MARK: Drawing

function render() {
  renderBar();
  renderContent();
  renderSide();
  renderStatus();
}

const chips = new Map();
function renderBar() {
  const focused = document.activeElement, focusedScope = $scopes.contains(focused);
  const code = isCode(), apps = isAppsMode(), settings = isSettingsMode();
  const glass = $("glass"), icon = code ? "code" : "search";
  if (glass.dataset.icon !== icon) {
    glass.dataset.icon = icon; glass.innerHTML = code ? ICONS.code : SEARCH_ICON;
  }
  document.body.classList.toggle("apps-mode", apps);
  const placeholder = settings ? "Search Windows settings…" : apps ? "Find an app by name or purpose…"
    : code ? "Describe the code or type a name…" : "Search by name or describe it…";
  if ($query.placeholder !== placeholder) $query.placeholder = placeholder;
  const name = Apps.supported ? "Search files, apps and settings" : "Search files and code";
  if ($query.getAttribute("aria-label") !== name) $query.setAttribute("aria-label", name);
  const nodes = [chip("All", null, null, state.filter === null && !code && !apps && !settings, () => setFilter(null), 1)];
  if (Apps.supported && Apps.enabled) nodes.push(chip("Apps", null, state.counts.apps, apps, () => setFilter("apps"), 8));
  if (WindowsSettings.supported && WindowsSettings.enabled) nodes.push(chip("Windows settings", null, state.counts.settings, settings, () => setFilter("settings"), 9));
  if (state.info.hasCode) {
    nodes.push(chip("Code", "code", code ? state.counts.code : null, code,
                    () => setFilter(state.filter === "code" ? null : "code"), 7));
  }
  const activeType = code || apps || settings ? null : FILTERS.find(filter => filter.key === state.filter);
  const typeLabel = activeType?.title || "File types";
  const count = activeType && state.query.trim() ? state.counts[activeType.key] : null;
  const badge = $("file-types-count"), value = count == null ? "" : count.toLocaleString();
  if ($("file-types-label").textContent !== typeLabel) $("file-types-label").textContent = typeLabel;
  if (badge.textContent !== value) badge.textContent = value;
  badge.hidden = !value;
  $fileTypes.classList.toggle("filter-active", Boolean(activeType));
  $fileTypes.title = activeType ? `${typeLabel} · Change file type${matchCountHint(count)}` : "Filter by file type";
  if ($scopes.childElementCount === nodes.length && nodes.every((node, index) => $scopes.children[index] === node)) return;
  $scopes.replaceChildren(...nodes);
  if (focusedScope) ($scopes.contains(focused) ? focused : $query).focus({ preventScroll: true });
}

function matchCountHint(count) {
  return count == null ? "" : state.countScope === "ranked_candidates" ? " · Counts cover the current matching result set"
    : state.countScope === "displayed_matches" ? " · Counts cover displayed matching files" : "";
}

function chip(title, icon, count, selected, action, number) {
  let entry = chips.get(title);
  if (!entry) {
    const button = element("button", "chip"), badge = element("span", "number");
    button.dataset.title = title;
    button.setAttribute("aria-keyshortcuts", `${isMac ? "Meta" : "Control"}+${number}`);
    if (icon) button.insertAdjacentHTML("beforeend", ICONS[icon]);
    button.append(title, badge);
    entry = { button, badge }; chips.set(title, entry);
  }
  const {button, badge} = entry;
  const value = count != null && state.query.trim() ? count.toLocaleString() : "";
  if (badge.textContent !== value) badge.textContent = value;
  badge.hidden = !value;
  const tip = `${title} (${MOD}${number})${matchCountHint(count)}`;
  if (button.title !== tip) button.title = tip;
  if (button.getAttribute("aria-pressed") !== String(selected)) button.setAttribute("aria-pressed", String(selected));
  button.classList.toggle("selected", selected);
  button.onclick = action;
  return button;
}

function restoreHandoff() {
  const pending = state.handoff;
  if (!pending || pending.generation !== state.generation) return;
  if (state.weaker.some(hit => resultKey(hit) === pending.key)) state.showWeaker = true;
  const hit = rows().find(hit => resultKey(hit) === pending.key);
  if (hit) { state.selection = pending.key; state.chosen = hit; state.navigated = true; state.handoff = null; }
}
function renderContent() {
  restoreHandoff();
  const focused = document.activeElement;
  const focusedLaunch = focused.closest?.(".app-row")?.dataset.resultKey;
  const focusedScope=focused.closest?.("[data-scope-setup]")?.dataset.scopeSetup;
  const focusedWeaker = focused.matches(".weaker-toggle");
  const scroll = state.renderedGeneration === state.generation ? $content.scrollTop : 0;
  state.renderedGeneration = state.generation;
  thumbnails.disconnect();
  $sections.replaceChildren();
  $feedback.replaceChildren();
  const layout = resultLayout();
  let showRecoveryFirst = false;
  if (isSettingsMode()) $sections.append(windowsSettingsGroup());
  else if (isAppsMode()) $sections.append(applicationGroup(applicationSearch.hits));
  else {
    if (layout.best.length) $sections.append(bestMatches(layout.best));
    for (const section of layout.sections) {
      if (section.source === "apps") $sections.append(applicationGroup(section.hits));
      else if (section.source === "settings") $sections.append(windowsSettingsGroup(section.hits, settingsSearch.visible().length));
      else if (section.hits.length || weakerFiles(layout).length) {
        const files = element("section", "file-results-group");
        files.setAttribute("aria-label", "Files");
        if (layout.best.length || applicationSearch.hits.length || settingsSearch.visible().length)
          files.append(element("h2", "result-section-title", "Files"));
        files.append(isCode() ? codeList() : grid(section.hits)); $sections.append(files);
      }
    }
    const shownApps = layout.rows.filter(isApp).length, shownSettings = layout.rows.filter(isSetting).length;
    if (shownApps && !layout.sections.some(section => section.source === "apps") && applicationSearch.total > shownApps)
      $sections.append(applicationGroup([], "Apps", shownApps));
    if (shownSettings && !layout.sections.some(section => section.source === "settings") && settingsSearch.total > shownSettings)
      $sections.append(windowsSettingsGroup([], shownSettings));
    if(state.fileScopeEmpty===true)$feedback.append(chooseFolders(isCode()));
    else if(state.fileScopeEmpty!==false&&!state.info.folders.length&&!isCode())$feedback.append(chooseFolders());
    else if (!state.query.trim()) $feedback.append(home());
    else if (state.codePhase) $feedback.append(codeHintOrOff());
    else if (state.fileError) {
      showRecoveryFirst = layout.rows.length > 0;
      $feedback.append(fileSearchFailure(showRecoveryFirst));
    }
    else if (!state.lexicalReady && !state.ranked.length && !layout.rows.length)
      $feedback.append(centered(element("h2", "", "Finding filenames and exact words…")));
    else if (!state.ranked.length && !weakerFiles(layout).length && !layout.rows.length) $feedback.append(nothingFound());
  }
  if (showRecoveryFirst && $feedback.nextElementSibling !== $sections) $sections.before($feedback);
  if (!showRecoveryFirst && $sections.nextElementSibling !== $feedback) $sections.after($feedback);
  const resultRows = $sections.querySelectorAll('[role="row"][data-result-key]');
  resultRows.forEach((row, index) => {
    row.id = "search-result-" + encodeURIComponent(row.dataset.resultKey);
    row.setAttribute("aria-rowindex", String(index + 1));
  });
  $results.setAttribute("aria-rowcount", String(resultRows.length));
  $results.hidden = resultRows.length === 0;
  if ($results.hidden) $results.removeAttribute("aria-owns");
  else $results.setAttribute("aria-owns", [...$sections.querySelectorAll('[role="rowgroup"]')].map(group => group.id).join(" "));
  const activeResult = updateActiveResult();
  if ($big.open && !activeResult) closeBig();
  $content.scrollTop = scroll;
  if (focused.isConnected) focused.focus({preventScroll: true});
  else if (focusedLaunch) ($content.querySelector('[data-result-key="' + CSS.escape(focusedLaunch) + '"] .app-launch') || $query).focus({preventScroll: true});
  else if(focusedScope)$content.querySelector('[data-scope-setup="' + CSS.escape(focusedScope) + '"]')?.focus({preventScroll:true});
  else if (focusedWeaker) $content.querySelector(".weaker-toggle")?.focus({ preventScroll: true });
}

function updateActiveResult() {
  const expanded = !$results.hidden && !activityCoversResults();
  const active = expanded ? $sections.querySelector('[role="row"][aria-selected="true"]') : null;
  $query.setAttribute("aria-expanded", String(expanded));
  if (active) $query.setAttribute("aria-activedescendant", active.id);
  else $query.removeAttribute("aria-activedescendant");
  const count = Number($results.getAttribute("aria-rowcount"));
  const announcement = expanded ? `${count} ${count === 1 ? "result" : "results"} shown` : "";
  const status = $("results-status");
  if (status.textContent !== announcement) status.textContent = announcement;
  return active;
}

function resultGroup(className, label) {
  const group = element("div", className);
  group.id = "search-group-" + encodeURIComponent(label);
  group.setAttribute("role", "rowgroup");
  group.setAttribute("aria-label", label);
  return group;
}

function bestMatches(hits) {
  const section = element("section", "best-matches app-group app-group-mixed");
  section.setAttribute("aria-label", "Best matches");
  const heading = element("div", "app-group-heading");
  heading.append(element("h2", "app-group-title", "Best matches")); section.append(heading);
  const list = resultGroup("app-results", "Best matches");
  for (const hit of hits) list.append(isLauncher(hit)
    ? Apps.row(hit, state.selection === resultKey(hit), select, open, true) : cell(hit, true));
  section.append(list); return section;
}

function applicationGroup(hits=applicationSearch.hits,title="Apps",shownCount=resultLayout().rows.filter(isApp).length) {
  const box = element("section", "app-group"+(isAppsMode()?"":" app-group-mixed")); box.setAttribute("aria-label", "Applications");
  const heading=element("div", "app-group-heading");
  heading.append(element("h2", "app-group-title", title));
  if(isAppsMode()) {
    const count = applicationSearch.total;
    const unit = state.text ? (count === 1 ? "match" : "matches") : (count === 1 ? "app" : "apps");
    heading.append(element("span", "app-group-count", `${count.toLocaleString()} ${unit}`),
      element("span", "app-purpose-state", applicationSearch.purposeLabel()));
  }
  box.append(heading);
  const list = resultGroup("app-results", "Matching applications");
  for (const hit of hits) {
    const row = Apps.row(hit, state.selection === resultKey(hit), select, open, true);
    row.oncontextmenu = (event) => {
      event.preventDefault(); select(resultKey(hit));
      showMenu(event.clientX, event.clientY, [["Launch", () => open(hit)],
        ...(hit.shortcut ? [["Show shortcut location", () => reveal(hit)]] : [])]);
    };
    list.append(row);
  }
  if (hits.length) box.append(list);
  if (applicationSearch.total > (isAppsMode() ? hits.length : shownCount)) {
    const more = element("button", "app-more", isAppsMode() ? "Show more applications" : `Show all ${applicationSearch.total} matching apps…`);
    more.onclick = () => isAppsMode() ? applicationSearch.more() : setFilter("apps"); box.append(more);
  }
  if((!hits.length && isAppsMode()) || applicationSearch.error) box.append(element("div", "app-status", applicationSearch.status()));
  if(isAppsMode()) {
    const manage=element("button","app-manage","Manage apps…"); manage.onclick=()=>invoke("open_settings",{tab:"apps"}).catch(failed); box.append(manage);
  }
  return box;
}

function grid(hits = state.ranked) {
  const box = element("div");
  if (hits.length) box.append(cells(hits, "grid", "Matching files"));
  const weaker = weakerFiles();
  if (weaker.length) {
    box.append(weakerToggle());
    if (state.showWeaker) box.append(cells(weaker, "grid weaker-results", "Weaker file matches"));
  }
  return box;
}

const fileCells=new Map();
function cells(hits, className, label) {
  const box = resultGroup(className, label);
  for (const hit of hits) box.append(cell(hit));
  return box;
}

/// A result in the grid: its picture in a fixed box (a picture's own shape never sizes the cell), what kind it is,
/// the page or moment that matched, its name and folder.
function cell(hit, compact = false) {
  const key=resultKey(hit),signature=JSON.stringify(hit);
  const previous=fileCells.get(key);
  if(previous?.signature===signature){
    styleFileCell(previous.node, compact, key === state.selection);
    const image=previous.node.querySelector("img[data-render]");if(image&&!image.src)thumbnails.observe(image);
    return previous.node;
  }
  const item = element("div", "cell" + (resultKey(hit) === state.selection ? " selected" : ""));
  item.dataset.path = hit.path;
  item.dataset.resultKey = resultKey(hit);
  item.setAttribute("role", "row");
  item.setAttribute("aria-label", `${KIND_TITLE[hit.kind] || "File"}, ${nameOf(hit.path)}, ${reasonOf(hit)}`);
  const picture = element("div", "picture");
  picture.append(cellPicture(hit));
  if (hit.kind !== "image" && hit.kind !== "screenshot") {
    const badge = element("span", "kind-badge");
    badge.innerHTML = ICONS[hit.kind] || ICONS.doc;
    picture.append(badge);
  }
  const place = placeOf(hit);
  if (place) picture.append(element("span", "place on-image", place));
  item.append(picture, element("div", "name", "‎" + nameOf(hit.path)), folderLine(folderOf(hit)),
    element("div","result-match-reason",[matchLabel(hit),availabilityLabel(hit)].filter(Boolean).join(" · ")));
  for (const child of item.children) child.setAttribute("role", "gridcell");
  wire(item, hit);
  styleFileCell(item, compact, key === state.selection);
  fileCells.set(key,{signature,node:item});
  if(fileCells.size>240)fileCells.delete(fileCells.keys().next().value);
  return item;
}

function styleFileCell(item, compact, selected) {
  item.classList.toggle("best-file-row", compact); item.classList.toggle("selected", selected);
  item.setAttribute("aria-selected", String(selected));
}

/// The picture of a cell: the photo or screenshot, the frame or page that matched (from the helper, once the cell
/// scrolls into view), a document's passage in small print, or the kind's icon.
function cellPicture(hit) {
  if (hit.kind === "audio") return bigIcon("audio");
  const what = renderOf(hit);
  if (what) {
    const image = element("img", hit.kind === "pdf" ? "page" : "");
    image.alt = "";
    image.dataset.render = JSON.stringify([...what, Math.round(240 * (window.devicePixelRatio || 1))]);
    thumbnails.observe(image);
    return image;
  }
  if (hit.kind === "doc" && hit.excerpt) {
    const card = element("div", "text-card");
    card.dir = "auto";
    card.innerHTML = marked(hit.excerpt.slice(0, 600));
    return card;
  }
  return bigIcon(hit.kind, true);
}

function bigIcon(kind, quiet) {
  const icon = element("div", "big-icon" + (quiet ? " quiet" : ""));
  icon.innerHTML = ICONS[kind] || ICONS.doc;
  return icon;
}

/// Pictures are asked of the helper as their cells come into view: a search can show a hundred of them.
const thumbnails = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    const image = entry.target;
    thumbnails.unobserve(image);
    const [kind, loc, pixels] = JSON.parse(image.dataset.render);
    const path = image.closest("[data-path]").dataset.path;
    const generation=SearchTiming.generation;
    rendered(path, kind, loc, pixels)
      .then((file) => {
        if(!image.isConnected)return;
        image.src = fileURL(file);
        image.closest("[data-path]").dataset.thumb = file;   // the picture under the pointer when it's dragged out
      })
      .catch(error => {
        if(!image.isConnected)return;
        if(error.superseded&&generation!==SearchTiming.generation){thumbnails.observe(image);return;}
        image.replaceWith(bigIcon(kind === "image" ? "image" : kind, true));
      });
  }
}, { root: $content, rootMargin: "300px" });

function folderLine(text, tag = "div") {
  const line = element(tag, "folder");
  const inner = document.createElement("bdi");
  inner.textContent = text;
  line.append(inner);
  line.title = text;
  return line;
}

function weakerToggle() {
  const count = weakerFiles().length;
  const toggle = element("button", "weaker-toggle" + (state.showWeaker ? " open" : ""));
  toggle.setAttribute("aria-expanded", String(state.showWeaker));
  toggle.innerHTML = ICONS.chevron;
  toggle.append(state.showWeaker ? "Weaker matches" : `${count} weaker ${count === 1 ? "match" : "matches"}`);
  toggle.onmousedown = (event) => event.preventDefault();
  toggle.onclick = () => {
    state.showWeaker = !state.showWeaker;
    if (!rows().some((hit) => resultKey(hit) === state.selection)) state.selection = rows().length ? resultKey(rows()[0]) : null;
    const scroll = $content.scrollTop;
    renderContent();
    $content.scrollTop = scroll;
    renderSide();
  };
  return toggle;
}

/// Code results, one under another: the file, where in its repo, the lines that matched.
function codeList() {
  const box = element("div", "code-list");
  if (state.ranked.length) {
    const group = resultGroup("code-rows", "Matching code");
    group.append(...state.ranked.map(hit => codeRow(hit)));
    box.append(group);
  }
  if (state.weaker.length) {
    box.append(weakerToggle());
    if (state.showWeaker) {
      const group = resultGroup("code-rows", "Weaker code matches");
      group.append(...state.weaker.map(hit => codeRow(hit, true)));
      box.append(group);
    }
  }
  return box;
}

function codeRow(hit, weaker) {
  const item = element("div", "row" + (resultKey(hit) === state.selection ? " selected" : "") + (weaker ? " weaker-results" : ""));
  item.dataset.path = hit.path;
  item.dataset.resultKey = resultKey(hit);
  item.setAttribute("role", "row");
  item.setAttribute("aria-selected", String(resultKey(hit) === state.selection));
  const icon = element("div", "icon");
  icon.innerHTML = ICONS.code;
  const text = element("div", "text");
  const head = element("div", "head");
  head.append(element("span", "title", "‎" + nameOf(hit.path)));
  const place = placeOf(hit);
  item.setAttribute("aria-label", ["Code", nameOf(hit.path), place].filter(Boolean).join(", "));
  if (place) head.append(element("span", "place", place));
  head.append(folderLine(folderOf(hit), "span"));
  text.append(head);
  if (hit.excerpt) {
    const lines = element("div", "lines");
    lines.innerHTML = marked(hit.excerpt);
    text.append(lines);
  }
  item.append(icon, text);
  for (const child of item.children) child.setAttribute("role", "gridcell");
  wire(item, hit);
  return item;
}

/// A result's clicks: one selects it, two open it, the other button offers what to do with the file. The field keeps
/// the keyboard (as on the Mac: ← → move the selection once you've picked a result).
function wire(item, hit) {
  // Dragged out of the window, the file goes along (to a file manager, a mail, a chat). On Linux, WebKit's own drag with
  // the file's address: GTK starts it from the press, as Wayland wants (a drag started later is refused).
  if (isLinux) {
    item.draggable = true;
    item.ondragstart = (event) => {
      const address = "file://" + hit.path.split("/").map(encodeURIComponent).join("/");
      event.dataTransfer.setData("text/uri-list", address);
      event.dataTransfer.setData("text/plain", hit.path);
      event.dataTransfer.effectAllowed = "copy";
    };
  }
  // Elsewhere: pressed and moved a little, the system's drag (which needs the button down).
  item.onmousedown = (event) => {
    if (event.button !== 0 || isLinux) return;
    event.preventDefault();
    const [x, y] = [event.clientX, event.clientY];
    const moved = (move) => {
      if (Math.hypot(move.clientX - x, move.clientY - y) < 6) return;
      done();
      invoke("drag_out", { path: hit.path, icon: item.dataset.thumb || null }).catch(() => {});
    };
    const done = () => {
      window.removeEventListener("mousemove", moved);
      window.removeEventListener("mouseup", done);
    };
    window.addEventListener("mousemove", moved);
    window.addEventListener("mouseup", done);
  };
  item.onclick = () => select(resultKey(hit));
  item.ondblclick = () => open(hit);
  item.oncontextmenu = (event) => {
    event.preventDefault();
    select(resultKey(hit));
    showMenu(event.clientX, event.clientY, [
      ["Open", () => open(hit)],
      [`Show in ${FILE_MANAGER}`, () => reveal(hit)],
      null,
      ["Copy", () => invoke("copy_file", { path: hit.path }).catch(failed)],
      ["Copy Path", () => navigator.clipboard.writeText(hit.path).catch(() => {})],
    ]);
  };
}

function select(path) {
  state.handoff = null;
  state.selection = path;
  state.chosen = rows().find(hit=>resultKey(hit)===path)??null;
  state.navigated = true;
  for (const item of $content.querySelectorAll("[data-result-key]")) {
    const selected=item.dataset.resultKey === path; item.classList.toggle("selected", selected);item.setAttribute("aria-selected",String(selected));
    const launch=item.querySelector(".app-launch");if(launch)launch.tabIndex=selected?0:-1;
  }
  $content.querySelector(".selected")?.scrollIntoView({ block: "nearest" });
  updateActiveResult();
  renderSide();
  if ($big.open) renderBig();
}

/// Arrows move through the grid: ↑ ↓ by a row, ← → by one.
function move(step) {
  const shown = rows();
  if (!shown.length) return;
  const index = shown.findIndex((hit) => resultKey(hit) === state.selection);
  select(resultKey(shown[Math.max(0, Math.min(shown.length - 1, (index < 0 ? -1 : index) + step))]));
}

function moveVertical(direction) {
  const shown = rows(), index = shown.findIndex(hit => resultKey(hit) === state.selection);
  const current = $content.querySelector('[data-result-key="' + CSS.escape(state.selection || "") + '"]');
  const grid = current?.closest(".grid");
  if (!grid) { move(direction); return; }
  const cells = [...grid.querySelectorAll("[data-result-key]")], at = cells.indexOf(current), next = at + direction * columns();
  if (next >= 0 && next < cells.length) select(cells[next].dataset.resultKey);
  else {
    const boundary = direction < 0 ? index - at - 1 : index + cells.length - at;
    if (shown[boundary]) select(resultKey(shown[boundary]));
  }
}

function columns() {
  if (isLauncher(selectedHit()) || $content.querySelector(".best-matches .selected")) return 1;
  const grid = $content.querySelector(".grid");
  return grid ? getComputedStyle(grid).gridTemplateColumns.split(" ").length : 1;
}

function open(hit) {
  state.selection = resultKey(hit); state.navigated = true;state.chosen=hit;
  return openResult(hit).catch(failed);
}

function reveal(hit) {
  if (isLauncher(hit)) { if (hit.shortcut) invoke("reveal", { path: hit.shortcut }).catch(failed); return; }
  invoke("reveal", { path: hit.path }).catch(failed);
}

function failed(error) {
  state.error = String(error);
  renderStatus();
}

// MARK: What shows instead of results

function fileSearchFailure(withResults) {
  const box = element("section", withResults ? "file-search-failure" : "center");
  const retry = element("button", "button", "Retry file search");
  retry.onclick = () => { $query.focus({ preventScroll: true }); run(true); };
  const message = element("div", "");
  message.append(element("h2", "", "File search unavailable"), element("p", "", state.fileError));
  box.append(message, retry);
  return box;
}

/// Nothing typed yet: the app's mark, a pointer to the field above, examples to click (each with the kind it finds),
/// what's indexed, and the shortcut. A click anywhere else puts the cursor in the field.
function home() {
  const box = element("section", "home");
  const intro = element("div", "home-intro"), copy = element("div");
  copy.append(element("h2", "", "Search this PC"), element("p", "", "Type a name or describe what you remember."));
  intro.append(brandMark(), copy);
  const examples = element("div", "examples");
  for (const [text, kind] of EXAMPLES) {
    const example = element("button", "example");
    example.innerHTML = ICONS[kind];
    example.firstElementChild.setAttribute("aria-hidden", "true");
    example.append(text);
    example.title = `Search for “${text}”`;
    example.onmousedown = (event) => event.preventDefault();
    example.onclick = () => tryExample(text);
    examples.append(example);
  }
  box.append(intro, element("h3", "", "Try a search"), examples, about());
  box.onmousedown = (event) => { if (!event.target.closest("button")) event.preventDefault(); };
  box.onclick = (event) => { if (!event.target.closest("button")) $query.focus(); };
  return box;
}

/// What's in the index ("136 screenshots, 104 images… in Pictures and Documents") and the shortcut.
function about() {
  const box = element("div", "about");
  const kinds = state.indexed && KIND_ORDER.filter((kind) => state.indexed[kind] > 0);
  if (kinds?.length) {
    const line = element("div", "line");
    const counts = element("div", "kind-counts");
    for (const kind of kinds) {
      const item = element("span");
      item.innerHTML = ICONS[kind];
      item.append(state.indexed[kind].toLocaleString());
      counts.append(item);
    }
    counts.title = kinds.map((kind) => counted(kind, state.indexed[kind])).join(", ");
    line.append(counts, element("span", "", `in ${folderNames()}`));
    box.append(line);
  } else if (state.app.searchable > 0) {
    box.append(element("div", "line", `${state.app.searchable.toLocaleString()} files to search in ${folderNames()}`));
  }
  if (state.info.hotkey) {
    const line = element("div", "line");
    const caps = element("span", "keycaps");
    for (const key of keysOf(state.info.hotkey)) caps.append(element("kbd", "keycap", key));
    line.append(caps, element("span", "", "opens DigUp from any app"));
    box.append(line);
  }
  return box;
}

/// "1 screenshot", "25 PDFs", "6 audio files"
function counted(kind, count) {
  const [one, many] = COUNTED[kind] || ["file", "files"];
  return `${count.toLocaleString()} ${count === 1 ? one : many}`;
}

/// "Pictures, Documents and Videos", or "5 folders".
function folderNames() {
  const names = state.info.folders.map((folder) => folder.split(/[\\/]/).filter(Boolean).pop() || folder);
  return names.length <= 3 ? new Intl.ListFormat("en", { type: "conjunction" }).format(names) : `${names.length} folders`;
}

/// "Ctrl+Shift+Space" as keys; a Mac's "⇧⌘Space" too.
function keysOf(hotkey) {
  if (hotkey.includes("+")) return hotkey.split("+").filter(Boolean);
  const signs = [...hotkey.replace(/[^⌃⌥⇧⌘]/g, "")];
  return [...signs, hotkey.replace(/[⌃⌥⇧⌘]/g, "")].filter(Boolean);
}

function brandMark() {
  const mark = element("div", "mark");
  const icon = element("img");
  icon.src = "icon.png";
  icon.alt = "";
  mark.append(icon);
  return mark;
}

function chooseFolders(code = false) {
  const button = element("button", "button primary", code?"Choose folders for code search":"Choose Folders…");
  button.setAttribute("aria-label",code?"Choose folders for code search":"Choose folders for file search");
  button.dataset.scopeSetup=code?"code":"files";
  button.onclick = () => invoke(code?"choose_code_folders":"choose_folders").catch(failed);
  return centered(brandMark(), element("h2", "", code?"Choose code folders to search":"Choose folders to search"),
                  element("p", "", "DigUp only looks where you tell it to."), button);
}

function nothingFound() {
  const icon = element("div", "quiet-icon");
  icon.innerHTML = isCode() ? ICONS.code : SEARCH_ICON;
  const wordsOnly = state.finalGeneration === state.generation && !state.meaning;
  const tip = wordsOnly
    ? (isCode() ? "Try a filename, a symbol name, or words from the code." : "Try a filename or words you remember from the file.")
    : (isCode() ? "Try saying what the code does, or a name that's in it." : "Try describing what's in it: what you'd see or hear, or words you remember.");
  return centered(icon, element("h2", "", `${wordsOnly ? "No word matches" : "No good matches"} for “${state.query.trim()}”`),
                  element("p", "", tip));
}

/// "code:" with nothing after it (what to type), or without code folders (what code search is).
function codeHintOrOff() {
  const icon = element("div", "brand-icon");
  icon.innerHTML = ICONS.code;
  if (state.codePhase === "off") {
    const actions = element("div", "actions");
    const choose = element("button", "primary", "Choose Code Folders…");
    choose.onclick = () => invoke("choose_code_folders").catch(failed);
    actions.append(choose);
    return centered(icon, element("h2", "", "Code search is off"),
                    element("p", "", "DigUp can find code by what it does, in folders you choose for it. Code gets an "
                            + "index of its own and never shows up in other searches."), actions);
  }
  return centered(icon, element("h2", "", "Search your code"),
                  element("p", "", "Say what the code does, or type a name that's in it."));
}

function centered(...children) {
  const box = element("div", "center");
  box.append(...children);
  return box;
}

// MARK: The preview pane

let playing = null,sideSignature=null;   // the audio of the selected result, while it plays

function renderSide() {
  const selected=selectedHit();
  const preview = shouldShowPreview();
  const signature=JSON.stringify([state.activityOpen,preview,state.text,selected]);
  if(signature===sideSignature)return;
  sideSignature=signature;
  stopPlaying();
  if (state.activityOpen) {
    $side.hidden = false;
    if (!activityHost.isConnected) $side.replaceChildren(activityHost);
    activityView.show();
    return;
  }
  const hit = state.hasResults && !state.codePhase && hasQuery() ? selectedHit() : null;
  $side.hidden = !preview || !hit;
  $side.replaceChildren();
  if (!hit) return;
  if (isLauncher(hit)) { $side.append(Apps.details(hit, failed)); return; }
  $side.append(previewPicture(hit), facts(hit), why(hit), actions(hit));
}

/// The big picture: the photo or screenshot, the frame at the moment (it plays from there), the page, the moment in a
/// recording, the passage that matched, or the lines of code.
function previewPicture(hit) {
  const box = element("div", "preview-picture");
  if (hit.kind === "audio") {
    box.append(audioMoment(hit));
    box.style.height = "150px";
    return box;
  }
  if (hit.kind === "code") {
    box.append(codeLines(hit));
    addPlace(box, span(hit));
    return box;
  }
  if (hit.segment === "chunk") {
    box.append(passage(hit));
    const parts = Number(hit.info?.chunks || 0);
    if (hit.loc != null && parts > 1) addPlace(box, `Part ${Math.trunc(hit.loc)} of ${parts}`);
    return box;
  }
  const what = renderOf(hit);
  if (!what) {
    const placeholder = element("div", "placeholder");
    placeholder.innerHTML = ICONS[hit.kind] || ICONS.doc;
    placeholder.ondblclick = () => open(hit);
    box.append(placeholder);
    return box;
  }
  const frame = element("div", "frame");
  const image = element("img");
  image.alt = "";
  frame.append(image);
  // The cell's picture first (already drawn), then the bigger one.
  const small = renders.get(`${hit.path}|${what[0]}|${what[1]}|${Math.round(240 * (window.devicePixelRatio || 1))}`);
  small?.then((file) => { if (!image.dataset.big) image.src = fileURL(file); }).catch(() => {});
  rendered(hit.path, what[0], what[1], Math.round(300 * (window.devicePixelRatio || 1)), true)
    .then((file) => { image.dataset.big = "1"; image.src = fileURL(file); })
    .catch(() => {});
  image.ondblclick = () => open(hit);
  const place = placeOf(hit);
  if (place) {
    const marks = element("div", "marks" + (hit.kind === "video" ? " dim" : ""));
    marks.append(element("span", "place on-image", place));
    const duration = Number(hit.info?.duration || 0);
    if (hit.kind === "video" && hit.loc != null && duration > 0) {
      marks.append(momentBar(hit.loc, hit.loc_end ?? hit.loc + 3, duration));
    }
    frame.append(marks);
  }
  if (hit.kind === "video") {
    // ▶ plays it here from the moment that matched.
    const play = element("button", "play");
    play.innerHTML = ICONS.play;
    play.title = `Play from ${clock(hit.loc ?? 0)}`;
    play.onclick = () => {
      const video = element("video");
      video.src = `${fileURL(hit.path)}#t=${hit.loc ?? 0}`;
      video.controls = true;
      video.autoplay = true;
      box.replaceChildren(video);
    };
    frame.append(play);
  }
  box.append(frame);
  return box;
}

// MARK: The big preview (Space, as Quick Look on the Mac)

let previewReturnFocus = null;
$big.onclick = (event) => { if (event.target === $big) closeBig(); };
$big.addEventListener("cancel", event => {
  event.preventDefault();
  closeBig();
});
$big.addEventListener("keydown", event => {
  if (event.key === "Escape" && !document.fullscreenElement) {
    event.preventDefault();
    closeBig();
    return;
  }
  if (event.key === "Tab") {
    const stops = [...$big.querySelectorAll("button, [tabindex='0'], video[controls], audio[controls]")];
    const first = stops[0], last = stops.at(-1);
    if (event.shiftKey ? event.target === first : event.target === last) {
      if (event.target.matches("video, audio")) {
        // Let the browser visit the media controls before cycling back to the header.
        requestAnimationFrame(() => {
          if ($big.open && !$big.contains(document.activeElement)) first.focus();
        });
      } else {
        event.preventDefault();
        (event.shiftKey ? last : first).focus();
      }
    }
    return;
  }
  if (!event.target.closest(".head") || event.altKey || event.shiftKey || event.ctrlKey || event.metaKey) return;
  switch (event.key) {
    case "ArrowUp": case "ArrowDown":
      event.preventDefault();
      moveVertical(event.key === "ArrowDown" ? 1 : -1);
      break;
    case "ArrowLeft": case "ArrowRight":
      event.preventDefault();
      move(event.key === "ArrowRight" ? 1 : -1);
      break;
  }
});

function showBig() {
  stopPlaying();
  previewReturnFocus = document.activeElement;
  if (!renderBig()) { previewReturnFocus = null; return; }
  $big.showModal();
  $big.querySelector(".close").focus();
}

function closeBig() {
  if (!$big.open) return;
  $big.close();
  $big.replaceChildren();
  const trigger = previewReturnFocus;
  previewReturnFocus = null;
  (trigger !== document.body && trigger?.getClientRects().length ? trigger : $query).focus({ preventScroll: true });
}

function renderBig() {
  const hit = state.hasResults && state.query.trim() ? selectedHit() : null;
  if (!hit || isLauncher(hit)) { closeBig(); return false; }
  const focusedOpening = document.activeElement === $big.querySelector(".primary");
  const sheet = element("div", "sheet");
  const head = element("div", "head");
  const title = element("div", "title");
  title.id = "big-preview-title";
  title.append(element("span", "name", nameOf(hit.path)));
  const place = placeOf(hit);
  if (place) title.append(element("span", "place", place));
  const opening = element("button", "primary", "Open");
  opening.onclick = () => { closeBig(); open(hit); };
  const close = element("button", "close", "Close");
  close.title = "Close preview (Esc)";
  close.setAttribute("aria-label", "Close preview");
  close.onclick = closeBig;
  head.append(title, opening, close);
  sheet.append(head, bigView(hit));
  $big.replaceChildren(sheet);
  if ($big.open) (focusedOpening ? opening : close).focus();
  return true;
}

/// The result as big as the window allows: the picture or the page, the video or the recording from the moment, the
/// passage or the lines of code.
function bigView(hit) {
  const view = element("div", "view");
  if (hit.kind === "code" || hit.segment === "chunk") {
    view.classList.add("text");
    view.tabIndex = 0;
    view.setAttribute("role", "region");
    view.setAttribute("aria-label", "File content");
    view.append(hit.kind === "code" ? codeLines(hit) : passage(hit));
    return view;
  }
  if (hit.kind === "video" || hit.kind === "audio") {
    const media = element(hit.kind === "video" ? "video" : "audio");
    media.src = `${fileURL(hit.path)}#t=${hit.loc ?? 0}`;
    media.controls = true;
    media.autoplay = true;
    view.append(media);
    return view;
  }
  const what = renderOf(hit);
  if (!what) {
    const placeholder = element("div", "placeholder");
    placeholder.innerHTML = ICONS[hit.kind] || ICONS.doc;
    view.append(placeholder);
    return view;
  }
  const image = element("img");
  image.alt = "";
  const extension = hit.path.split(".").pop().toLowerCase();
  if (what[0] === "image" && SHOWN_AS_IS.has(extension)) {
    image.src = fileURL(hit.path);
  } else {
    const pixels = Math.round(Math.max(innerWidth, innerHeight) * (window.devicePixelRatio || 1));
    rendered(hit.path, what[0], what[1], pixels, true).then((file) => { image.src = fileURL(file); }).catch(() => {});
  }
  image.ondblclick = () => { closeBig(); open(hit); };
  view.append(image);
  return view;
}

function addPlace(box, text) {
  if (!text) return;
  box.style.position = "relative";
  box.append(element("span", "place on-image", text));
}

/// Where a moment sits in a recording: a track with the matched stretch lit (and where playback is).
function momentBar(start, end, duration, playhead) {
  const bar = element("div", "moment-bar");
  const from = Math.max(0, Math.min(1, start / duration)), to = Math.max(from, Math.min(1, end / duration));
  const lit = element("div", "lit");
  lit.style.left = `${from * 100}%`;
  lit.style.width = `${(to - from) * 100}%`;
  bar.append(lit);
  if (playhead != null) {
    const head = element("div", "head");
    head.style.left = `${Math.max(0, Math.min(1, playhead / duration)) * 100}%`;
    bar.append(head);
  }
  bar.title = `At ${clock(start)} of ${clock(duration)}`;
  return bar;
}

/// An audio result: the stretch that matched on the file's timeline, and ▶ to hear it from there.
function audioMoment(hit) {
  const box = element("div", "audio-moment");
  const start = hit.loc ?? 0, end = hit.loc_end ?? start + 30;
  const duration = Number(hit.info?.duration || 0);
  const controls = element("div", "controls");
  const wave = element("div", "wave");
  wave.innerHTML = ICONS.audio;
  const toggle = element("button", "toggle play-icon");
  toggle.innerHTML = ICONS.play;
  toggle.title = `Play from ${clock(start)}`;
  controls.append(wave, toggle);
  const line = element("div", "span", `${clock(start)} – ${clock(end)}` + (duration ? ` of ${clock(duration)}` : ""));
  let bar = duration > 0 ? momentBar(start, end, duration) : null;
  box.append(controls, ...(bar ? [bar] : []), line);
  const showPlaying = () => {
    const on = playing != null && !playing.paused;
    toggle.innerHTML = on ? ICONS.pause : ICONS.play;
    toggle.classList.toggle("play-icon", !on);
  };
  toggle.onclick = () => {
    if (!playing) {
      const audio = new Audio(`${fileURL(hit.path)}#t=${start}`);
      audio.ontimeupdate = () => {
        line.textContent = `${clock(audio.currentTime)} – playing from ${clock(start)}`;
        if (bar) {
          const moved = momentBar(start, end, duration, audio.currentTime);
          bar.replaceWith(moved);
          bar = moved;
        }
      };
      audio.onplay = audio.onpause = showPlaying;
      audio.onended = () => {
        stopPlaying();
        showPlaying();
      };
      playing = audio;
    }
    if (playing.paused) playing.play().catch(() => {});
    else playing.pause();
  };
  return box;
}

function stopPlaying() {
  if (!playing) return;
  playing.pause();
  playing.removeAttribute("src");
  playing = null;
}

/// The part of a document that matched, on a page, the words marked.
function passage(hit) {
  const page = element("div", "passage");
  const found = foundWords(hit.excerpt);
  const show = (text) => {
    page.dir = isRightToLeft(text) ? "rtl" : "ltr";
    page.innerHTML = highlighted(passageAround(text, [...found, ...queryWords(state.text)]), state.text, found);
  };
  show((hit.excerpt ?? "").replace(/[«»]/g, ""));
  ask({ op: "text", segment: hit.segment_id, code: false })
    .then((reply) => { if (reply.text) show(reply.text); })
    .catch(() => {});
  page.ondblclick = () => open(hit);
  return page;
}

/// The lines of code that matched, numbered as in the file: the query's words marked, the line it opens at lit, and
/// scrolled to it. A notebook's cells have no line numbers of their own, so theirs count from 1.
function codeLines(hit) {
  const box = element("div", "code-lines");
  const first = hit.segment === "lines" ? Math.max(1, Math.trunc(hit.loc ?? 1)) : 1;
  const focus = hit.segment === "lines" && hit.focus != null ? Math.trunc(hit.focus) - first : null;
  const found = foundWords(hit.excerpt);
  const show = (text) => {
    const lines = text.split(/\r?\n/).map((line) => line.replaceAll("\t", "    "));
    const width = String(first + Math.max(lines.length, 1)).length;
    box.replaceChildren();
    let firstMarked = null;
    lines.forEach((line, offset) => {
      const row = element("div", "line" + (offset === focus ? " focus" : ""));
      const number = element("span", "number", String(first + offset));
      number.style.width = `${width}ch`;
      const code = element("span");
      code.innerHTML = highlighted(line || " ", state.text, found);
      if (firstMarked == null && code.querySelector("mark")) firstMarked = offset;
      row.append(number, code);
      box.append(row);
    });
    const target = focus ?? firstMarked;
    if (target != null && target > 3) box.children[target - 2]?.scrollIntoView({ block: "start" });
  };
  ask({ op: "text", segment: hit.segment_id, code: true })
    .then((reply) => show(reply.text || (hit.excerpt ?? "").replace(/[«»]/g, "")))
    .catch(() => show((hit.excerpt ?? "").replace(/[«»]/g, "")));
  box.ondblclick = () => open(hit);
  return box;
}

function facts(hit) {
  const box = element("div", "facts");
  const title = element("div", "title", "‎" + nameOf(hit.path));
  title.title = nameOf(hit.path);
  const folder = folderLine(folderOf(hit), "button");
  folder.title = `Show in ${FILE_MANAGER}`;
  folder.onclick = () => reveal(hit);
  box.append(title, folder, element("div", "details", details(hit)));
  return box;
}

/// "Matches the frame at 0:06", and the words it has, if any.
function why(hit) {
  const box = element("div", "why");
  const reason = element("div", "reason" + (matchedMeaning(hit) ? "" : " words"));
  reason.innerHTML = matchedMeaning(hit) ? ICONS.found : ICONS.words;
  reason.append(element("span", "", reasonOf(hit)));
  box.append(reason);
  // Code shows its lines above, the words marked there.
  if (hit.excerpt && hit.kind !== "code") {
    const excerpt = element("div", "excerpt");
    excerpt.dir = "auto";
    excerpt.innerHTML = marked(hit.excerpt);
    box.append(excerpt);
  }
  return box;
}

function actions(hit) {
  const box = element("div", "actions");
  const openButton = element("button", "primary", "Open");
  openButton.onclick = () => open(hit);
  const revealButton = element("button", "", `Show in ${FILE_MANAGER}`);
  revealButton.onclick = () => reveal(hit);
  box.append(openButton, revealButton);
  appendUsefulResult(box, hit, failed);
  return box;
}

// MARK: The status bar

function renderStatus() {
  const app = state.app;
  const index = $("index-summary"), indexLine = app.line || "";
  if (index.textContent !== indexLine) index.textContent = indexLine;
  let count = "";
  if (state.error) count = `DigUp: ${state.error}`;
  else if(isSettingsMode())count=settingsSearch.status();
  else if (isAppsMode()) count = applicationSearch.status();
  else if (state.query.trim() && !state.codePhase) {
    const weaker = weakerFiles().length, strong = state.ranked.length + state.weaker.length - weaker;
    const phase = !state.lexicalReady ? "Finding names and words…" : state.finalGeneration !== state.generation
      ? "Checking file contents…" : !state.meaning ? "Words only · Content search unavailable" : "";
    const providers = [];
    if(applicationSearch.active&&applicationSearch.total)providers.push(applicationSearch.total+" "+(applicationSearch.total===1?"app":"apps"));
    if(settingsSearch.active&&settingsSearch.total)providers.push(settingsSearch.total+" Windows "+(settingsSearch.total===1?"setting":"settings"));
    if (state.lexicalReady) providers.push(`${strong} file ${strong === 1 ? "match" : "matches"}`);
    if (weaker) providers.push(`${weaker} weaker`);
    count = [phase || app.caveat, ...providers].filter(Boolean).join(" · ");
  }
  const summary = $("count");
  if (summary.textContent !== count) { summary.textContent = count; summary.title = count; }
  renderUpdate(app.update);
}

/// An update waiting (updates.rs), as on the Mac: a line on the right of the status bar, then its download.
function renderUpdate(update) {
  const button = $("update");
  button.hidden = !update;
  if (!update) return;
  const text = update.state === "downloading"
    ? `Downloading DigUp ${update.version}…` + (update.percent != null ? ` ${update.percent}%` : "")
    : update.state === "installing" ? `Installing DigUp ${update.version}…` : `DigUp ${update.version} is available`;
  button.innerHTML = '<svg viewBox="0 0 12 12"><circle cx="6" cy="6" r="6" fill="currentColor"/>'
    + '<path d="M6 3v5M3.8 6l2.2 2.2L8.2 6" fill="none" stroke="white" stroke-width="1.4" stroke-linecap="round" '
    + 'stroke-linejoin="round"/></svg>';
  button.append(text);
  button.disabled = update.state !== "available";
}

// MARK: Menus

const $more = $("more");
let menuTrigger = null;

/// Menu entries may include a shortcut, enabled flag, and checked state for choices.
function showMenu(x, y, items, trigger = document.activeElement, last = false) {
  if (!$menu.hidden) hideMenu(false);
  menuTrigger = trigger;
  if (trigger.hasAttribute("aria-expanded")) trigger.setAttribute("aria-expanded", "true");
  $menu.setAttribute("aria-label", trigger === $more ? "More actions" : trigger === $fileTypes ? "File types" : "Result actions");
  $menu.replaceChildren();
  for (const item of items) {
    if (!item) {
      const separator = element("hr");
      separator.setAttribute("role", "separator");
      $menu.append(separator);
      continue;
    }
    const [title, action, shortcut, enabled = true, checked] = item;
    const button = element("button", "", title);
    button.setAttribute("role", checked === undefined ? "menuitem" : "menuitemradio");
    if (checked !== undefined) button.setAttribute("aria-checked", String(checked));
    button.tabIndex = -1;
    button.disabled = !enabled;
    if (shortcut) {
      const hint = element("span", "shortcut", shortcut);
      hint.setAttribute("aria-hidden", "true");
      button.append(hint);
    }
    button.onmousedown = (event) => event.preventDefault();
    button.onclick = () => {
      hideMenu();
      action();
    };
    $menu.append(button);
  }
  $menu.hidden = false;
  const { width, height } = $menu.getBoundingClientRect();
  $menu.style.left = `${Math.max(4, Math.min(x, innerWidth - width - 4))}px`;
  $menu.style.top = `${Math.max(4, Math.min(y, innerHeight - height - 4))}px`;
  const enabled = menuItems();
  focusMenuItem(last ? enabled.at(-1) : enabled.find(button => button.getAttribute("aria-checked") === "true") || enabled[0]);
}

function hideMenu(restoreFocus = true) {
  if ($menu.hidden) return;
  const trigger = menuTrigger;
  menuTrigger = null;
  $menu.hidden = true;
  if (trigger?.hasAttribute("aria-expanded")) trigger.setAttribute("aria-expanded", "false");
  if (restoreFocus) (trigger !== document.body && trigger?.getClientRects().length ? trigger : $query).focus({ preventScroll: true });
}

function menuItems() { return [...$menu.querySelectorAll("button:enabled")]; }

function focusMenuItem(item) {
  if (!item) return;
  $menu.querySelector('[tabindex="0"]')?.setAttribute("tabindex", "-1");
  item.tabIndex = 0;
  item.focus();
}

$menu.addEventListener("keydown", event => {
  if (event.key === "Tab") {
    hideMenu();
    // Native Tab now advances from the trigger in the window's tab order.
    return;
  }
  if (event.key === "Escape") {
    event.preventDefault();
    event.stopPropagation();
    hideMenu();
    return;
  }
  const items = menuItems(), current = items.indexOf(event.target);
  if (current < 0 || !["ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) return;
  event.preventDefault();
  const next = event.key === "Home" ? 0 : event.key === "End" ? items.length - 1
    : (current + (event.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
  focusMenuItem(items[next]);
});

/// ⋯: what the tray's menu has, for desktops without a tray.
function showMainMenu(last = false) {
  const button = $more.getBoundingClientRect();
  const folders = state.info.folders.length > 0, paused = state.app.paused === true;
  showMenu(button.right - 200, button.bottom + 4, [
    ["Activity and Diagnostics…", () => showActivity()],
    ["Choose Folders…", () => invoke("choose_folders").catch(failed)],
    ["Index Now", () => invoke("index_now").catch(failed), null, folders && state.app.busy === false],
    [paused ? "Resume Indexing" : "Pause Indexing", () => invoke("pause_indexing", { paused: !paused }).catch(failed),
     null, folders],
    null,
    ["Settings…", () => invoke("open_settings").catch(failed), `${MOD},`],
    state.app.update
      ? [`Update to DigUp ${state.app.update.version}…`, () => invoke("offer_update").catch(failed), null,
         state.app.update.state === "available"]
      : ["Check for Updates…", () => invoke("check_for_updates").catch(failed)],
    null,
    ["Quit DigUp", () => invoke("quit_app").catch(failed)],
  ], $more, last);
}

function showFileTypes(last = false) {
  const button = $fileTypes.getBoundingClientRect();
  const countsVisible = state.query.trim() && !isAppsMode() && !isSettingsMode() && !isCode();
  const current = $fileTypes.classList.contains("filter-active") ? state.filter : null;
  showMenu(button.left, button.bottom + 4, [
    ["All types", () => setFilter(null), `${MOD}1`, true, !current],
    ...FILTERS.map((filter, index) => {
      const count = countsVisible ? state.counts[filter.key] : null;
      const title = count == null ? filter.title : `${filter.title} (${count.toLocaleString()})`;
      return [title, () => setFilter(filter.key), `${MOD}${index + 2}`, true, current === filter.key];
    }),
  ], $fileTypes, last);
}

document.addEventListener("pointerdown", (event) => {
  if (!$menu.contains(event.target) && !menuTrigger?.contains(event.target)) hideMenu(false);
});
window.addEventListener("blur", () => hideMenu(false));

// MARK: Keys and events

$query.addEventListener("input", queryChanged);
// A click back in the field: ← → move the cursor again (after picking a result, they moved the selection).
$query.addEventListener("mousedown", () => { state.navigated = false; });
$("field").addEventListener("click", event => {
  returnToSearch();
  if (event.target.closest("input, button")) return;
  state.navigated = false;
  $query.focus();
});
$("clear").onmousedown = (event) => event.preventDefault();
$("clear").onclick = () => setQuery("");
$("toggle-preview").onmousedown = (event) => event.preventDefault();
$("toggle-preview").onclick = () => {
  if (state.activityOpen) {
    state.showsPreview = true;
    closeActivity(false);
    $("toggle-preview").focus({ preventScroll: true });
    return;
  }
  state.showsPreview = !shouldShowPreview();
  updatePreviewButton();
  renderSide();
};
$("settings").onmousedown = (event) => event.preventDefault();
$("settings").onclick = () => invoke("open_settings").catch(failed);
$("settings").title = `Settings (${MOD},)`;
$more.onmousedown = (event) => event.preventDefault();
for (const [trigger, show] of [[$more, showMainMenu], [$fileTypes, showFileTypes]]) {
  trigger.onclick = () => (menuTrigger === trigger ? hideMenu() : show());
  trigger.onkeydown = event => {
    if (menuTrigger !== trigger && ["ArrowDown", "ArrowUp"].includes(event.key)) {
      event.preventDefault();
      show(event.key === "ArrowUp");
    }
  };
}
$("status-line").onclick = () => showActivity();
$("update").onclick = () => invoke("offer_update").catch(failed);
$kinds.onmousedown = (event) => event.preventDefault();

function shouldShowPreview() { return state.showsPreview ?? !compactPreview.matches; }

function updatePreviewButton() {
  const button = $("toggle-preview");
  const pressed = !state.activityOpen && shouldShowPreview();
  button.setAttribute("aria-pressed", String(pressed));
  button.title = pressed ? "Hide result details" : "Show result details";
}

compactPreview.addEventListener("change", () => { updatePreviewButton(); renderSide(); });

document.addEventListener("keydown", (event) => {
  if (event.isComposing) return;   // an input method is composing: its keys
  if ($big.open || searchHelp.open || event.defaultPrevented) return;
  if (document.querySelector(".activity-report[open]") || event.target.closest(".activity-view")) return;
  if (event.key === "Escape" && state.activityOpen) { event.preventDefault(); closeActivity(); return; }
  const modifier = isMac ? event.metaKey : event.ctrlKey;
  const plain = !event.altKey && !event.shiftKey && !event.ctrlKey && !event.metaKey;
  if (!$menu.hidden && event.key === "Escape") {
    event.preventDefault();
    hideMenu();
    return;
  }
  // Enter/Space/arrows belong to the focused control, including menu items,
  // pagination and media controls. Only the query/body drive result navigation.
  if (event.target !== $query && event.target.closest("button, a, input, textarea, select, summary, video, audio, [contenteditable]")) return;
  if (modifier && !event.altKey && !event.shiftKey) {
    const number = Number(event.key);
    if (number >= 1 && number <= 6) {
      event.preventDefault();
      setFilter(number === 1 ? null : FILTERS[number - 2].key);
      return;
    }
    if (number === 7 && state.info.hasCode) {
      event.preventDefault();
      setFilter("code");
      return;
    }
    if (number === 8 && Apps.supported && Apps.enabled) { event.preventDefault(); setFilter("apps"); return; }
    if(number===9&&WindowsSettings.supported&&WindowsSettings.enabled){event.preventDefault();setFilter("settings");return;}
    switch (event.key.toLowerCase()) {
      case ",":
        event.preventDefault();
        invoke("open_settings").catch(failed);
        return;
      case "w":
        event.preventDefault();
        invoke("close_window").catch(() => {});
        return;
      case "c":
        copyResult(event, !activityCoversResults() && state.hasResults && state.query.trim() ? selectedHit() : null, state.navigated);
        return;
      case "f":
      case "l":
        event.preventDefault();
        $query.focus();
        $query.select();
        state.navigated = false;
        return;
    }
  }
  if (activityCoversResults() && [" ", "Enter", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(event.key)) return;
  switch (event.key) {
    case " ":
      if (isLauncher(selectedHit())) return;
      // After the arrows or a click: the big preview. While typing: a space.
      if (!plain || !state.navigated || !state.hasResults || !state.query.trim() || !selectedHit()) return;
      event.preventDefault();
      showBig();
      return;
    case "ArrowDown":
    case "ArrowUp":
      if (!plain || !rows().length) return;
      event.preventDefault();
      moveVertical(event.key === "ArrowDown" ? 1 : -1);
      return;
    case "ArrowLeft":
    case "ArrowRight":
      if (!plain || !state.navigated || !rows().length) return;
      event.preventDefault();
      move(event.key === "ArrowRight" ? 1 : -1);
      return;
    case "Enter": {
      const hit = state.hasResults && hasQuery() ? selectedHit() : null;
      if (!hit) return;
      if (modifier && !event.altKey && !event.shiftKey) reveal(hit);
      else if (plain) open(hit);
      else return;
      event.preventDefault();
      return;
    }
    case "Escape":
      if (!$query.value) return;
      event.preventDefault();
      setQuery("");
      return;
  }
  // Typing anywhere goes to the field.
  if (event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey
      && document.activeElement !== $query && !window.getSelection()?.toString()) {
    $query.focus();
  }
});


tauri.event.listen("search-scope", ({payload}) => {
  if(Array.isArray(payload.folders))state.info.folders=payload.folders;
  if(typeof payload.hasCode==="boolean")state.info.hasCode=payload.hasCode;
  if(isAppsMode()||isSettingsMode()){render();return;}
  run(true);
});

tauri.event.listen("state", ({ payload }) => {
  const before = state.app;
  state.app = payload;
  // Code search turned on or off (Settings): the Code chip, the examples, a code: search.
  if (payload.hasCode != null && payload.hasCode !== state.info.hasCode) {
    state.info.hasCode = payload.hasCode;
    if (isCode() && state.query.trim()) run(); else render();
  }
  renderStatus();
  if (payload.searchable !== before.searchable || payload.files !== before.files) loadIndexed();
});

// The first prewarm can arrive before download/verification completes. Resume when weights become usable.
tauri.event.listen("model", ({ payload }) => {
  if (payload.state === "ready" && !isAppsMode() && !isSettingsMode()) ask({ op: "prewarm" }).catch(() => {});
});
tauri.event.listen("helper",({payload})=>{
  if(payload.from==="search"&&payload.event?.event==="search_index"&&payload.event.state==="words_ready"
    &&!document.hidden&&!isAppsMode() && !isSettingsMode()&&state.query.trim())state.refreshWords?.();
  if(payload.from==="search"&&payload.event?.event==="search_index"&&payload.event.state==="ready"
    &&!document.hidden&&!isAppsMode() && !isSettingsMode()&&state.query.trim())state.refine?.(true);
});

// The panel handed its search over (Ctrl+O, "Show all…"): this window was already open.
tauri.event.listen("window-search", ({ payload }) => {
  state.nextSelection = payload.selected || null;
  state.filter = payload.kind || null;
  setQuery(payload.query || "");
  $query.focus();
});

window.addEventListener("focus", () => { if (!isAppsMode() && !isSettingsMode()) ask({ op: "prewarm" }).catch(() => {}); });

// Its size, for the next time it opens (the shell keeps it when the window closes).
let sizeTimer = null;
function reportSize() {
  invoke("window_resized", { width: window.innerWidth, height: window.innerHeight }).catch(() => {});
}
window.addEventListener("resize", () => {
  if (state.activityOpen) updateActiveResult();
  clearTimeout(sizeTimer);
  sizeTimer = setTimeout(reportSize, 300);
});
reportSize();

/// What's indexed of each kind under the chosen folders (the home's counts), at most every two seconds while indexing.
let indexedTimer = null;
function loadIndexed() {
  if (indexedTimer) return;
  indexedTimer = setTimeout(async () => {
    indexedTimer = null;
    try {
      const reply = await ask({ op: "summaries" });
      const kinds = {};
      for (const root of reply.roots || []) {
        for (const [kind, count] of Object.entries(root.kinds || {})) kinds[kind] = (kinds[kind] || 0) + count;
      }
      state.indexed = kinds;
      if (!state.query.trim() && state.info.folders.length) {
        $content.querySelector(".about")?.replaceWith(about());
      }
    } catch {
      // The home goes without the counts.
    }
  }, state.indexed ? 2000 : 0);
}

async function start() {
  const info = await invoke("window_info");
  state.info = { ...state.info, ...info };
  Apps.configure(info.applications);
  WindowsSettings.configure(info.windowsSettings);
  state.app = info.state || {};
  if (info.search) {
    state.nextSelection = info.search.selected || null;
    state.filter = info.search.kind || null;
    $query.value = info.search.query || "";
    state.query = $query.value;
    $("clear").hidden = !state.query;
  }
  updatePreviewButton();
  render();
  loadIndexed();
  $query.focus();
  if (state.query || isAppsMode() || isSettingsMode()) run();
  if (!isAppsMode() && !isSettingsMode()) ask({ op: "prewarm" }).catch(() => {});
  if (info.debugQuery != null){if(info.debugSelected)state.nextSelection=info.debugSelected;debugSearch(info.debugQuery);}
}

// Debug runs (--debug-window): type the query in, and once the results and their pictures are in, report what the
// window shows ("" reports the home).
function debugSearch(query) {
  if (!query) {
    setTimeout(report, 1500);
    return;
  }
  debugPending = true;
  setQuery(query);
}

function report() {
  // Drive discovery publishes names after the first reply; do not end an installed launch check on a partial catalog.
  if (isAppsMode() && !applicationSearch.hits.length && applicationSearch.catalog.refreshing) return;
  if (isSettingsMode() && settingsSearch.active && (settingsSearch.settledEpoch !== settingsSearch.epoch || (!settingsSearch.hits.length && settingsSearch.catalog.refreshing))) return;
  debugPending = false;
  if (state.info.debugLaunch) {
    const hit = selectedHit();
    if (!isLauncher(hit)) { invoke("debug_report", {report:{launchAccepted:false,error:"No matching catalog application",settingsCatalog:settingsSearch.catalog}}); return; }
    Apps.launch(hit).then(() => invoke("debug_report", {report:{launchAccepted:true,applicationId:hit.id,name:hit.name,settingsCatalog:settingsSearch.catalog}}),
      error => invoke("debug_report", {report:{launchAccepted:false,error:String(error)}}));
    return;
  }
  // With --debug-settings, Settings opens as its button opens it, and Settings reports once its page is up.
  if (state.info.debugSettings) {
    setTimeout(() => $("settings").click(), 500);
    return;
  }
  // --debug-copy: the selected result on the clipboard, as Ctrl+C puts it.
  if (state.info.debugCopy && selectedHit()) {
    invoke("copy_file", { path: selectedHit().path })
      .then(() => "copied", (error) => `not copied: ${error}`)
      .then((copied) => invoke("debug_report", { report: { copied, path: selectedHit()?.path } }));
  }
  // Dev snapshots (window.html?big): the selected result's big preview, as Space shows it.
  if (new URLSearchParams(location.search).has("big")) toggleBig();
  setTimeout(() => {
    const thumbs = [...$content.querySelectorAll(".cell img")];
    const big = $side.querySelector(".frame img, .passage, .code-lines, .audio-moment, .placeholder");
    invoke("debug_report", {
      report: {
        window: true,
        query: $query.value,
        filter: state.filter,
        kinds: [...$kinds.querySelectorAll(".chip")].map((chip) => chip.textContent + (chip.classList.contains("selected") ? " (selected)" : "")),
        results: [...applicationSearch.hits, ...state.ranked].map(titleOf),
        applications: applicationSearch.hits.map(hit => ({id: hit.id, name: hit.name})),
        weaker: state.weaker.length,
        columns: columns(),
        selected: state.selection && nameOf(state.selection),
        thumbnails: `${thumbs.filter((image) => image.complete && image.naturalWidth > 0).length} of ${thumbs.length} drawn`,
        preview: big && {
          what: big.className || big.tagName.toLowerCase(),
          loaded: big.tagName === "IMG" ? big.complete && big.naturalWidth > 0 : null,
          size: big.tagName === "IMG" ? `${big.naturalWidth}x${big.naturalHeight}` : null,
          text: big.tagName === "IMG" ? null : big.textContent.slice(0, 80),
        },
        facts: [...$side.querySelectorAll(".facts .title, .facts .folder, .facts .details, .why .reason span")].map((node) => node.textContent),
        home: $content.querySelector(".home") && [...$content.querySelectorAll(".about .line")].map((line) => line.textContent),
        status: [$("index-summary").textContent || "Activity", $("count").textContent],
      },
    }).catch(() => {});
  }, 1500);
}

start();

$query.addEventListener("compositionstart",()=>{state.composing=true;clearTimeout(state.timer);cancelAnimationFrame(state.frame);});
$query.addEventListener("compositionend",()=>{state.composing=false;queryChanged();});
document.addEventListener("visibilitychange",()=>{
  if(document.hidden){clearTimeout(state.timer);cancelAnimationFrame(state.frame);applicationSearch.suspend();settingsSearch.suspend();ask({op:"cancel",generation:++state.generation}).catch(()=>{});}
  else if(state.query.trim())run();
});

"use strict";
window.OpenVINOSetup = class {
  constructor({ invoke, read, changed }) {
    this.invoke = invoke; this.read = read; this.changed = changed;
    this.generation = 0; this.backend = null; this.timer = null; this.ready = false; this.running = false;
    const node = (id) => document.getElementById(id); this.node = node;
    node("openvino-check").onclick = () => this.inspect();
    for (const kind of ["models", "python", "source"]) node("openvino-choose-" + kind).onclick = () => this.pick(kind);
    node("openvino-prepare").onclick = () => this.prepare();
    node("openvino-model-page").onclick = () => this.invoke("open_openvino_model_page").catch(error => this.message(error));
    node("openvino-download").onclick = () => this.prepare(true);
    node("openvino-cancel").onclick = async () => {
      try { this.renderPreparation(await this.invoke("cancel_openvino_preparation")); }
      catch (error) { this.message(error); }
    };
    node("openvino-device").onchange = () => {
      node("gpu-device").value = node("openvino-device").value; this.changed(); this.generation++;
    };
    node("npu-models").addEventListener("input", () => { this.generation++; });
    node("npu-python").addEventListener("input", () => { this.ready = false; this.generation++; this.buttons(); });
    node("openvino-revision").oninput = () => this.buttons();
    node("openvino-use-prepared").onclick = () => this.usePrepared();
  }
  show(backend) {
    if (this.backend === backend) return;
    this.backend = backend; this.generation++;
    clearTimeout(this.timer);
    if (this.active()) this.inspect();
  }
  active() { return ["openvino-npu", "openvino-gpu"].includes(this.backend); }
  message(error) {
    const field = this.node("openvino-device-status");
    field.textContent = error?.message || String(error); field.classList.add("problem");
  }
  buttons() {
    this.node("openvino-prepare").disabled = this.running || !this.ready || !this.node("openvino-source").value
      || !/^[0-9a-f]{40}$/.test(this.node("openvino-revision").value.trim());
    this.node("openvino-cancel").disabled = !this.running;
    this.node("openvino-download").disabled = this.running || !this.ready;
  }
  async inspect() {
    if (!this.active()) return;
    const generation = ++this.generation, draft = this.read();
    this.node("openvino-check").disabled = true;
    this.node("openvino-device-status").textContent = "Checking Intel devices and model preparation…";
    this.node("openvino-device-status").classList.remove("problem");
    try {
      const result = await this.invoke("openvino_status", { acceleration: draft });
      if (generation !== this.generation || !this.active()) return;
      if (result?.schemaVersion !== 1) throw new Error("Intel setup status is unavailable in this build.");
      this.ready = result.runtimeReady === true;
      this.node("openvino-runtime").textContent = this.ready
        ? "OpenVINO " + (result.runtimeVersion || "") + " runtime is ready."
        : result.backends?.[0]?.message || "The OpenVINO runtime is missing. Install the Windows build with bundled Intel support.";
      if (!draft.python && result.python) this.node("npu-python").value = result.python;
      if (!draft.models && result.models) this.node("npu-models").value = result.models;
      const available = (result.devices || []).filter(device => device.available && device.backend === draft.backend);
      const selected = this.node("gpu-device").value;
      const options = [new Option("Automatic · one eligible device", "")];
      for (const device of available) options.push(new Option(device.name + " · " + device.id, device.stableID || device.id));
      if (selected && !options.some(option => option.value === selected)) options.push(new Option("Saved selection · unavailable: " + selected, selected));
      this.node("openvino-device").replaceChildren(...options);
      this.node("openvino-device").value = selected;
      this.node("openvino-device-status").textContent = available.length
        ? available.map(device => device.name).join(", ") + ". Device available; model execution is verified after restart."
        : result.backends?.[0]?.message || "No eligible Intel device is available to OpenVINO. Check the Intel driver.";
      this.node("openvino-model-status").textContent = result.modelMessage || "Choose or prepare an exported model bundle.";
      this.renderPreparation(result.preparation);
    } catch (error) {
      if (generation === this.generation) this.message(error);
    } finally {
      if (this.active()) this.node("openvino-check").disabled = false;
      this.buttons();
    }
  }
  async pick(kind) {
    const generation = ++this.generation, backend = this.backend;
    try {
      const path = await this.invoke("pick_openvino_path", { kind });
      if (!path || generation !== this.generation || backend !== this.backend) return;
      const field = this.node(kind === "source" ? "openvino-source" : "npu-" + kind);
      field.value = path;
      if (kind === "source") {
        const name = path.split(/[\\/]/).filter(Boolean).pop();
        if (/^[0-9a-f]{40}$/.test(name)) this.node("openvino-revision").value = name;
        this.buttons();
      } else { this.changed(); this.inspect(); }
    } catch (error) { this.message(error); }
  }
  async prepare(download = false) {
    if (this.node(download ? "openvino-download" : "openvino-prepare").disabled) return;
    this.modelAtStart = this.node("npu-models").value;
    try {
      this.running = true; this.buttons();
      const accessToken = download ? this.node("openvino-access-token").value.trim() : "";
      if (download) this.node("openvino-access-token").value = "";
      const result = await this.invoke(download ? "download_openvino" : "prepare_openvino", { acceleration: this.read(), accessToken,
        source: this.node("openvino-source").value, revision: this.node("openvino-revision").value.trim() });
      this.renderPreparation(result);
    } catch (error) {
      this.running = false; this.buttons();
      this.node("openvino-preparation-status").textContent = error?.message || String(error);
    }
  }
  renderPreparation(value) {
    if (!value || value.phase === "idle") { this.buttons(); return; }
    this.running = !["ready", "failed", "cancelled"].includes(value.phase);
    this.node("openvino-preparation-status").textContent = value.message || value.phase;
    this.node("openvino-preparation-status").classList.toggle("problem", value.phase === "failed");
    if (value.phase === "ready" && value.bundle) {
      this.prepared = value.bundle;
      if (this.modelAtStart !== undefined && this.node("npu-models").value === this.modelAtStart) {
        this.modelAtStart = undefined; this.usePrepared();
      } else this.node("openvino-use-prepared").hidden = this.node("npu-models").value === value.bundle;
    }
    this.buttons(); clearTimeout(this.timer);
    if (this.running && this.active()) this.timer = setTimeout(() => this.poll(), 1000);
  }
  async poll() {
    if (!this.active()) return;
    try { this.renderPreparation(await this.invoke("openvino_preparation")); }
    catch (error) { this.node("openvino-preparation-status").textContent = error?.message || String(error); }
  }
  usePrepared() {
    if (!this.prepared) return;
    this.node("npu-models").value = this.prepared; this.changed();
    this.node("openvino-use-prepared").hidden = true; this.inspect();
  }
};

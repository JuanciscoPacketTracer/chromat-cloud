export function readOfficialResult(currentResult) {
  if (!currentResult) return null;
  let result = currentResult.result;
  if (typeof result === "string") {
    try {
      result = JSON.parse(result);
    } catch {
      throw new Error("El resultado oficial tiene un formato inválido.");
    }
  }
  if (!result || typeof result !== "object" || Array.isArray(result) ||
      typeof result.classification !== "string" || !result.classification.trim()) {
    throw new Error("El resultado oficial no contiene una clasificación válida.");
  }
  return result;
}

export function measurement(value, unit) {
  if (value == null) return "Sin medición";
  if (typeof value !== "number" || !Number.isFinite(value)) return "Medición no válida";
  return `${new Intl.NumberFormat("es-MX", { maximumFractionDigits: 2 }).format(value)} ${unit}`;
}

export function summarizeEvents(events) {
  return {
    total: events.length,
    completed: events.filter((event) => event.status === "completed").length,
    waiting: events.filter((event) => ["pending", "processing"].includes(event.status)).length,
    failed: events.filter((event) => event.status === "failed").length,
  };
}

export function filterEvents(events, status, query) {
  const search = query.trim().toLowerCase();
  return events.filter((event) => (status === "all" || event.status === status) &&
    event.event_id.toLowerCase().includes(search));
}

const statuses = { pending: "Pendiente", processing: "Procesando", failed: "Fallo", completed: "Completado" };
const stages = { verde: "Verde", maduro: "Maduro", otro: "Otro", uncertain: "Sin determinar" };
const stageLabel = (stage) => stage == null ? "Sin etapa" : Object.hasOwn(stages, stage) ? stages[stage] : stage;

if (typeof document !== "undefined") {
  const state = { role: "operator", csrfToken: null, source: null, revision: 0, sources: [], events: null };
  const $ = (selector) => document.querySelector(selector);
  const loginView = $("#login-view");
  const dashboardView = $("#dashboard-view");
  const loginError = $("#login-error");
  const dashboardError = $("#dashboard-error");
  const panels = [
    { key: "events", path: "events", container: $("#events"), render: renderEvents },
    { key: "states", path: "state", container: $("#state"), render: renderState },
    { key: "history", path: "state/history", container: $("#state-history"), render: renderHistory },
  ];

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  function empty(container, title, description) {
    const message = element("div", "empty-state");
    message.append(element("strong", "", title), element("span", "", description));
    container.replaceChildren(message);
  }

  function timestamp(value) {
    const date = value ? new Date(value) : null;
    const node = element("time");
    if (!date || Number.isNaN(date.getTime())) {
      node.textContent = value ? "Fecha no válida" : "Sin fecha";
    } else {
      node.dateTime = value;
      node.title = value;
      node.textContent = new Intl.DateTimeFormat("es-MX", {
        dateStyle: "medium", timeStyle: "medium", timeZone: "UTC",
      }).format(date) + " UTC";
    }
    return node;
  }

  function statusBadge(status) {
    const badge = element("span", "badge", Object.hasOwn(statuses, status) ? statuses[status] : `Estado desconocido: ${status}`);
    if (Object.hasOwn(statuses, status)) badge.classList.add(status);
    return badge;
  }

  async function request(path, options = {}) {
    const response = await fetch(path, {
      credentials: "same-origin", ...options,
      headers: { "content-type": "application/json", ...options.headers },
    });
    let body = null;
    if (response.status !== 204) {
      try {
        body = await response.json();
      } catch {
        throw Object.assign(new Error("La respuesta del servidor no es válida."), { status: response.status });
      }
    }
    if (!response.ok) {
      throw Object.assign(new Error(body?.message || `Error HTTP ${response.status}`), { status: response.status });
    }
    return body;
  }

  function showError(container, message) {
    container.textContent = message;
    container.hidden = false;
  }

  function clearDetails() {
    state.events = null;
    $("#event-overview").replaceChildren();
    $("#events-message").textContent = "";
    $("#event-status").value = "all";
    $("#event-search").value = "";
    $("#event-status").disabled = true;
    $("#event-search").disabled = true;
    for (const panel of panels) {
      panel.container.replaceChildren();
      panel.container.setAttribute("aria-busy", "false");
    }
  }

  function clearSession() {
    state.revision += 1;
    state.source = null;
    state.csrfToken = null;
    state.sources = [];
    clearDetails();
    $("#sources").replaceChildren();
    $("#sources").setAttribute("aria-busy", "false");
    $("#sources-message").textContent = "";
    $("#source-count").textContent = "—";
    $("#source-search").value = "";
    $("#details").hidden = true;
    $("#choose-source").hidden = false;
    dashboardView.hidden = true;
    loginView.hidden = false;
    $("#username").focus();
  }

  function expireSession() {
    clearSession();
    $("#login-message").textContent = "";
    showError(loginError, "La sesión venció o ya no es válida. Inicia sesión de nuevo.");
  }

  function table(container, headers, rows) {
    const wrapper = element("div", "table-wrap");
    wrapper.tabIndex = 0;
    wrapper.setAttribute("role", "region");
    wrapper.setAttribute("aria-label", "Historial de observaciones, tabla desplazable");
    const tableElement = element("table");
    const thead = element("thead");
    const header = element("tr");
    for (const title of headers) {
      const th = element("th", "", title);
      th.scope = "col";
      header.append(th);
    }
    thead.append(header);
    const tbody = element("tbody");
    for (const values of rows) {
      const row = element("tr");
      for (const value of values) {
        const cell = element("td");
        if (value instanceof Node) cell.append(value);
        else cell.textContent = String(value ?? "Sin datos");
        row.append(cell);
      }
      tbody.append(row);
    }
    tableElement.append(thead, tbody);
    wrapper.append(tableElement);
    container.replaceChildren(wrapper);
  }

  function resultCell(event) {
    const cell = element("div", "official-result");
    if (!event.current_result) {
      cell.append(element("strong", "result-value",
        ["pending", "processing"].includes(event.status) ? "Aún no disponible" : "Sin resultado disponible"));
      return cell;
    }
    try {
      const result = readOfficialResult(event.current_result);
      cell.append(element("strong", "result-value", stageLabel(result.classification)));
      const run = event.current_result;
      const label = run.algorithm === "hsv" ? "HSV experimental"
        : run.algorithm === "cnn" ? "CNN: simulador" : `Algoritmo: ${run.algorithm || "desconocido"}`;
      cell.append(element("span", "result-detail", `${label} · versión ${run.algorithm_version || "no disponible"}`
        + (run.model_version ? ` · modelo ${run.model_version}` : "")));
      if (event.status !== "completed") {
        cell.append(element("span", "result-detail", "Resultado oficial anterior; el evento no está completado actualmente."));
      }
    } catch (error) {
      cell.className = "error";
      cell.textContent = error.message;
    }
    return cell;
  }

  function renderOverview(events) {
    const container = $("#event-overview");
    const counts = summarizeEvents(events);
    const stats = element("div", "stats");
    for (const [label, value, note] of [
      ["Eventos consultados", counts.total, "Máximo 100 de esta fuente"],
      ["Completados", counts.completed, "Procesamiento finalizado"],
      ["En espera", counts.waiting, "Pendientes o procesando"],
      ["Con fallo", counts.failed, "Requieren revisión"],
    ]) {
      const stat = element("div", "stat");
      stat.append(element("span", "stat-label", label), element("strong", "stat-value", value), element("span", "stat-note", note));
      stats.append(stat);
    }
    container.replaceChildren(stats);
    container.append(element("p", "overview-note", "Resumen de los eventos consultados, no del total histórico. Los filtros de la bitácora no cambian estos conteos."));
    if (!events.length) return;
    const latest = events[0];
    const card = element("section", "card latest-event");
    card.setAttribute("aria-label", "Último evento consultado y sus mediciones");
    const result = element("div");
    result.append(element("p", "eyebrow", "Último evento consultado"), timestamp(latest.occurred_at),
      element("p", "result-label", "Resultado oficial"), resultCell(latest), statusBadge(latest.status));
    if (latest.clock_suspect) result.append(element("p", "clock-warning", "Reloj sospechoso: revisa la fecha de captura."));
    const readings = element("div", "measurement-grid");
    for (const [label, value] of [
      ["Temperatura", measurement(latest.temperature_c, "°C")],
      ["Humedad relativa", measurement(latest.humidity_rh, "% HR")],
    ]) {
      const reading = element("dl", "measurement");
      reading.append(element("dt", "", label), element("dd", "", value));
      readings.append(reading);
    }
    readings.append(element("p", "measurement-caption", "Mediciones de esa captura. No son datos en vivo ni confirman la conexión del sensor."));
    card.append(result, readings);
    container.append(card);
  }

  function renderEvents(events) {
    state.events = [...events].sort((a, b) => String(b.occurred_at).localeCompare(String(a.occurred_at)));
    renderOverview(state.events);
    $("#event-status").disabled = false;
    $("#event-search").disabled = false;
    renderFilteredEvents();
  }

  function renderFilteredEvents() {
    if (state.events === null) return;
    const events = filterEvents(state.events, $("#event-status").value, $("#event-search").value);
    $("#events-message").textContent = `${events.length} de ${state.events.length} eventos consultados.`;
    const container = $("#events");
    if (!events.length) {
      empty(container, state.events.length ? "No hay coincidencias" : "Esta fuente aún no tiene eventos",
        state.events.length ? "Cambia el estado o el identificador de búsqueda." : "Las observaciones aparecerán cuando la fuente las envíe al servidor.");
      return;
    }
    const grid = element("div", "event-grid");
    for (const event of events) {
      const card = element("article", "event-card");
      const heading = element("div", "event-card-heading");
      heading.append(element("span", "event-number", `Evento ${event.event_id.slice(0, 8)}`), statusBadge(event.status));
      const body = element("div", "event-body");
      const time = element("div", "event-time");
      time.append(timestamp(event.occurred_at));
      body.append(time, element("p", "result-label", "Resultado oficial"), resultCell(event));
      if (event.clock_suspect) body.append(element("p", "clock-warning", "Reloj sospechoso"));
      const measurements = element("div", "event-measurements");
      for (const [label, value] of [
        ["Temperatura", measurement(event.temperature_c, "°C")],
        ["Humedad relativa", measurement(event.humidity_rh, "% HR")],
      ]) {
        const reading = element("div");
        reading.append(element("span", "", label), element("strong", "", value));
        measurements.append(reading);
      }
      body.append(measurements);
      const details = element("details");
      const metadata = element("dl", "event-metadata");
      metadata.append(element("dt", "", "Identificador completo"), element("dd", "", event.event_id));
      for (const [label, value] of [["Recibido", event.received_at], ["Procesado", event.processed_at]]) {
        const date = element("dd");
        date.append(value ? timestamp(value) : element("span", "", "Sin fecha registrada"));
        metadata.append(element("dt", "", label), date);
      }
      details.append(element("summary", "", "Ver trazabilidad del evento"), metadata);
      card.append(heading, body, details);
      grid.append(card);
    }
    container.replaceChildren(grid);
  }

  function renderState(states, container) {
    if (!states.length) {
      empty(container, "Sin estado agregado", "Todavía no hay observaciones elegibles. Puede haber eventos que no cumplan las reglas de agregación.");
      return;
    }
    const grid = element("div", "state-grid");
    for (const entry of states) {
      const card = element("article", "state-card");
      card.append(element("h4", "", entry.crop), element("p", "state-stage", stageLabel(entry.current_stage)));
      for (const text of [
        `Consecutividad: ${stageLabel(entry.consecutive_stage)} (${entry.consecutive_count})`,
        `Episodio ${entry.episode_seq} · Regla ${entry.aggregation_rule_version ?? "sin versión"}`,
      ]) card.append(element("p", "state-meta", text));
      const last = element("p", "state-meta", "Última observación elegible: ");
      last.append(timestamp(entry.last_occurred_at));
      card.append(last);
      grid.append(card);
    }
    container.replaceChildren(grid);
  }

  function renderHistory(history, container) {
    if (!history.length) {
      empty(container, "Sin observaciones aceptadas", "El historial se construye con los eventos que cumplen las reglas de agregación.");
      return;
    }
    table(container, ["Capturado (UTC)", "Evento", "Cultivo", "Clasificación", "Confianza no calibrada", "Consecutividad", "Transición"], history.map((entry) => [
      timestamp(entry.occurred_at), element("span", "history-id", entry.event_id), entry.crop, stageLabel(entry.classification), entry.confidence,
      `${stageLabel(entry.consecutive_stage)} (${entry.consecutive_count})`,
      entry.transition ? `${stageLabel(entry.transition.fromStage)} → ${stageLabel(entry.transition.toStage)}` : "Sin transición",
    ]));
  }

  function renderSources() {
    const container = $("#sources");
    container.replaceChildren();
    const query = $("#source-search").value.trim().toLowerCase();
    const sources = state.sources.filter((source) => [source.name, source.crop, source.source_id].some(
      (value) => value.toLowerCase().includes(query)));
    $("#source-count").textContent = String(state.sources.length);
    if (!sources.length) {
      $("#sources-message").textContent = state.sources.length ? "No hay fuentes que coincidan con tu búsqueda."
        : state.role === "producer" ? "No tienes fuentes asignadas disponibles." : "No hay fuentes para mostrar.";
      return;
    }
    $("#sources-message").textContent = `${sources.length} fuentes disponibles en esta consulta. Selecciona una para explorar sus observaciones.`;
    for (const source of sources) {
      const button = element("button", "source");
      button.type = "button";
      button.dataset.sourceId = source.source_id;
      button.setAttribute("aria-pressed", String(source.source_id === state.source?.source_id));
      const top = element("span", "source-top");
      const icon = element("span", "source-icon", "⌁");
      icon.setAttribute("aria-hidden", "true");
      top.append(icon, element("span", "badge neutral", source.status === "active" ? "Activa" : source.status === "revoked" ? "Revocada" : source.status));
      button.append(top, element("strong", "", source.name), element("span", "source-meta", `Cultivo · ${source.crop}`));
      if (source.is_test) button.append(element("span", "source-test", "Fuente de prueba"));
      button.append(element("span", "source-id", source.source_id));
      button.addEventListener("click", () => selectSource(source));
      container.append(button);
    }
  }

  function rolePath() {
    return state.role === "operator" ? "admin" : "producer";
  }

  async function loadSources() {
    const revision = ++state.revision;
    state.source = null;
    state.sources = [];
    clearDetails();
    $("#details").hidden = true;
    $("#choose-source").hidden = false;
    $("#sources").replaceChildren();
    $("#sources").setAttribute("aria-busy", "true");
    $("#source-count").textContent = "—";
    $("#source-search").disabled = true;
    $("#sources-message").textContent = "Cargando fuentes…";
    try {
      const body = await request(`/api/v1/${rolePath()}/sources`);
      if (revision !== state.revision) return;
      if (!Array.isArray(body?.sources)) throw new Error("La lista de fuentes no es válida.");
      state.sources = body.sources;
      renderSources();
    } catch (error) {
      if (revision !== state.revision) return;
      if (error.status === 401) return expireSession();
      $("#sources-message").textContent = `No se pudieron cargar las fuentes: ${error.message}. Usa «Actualizar fuentes» para reintentar.`;
    } finally {
      if (revision === state.revision) {
        $("#sources").setAttribute("aria-busy", "false");
        $("#source-search").disabled = false;
      }
    }
  }

  async function selectSource(source) {
    const changed = state.source?.source_id !== source.source_id;
    state.source = source;
    const revision = ++state.revision;
    clearDetails();
    document.querySelectorAll(".source").forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.sourceId === source.source_id));
    });
    $("#details-title").textContent = source.name;
    $("#source-description").textContent = `${source.crop} · ${source.is_test ? "Fuente de prueba · " : ""}${source.source_id}`;
    $("#details").hidden = false;
    $("#choose-source").hidden = true;
    if (changed) $("#details-title").focus();
    $("#event-overview").append(element("p", "loading", "Cargando resumen y mediciones…"));
    for (const panel of panels) {
      panel.container.replaceChildren(element("p", "loading", "Cargando…"));
      panel.container.setAttribute("aria-busy", "true");
    }
    const base = `/api/v1/${rolePath()}/sources/${encodeURIComponent(source.source_id)}`;
    await Promise.all(panels.map(async (panel) => {
      try {
        const body = await request(`${base}/${panel.path}`);
        if (revision !== state.revision) return;
        if (!Array.isArray(body?.[panel.key])) throw new Error("La respuesta no tiene el formato esperado.");
        panel.render(body[panel.key], panel.container);
      } catch (error) {
        if (revision !== state.revision) return;
        if (error.status === 401) return expireSession();
        panel.container.replaceChildren(element("p", "error", `No se pudo cargar esta sección: ${error.message}. Usa «Actualizar consulta» para reintentar.`));
        if (panel.key === "events") {
          state.events = null;
          $("#events-message").textContent = "";
          $("#event-overview").replaceChildren(element("p", "error", "Resumen y mediciones no disponibles: no se pudo consultar la bitácora."));
        }
      } finally {
        if (revision === state.revision) panel.container.setAttribute("aria-busy", "false");
      }
    }));
  }

  async function login(event) {
    event.preventDefault();
    loginError.hidden = true;
    $("#login-message").textContent = "Iniciando sesión…";
    $("#login-submit").disabled = true;
    document.querySelectorAll('input[name="role"]').forEach((radio) => { radio.disabled = true; });
    const body = Object.fromEntries(new FormData(event.currentTarget));
    state.role = document.querySelector('input[name="role"]:checked').value;
    try {
      const result = await request(`/api/v1/${rolePath()}/login`, { method: "POST", body: JSON.stringify(body) });
      state.csrfToken = result.csrf_token ?? null;
      $("#password").value = "";
      loginView.hidden = true;
      dashboardView.hidden = false;
      dashboardError.hidden = true;
      $("#role-badge").textContent = state.role === "operator" ? "Operador" : "Productor · Solo lectura";
      $("#dashboard-title").textContent = "Tu panel de monitoreo";
      $("#dashboard-subtitle").textContent = state.role === "operator"
        ? "Explora las fuentes y los eventos de tu instalación." : "Explora las fuentes asignadas a tu cuenta, en modo de solo lectura.";
      $("#dashboard-title").focus();
      await loadSources();
    } catch (error) {
      showError(loginError, `No se pudo iniciar sesión: ${error.message}`);
    } finally {
      $("#login-message").textContent = "";
      $("#login-submit").disabled = false;
      document.querySelectorAll('input[name="role"]').forEach((radio) => { radio.disabled = false; });
    }
  }

  async function logout() {
    dashboardError.hidden = true;
    $("#logout").disabled = true;
    try {
      await request(`/api/v1/${rolePath()}/logout`, {
        method: "POST", headers: state.csrfToken ? { "x-csrf-token": state.csrfToken } : {},
      });
      clearSession();
      $("#login-message").textContent = "Sesión cerrada.";
    } catch (error) {
      if (error.status === 401) expireSession();
      else showError(dashboardError, `No se pudo cerrar la sesión: ${error.message}. Inténtalo de nuevo.`);
    } finally {
      $("#logout").disabled = false;
    }
  }

  $("#login-form").addEventListener("submit", login);
  $("#logout").addEventListener("click", logout);
  $("#refresh-sources").addEventListener("click", loadSources);
  $("#refresh-details").addEventListener("click", () => { if (state.source) selectSource(state.source); });
  $("#source-search").addEventListener("input", renderSources);
  $("#event-search").addEventListener("input", renderFilteredEvents);
  $("#event-status").addEventListener("change", renderFilteredEvents);
}

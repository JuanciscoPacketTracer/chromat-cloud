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

if (typeof document !== "undefined") {
  const state = { role: "operator", csrfToken: null, source: null, revision: 0 };
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

  async function request(path, options = {}) {
    const response = await fetch(path, {
      credentials: "same-origin",
      ...options,
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

  function showError(element, message) {
    element.textContent = message;
    element.hidden = false;
  }

  function expireSession() {
    state.revision += 1;
    state.source = null;
    state.csrfToken = null;
    dashboardView.hidden = true;
    $("#sources").replaceChildren();
    $("#details").hidden = true;
    for (const panel of panels) panel.container.replaceChildren();
    loginView.hidden = false;
    $("#login-message").textContent = "";
    showError(loginError, "La sesión venció o ya no es válida. Inicia sesión de nuevo.");
    $("#username").focus();
  }

  function table(container, headers, rows) {
    const wrapper = document.createElement("div");
    wrapper.className = "table-wrap";
    wrapper.tabIndex = 0;
    wrapper.setAttribute("role", "region");
    wrapper.setAttribute("aria-label", "Tabla desplazable");
    const tableElement = document.createElement("table");
    const thead = document.createElement("thead");
    const header = document.createElement("tr");
    for (const title of headers) {
      const th = document.createElement("th");
      th.scope = "col";
      th.textContent = title;
      header.append(th);
    }
    thead.append(header);
    const tbody = document.createElement("tbody");
    for (const values of rows) {
      const row = document.createElement("tr");
      for (const value of values) {
        const cell = document.createElement("td");
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
    const cell = document.createElement("div");
    if (!event.current_result) {
      cell.textContent = event.status === "pending" || event.status === "processing"
        ? "Aún no disponible" : "Sin resultado disponible";
      return cell;
    }
    try {
      const result = readOfficialResult(event.current_result);
      const classification = document.createElement("strong");
      classification.textContent = result.classification;
      cell.append(classification);
      const details = document.createElement("span");
      details.className = "result-detail";
      const algorithm = event.current_result.algorithm;
      const label = algorithm === "hsv" ? "HSV experimental"
        : algorithm === "cnn" ? "CNN: simulador" : `Algoritmo: ${algorithm || "desconocido"}`;
      details.textContent = `${label} · versión ${event.current_result.algorithm_version || "no disponible"}`
        + (event.current_result.model_version ? ` · modelo ${event.current_result.model_version}` : "");
      cell.append(details);
      if (event.status !== "completed") {
        const previous = document.createElement("span");
        previous.className = "result-detail";
        previous.textContent = "Resultado oficial anterior; el evento no está completado actualmente.";
        cell.append(previous);
      }
    } catch (error) {
      cell.className = "error";
      cell.textContent = error.message;
    }
    return cell;
  }

  function renderEvents(events, container) {
    if (!events.length) {
      container.textContent = "No hay eventos para esta fuente.";
      return;
    }
    const statuses = { pending: "Pendiente", processing: "Procesando", failed: "Fallo", completed: "Completado" };
    table(container, ["Evento", "Capturado (UTC)", "Estado", "Resultado oficial"], events.map((event) => [
      event.event_id,
      `${event.occurred_at || "Sin fecha"}${event.clock_suspect ? " · reloj sospechoso" : ""}`,
      statuses[event.status] || `Estado desconocido: ${event.status}`,
      resultCell(event),
    ]));
  }

  function renderState(states, container) {
    if (!states.length) {
      container.textContent = "No hay observaciones elegibles para el estado agregado.";
      return;
    }
    table(container, ["Cultivo", "Etapa agregada", "Consecutividad", "Episodio", "Regla"], states.map((entry) => [
      entry.crop, entry.current_stage ?? "Sin etapa", `${entry.consecutive_stage ?? "Sin etapa"} (${entry.consecutive_count})`,
      entry.episode_seq, entry.aggregation_rule_version ?? "Sin versión",
    ]));
  }

  function renderHistory(history, container) {
    if (!history.length) {
      container.textContent = "No hay observaciones aceptadas en el historial.";
      return;
    }
    table(container, ["Capturado (UTC)", "Evento", "Cultivo", "Clasificación", "Confianza no calibrada", "Consecutividad", "Transición"], history.map((entry) => [
      entry.occurred_at, entry.event_id, entry.crop, entry.classification, entry.confidence,
      `${entry.consecutive_stage ?? "Sin etapa"} (${entry.consecutive_count})`,
      entry.transition ? `${entry.transition.fromStage ?? "Sin etapa"} → ${entry.transition.toStage}` : "Sin transición",
    ]));
  }

  function renderSources(sources) {
    const container = $("#sources");
    container.replaceChildren();
    if (!sources.length) {
      $("#sources-message").textContent = state.role === "producer"
        ? "No tienes fuentes asignadas disponibles." : "No hay fuentes para mostrar.";
      return;
    }
    $("#sources-message").textContent = "Selecciona una fuente para consultar sus eventos y estado.";
    for (const source of sources) {
      const button = document.createElement("button");
      button.className = "source";
      button.type = "button";
      button.setAttribute("aria-pressed", String(source.source_id === state.source?.source_id));
      const name = document.createElement("strong");
      name.textContent = source.name;
      const description = document.createElement("span");
      description.textContent = `${source.crop} · ${source.status}${source.is_test ? " · fuente de prueba" : ""}`;
      const id = document.createElement("span");
      id.textContent = source.source_id;
      button.append(name, description, id);
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
    $("#details").hidden = true;
    $("#sources").replaceChildren();
    $("#sources-message").textContent = "Cargando fuentes…";
    try {
      const body = await request(`/api/v1/${rolePath()}/sources`);
      if (revision !== state.revision) return;
      if (!Array.isArray(body?.sources)) throw new Error("La lista de fuentes no es válida.");
      renderSources(body.sources);
    } catch (error) {
      if (revision !== state.revision) return;
      if (error.status === 401) return expireSession();
      $("#sources-message").textContent = `No se pudieron cargar las fuentes: ${error.message}. Usa «Actualizar fuentes» para reintentar.`;
    }
  }

  async function selectSource(source) {
    state.source = source;
    const revision = ++state.revision;
    document.querySelectorAll(".source").forEach((button) => {
      button.setAttribute("aria-pressed", String(button.lastElementChild.textContent === source.source_id));
    });
    $("#details-title").textContent = `Fuente: ${source.name}`;
    $("#details").hidden = false;
    for (const panel of panels) panel.container.textContent = "Cargando…";
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
        panel.container.textContent = `No se pudo cargar esta sección: ${error.message}. Usa «Actualizar consulta» para reintentar.`;
      }
    }));
  }

  async function login(event) {
    event.preventDefault();
    loginError.hidden = true;
    $("#login-message").textContent = "Iniciando sesión…";
    $("#login-submit").disabled = true;
    const body = Object.fromEntries(new FormData(event.currentTarget));
    state.role = document.querySelector('input[name="role"]:checked').value;
    try {
      const result = await request(`/api/v1/${rolePath()}/login`, { method: "POST", body: JSON.stringify(body) });
      state.csrfToken = result.csrf_token ?? null;
      $("#password").value = "";
      loginView.hidden = true;
      dashboardView.hidden = false;
      dashboardError.hidden = true;
      $("#dashboard-title").textContent = state.role === "operator" ? "Vista de operador" : "Vista de productor";
      $("#dashboard-subtitle").textContent = state.role === "operator"
        ? "Consulta de fuentes y eventos para operación." : "Solo lectura: fuentes asignadas a tu cuenta.";
      $("#dashboard-title").focus();
      await loadSources();
    } catch (error) {
      showError(loginError, `No se pudo iniciar sesión: ${error.message}`);
    } finally {
      $("#login-message").textContent = "";
      $("#login-submit").disabled = false;
    }
  }

  async function logout() {
    dashboardError.hidden = true;
    $("#logout").disabled = true;
    try {
      await request(`/api/v1/${rolePath()}/logout`, {
        method: "POST",
        headers: state.csrfToken ? { "x-csrf-token": state.csrfToken } : {},
      });
      state.revision += 1;
      state.source = null;
      state.csrfToken = null;
      $("#sources").replaceChildren();
      $("#details").hidden = true;
      for (const panel of panels) panel.container.replaceChildren();
      dashboardView.hidden = true;
      loginView.hidden = false;
      $("#login-message").textContent = "Sesión cerrada.";
      $("#username").focus();
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
  $("#refresh-details").addEventListener("click", () => {
    if (state.source) selectSource(state.source);
  });
}

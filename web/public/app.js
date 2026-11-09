const state = {
  role: "operator",
  csrfToken: null,
  sourceId: null,
};

const $ = (selector) => document.querySelector(selector);
const loginView = $("#login-view");
const dashboardView = $("#dashboard-view");
const loginError = $("#login-error");
const dashboardError = $("#dashboard-error");

async function request(path, options = {}) {
  const response = await fetch(path, {
    credentials: "same-origin",
    headers: { "content-type": "application/json", ...options.headers },
    ...options,
  });
  const body = response.status === 204 ? null : await response.json();
  if (!response.ok) {
    throw new Error(body?.message ?? "No fue posible completar la solicitud");
  }
  return body;
}

function showError(element, error) {
  element.textContent = error.message;
  element.hidden = false;
}

function renderSources(sources) {
  const container = $("#sources");
  container.replaceChildren();
  for (const source of sources) {
    const button = document.createElement("button");
    button.className = "source";
    button.type = "button";
    button.innerHTML = `<strong></strong><span></span><span></span>`;
    button.querySelector("strong").textContent = source.name;
    button.querySelectorAll("span")[0].textContent = `${source.crop} · ${source.status}`;
    button.querySelectorAll("span")[1].textContent = source.source_id;
    button.addEventListener("click", () => loadEvents(source));
    container.append(button);
  }
}

function renderEvents(events) {
  const container = $("#events");
  if (events.length === 0) {
    container.textContent = "No hay eventos para mostrar.";
    return;
  }
  const table = document.createElement("table");
  table.innerHTML = "<thead><tr><th>Evento</th><th>Ocurrido</th><th>Estado</th><th>Etapa</th></tr></thead>";
  const body = document.createElement("tbody");
  for (const event of events) {
    const row = document.createElement("tr");
    row.innerHTML = "<td></td><td></td><td></td><td></td>";
    row.children[0].textContent = event.event_id;
    row.children[1].textContent = event.occurred_at;
    row.children[2].textContent = event.status;
    row.children[3].textContent = event.current_result?.result?.classification ?? "Pendiente";
    body.append(row);
  }
  table.append(body);
  container.replaceChildren(table);
}

function renderState(states) {
  const container = $("#state");
  if (states.length === 0) {
    container.textContent = "Todavía no hay observaciones elegibles para el estado agregado.";
    return;
  }
  const table = document.createElement("table");
  table.innerHTML = "<thead><tr><th>Cultivo</th><th>Etapa</th><th>Consecutividad</th><th>Episodio</th></tr></thead>";
  const body = document.createElement("tbody");
  for (const state of states) {
    const row = document.createElement("tr");
    row.innerHTML = "<td></td><td></td><td></td><td></td>";
    row.children[0].textContent = state.crop;
    row.children[1].textContent = state.current_stage ?? "Pendiente";
    row.children[2].textContent = `${state.consecutive_stage ?? "-"} (${state.consecutive_count})`;
    row.children[3].textContent = String(state.episode_seq);
    body.append(row);
  }
  table.append(body);
  container.replaceChildren(table);
  $("#state-panel").hidden = false;
}

async function loadSources() {
  const path = state.role === "operator"
    ? "/api/v1/admin/sources"
    : "/api/v1/producer/sources";
  const body = await request(path, { headers: {} });
  renderSources(body.sources);
}

async function loadEvents(source) {
  state.sourceId = source.source_id;
  const path = state.role === "operator"
    ? `/api/v1/admin/sources/${source.source_id}/events`
    : `/api/v1/producer/sources/${source.source_id}/events`;
  const body = await request(path, { headers: {} });
  const statePath = state.role === "operator"
    ? `/api/v1/admin/sources/${source.source_id}/state`
    : `/api/v1/producer/sources/${source.source_id}/state`;
  const stateBody = await request(statePath, { headers: {} });
  renderState(stateBody.states);
  $("#events-panel").hidden = false;
  renderEvents(body.events);
}

async function login(event) {
  event.preventDefault();
  loginError.hidden = true;
  const body = Object.fromEntries(new FormData(event.currentTarget));
  const path = state.role === "operator"
    ? "/api/v1/admin/login"
    : "/api/v1/producer/login";
  try {
    const result = await request(path, { method: "POST", body: JSON.stringify(body) });
    state.csrfToken = result.csrf_token ?? null;
    loginView.hidden = true;
    dashboardView.hidden = false;
    $("#dashboard-title").textContent = state.role === "operator" ? "Vista de operador" : "Vista de productor";
    $("#dashboard-subtitle").textContent = state.role === "operator"
      ? "Fuentes y eventos autorizados para operación."
      : "Fuentes asignadas en modo de solo lectura.";
    await loadSources();
  } catch (error) {
    showError(loginError, error);
  }
}

async function logout() {
  const path = state.role === "operator" ? "/api/v1/admin/logout" : "/api/v1/producer/logout";
  try {
    await request(path, {
      method: "POST",
      headers: state.csrfToken ? { "x-csrf-token": state.csrfToken } : {},
    });
  } catch {
    // Clearing the local view still prevents stale data from remaining visible.
  }
  window.location.reload();
}

document.querySelectorAll(".tab").forEach((tab) => tab.addEventListener("click", () => {
  state.role = tab.dataset.role;
  document.querySelectorAll(".tab").forEach((item) => item.classList.toggle("active", item === tab));
}));
$("#login-form").addEventListener("submit", login);
$("#logout").addEventListener("click", logout);

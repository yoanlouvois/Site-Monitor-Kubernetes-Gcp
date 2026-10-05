const API = "/api";
const REFRESH_MS = 30000;

// Période choisie pour l'uptime et le temps moyen (en jours)
let periodDays = 7;
const PERIOD_LABELS = { 1: "24 h", 7: "7 j", 30: "30 j" };

// Site en cours de modification (null = aucun) et dernières données reçues,
// pour pouvoir réafficher la liste sans rappeler l'api
let editingId = null;
let lastData = null;

// Crée un élément HTML. Le texte passe par textContent, jamais par innerHTML :
// un nom de site comme <script>...</script> s'affiche comme du texte, sans être exécuté.
function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = text;
  return node;
}

function setText(id, value) {
  document.getElementById(id).textContent = value;
}

function setBanner(state, text) {
  document.getElementById("banner").className = `banner ${state}`;
  setText("banner-text", text);
}

// Appel à l'api, avec un message d'erreur lisible
async function callApi(path, options = {}) {
  const response = await fetch(API + path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (!response.ok) {
    let message = `Erreur ${response.status}`;
    if (response.status === 422) message = "Données invalides (vérifie l'URL)";
    try {
      const body = await response.json();
      if (typeof body.detail === "string") message = body.detail;
    } catch {}
    throw new Error(message);
  }
  return response.status === 204 ? null : response.json();
}

function siteRow(site, checks, uptime) {
  if (site.id === editingId) return editRow(site);

  const state = site.is_up === null ? "unknown" : site.is_up ? "up" : "down";
  const labels = { up: "EN LIGNE", down: "EN PANNE", unknown: "EN ATTENTE" };
  const row = el("div", `site ${state}`);

  // Nom, état et URL
  const title = el("div", "title");
  title.append(el("span", "dot"), el("span", "name", site.name), el("span", "tag", labels[state]));
  const info = el("div", "info");
  info.append(title, el("span", "url", site.url));

  // Historique : l'api renvoie le plus récent en premier, on l'affiche de gauche à droite
  const history = el("div", "history");
  [...checks].reverse().forEach((check) => {
    const bar = el("span", check.is_up ? "bar up" : "bar down");
    const date = new Date(check.checked_at).toLocaleString("fr-FR");
    const detail = check.is_up
      ? `HTTP ${check.status_code} en ${check.response_time_ms} ms`
      : check.error || `HTTP ${check.status_code}`;
    bar.title = `${date} — ${detail}`;
    history.append(bar);
  });

  // Uptime et temps moyen sur la période choisie (route /uptime), dernier temps de réponse
  const last = checks[0];
  const period = PERIOD_LABELS[periodDays];
  const meta = el("div", "meta");

  const uptimeText = uptime && uptime.uptime_percent !== null ? `${uptime.uptime_percent} %` : "—";
  const uptimeEl = el("span", "uptime", uptimeText);
  if (uptime) uptimeEl.title = `Uptime sur ${period} (${uptime.total_checks} checks)`;

  const avg = uptime && uptime.avg_response_ms !== null ? `moy. ${uptime.avg_response_ms} ms` : "moy. —";
  const lastMs = last && last.response_time_ms !== null ? `${last.response_time_ms} ms` : "—";
  const latencyEl = el("span", "latency", `${avg} · dern. ${lastMs}`);
  latencyEl.title = `Temps de réponse moyen sur ${period} · dernier check`;

  meta.append(uptimeEl, latencyEl);

  // Boutons modifier et supprimer
  const edit = el("button", "edit", "✎");
  edit.type = "button";
  edit.title = "Modifier";
  edit.addEventListener("click", () => startEdit(site.id));

  const del = el("button", "delete", "✕");
  del.type = "button";
  del.title = "Supprimer";
  del.addEventListener("click", () => removeSite(site));

  const actions = el("div", "actions");
  actions.append(edit, del);

  row.append(info, history, meta, actions);
  return row;
}

// Formulaire de modification, affiché à la place de la ligne du site
function editRow(site) {
  const form = el("form", "site-edit");

  const nameField = el("label", "field");
  const nameInput = el("input");
  nameInput.value = site.name;
  nameInput.required = true;
  nameInput.maxLength = 100;
  nameField.append(el("span", "field-label", "Nom"), nameInput);

  const urlField = el("label", "field field-url");
  const urlInput = el("input");
  urlInput.type = "url";
  urlInput.value = site.url;
  urlInput.required = true;
  urlField.append(el("span", "field-label", "URL"), urlInput);

  const save = el("button", "btn-save", "Enregistrer");
  save.type = "submit";
  const cancel = el("button", "btn-cancel", "Annuler");
  cancel.type = "button";
  cancel.addEventListener("click", cancelEdit);

  const buttons = el("div", "edit-buttons");
  buttons.append(cancel, save);

  const hint = el("p", "edit-hint", "Changer l'URL remet le site en attente jusqu'au prochain passage du checker.");
  const msg = el("p", "edit-msg");

  form.append(nameField, urlField, buttons, hint, msg);

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    save.disabled = true;
    msg.textContent = "";
    try {
      await callApi(`/sites/${site.id}`, {
        method: "PUT",
        body: JSON.stringify({ name: nameInput.value.trim(), url: urlInput.value.trim() }),
      });
      editingId = null;
      loadSites();
    } catch (err) {
      msg.textContent = err.message;
      save.disabled = false;
    }
  });

  // Échap pour annuler
  form.addEventListener("keydown", (event) => {
    if (event.key === "Escape") cancelEdit();
  });

  // Mettre le curseur dans le champ nom dès l'ouverture
  requestAnimationFrame(() => nameInput.focus());
  return form;
}

function startEdit(id) {
  editingId = id;
  if (lastData) render(...lastData);
}

function cancelEdit() {
  editingId = null;
  if (lastData) render(...lastData);
}

function render(sites, histories, uptimes) {
  const container = document.getElementById("sites");
  container.replaceChildren();

  const up = sites.filter((s) => s.is_up === true).length;
  const down = sites.filter((s) => s.is_up === false).length;
  setText("stat-total", sites.length);
  setText("stat-up", up);
  setText("stat-down", down);

  if (sites.length === 0) {
    container.append(el("p", "empty", "Aucune cible. Ajoute un site ci-dessous."));
    setBanner("", "AUCUNE CIBLE SURVEILLÉE");
    return;
  }

  if (down === 0) setBanner("ok", "TOUS LES SYSTÈMES SONT OPÉRATIONNELS");
  else setBanner("ko", `ALERTE : ${down} SYSTÈME(S) EN PANNE`);

  sites.forEach((site, i) => container.append(siteRow(site, histories[i], uptimes[i])));
}

async function loadSites() {
  try {
    const sites = await callApi("/sites");
    // Pour chaque site, en parallèle : les 30 derniers checks et les stats de la période
    const [histories, uptimes] = await Promise.all([
      Promise.all(sites.map((s) => callApi(`/sites/${s.id}/checks?limit=30`).catch(() => []))),
      Promise.all(sites.map((s) => callApi(`/sites/${s.id}/uptime?days=${periodDays}`).catch(() => null))),
    ]);
    lastData = [sites, histories, uptimes];
    render(sites, histories, uptimes);
    setText("stat-sync", new Date().toLocaleTimeString("fr-FR"));
  } catch (err) {
    setBanner("ko", `LIAISON API PERDUE — ${err.message}`);
  }
}

// Le rafraîchissement automatique est suspendu pendant une modification,
// sinon il effacerait ce qui est en train d'être tapé
function autoRefresh() {
  if (editingId === null) loadSites();
}

async function removeSite(site) {
  if (!confirm(`Supprimer « ${site.name} » ?`)) return;
  try {
    await callApi(`/sites/${site.id}`, { method: "DELETE" });
    loadSites();
  } catch (err) {
    alert(err.message);
  }
}

// Sélecteur de période : 24 h / 7 j / 30 j
document.getElementById("period").addEventListener("click", (event) => {
  const button = event.target.closest("button[data-days]");
  if (!button) return;
  periodDays = Number(button.dataset.days);
  document.querySelectorAll("#period button").forEach((b) => b.classList.toggle("active", b === button));
  loadSites();
});

document.getElementById("add-form").addEventListener("submit", async (event) => {
  event.preventDefault(); // empêche le rechargement de la page
  const msg = document.getElementById("form-msg");
  const name = document.getElementById("name").value.trim();
  const url = document.getElementById("url").value.trim();

  try {
    await callApi("/sites", { method: "POST", body: JSON.stringify({ name, url }) });
    event.target.reset();
    msg.className = "form-msg ok";
    msg.textContent = "Cible ajoutée. Elle sera testée au prochain passage du checker.";
    loadSites();
  } catch (err) {
    msg.className = "form-msg ko";
    msg.textContent = err.message;
  }
});

// Horloge en haut à droite
setInterval(() => setText("clock", new Date().toLocaleTimeString("fr-FR")), 1000);

loadSites();
setInterval(autoRefresh, REFRESH_MS);
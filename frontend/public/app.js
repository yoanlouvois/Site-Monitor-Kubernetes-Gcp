const API = "/api";
const REFRESH_MS = 30000;

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

function siteRow(site, checks) {
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

  // Uptime sur 7 jours et dernier temps de réponse
  const last = checks[0];
  const meta = el("div", "meta");
  meta.append(
    el("span", "uptime", site.uptime_7d === null ? "—" : `${site.uptime_7d} %`),
    el("span", "latency", last && last.response_time_ms !== null ? `${last.response_time_ms} ms` : "—"),
  );

  const del = el("button", "delete", "✕");
  del.title = "Supprimer";
  del.addEventListener("click", () => removeSite(site));

  row.append(info, history, meta, del);
  return row;
}

function render(sites, histories) {
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

  sites.forEach((site, i) => container.append(siteRow(site, histories[i])));
}

async function loadSites() {
  try {
    const sites = await callApi("/sites");
    // Les 30 derniers checks de chaque site, en parallèle
    const histories = await Promise.all(
      sites.map((s) => callApi(`/sites/${s.id}/checks?limit=30`).catch(() => [])),
    );
    render(sites, histories);
    setText("stat-sync", new Date().toLocaleTimeString("fr-FR"));
  } catch (err) {
    setBanner("ko", `LIAISON API PERDUE — ${err.message}`);
  }
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

document.getElementById("add-form").addEventListener("submit", async (event) => {
  event.preventDefault();  // empêche le rechargement de la page
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
setInterval(loadSites, REFRESH_MS);
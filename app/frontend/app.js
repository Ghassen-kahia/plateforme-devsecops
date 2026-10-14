// Frontend minimal : appelle l'API via le même domaine (/api), relayée par Nginx.
// Aucune donnée n'est injectée via innerHTML : textContent empêche les failles XSS.
"use strict";

const list = document.getElementById("tasks");
const form = document.getElementById("task-form");
const input = document.getElementById("title");
const errorBox = document.getElementById("error");

function showError(message) {
  errorBox.textContent = message;
  errorBox.hidden = !message;
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new Error(typeof body.detail === "string" ? body.detail : `Erreur HTTP ${response.status}`);
  }
  return response.status === 204 ? null : response.json();
}

function render(tasks) {
  list.replaceChildren(
    ...tasks.map((task) => {
      const li = document.createElement("li");
      li.classList.toggle("done", task.done);

      const checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      checkbox.checked = task.done;
      checkbox.setAttribute("aria-label", "Terminée");
      checkbox.addEventListener("change", () => run(() =>
        api(`/api/tasks/${task.id}`, { method: "PATCH", body: JSON.stringify({ done: checkbox.checked }) })));

      const title = document.createElement("span");
      title.textContent = task.title;

      const remove = document.createElement("button");
      remove.textContent = "Supprimer";
      remove.addEventListener("click", () => run(() => api(`/api/tasks/${task.id}`, { method: "DELETE" })));

      li.append(checkbox, title, remove);
      return li;
    }),
  );
}

async function refresh() {
  render(await api("/api/tasks"));
}

async function run(action) {
  try {
    await action();
    showError("");
    await refresh();
  } catch (err) {
    showError(err.message);
  }
}

async function status() {
  const db = document.getElementById("db");
  try {
    const version = await api("/api/version");
    document.getElementById("version").textContent = version.version;
    await api("/ready");
    db.textContent = "disponible";
    db.className = "badge up";
  } catch {
    db.textContent = "indisponible";
    db.className = "badge down";
  }
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  const title = input.value.trim();
  if (!title) return;
  run(async () => {
    await api("/api/tasks", { method: "POST", body: JSON.stringify({ title }) });
    input.value = "";
  });
});

status();
run(async () => {});

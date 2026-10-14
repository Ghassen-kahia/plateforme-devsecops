"""Tests unitaires : logique HTTP de l'API, sans base de données.

TestClient est utilisé SANS bloc `with` : le lifespan (connexion PostgreSQL) n'est donc pas
exécuté, et on injecte un dépôt en mémoire à la place.
"""

import pytest
from fastapi.testclient import TestClient

from api.main import app
from api.repository import InMemoryTaskRepository


@pytest.fixture
def repo() -> InMemoryTaskRepository:
    return InMemoryTaskRepository()


@pytest.fixture
def client(repo: InMemoryTaskRepository) -> TestClient:
    app.state.repo = repo
    return TestClient(app)


def test_health_ne_depend_pas_de_la_base(client, repo):
    repo.available = False
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_ready_ok_quand_base_disponible(client):
    r = client.get("/ready")
    assert r.status_code == 200
    assert r.json()["database"] == "up"


def test_ready_503_quand_base_indisponible(client, repo):
    repo.available = False
    r = client.get("/ready")
    assert r.status_code == 503
    assert r.json()["database"] == "down"


def test_creation_et_lecture_tache(client):
    r = client.post("/api/tasks", json={"title": "  Écrire le Dockerfile  "})
    assert r.status_code == 201
    task = r.json()
    assert task["title"] == "Écrire le Dockerfile"  # espaces supprimés
    assert task["done"] is False

    r = client.get(f"/api/tasks/{task['id']}")
    assert r.status_code == 200
    assert r.json()["id"] == task["id"]


def test_liste_taches(client):
    client.post("/api/tasks", json={"title": "a"})
    client.post("/api/tasks", json={"title": "b"})
    r = client.get("/api/tasks")
    assert [t["title"] for t in r.json()] == ["a", "b"]


@pytest.mark.parametrize("payload", [{"title": ""}, {"title": "x" * 201}, {}, {"title": None}])
def test_validation_titre_invalide(client, payload):
    assert client.post("/api/tasks", json=payload).status_code == 422


def test_marquer_tache_terminee(client):
    task_id = client.post("/api/tasks", json={"title": "t"}).json()["id"]
    r = client.patch(f"/api/tasks/{task_id}", json={"done": True})
    assert r.status_code == 200
    assert r.json()["done"] is True


def test_suppression_puis_404(client):
    task_id = client.post("/api/tasks", json={"title": "t"}).json()["id"]
    assert client.delete(f"/api/tasks/{task_id}").status_code == 204
    assert client.get(f"/api/tasks/{task_id}").status_code == 404
    assert client.delete(f"/api/tasks/{task_id}").status_code == 404
    assert client.patch(f"/api/tasks/{task_id}", json={"done": True}).status_code == 404


def test_identifiant_non_entier_rejete(client):
    assert client.get("/api/tasks/abc").status_code == 422


def test_version(client, monkeypatch):
    r = client.get("/api/version")
    assert r.status_code == 200
    assert set(r.json()) == {"name", "version"}


def test_metrics_format_prometheus_et_cardinalite(client):
    client.post("/api/tasks", json={"title": "t"})
    client.get("/api/tasks/1")
    client.get("/api/tasks/999")
    r = client.get("/metrics")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/plain")
    body = r.text
    assert "http_requests_total" in body
    assert "http_request_duration_seconds_bucket" in body
    assert "app_tasks_created_total" in body
    # Le modèle de route est utilisé, pas l'identifiant réel
    assert 'route="/api/tasks/{task_id}"' in body
    assert 'route="/api/tasks/999"' not in body


def test_secret_absent_de_la_representation():
    from api.config import Settings

    s = Settings(db_password="ne-pas-afficher")  # valeur factice de test
    assert "ne-pas-afficher" not in repr(s)
    assert "ne-pas-afficher" not in str(s.model_dump())


def test_erreur_base_pendant_requete_renvoie_503_sans_detail(client, repo, monkeypatch):
    import psycopg

    def panne(*_args):
        raise psycopg.OperationalError("connection refused host=db password=secret-factice")

    monkeypatch.setattr(repo, "list", panne)
    r = client.get("/api/tasks")
    assert r.status_code == 503
    assert r.json() == {"detail": "Base de données indisponible"}
    assert "secret-factice" not in r.text  # aucun détail interne renvoyé au client

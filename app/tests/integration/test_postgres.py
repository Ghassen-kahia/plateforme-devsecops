"""Tests d'intégration : SQL réel contre PostgreSQL.

Exécutés quand RUN_INTEGRATION=1 et les variables DB_* pointent vers une base de test
(Docker Compose en local, conteneur de service dans GitHub Actions). Sinon ils sont
explicitement signalés comme « skipped » — jamais comptés comme réussis.
"""

import os

import pytest
from fastapi.testclient import TestClient

pytestmark = pytest.mark.integration

if os.getenv("RUN_INTEGRATION") != "1":
    pytest.skip(
        "RUN_INTEGRATION=1 non défini : base PostgreSQL non fournie",
        allow_module_level=True,
    )


@pytest.fixture(scope="module")
def client():
    from api.main import app

    # Bloc `with` : le lifespan s'exécute et ouvre une vraie connexion PostgreSQL
    with TestClient(app) as c:
        yield c


def test_ready_avec_vraie_base(client):
    r = client.get("/ready")
    assert r.status_code == 200, r.text
    assert r.json()["database"] == "up"


def test_cycle_de_vie_complet(client):
    created = client.post("/api/tasks", json={"title": "test d'intégration"}).json()
    task_id = created["id"]
    assert created["done"] is False
    assert "created_at" in created

    assert client.patch(f"/api/tasks/{task_id}", json={"done": True}).json()["done"] is True
    assert any(t["id"] == task_id for t in client.get("/api/tasks").json())
    assert client.delete(f"/api/tasks/{task_id}").status_code == 204
    assert client.get(f"/api/tasks/{task_id}").status_code == 404


def test_injection_sql_stockee_comme_texte(client):
    malveillant = "x'); DROP TABLE tasks; --"
    task = client.post("/api/tasks", json={"title": malveillant}).json()
    assert client.get(f"/api/tasks/{task['id']}").json()["title"] == malveillant
    assert client.get("/api/tasks").status_code == 200  # la table existe toujours
    client.delete(f"/api/tasks/{task['id']}")


def test_metrique_base_disponible(client):
    client.get("/ready")
    assert "app_database_up 1.0" in client.get("/metrics").text

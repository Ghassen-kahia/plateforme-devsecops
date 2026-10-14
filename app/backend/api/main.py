"""API FastAPI de démonstration : gestion de tâches stockées dans PostgreSQL."""

import logging
from collections.abc import Iterator
from contextlib import asynccontextmanager
from typing import Annotated

import psycopg
from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.responses import JSONResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from psycopg_pool import ConnectionPool
from pydantic import BaseModel, Field

from api.config import get_settings
from api.metrics import APP_INFO, DB_UP, TASKS_CREATED, MetricsMiddleware
from api.repository import PostgresTaskRepository, TaskRepository

logger = logging.getLogger("api")


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    logging.basicConfig(
        level=settings.log_level.upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    APP_INFO.labels(settings.app_version).set(1)

    # open(wait=False) : l'API démarre même si PostgreSQL n'est pas encore prêt.
    # /health répond donc immédiatement, et /ready reflète l'état réel de la base.
    pool = ConnectionPool(
        settings.conninfo(),
        min_size=settings.db_pool_min,
        max_size=settings.db_pool_max,
        timeout=settings.db_connect_timeout,
        open=False,
    )
    pool.open(wait=False)
    repo = PostgresTaskRepository(pool)
    app.state.repo = repo
    try:
        repo.ensure_schema()
        logger.info("schéma de base de données vérifié")
    except Exception as exc:  # noqa: BLE001 — la base peut démarrer après l'API
        logger.warning("schéma non initialisé au démarrage (%s) ; nouvel essai sur /ready", exc)
    logger.info("démarrage de %s version %s", settings.app_name, settings.app_version)
    yield
    pool.close()


app = FastAPI(
    title="Plateforme DevSecOps — API",
    version=get_settings().app_version,
    lifespan=lifespan,
)
app.add_middleware(MetricsMiddleware)


def get_repo(request: Request) -> Iterator[TaskRepository]:
    yield request.app.state.repo


# Injection de dépendance : les routes reçoivent un dépôt sans connaître son implémentation
# (PostgreSQL en production, mémoire dans les tests unitaires)
Repo = Annotated[TaskRepository, Depends(get_repo)]


@app.exception_handler(psycopg.OperationalError)
@app.exception_handler(TimeoutError)
async def database_unavailable(request: Request, exc: Exception) -> JSONResponse:
    # Pas de détail technique renvoyé au client (fuite d'informations) ; détail dans les logs.
    logger.error("base de données indisponible : %s", exc)
    DB_UP.set(0)
    return JSONResponse(status_code=503, content={"detail": "Base de données indisponible"})


# --- Sondes et observabilité --------------------------------------------------


@app.get("/health", tags=["observabilité"])
def health() -> dict:
    """Liveness : le processus répond. Ne dépend volontairement PAS de la base."""
    return {"status": "ok"}


@app.get("/ready", tags=["observabilité"])
def ready(repo: Repo) -> JSONResponse:
    """Readiness : l'instance peut servir du trafic (base joignable et schéma présent)."""
    try:
        if hasattr(repo, "ensure_schema"):
            repo.ensure_schema()
        repo.ping()
    except Exception as exc:  # noqa: BLE001
        logger.warning("readiness en échec : %s", exc)
        DB_UP.set(0)
        return JSONResponse(status_code=503, content={"status": "unavailable", "database": "down"})
    DB_UP.set(1)
    return JSONResponse(content={"status": "ready", "database": "up"})


@app.get("/metrics", tags=["observabilité"], include_in_schema=False)
def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/api/version", tags=["observabilité"])
def version() -> dict:
    s = get_settings()
    return {"name": s.app_name, "version": s.app_version}


# --- API métier ---------------------------------------------------------------


class TaskIn(BaseModel):
    title: str = Field(min_length=1, max_length=200)


class TaskPatch(BaseModel):
    done: bool


@app.get("/api/tasks", tags=["tâches"])
def list_tasks(repo: Repo) -> list[dict]:
    return repo.list()


@app.post("/api/tasks", status_code=status.HTTP_201_CREATED, tags=["tâches"])
def create_task(payload: TaskIn, repo: Repo) -> dict:
    task = repo.create(payload.title.strip())
    TASKS_CREATED.inc()
    return task


@app.get("/api/tasks/{task_id}", tags=["tâches"])
def get_task(task_id: int, repo: Repo) -> dict:
    task = repo.get(task_id)
    if task is None:
        raise HTTPException(status_code=404, detail="Tâche introuvable")
    return task


@app.patch("/api/tasks/{task_id}", tags=["tâches"])
def update_task(task_id: int, payload: TaskPatch, repo: Repo) -> dict:
    task = repo.set_done(task_id, payload.done)
    if task is None:
        raise HTTPException(status_code=404, detail="Tâche introuvable")
    return task


@app.delete("/api/tasks/{task_id}", status_code=status.HTTP_204_NO_CONTENT, tags=["tâches"])
def delete_task(task_id: int, repo: Repo) -> Response:
    if not repo.delete(task_id):
        raise HTTPException(status_code=404, detail="Tâche introuvable")
    return Response(status_code=status.HTTP_204_NO_CONTENT)

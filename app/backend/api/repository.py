"""Accès aux données des tâches.

Le pattern « repository » isole SQL du reste de l'API : les routes dépendent d'une interface
(TaskRepository), ce qui permet de tester la logique HTTP avec une implémentation en mémoire
(tests unitaires) et le SQL avec un vrai PostgreSQL (tests d'intégration).
"""

from datetime import UTC, datetime
from typing import Protocol

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS tasks (
    id          SERIAL PRIMARY KEY,
    title       VARCHAR(200) NOT NULL,
    done        BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);
"""


class TaskRepository(Protocol):
    def list(self) -> list[dict]: ...
    def get(self, task_id: int) -> dict | None: ...
    def create(self, title: str) -> dict: ...
    def set_done(self, task_id: int, done: bool) -> dict | None: ...
    def delete(self, task_id: int) -> bool: ...
    def ping(self) -> None: ...


class PostgresTaskRepository:
    """Implémentation PostgreSQL.

    Toutes les requêtes sont paramétrées (%s) : les valeurs ne sont jamais concaténées au SQL,
    ce qui empêche l'injection SQL.
    """

    def __init__(self, pool: ConnectionPool) -> None:
        self._pool = pool
        self._schema_ready = False

    def ensure_schema(self) -> None:
        """Crée la table si besoin (idempotent). Exécuté une seule fois par processus.

        Suffisant pour une démo ; un vrai projet utiliserait un outil de migration (Alembic).
        """
        if self._schema_ready:
            return
        with self._pool.connection() as conn:
            conn.execute(SCHEMA_SQL)
        self._schema_ready = True

    def ping(self) -> None:
        with self._pool.connection() as conn:
            conn.execute("SELECT 1")

    def list(self) -> list[dict]:
        with self._pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
            cur.execute("SELECT id, title, done, created_at FROM tasks ORDER BY id")
            return cur.fetchall()

    def get(self, task_id: int) -> dict | None:
        with self._pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
            cur.execute("SELECT id, title, done, created_at FROM tasks WHERE id = %s", (task_id,))
            return cur.fetchone()

    def create(self, title: str) -> dict:
        with self._pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                "INSERT INTO tasks (title) VALUES (%s) RETURNING id, title, done, created_at",
                (title,),
            )
            return cur.fetchone()

    def set_done(self, task_id: int, done: bool) -> dict | None:
        with self._pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                "UPDATE tasks SET done = %s WHERE id = %s RETURNING id, title, done, created_at",
                (done, task_id),
            )
            return cur.fetchone()

    def delete(self, task_id: int) -> bool:
        with self._pool.connection() as conn:
            cur = conn.execute("DELETE FROM tasks WHERE id = %s", (task_id,))
            return cur.rowcount == 1


class InMemoryTaskRepository:
    """Implémentation en mémoire, utilisée par les tests unitaires."""

    def __init__(self) -> None:
        self._tasks: dict[int, dict] = {}
        self._next_id = 1
        self.available = True

    def ping(self) -> None:
        if not self.available:
            raise ConnectionError("base indisponible (simulée)")

    def list(self) -> list[dict]:
        self.ping()
        return [dict(t) for t in self._tasks.values()]

    def get(self, task_id: int) -> dict | None:
        self.ping()
        return self._tasks.get(task_id)

    def create(self, title: str) -> dict:
        self.ping()
        task = {"id": self._next_id, "title": title, "done": False, "created_at": datetime.now(UTC)}
        self._tasks[self._next_id] = task
        self._next_id += 1
        return task

    def set_done(self, task_id: int, done: bool) -> dict | None:
        self.ping()
        task = self._tasks.get(task_id)
        if task:
            task["done"] = done
        return task

    def delete(self, task_id: int) -> bool:
        self.ping()
        return self._tasks.pop(task_id, None) is not None

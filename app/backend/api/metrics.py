"""Métriques Prometheus exposées sur /metrics.

On suit la méthode RED (Rate, Errors, Duration) :
- http_requests_total{method, route, status}   → débit et taux d'erreurs
- http_request_duration_seconds{method, route} → latence (histogramme → percentiles)

Le label `route` utilise le *modèle* de route (/api/tasks/{task_id}) et non le chemin réel
(/api/tasks/42) : sinon chaque identifiant créerait une nouvelle série temporelle
(explosion de cardinalité, mémoire de Prometheus saturée).
"""

import time

from prometheus_client import Counter, Gauge, Histogram
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request

HTTP_REQUESTS = Counter(
    "http_requests_total", "Nombre de requêtes HTTP traitées", ["method", "route", "status"]
)
HTTP_LATENCY = Histogram(
    "http_request_duration_seconds",
    "Durée de traitement des requêtes HTTP",
    ["method", "route"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
)
APP_INFO = Gauge("app_info", "Informations sur la version déployée", ["version"])
DB_UP = Gauge("app_database_up", "1 si la dernière vérification de la base a réussi, sinon 0")
TASKS_CREATED = Counter("app_tasks_created_total", "Nombre de tâches créées")


class MetricsMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        start = time.perf_counter()
        status = 500
        try:
            response = await call_next(request)
            status = response.status_code
            return response
        finally:
            route = request.scope.get("route")
            # Routes inconnues regroupées sous un seul label (404 de scanners, etc.)
            route_label = getattr(route, "path", "<non_routé>")
            HTTP_REQUESTS.labels(request.method, route_label, str(status)).inc()
            HTTP_LATENCY.labels(request.method, route_label).observe(time.perf_counter() - start)

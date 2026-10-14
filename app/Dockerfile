# Image de l'API — VERSION INITIALE (Phase 1), volontairement simple.
# Elle sera mesurée avec Trivy puis durcie en Phase 2 (multi-stage, image slim, non-root).
FROM python:3.12.15

WORKDIR /app
COPY backend/ .
RUN pip install -r requirements.txt

EXPOSE 8000
CMD ["uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000"]

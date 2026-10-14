#!/usr/bin/env bash
# =============================================================================
# build-rapport.sh — Génère le rapport final (PDF de dépôt + DOCX modifiable)
#
#   bash scripts/build-rapport.sh
#
# Logos de la page de garde (facultatifs) : déposer
#   docs/rapport/images/logo-rif.png  et  docs/rapport/images/logo-esprit.png
# puis relancer le script. Sans eux, un cadre indique leur emplacement.
# Outil : image Docker pandoc/latex (aucune installation de TeX Live nécessaire).
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="docs/rapport/pfe"
IMAGE="pandoc/latex:3.11.0"
SORTIE="docs/rapport"

pandoc_docker() {
  docker run --rm -u "$(id -u):$(id -g)" -v "$ROOT:/data" -w "/data/$DIR" "$IMAGE" "$@"
}

echo "→ PDF (version de dépôt)"
pandoc_docker rapport.md -H entete.tex --top-level-division=chapter \
  --resource-path=.:../images:../../architecture --pdf-engine=xelatex \
  -o "../rapport-final.pdf"

echo "→ DOCX (version modifiable)"
# Word ne comprend pas la page de garde LaTeX : on la remplace par une version Markdown.
python3 - "$ROOT/$DIR" <<'PY'
import pathlib, re, sys
d = pathlib.Path(sys.argv[1])
src = (d / "rapport.md").read_text()
logos = " ".join(f"![](../images/{n}){{height=2.5cm}}" for n in ("logo-rif.png", "logo-esprit.png")
                 if (d.parent / "images" / n).exists())
garde = f"""{logos}

**École Supérieure Privée d'Ingénierie et de Technologies — ESPRIT**

**RAPPORT DE PROJET**

# Plateforme DevSecOps de déploiement continu sur Kubernetes {{.unnumbered}}

*Intégration continue sécurisée, GitOps et supervision*

Réalisé par **Ghassen KAHIA**

Au sein du **RIF — Rassemblement des Ingénieurs Francophones**

Encadré par **M. Tawfik KESKES**

Année universitaire 2025–2026

# Remerciements {{.unnumbered}}

"""
remerciements = (d / "garde.tex").read_text()
r = remerciements.split("\\vspace{1.2cm}", 1)[1].split("\\vfill", 1)[0]
r = re.sub(r"\\textit\{([^}]*)\}", r"*\1*", r).replace("---", "—").strip()
src = re.sub(r"```\{=latex\}\n\\input\{garde.tex\}\n```", garde + r + "\n\n*Ghassen KAHIA*\n", src)
src = re.sub(r"```\{=latex\}.*?```\n", "", src, flags=re.S)
(d / "rapport-docx.md").write_text(src)
PY
pandoc_docker rapport-docx.md --top-level-division=chapter --toc --toc-depth=2 \
  --resource-path=.:../images:../../architecture -o "../rapport-final.docx"
rm -f "$ROOT/$DIR/rapport-docx.md"

echo "✔ $SORTIE/rapport-final.pdf et $SORTIE/rapport-final.docx"

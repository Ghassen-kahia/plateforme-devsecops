{{/* Nom complet de la release (préfixe de toutes les ressources) */}}
{{- define "plateforme.fullname" -}}
{{- .Release.Name | trunc 50 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels communs recommandés par Kubernetes */}}
{{- define "plateforme.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/part-of: plateforme
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ include "plateforme.tag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Sélecteur d'un composant : labels stables, jamais modifiés après création */}}
{{- define "plateforme.selector" -}}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "plateforme.tag" -}}
{{- .Values.image.tag | default .Chart.AppVersion -}}
{{- end -}}

{{/* Référence d'image : <registre>/<nom>:<tag> */}}
{{- define "plateforme.image" -}}
{{- $registry := .root.Values.image.registry -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry .name (include "plateforme.tag" .root) -}}
{{- else -}}
{{- printf "%s:%s" .name (include "plateforme.tag" .root) -}}
{{- end -}}
{{- end -}}

{{- define "plateforme.apiName" -}}{{ include "plateforme.fullname" . }}-api{{- end -}}
{{- define "plateforme.frontendName" -}}{{ include "plateforme.fullname" . }}-frontend{{- end -}}
{{- define "plateforme.dbName" -}}{{ include "plateforme.fullname" . }}-db{{- end -}}

{{/*
Labels du modèle de pod PostgreSQL : SANS app.kubernetes.io/version.
Ce label suit la version de l'application ; dans le modèle de pod du StatefulSet, il ferait
redémarrer la base à chaque release de l'API (constaté en test : 502 pendant ~5 s).
*/}}
{{- define "plateforme.dbPodLabels" -}}
app.kubernetes.io/part-of: plateforme
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{ include "plateforme.selector" (dict "root" . "component" "database") }}
{{- end -}}

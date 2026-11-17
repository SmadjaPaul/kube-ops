{{/*
Contrat platform.smadja.dev/v1 Application, profil web.
Aucune valeur ne vient de .Release (determinisme) : tout part de app.yaml.
*/}}

{{/* Rejets explicites des capacites non disponibles. Un seul message par execution (fail s'arrete au premier). */}}
{{- define "platform-app.validate" -}}
{{- if or (eq .Values.spec.profile "web-postgres") .Values.spec.database -}}
{{- fail "capability database unavailable: pg-shared-homelab not reconciled (AppProject infrastructure lacks databases). Profil web-postgres refuse : utiliser profile: web tant que la base n'est pas reconciliee." -}}
{{- end -}}
{{- if .Values.spec.storage -}}
{{- fail "capability storage unavailable: aucun profil de stockage valide pour apps-generated. Retirer spec.storage." -}}
{{- end -}}
{{- if eq .Values.spec.exposure.mode "public" -}}
{{- fail "capability exposure.mode=public unavailable: seule l'exposition private (Gateway internal) est supportee dans le pilote." -}}
{{- end -}}
{{- if eq .Values.spec.exposure.auth "authentik" -}}
{{- fail "capability exposure.auth=authentik unavailable: aucun mecanisme d'authentification par route dans le depot, sans toucher au namespace auth. Utiliser auth: none." -}}
{{- end -}}
{{- end -}}

{{/* Garde-fous 0.2.0 : secrets (prefixe NAME_), config (aucune cle privee), egress (FQDN publics). */}}
{{- define "platform-app.validateExtras" -}}
{{- $prefix := printf "%s_" (upper (replace "-" "_" .Values.metadata.name)) -}}
{{- range .Values.spec.secrets -}}
{{- if not (hasPrefix $prefix .) -}}
{{- fail (printf "secret %s refuse : la cle doit commencer par %s (NAME en majuscules). Aucun store ni prefixe arbitraire." . $prefix) -}}
{{- end -}}
{{- end -}}
{{- range $k, $v := .Values.spec.config -}}
{{- if regexMatch "-----BEGIN [A-Z ]*PRIVATE KEY-----" $v -}}
{{- fail (printf "config %s contient une cle privee : la declarer dans spec.secrets, jamais dans spec.config." $k) -}}
{{- end -}}
{{- end -}}
{{- if .Values.spec.egress -}}
{{- range .Values.spec.egress.https -}}
{{- if regexMatch "\\.(local|svc)$" . -}}
{{- fail (printf "egress %s refuse : domaine interne du cluster" .) -}}
{{- end -}}
{{- if not (regexMatch "\\.[a-z]{2,}$" .) -}}
{{- fail (printf "egress %s refuse : FQDN requis (pas d'adresse IP)" .) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "platform-app.labels" -}}
app.kubernetes.io/name: {{ .Values.metadata.name }}
app.kubernetes.io/managed-by: platform-app
platform.smadja.dev/contract: v1
platform.smadja.dev/renderer: platform-app-{{ .Chart.Version }}
{{- end -}}

{{- define "platform-app.annotations" -}}
platform.smadja.dev/owner: {{ .Values.metadata.owner | quote }}
{{- if .Values.metadata.description }}
platform.smadja.dev/description: {{ .Values.metadata.description | quote }}
{{- end }}
{{- end -}}

{{/* Table centralisee requests/limits. Plafond pilote : 500m CPU / 512Mi RAM. */}}
{{- define "platform-app.resources" -}}
{{- $table := dict
      "small" (dict "cpuRequest" "50m" "cpuLimit" "250m" "memoryRequest" "128Mi" "memoryLimit" "256Mi")
      "medium" (dict "cpuRequest" "200m" "cpuLimit" "500m" "memoryRequest" "256Mi" "memoryLimit" "512Mi") -}}
{{- $s := index $table .Values.spec.runtime.size -}}
resources:
  requests:
    cpu: {{ $s.cpuRequest | quote }}
    memory: {{ $s.memoryRequest | quote }}
  limits:
    cpu: {{ $s.cpuLimit | quote }}
    memory: {{ $s.memoryLimit | quote }}
{{- end -}}

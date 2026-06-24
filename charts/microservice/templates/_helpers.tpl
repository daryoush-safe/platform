{{- define "microservice.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "microservice.selectorLabels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "microservice.labels" -}}
{{ include "microservice.selectorLabels" . }}
app.kubernetes.io/part-of: fastapi-ms
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "microservice.envFrom" -}}
{{- if .Values.env }}
- configMapRef:
    name: {{ include "microservice.fullname" . }}-env
{{- end }}
{{- if .Values.existingSecret }}
- secretRef:
    name: {{ .Values.existingSecret }}
{{- end }}
{{- end -}}

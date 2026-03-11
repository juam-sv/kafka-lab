{{/*
Chart name.
*/}}
{{- define "kafka-lab.name" -}}
kafka-lab
{{- end }}

{{/*
Fully qualified release name (release-chartname), truncated to 63 chars.
*/}}
{{- define "kafka-lab.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "kafka-lab.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "kafka-lab.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "kafka-lab.name" . }}
{{- end }}

{{/*
Selector labels for a specific component.
Usage: include "kafka-lab.selectorLabels" (dict "context" . "component" "producer")
*/}}
{{- define "kafka-lab.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kafka-lab.name" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Build an IRSA role ARN from the AWS account ID and role name.
Usage: include "kafka-lab.irsaArn" (dict "accountId" .Values.aws.accountId "roleName" "producer")
*/}}
{{- define "kafka-lab.irsaArn" -}}
arn:aws:iam::{{ .accountId }}:role/{{ .roleName }}
{{- end }}

{{/*
ConfigMap name.
*/}}
{{- define "kafka-lab.configmapName" -}}
{{ include "kafka-lab.fullname" . }}-config
{{- end }}

{{/*
Oracle secret name.
*/}}
{{- define "kafka-lab.oracleSecretName" -}}
{{ include "kafka-lab.fullname" . }}-oracle
{{- end }}

{{/*
API secret name.
*/}}
{{- define "kafka-lab.apiSecretName" -}}
{{ include "kafka-lab.fullname" . }}-api
{{- end }}

{{/*
Database writer DSN (used by consumer). Falls back to database.dsn if writerDsn is empty.
*/}}
{{- define "kafka-lab.writerDsn" -}}
{{- if .Values.database.writerDsn }}{{ .Values.database.writerDsn }}{{- else }}{{ .Values.database.dsn }}{{- end }}
{{- end }}

{{/*
Database reader DSN (used by API). Falls back to database.dsn if readerDsn is empty.
*/}}
{{- define "kafka-lab.readerDsn" -}}
{{- if .Values.database.readerDsn }}{{ .Values.database.readerDsn }}{{- else }}{{ .Values.database.dsn }}{{- end }}
{{- end }}

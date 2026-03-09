{{/*
Expand the name of the chart.
*/}}
{{- define "fastapi-chassis.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "fastapi-chassis.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "fastapi-chassis.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "fastapi-chassis.labels" -}}
helm.sh/chart: {{ include "fastapi-chassis.chart" . }}
{{ include "fastapi-chassis.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "fastapi-chassis.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fastapi-chassis.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "fastapi-chassis.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "fastapi-chassis.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return the internal application port (what uvicorn listens on).
*/}}
{{- define "fastapi-chassis.containerPort" -}}
{{- .Values.app.port | default 8000 }}
{{- end }}

{{/*
Return true if the SQLite backend is selected
*/}}
{{- define "fastapi-chassis.isSqlite" -}}
{{- eq (.Values.database.backend | default "postgres") "sqlite" }}
{{- end }}

{{/*
Return true if LiteFS is active (sqlite + litefs.enabled)
*/}}
{{- define "fastapi-chassis.isLitefs" -}}
{{- and (eq (.Values.database.backend | default "postgres") "sqlite") .Values.litefs.enabled }}
{{- end }}

{{/*
Return the port exposed by the container — LiteFS proxy port when active,
otherwise the app port directly.
*/}}
{{- define "fastapi-chassis.exposedPort" -}}
{{- if eq (include "fastapi-chassis.isLitefs" .) "true" -}}
{{- .Values.litefs.proxy.port | default 8080 }}
{{- else -}}
{{- include "fastapi-chassis.containerPort" . }}
{{- end -}}
{{- end }}

{{/*
Return the workload kind based on database backend.
SQLite requires a StatefulSet for stable storage identity.
*/}}
{{- define "fastapi-chassis.workloadKind" -}}
{{- if eq (include "fastapi-chassis.isSqlite" .) "true" -}}
StatefulSet
{{- else -}}
Deployment
{{- end -}}
{{- end }}

{{/*
Headless service name for StatefulSet.
*/}}
{{- define "fastapi-chassis.headlessServiceName" -}}
{{- printf "%s-headless" (include "fastapi-chassis.fullname" .) }}
{{- end }}

{{/*
Pod template spec shared between Deployment and StatefulSet.
Takes a dict with keys: root (the top-level context) and isSqlite (bool string).
*/}}
{{- define "fastapi-chassis.podSpec" -}}
{{- $isLitefs := and (eq .isSqlite "true") .root.Values.litefs.enabled -}}
{{- $isLitestream := and (eq .isSqlite "true") .root.Values.litestream.enabled -}}
metadata:
  annotations:
    checksum/config: {{ include (print $.root.Template.BasePath "/configmap.yaml") .root | sha256sum }}
    {{- if .root.Values.secret.create }}
    checksum/secret: {{ include (print $.root.Template.BasePath "/secret.yaml") .root | sha256sum }}
    {{- end }}
    {{- with .root.Values.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  labels:
    {{- include "fastapi-chassis.labels" .root | nindent 4 }}
    {{- with .root.Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  {{- with .root.Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  serviceAccountName: {{ include "fastapi-chassis.serviceAccountName" .root }}
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  {{- if .root.Values.terminationGracePeriodSeconds }}
  terminationGracePeriodSeconds: {{ .root.Values.terminationGracePeriodSeconds }}
  {{- end }}
  {{- if .root.Values.topologySpreadConstraints }}
  topologySpreadConstraints:
    {{- toYaml .root.Values.topologySpreadConstraints | nindent 4 }}
  {{- end }}
  {{- if or $isLitefs $isLitestream }}
  initContainers:
    {{- if $isLitefs }}
    - name: litefs-init
      image: "{{ .root.Values.litefs.image.repository }}:{{ .root.Values.litefs.image.tag }}"
      command: ["cp", "/usr/local/bin/litefs", "/litefs-bin/litefs"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 32Mi
      volumeMounts:
        - name: litefs-bin
          mountPath: /litefs-bin
    {{- end }}
    {{- if $isLitestream }}
    - name: litestream-restore
      image: "{{ .root.Values.litestream.image.repository }}:{{ .root.Values.litestream.image.tag }}"
      args: ["restore", "-if-db-not-exists", "-if-replica-exists", "-o", "/app/data/app.db", "{{ .root.Values.litestream.replica.url }}"]
      {{- if .root.Values.litestream.existingSecret }}
      envFrom:
        - secretRef:
            name: {{ .root.Values.litestream.existingSecret }}
      {{- end }}
      {{- with .root.Values.litestream.env }}
      env:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          memory: 128Mi
      volumeMounts:
        - name: data
          mountPath: /app/data
    {{- end }}
  {{- end }}
  containers:
    - name: {{ .root.Chart.Name }}
      image: "{{ .root.Values.image.repository }}:{{ .root.Values.image.tag | default .root.Chart.AppVersion }}"
      imagePullPolicy: {{ .root.Values.image.pullPolicy }}
      {{- if $isLitefs }}
      command: ["/litefs-bin/litefs", "mount"]
      {{- end }}
      ports:
        - name: http
          containerPort: {{ include "fastapi-chassis.exposedPort" .root }}
          protocol: TCP
        {{- if $isLitefs }}
        - name: litefs
          containerPort: 20202
          protocol: TCP
        {{- end }}
      envFrom:
        - configMapRef:
            name: {{ include "fastapi-chassis.fullname" .root }}
        {{- if .root.Values.secret.create }}
        - secretRef:
            name: {{ include "fastapi-chassis.fullname" .root }}
        {{- end }}
        {{- if .root.Values.existingSecret }}
        - secretRef:
            name: {{ .root.Values.existingSecret }}
        {{- end }}
        {{- with .root.Values.extraEnvFrom }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      livenessProbe:
        httpGet:
          path: {{ .root.Values.app.healthCheckPath | default "/healthcheck" }}
          port: http
        initialDelaySeconds: {{ .root.Values.probes.liveness.initialDelaySeconds | default 15 }}
        periodSeconds: {{ .root.Values.probes.liveness.periodSeconds | default 30 }}
        timeoutSeconds: {{ .root.Values.probes.liveness.timeoutSeconds | default 5 }}
        failureThreshold: {{ .root.Values.probes.liveness.failureThreshold | default 3 }}
        successThreshold: 1
      readinessProbe:
        httpGet:
          path: {{ .root.Values.app.readinessCheckPath | default "/ready" }}
          port: http
        initialDelaySeconds: {{ .root.Values.probes.readiness.initialDelaySeconds | default 5 }}
        periodSeconds: {{ .root.Values.probes.readiness.periodSeconds | default 10 }}
        timeoutSeconds: {{ .root.Values.probes.readiness.timeoutSeconds | default 5 }}
        failureThreshold: {{ .root.Values.probes.readiness.failureThreshold | default 3 }}
        successThreshold: 1
      startupProbe:
        httpGet:
          path: {{ .root.Values.app.healthCheckPath | default "/healthcheck" }}
          port: http
        initialDelaySeconds: {{ .root.Values.probes.startup.initialDelaySeconds | default 5 }}
        periodSeconds: {{ .root.Values.probes.startup.periodSeconds | default 5 }}
        timeoutSeconds: {{ .root.Values.probes.startup.timeoutSeconds | default 3 }}
        failureThreshold: {{ .root.Values.probes.startup.failureThreshold | default 12 }}
        successThreshold: 1
      resources:
        {{- toYaml .root.Values.resources | nindent 8 }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
          {{- if $isLitefs }}
          add:
            - SYS_ADMIN
          {{- end }}
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: var-tmp
          mountPath: /var/tmp
        {{- if eq .isSqlite "true" }}
        - name: data
          mountPath: /app/data
        {{- end }}
        {{- if $isLitefs }}
        - name: litefs-bin
          mountPath: /litefs-bin
          readOnly: true
        - name: litefs-fuse
          mountPath: /litefs
        - name: litefs-config
          mountPath: /etc/litefs.yml
          subPath: litefs.yml
        - name: dev-fuse
          mountPath: /dev/fuse
        {{- end }}
        {{- with .root.Values.extraVolumeMounts }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    {{- if $isLitestream }}
    - name: litestream
      image: "{{ .root.Values.litestream.image.repository }}:{{ .root.Values.litestream.image.tag }}"
      args: ["replicate"]
      {{- if .root.Values.litestream.existingSecret }}
      envFrom:
        - secretRef:
            name: {{ .root.Values.litestream.existingSecret }}
      {{- end }}
      {{- with .root.Values.litestream.env }}
      env:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      resources:
        {{- toYaml (.root.Values.litestream.resources | default (dict "requests" (dict "cpu" "50m" "memory" "64Mi") "limits" (dict "memory" "128Mi"))) | nindent 8 }}
      volumeMounts:
        - name: data
          mountPath: /app/data
        - name: litestream-config
          mountPath: /etc/litestream.yml
          subPath: litestream.yml
    {{- end }}
  volumes:
    - name: tmp
      emptyDir:
        sizeLimit: 64Mi
    - name: var-tmp
      emptyDir:
        sizeLimit: 64Mi
    {{- if $isLitefs }}
    - name: litefs-bin
      emptyDir:
        sizeLimit: 32Mi
    - name: litefs-fuse
      emptyDir: {}
    - name: litefs-config
      configMap:
        name: {{ include "fastapi-chassis.fullname" .root }}-litefs
    - name: dev-fuse
      hostPath:
        path: /dev/fuse
        type: CharDevice
    {{- end }}
    {{- if $isLitestream }}
    - name: litestream-config
      configMap:
        name: {{ include "fastapi-chassis.fullname" .root }}-litestream
    {{- end }}
    {{- with .root.Values.extraVolumes }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with .root.Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .root.Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .root.Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}

{{/*
SaaS overlay: entitlements-svc helpers.
ADR-0074: this chart is the SaaS-overlay counterpart to the core seam knob
(gibson.entitlementsEndpoint in gibson-workloads).
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "entitlements-svc.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "entitlements-svc.fullname" -}}
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
Common labels.
*/}}
{{- define "entitlements-svc.labels" -}}
helm.sh/chart: {{ include "entitlements-svc.name" . }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "entitlements-svc.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: gibson-saas-overlay
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "entitlements-svc.selectorLabels" -}}
app.kubernetes.io/name: {{ include "entitlements-svc.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: entitlements-svc
{{- end }}

{{/*
Wait-for-SPIRE socket init container. Mirrors the pattern used by the core
gibson-workloads chart (gibson.waitForSpireSocket helper). Blocks pod start
until the SPIRE agent socket is reachable.
*/}}
{{- define "entitlements-svc.waitForSpireSocket" -}}
- name: wait-for-spire-socket
  image: "ghcr.io/zeroroot-ai/mirror/busybox:1.36"
  imagePullPolicy: IfNotPresent
  command:
    - sh
    - -c
    - |
      until [ -e /run/spire/sockets/api.sock ]; do
        echo "waiting for SPIRE agent socket..."
        sleep 2
      done
      echo "SPIRE agent socket ready"
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
  volumeMounts:
    - name: spire-agent-socket
      mountPath: /run/spire/sockets
      readOnly: true
{{- end }}

{{/*
ServiceAccount name.

Security-relevant, not cosmetic: the entitlements-svc pod previously had NO
serviceAccountName at all, so it ran under the namespace `default` SA —
shared in ns `gibson` with docs-svc, grafana, jaeger, loki, redis-stack,
stripe-mock and the reachability helm test. A `k8s:sa:` workload selector on
the ClusterSPIFFEID would therefore have rendered `k8s:sa:default` and
matched all of them, which is worse than no selector because it looks like a
control.

The name appears in three places that must not drift: the Deployment's
serviceAccountName, the literal `k8s:sa:` selector on the ClusterSPIFFEID,
and the PROTECTED_SAS list of the overlay's ValidatingAdmissionPolicy.
*/}}
{{- define "entitlements-svc.serviceAccountName" -}}
{{- ((.Values.serviceAccount | default dict).name) | default (include "entitlements-svc.fullname" .) -}}
{{- end }}

{{/*
entitlements-svc.trustDomain: the SPIFFE trust domain of the install
(ADR-0164). It is global.spire.trustDomain, the same key the umbrella chart
reads. The Application loads it from the env's values.yaml. The render fails
when it is empty, so no ID falls back to a domain that this chart holds.
*/}}
{{- define "entitlements-svc.trustDomain" -}}
{{- $td := (((.Values.global).spire).trustDomain) | default "" | toString -}}
{{- if not $td -}}
{{- fail "global.spire.trustDomain is required: the SPIFFE trust domain of this install (ADR-0164). The Application loads it from envs/<env>/values.yaml." -}}
{{- end -}}
{{- $td -}}
{{- end -}}

{{/*
SaaS overlay: billing-webhook helpers.
ADR-0074: this chart is the billing service of the SaaS overlay, behind the
envoy.extraRoutes entries of each env (charts#375).
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "billing-webhook.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.

NOTE: values.yaml pins fullnameOverride to `gibson-billing-webhook` because
each envoy.extraRoutes entry of the billing routes names that exact Service.
Changing it breaks the cross-chart contract.
*/}}
{{- define "billing-webhook.fullname" -}}
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
{{- define "billing-webhook.labels" -}}
helm.sh/chart: {{ include "billing-webhook.name" . }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "billing-webhook.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: gibson-saas-overlay
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "billing-webhook.selectorLabels" -}}
app.kubernetes.io/name: {{ include "billing-webhook.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: billing-webhook
{{- end }}

{{/*
ServiceAccount name. It appears in three places that must not drift: the
Deployment's serviceAccountName, the literal `k8s:sa:` selector on the
ClusterSPIFFEID, and the protected list of the identity admission policy.
*/}}
{{- define "billing-webhook.serviceAccountName" -}}
{{- ((.Values.serviceAccount | default dict).name) | default (include "billing-webhook.fullname" .) -}}
{{- end }}

{{/*
billing-webhook.trustDomain: the SPIFFE trust domain of the install
(ADR-0164). It is global.spire.trustDomain, the same key the umbrella chart
reads. The Application loads it from the env's values.yaml. The render fails
when it is empty, so no ID falls back to a domain that this chart holds.
*/}}
{{- define "billing-webhook.trustDomain" -}}
{{- $td := (((.Values.global).spire).trustDomain) | default "" | toString -}}
{{- if not $td -}}
{{- fail "global.spire.trustDomain is required: the SPIFFE trust domain of this install (ADR-0164). The Application loads it from envs/<env>/values.yaml." -}}
{{- end -}}
{{- $td -}}
{{- end -}}

{{/*
billing-webhook.domain: the public domain of the install, global.domain. The
umbrella chart derives app.<domain> and api.<domain> from the same key
(charts gibson-common gibson.appHost and gibson.apiHost), so billing and the
edge cannot disagree on a host. The Application loads it from the env's
values.yaml.
*/}}
{{- define "billing-webhook.domain" -}}
{{- $d := ((.Values.global).domain) | default "" | toString -}}
{{- if not $d -}}
{{- fail "global.domain is required: billing derives the app host, the API host and the sign-in issuer from it. The Application loads it from envs/<env>/values.yaml." -}}
{{- end -}}
{{- $d -}}
{{- end -}}

{{/* The public origin of the app host. It is also the sign-in issuer
     (charts gibson.oidcIssuer is the same origin). */}}
{{- define "billing-webhook.appOrigin" -}}
{{- printf "https://app.%s" (include "billing-webhook.domain" .) -}}
{{- end -}}

{{/*
Wait-for-SPIRE socket init container. The same shape as the entitlements-svc
overlay. It blocks pod start until the SPIRE agent socket is reachable, so
the binary does not fail its boot dial of the daemon.
*/}}
{{- define "billing-webhook.waitForSpireSocket" -}}
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

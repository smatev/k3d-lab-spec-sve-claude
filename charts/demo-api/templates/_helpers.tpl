{{/*
Chart name, overridable. Truncated at 63 characters because it feeds label values,
and trailing dashes are trimmed because a label value may not end in one.
*/}}
{{- define "demo-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully-qualified app name, the base for every resource name.

The `contains` check keeps `helm install demo-api charts/demo-api` from producing
`demo-api-demo-api`, which is the sort of thing nobody notices until they read a
kubectl output column.
*/}}
{{- define "demo-api.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Chart name and version, as a label value. `+` is legal in a semver build-metadata
suffix but not in a label value, so it is replaced.
*/}}
{{- define "demo-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
The full recommended label set. Goes on every object.
*/}}
{{- define "demo-api.labels" -}}
helm.sh/chart: {{ include "demo-api.chart" . }}
{{ include "demo-api.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ include "demo-api.name" . }}
{{- end -}}

{{/*
Selector labels.

These are IMMUTABLE after install: spec.selector on a Deployment cannot be changed,
so a release whose selector shifts can only be uninstalled and reinstalled. Two rules
follow, and breaking either is the most common way to make a chart un-upgradeable:

  * they must be a strict subset of demo-api.labels, and
  * they must never include anything version-dependent — not app.kubernetes.io/version,
    not helm.sh/chart. Both change on a routine `helm upgrade`.
*/}}
{{- define "demo-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "demo-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Name of the ServiceAccount to use.
*/}}
{{- define "demo-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "demo-api.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Name of the Secret holding the app token — either the one this chart templates or an
externally-managed one. Every consumer goes through here, so swapping to an external
secret is a values change and not a template change.
*/}}
{{- define "demo-api.secretName" -}}
{{- if .Values.secret.existingSecret -}}
{{- .Values.secret.existingSecret -}}
{{- else -}}
{{- include "demo-api.fullname" . -}}
{{- end -}}
{{- end -}}

{{/*
The fully-resolved image reference. Empty image.tag falls back to the chart's
appVersion, which is the whole reason the two versions are separate fields.
*/}}
{{- define "demo-api.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}

{{/*
Value guards.

Included once from the top of deployment.yaml, which every install renders. These
duplicate constraints already encoded in values.schema.json — the schema catches them
earlier and this catches them at all, including when a value arrives from somewhere
the schema did not see. A `fail` aborts the whole render with the message below and
nothing is applied.
*/}}
{{- define "demo-api.validateValues" -}}
{{- if and .Values.route.httpRoute.enabled .Values.route.ingress.enabled -}}
{{- fail "\n\ndemo-api: route.httpRoute.enabled and route.ingress.enabled are both true.\n\nPick one. They are two ways of expressing the same routing, and enabling both\nputs two controllers on the same hostname, where the winner is whichever one\nreconciled last.\n\n  Gateway API (preferred):  --set route.ingress.enabled=false\n  Ingress (compat only):    --set route.httpRoute.enabled=false\n" -}}
{{- end -}}
{{- if and (not .Values.route.httpRoute.enabled) (not .Values.route.ingress.enabled) -}}
{{- /* Not an error: a Service with no external route is a legitimate deployment. */ -}}
{{- end -}}
{{- if and .Values.podDisruptionBudget.enabled .Values.podDisruptionBudget.minAvailable (ne (toString .Values.podDisruptionBudget.maxUnavailable) "") -}}
{{- fail "\n\ndemo-api: podDisruptionBudget.minAvailable and podDisruptionBudget.maxUnavailable are both set.\n\nA PodDisruptionBudget accepts exactly one of them. Clear the one you do not want:\n\n  --set podDisruptionBudget.maxUnavailable=\"\"\n" -}}
{{- end -}}
{{- if and .Values.secret.create .Values.secret.existingSecret -}}
{{- fail "\n\ndemo-api: secret.create is true and secret.existingSecret is set.\n\nThe chart would template a Secret and then mount a different one. Set\nsecret.create=false when pointing at an externally-managed Secret.\n" -}}
{{- end -}}
{{- if and (not .Values.secret.create) (not .Values.secret.existingSecret) -}}
{{- fail "\n\ndemo-api: secret.create is false but secret.existingSecret is empty.\n\nThe app expects a token mounted at secret.mountPath. Either let the chart create\none (secret.create=true, local dev only) or name the Secret to mount\n(secret.existingSecret=<name>).\n" -}}
{{- end -}}
{{- end -}}

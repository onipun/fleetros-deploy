{{/*
Helper: resolve the Slack channel for a given category. Falls back to the
default channel when the per-category override is blank.

Usage: {{ include "fleetros.alerting.channel" (dict "ctx" . "key" "podResources") }}
*/}}
{{- define "fleetros.alerting.channel" -}}
{{- $ctx := .ctx -}}
{{- $key := .key -}}
{{- $perCat := index $ctx.Values.alerting.channels $key -}}
{{- if $perCat -}}
{{- $perCat -}}
{{- else -}}
{{- $ctx.Values.alerting.slack.defaultChannel -}}
{{- end -}}
{{- end -}}

{{/*
Helper: emit a Grafana-managed alert rule that fires when `expr` returns
a non-zero value, threaded with severity + category labels.

Args (dict):
  uid       — stable identifier
  title     — human-readable
  expr      — full PromQL that already includes the comparison (so it
              yields 1/0 series).
  for       — pending duration before firing
  severity  — warning | high | critical
  category  — routing key (matches alerting.channels.<key>)
  summary   — short text for Slack
*/}}
{{- define "fleetros.alerting.rule" -}}
- uid: {{ .uid | quote }}
  title: {{ .title | quote }}
  condition: C
  data:
    - refId: A
      relativeTimeRange: { from: 300, to: 0 }
      datasourceUid: prometheus
      model:
        refId: A
        datasource: { type: prometheus, uid: prometheus }
        expr: {{ .expr | quote }}
        instant: true
        intervalMs: 1000
        maxDataPoints: 43200
    - refId: C
      relativeTimeRange: { from: 0, to: 0 }
      datasourceUid: __expr__
      model:
        refId: C
        type: threshold
        datasource: { type: __expr__, uid: __expr__ }
        expression: A
        conditions:
          - evaluator: { type: gt, params: [0] }
            operator: { type: and }
            query: { params: [C] }
            reducer: { type: last, params: [] }
            type: query
  noDataState: OK
  execErrState: Alerting
  for: {{ .for | quote }}
  labels:
    severity: {{ .severity | quote }}
    category: {{ .category | quote }}
  annotations:
    summary: {{ .summary | quote }}
    runbook_url: "https://github.com/fleetros/runbooks#{{ .category }}"
{{- end -}}

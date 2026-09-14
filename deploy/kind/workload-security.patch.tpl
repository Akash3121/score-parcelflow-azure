{{ range $i, $manifest := .Manifests }}
{{ $workload := dig "metadata" "annotations" "k8s.score.dev/workload-name" "" $manifest }}
{{ if and (eq $manifest.kind "Deployment") (or (eq $workload "parcel-api") (eq $workload "delivery-worker")) }}
- op: set
  path: {{ $i }}.spec.template.spec.automountServiceAccountToken
  value: false
  description: Disable service-account token mounting for the Kind workload
- op: set
  path: {{ $i }}.spec.template.spec.securityContext
  value:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  description: Apply the restricted pod security context
- op: set
  path: {{ $i }}.spec.template.spec.volumes
  value:
    - name: tmp
      emptyDir: {}
  description: Add a writable temporary directory for the read-only workload
{{ range $containerIndex, $_ := $manifest.spec.template.spec.containers }}
- op: set
  path: {{ $i }}.spec.template.spec.containers.{{ $containerIndex }}.imagePullPolicy
  value: IfNotPresent
  description: Use the application image loaded into Kind
- op: set
  path: {{ $i }}.spec.template.spec.containers.{{ $containerIndex }}.securityContext
  value:
    allowPrivilegeEscalation: false
    privileged: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
  description: Apply the restricted container security context
- op: set
  path: {{ $i }}.spec.template.spec.containers.{{ $containerIndex }}.volumeMounts
  value:
    - name: tmp
      mountPath: /tmp
  description: Mount the writable temporary directory
{{ end }}
{{ end }}
{{ end }}

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [string]$ResourceGroupName = 'rg-score-parcelflow-demo',
    [Parameter(Mandatory)][string]$OutputsPath,
    [Parameter(Mandatory)][string]$ClusterName,
    [string]$Namespace = 'parcelflow',
    [ValidatePattern('^[a-z][a-z0-9_]{0,62}$')][string]$DatabaseName = 'parcelflow',
    [string]$PostgresImage = 'postgres:16.4-alpine',
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-Command kubectl
Confirm-KubernetesContext -ClusterName $ClusterName

$outputs = Read-DeploymentOutputs -Path $OutputsPath
$yaml = @"
apiVersion: v1
kind: Namespace
metadata:
  name: $Namespace
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: parcel-api
  namespace: $Namespace
  annotations:
    azure.workload.identity/client-id: "$($outputs.apiIdentityClientId)"
  labels:
    azure.workload.identity/use: "true"
automountServiceAccountToken: false
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: delivery-worker
  namespace: $Namespace
  annotations:
    azure.workload.identity/client-id: "$($outputs.workerIdentityClientId)"
  labels:
    azure.workload.identity/use: "true"
automountServiceAccountToken: false
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: runtime-secret-sync
  namespace: $Namespace
  annotations:
    azure.workload.identity/client-id: "$($outputs.runtimeSecretsIdentityClientId)"
  labels:
    azure.workload.identity/use: "true"
automountServiceAccountToken: false
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: postgres-bootstrap
  namespace: $Namespace
  annotations:
    azure.workload.identity/client-id: "$($outputs.bootstrapIdentityClientId)"
  labels:
    azure.workload.identity/use: "true"
automountServiceAccountToken: false
---
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: parcelflow-runtime
  namespace: $Namespace
spec:
  provider: azure
  secretObjects:
    - secretName: parcelflow-postgres
      type: Opaque
      data:
        - objectName: postgres-application-login
          key: username
        - objectName: postgres-application-password
          key: password
  parameters:
    usePodIdentity: "false"
    clientID: "$($outputs.runtimeSecretsIdentityClientId)"
    keyvaultName: "$($outputs.keyVaultName)"
    tenantId: "$TenantId"
    objects: |
      array:
        - |
          objectName: postgres-application-login
          objectType: secret
        - |
          objectName: postgres-application-password
          objectType: secret
---
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: parcelflow-bootstrap
  namespace: $Namespace
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    clientID: "$($outputs.bootstrapIdentityClientId)"
    keyvaultName: "$($outputs.keyVaultName)"
    tenantId: "$TenantId"
    objects: |
      array:
        - |
          objectName: postgres-administrator-login
          objectType: secret
        - |
          objectName: postgres-administrator-password
          objectType: secret
        - |
          objectName: postgres-application-login
          objectType: secret
        - |
          objectName: postgres-application-password
          objectType: secret
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: runtime-secret-sync
  namespace: $Namespace
  labels:
    app.kubernetes.io/name: runtime-secret-sync
    app.kubernetes.io/part-of: parcelflow
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: runtime-secret-sync
  template:
    metadata:
      labels:
        app.kubernetes.io/name: runtime-secret-sync
        app.kubernetes.io/part-of: parcelflow
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: runtime-secret-sync
      automountServiceAccountToken: true
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: secret-sync
          image: registry.k8s.io/pause:3.10
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 5m
              memory: 8Mi
            limits:
              cpu: 20m
              memory: 32Mi
          volumeMounts:
            - name: runtime-secrets
              mountPath: /mnt/secrets/runtime
              readOnly: true
      volumes:
        - name: runtime-secrets
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: parcelflow-runtime
"@

$yaml | & kubectl apply -f -
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to apply namespace, service accounts, or SecretProviderClasses.'
}

& kubectl -n $Namespace rollout restart deployment/runtime-secret-sync
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to restart the runtime secret synchronization Deployment.'
}
& kubectl -n $Namespace rollout status deployment/runtime-secret-sync --timeout="${TimeoutSeconds}s"
if ($LASTEXITCODE -ne 0) {
    throw 'Runtime secret synchronization Deployment did not become ready.'
}
Invoke-WithRetry -Description 'runtime PostgreSQL Secret synchronization' -Attempts 30 -DelaySeconds 5 -Operation {
    $secretName = & kubectl -n $Namespace get secret parcelflow-postgres --output name
    if ($LASTEXITCODE -ne 0 -or ([string]$secretName).Trim() -ne 'secret/parcelflow-postgres') {
        throw 'The CSI-synchronized runtime Secret is not available yet.'
    }
}

& kubectl -n $Namespace delete job postgres-bootstrap --ignore-not-found=true
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to remove the previous bootstrap Job.'
}

$job = @"
apiVersion: batch/v1
kind: Job
metadata:
  name: postgres-bootstrap
  namespace: $Namespace
spec:
  backoffLimit: 6
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: postgres-bootstrap
      automountServiceAccountToken: true
      restartPolicy: OnFailure
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: bootstrap
          image: $PostgresImage
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            runAsNonRoot: true
            runAsUser: 70
            readOnlyRootFilesystem: true
          env:
            - name: PGHOST
              value: "$($outputs.postgresHost)"
            - name: PGPORT
              value: "5432"
            - name: PGDATABASE
              value: "$DatabaseName"
            - name: PGSSLMODE
              value: "require"
          command: ["/bin/sh", "-ec"]
          args:
            - |
              admin_user=`$(cat /mnt/secrets/postgres-administrator-login)
              export PGPASSWORD=`$(cat /mnt/secrets/postgres-administrator-password)
              app_user=`$(cat /mnt/secrets/postgres-application-login)
              app_password=`$(cat /mnt/secrets/postgres-application-password)
              export APP_USER="`$app_user"
              export APP_PASSWORD="`$app_password"
              psql --username="`$admin_user" --dbname=postgres --set=ON_ERROR_STOP=1 <<'SQL'
              \set app_user ``echo "`$APP_USER"``
              \set app_password ``echo "`$APP_PASSWORD"``
              SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
                WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') \gexec
              SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password') \gexec
              SQL
              if ! psql --username="`$admin_user" --dbname=postgres --tuples-only --no-align \
                --command="SELECT 1 FROM pg_database WHERE datname = '`$PGDATABASE'" | grep -q '^1`$'; then
                createdb --username="`$admin_user" --owner="`$app_user" "`$PGDATABASE"
              fi
              psql --username="`$admin_user" --dbname="`$PGDATABASE" --set=ON_ERROR_STOP=1 <<'SQL'
              \set app_user ``echo "`$APP_USER"``
              SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database()) \gexec
              SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'app_user') \gexec
              REVOKE CREATE ON SCHEMA public FROM PUBLIC;
              SELECT format('GRANT USAGE, CREATE ON SCHEMA public TO %I', :'app_user') \gexec
              SQL
          volumeMounts:
            - name: secrets
              mountPath: /mnt/secrets
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: secrets
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: parcelflow-bootstrap
        - name: tmp
          emptyDir: {}
"@

try {
    $job | & kubectl apply -f -
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create the PostgreSQL bootstrap Job.'
    }

    & kubectl -n $Namespace wait --for=condition=complete job/postgres-bootstrap --timeout="${TimeoutSeconds}s"
    if ($LASTEXITCODE -ne 0) {
        & kubectl -n $Namespace logs job/postgres-bootstrap --all-containers=true --tail=200
        throw 'PostgreSQL bootstrap Job did not complete successfully.'
    }
}
finally {
    $cleanupFailures = [System.Collections.Generic.List[string]]::new()
    $nativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false

    & kubectl -n $Namespace delete `
        job/postgres-bootstrap `
        secretproviderclass/parcelflow-bootstrap `
        serviceaccount/postgres-bootstrap `
        --ignore-not-found=true
    if ($LASTEXITCODE -ne 0) {
        $cleanupFailures.Add('remove temporary PostgreSQL bootstrap Kubernetes resources')
    }

    & az identity federated-credential delete `
        --resource-group $ResourceGroupName `
        --identity-name $outputs.bootstrapIdentityName `
        --name postgres-bootstrap `
        --yes --only-show-errors --output none
    if ($LASTEXITCODE -ne 0) {
        $cleanupFailures.Add('remove the PostgreSQL bootstrap federated credential')
    }

    $PSNativeCommandUseErrorActionPreference = $nativeErrorPreference
    if ($cleanupFailures.Count -gt 0) {
        throw "PostgreSQL bootstrap cleanup failed: $($cleanupFailures -join '; ')."
    }
}

Write-Host 'CSI secret boundaries and PostgreSQL application role/database are configured.'

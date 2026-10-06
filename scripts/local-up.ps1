# Recrée tout l'environnement Kubernetes local (kind) à partir du dépôt.
# Usage, depuis la racine du projet :  .\scripts\local-up.ps1
# Les versions ci-dessous doivent correspondre au bloc "images" de k8s/kustomization.yaml.

$Cluster = "site-monitor"
$Images = [ordered]@{
    "api"      = @{ Version = "0.1.0"; Dockerfile = "api/Dockerfile";     Context = "." }
    "checker"  = @{ Version = "0.1.0"; Dockerfile = "checker/Dockerfile"; Context = "." }
    "alerter"  = @{ Version = "0.1.1"; Dockerfile = "alerter/Dockerfile"; Context = "." }
    "frontend" = @{ Version = "0.1.1"; Dockerfile = "frontend/Dockerfile"; Context = "./frontend" }
}
$GatewayApiCrds = "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml"

function Step($message) { Write-Host "`n==> $message" -ForegroundColor Cyan }
function Check($what) { if ($LASTEXITCODE -ne 0) { throw "Échec : $what (code $LASTEXITCODE)" } }

# 0. Le secret n'est pas dans Git : il doit exister avant de commencer
if (-not (Test-Path "k8s/base/config/secret.yaml")) {
    throw "k8s/base/config/secret.yaml manquant : copie k8s/base/config/secret.example.yaml et remplis les vraies valeurs."
}

# 1. Le cluster
Step "Cluster kind '$Cluster'"
if ((kind get clusters) -contains $Cluster) {
    Write-Host "Le cluster existe déjà, on le garde."
} else {
    kind create cluster --name $Cluster --config k8s/local/kind-config.yaml --wait 120s
    Check "création du cluster"
}
kubectl config use-context "kind-$Cluster" | Out-Null
Check "changement de contexte"

# 2. Les images : construction puis chargement dans les nœuds
foreach ($name in $Images.Keys) {
    $img = $Images[$name]
    $tag = "site-monitor/${name}:$($img.Version)"
    Step "Image $tag"
    docker build --provenance=false -t $tag -f $img.Dockerfile $img.Context
    Check "build de $tag"
    kind load docker-image $tag --name $Cluster
    Check "chargement de $tag"
}

# 3. La Gateway API et Traefik
Step "CRD de la Gateway API"
kubectl apply --server-side -f $GatewayApiCrds
Check "installation des CRD"

Step "Traefik"
helm repo add traefik https://traefik.github.io/charts --force-update | Out-Null
helm upgrade --install traefik traefik/traefik -n traefik --create-namespace -f k8s/local/traefik-values.yaml --wait
Check "installation de Traefik"

# Metrics-server est nécessaire pour le HPA (Horizontal Pod Autoscaler)

Step "metrics-server (pour le HPA)"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update | Out-Null
helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system --set "args={--kubelet-insecure-tls}" --wait
Check "installation de metrics-server"

# 4. L'application
Step "Application (kubectl apply -k k8s/)"
kubectl apply -k k8s/overlays/local
Check "apply"

Step "Attente que tout soit prêt"
kubectl rollout status statefulset/postgres -n site-monitor --timeout=180s; Check "postgres"
foreach ($d in "redis", "api", "alerter", "frontend") {
    kubectl rollout status "deployment/$d" -n site-monitor --timeout=180s
    Check $d
}

Step "Terminé : http://localhost"
kubectl get pods -n site-monitor
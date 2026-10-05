#!/usr/bin/env bash
# Configure le kubelet pour s'authentifier à Artifact Registry avec le compte de
# service de la VM (jeton temporaire du serveur de métadonnées, aucune clé stockée).
# À lancer avec sudo, sur chaque nœud.
set -euo pipefail

REGISTRY="europe-west9-docker.pkg.dev"
BIN_DIR="/usr/local/lib/kubelet-credential-providers"
CONFIG="/etc/kubernetes/credential-provider-config.yaml"
PROVIDER="gcp-metadata-credential-provider"

echo "==> 1. Le programme du credential provider"
mkdir -p "$BIN_DIR"
cat <<'EOF' > "$BIN_DIR/$PROVIDER"
#!/usr/bin/env python3
"""Credential provider du kubelet : jeton Artifact Registry depuis le serveur de métadonnées."""
import json
import sys
import urllib.request

# 1. La requête du kubelet (contient l'image à télécharger)
request = json.load(sys.stdin)
registry = request["image"].split("/")[0]

# 2. Un jeton temporaire pour le compte de service de la VM
metadata = urllib.request.Request(
    "http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token",
    headers={"Metadata-Flavor": "Google"},
)
with urllib.request.urlopen(metadata, timeout=5) as resp:
    token = json.load(resp)

# 3. La réponse au kubelet : identifiants pour ce registre, et durée de cache
#    (un peu moins que la durée de vie du jeton)
cache_seconds = max(60, int(token["expires_in"]) - 300)
json.dump(
    {
        "apiVersion": "credentialprovider.kubelet.k8s.io/v1",
        "kind": "CredentialProviderResponse",
        "cacheKeyType": "Registry",
        "cacheDuration": f"{cache_seconds}s",
        "auth": {
            registry: {"username": "oauth2accesstoken", "password": token["access_token"]}
        },
    },
    sys.stdout,
)
EOF
chmod 755 "$BIN_DIR/$PROVIDER"

echo "==> 2. La configuration : quelles images utilisent ce provider"
cat <<EOF > "$CONFIG"
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ${PROVIDER}
    matchImages:
      - "${REGISTRY}"
    defaultCacheDuration: "50m"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
EOF

echo "==> 3. Les options du kubelet"
cat <<EOF > /etc/default/kubelet
KUBELET_EXTRA_ARGS="--image-credential-provider-config=${CONFIG} --image-credential-provider-bin-dir=${BIN_DIR}"
EOF
systemctl restart kubelet

echo "==> Vérifications"
sleep 5
systemctl is-active --quiet kubelet && echo "OK : kubelet redémarré"
echo "{\"apiVersion\":\"credentialprovider.kubelet.k8s.io/v1\",\"kind\":\"CredentialProviderRequest\",\"image\":\"${REGISTRY}/test/test:1\"}" \
  | "$BIN_DIR/$PROVIDER" | python3 -c "import json,sys; r=json.load(sys.stdin); print('OK : jeton obtenu pour', list(r['auth'])[0], '- cache', r['cacheDuration'])"
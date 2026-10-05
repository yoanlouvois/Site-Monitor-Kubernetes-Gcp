# Installer le cluster Kubernetes sur les VM GCP (kubeadm)

À suivre après `terraform apply` (réseau + 3 VM vierges).
Durée : 30 à 45 minutes.

| Nœud | IP interne | Rôle |
|---|---|---|
| `k8s-cp` | 10.10.0.10 | Control plane |
| `k8s-worker-1` | 10.10.0.11 | Worker |
| `k8s-worker-2` | 10.10.0.12 | Worker |

Les commandes **PowerShell** se lancent sur le PC, depuis la racine du projet.
Les commandes **bash** se lancent sur une VM, après un `gcloud compute ssh`.

Au début de chaque nouveau terminal PowerShell :

```powershell
$Zone = "europe-west9-b"
```

> Première connexion à une VM : PuTTY demande d'accepter la clé d'hôte, répondre `y`.
> Le faire une fois à la main par VM avant les boucles, sinon elles restent bloquées.

---

## 1. Préparer les 3 nœuds

Installe containerd, kubelet, kubeadm et kubectl, et règle le noyau (`prepare-node.sh`, en fins de ligne **LF**).

```powershell
foreach ($n in "k8s-cp", "k8s-worker-1", "k8s-worker-2") {
    gcloud compute scp infra/kubeadm/prepare-node.sh "${n}:prepare-node.sh" --zone $Zone --tunnel-through-iap
    gcloud compute ssh $n --zone $Zone --tunnel-through-iap --command "sudo bash prepare-node.sh"
}
```

Chaque nœud doit finir par `OK : containerd utilise les cgroups systemd` puis `Nœud prêt.`

> Avec PSCP (Windows), ne jamais utiliser `~` dans les chemins distants : écrire `k8s-cp:fichier` (relatif au dossier personnel).

---

## 2. Créer le control plane

```powershell
gcloud compute scp infra/kubeadm/kubeadm-config.yaml k8s-cp:kubeadm-config.yaml --zone $Zone --tunnel-through-iap
```

```powershell
gcloud compute ssh k8s-cp --zone $Zone --tunnel-through-iap
```

Sur `k8s-cp` :

```bash
sudo kubeadm init --config kubeadm-config.yaml
```

À la fin, kubeadm affiche **deux** commandes `kubeadm join`. Garder celle **sans** `--control-plane` (pour les workers). Elle contient un jeton secret valable 24 h : ne jamais la committer.

Configurer kubectl sur le nœud :

```bash
mkdir -p ~/.kube
```

```bash
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
```

```bash
sudo chown $(id -u):$(id -g) ~/.kube/config
```

```bash
kubectl get nodes
```

Le nœud est `NotReady` et CoreDNS `Pending` : normal, il n'y a pas encore de CNI (étape 4).

---

## 3. Piloter le cluster depuis le PC

À refaire après chaque nouveau `kubeadm init` (nouveaux certificats).

**Récupérer le kubeconfig :**

```powershell
gcloud compute scp k8s-cp:.kube/config "$HOME\.kube\gcp-site-monitor.yaml" --zone $Zone --tunnel-through-iap
```

**Le faire pointer vers le tunnel et renommer le contexte :**

```powershell
$f = "$HOME\.kube\gcp-site-monitor.yaml"
(Get-Content $f) -replace '10.10.0.10:6443', '127.0.0.1:6443' | Set-Content -Encoding ascii $f
kubectl --kubeconfig $f config rename-context kubernetes-admin@kubernetes gcp-site-monitor
```

**Le fusionner avec le kubeconfig principal :**

Si un ancien contexte `gcp-site-monitor` existe déjà (cluster précédent), le supprimer d'abord :

```powershell
kubectl config delete-context gcp-site-monitor
```

```powershell
if (Test-Path "$HOME\.kube\config") { Copy-Item "$HOME\.kube\config" "$HOME\.kube\config.bak" }
$env:KUBECONFIG = "$HOME\.kube\config;$HOME\.kube\gcp-site-monitor.yaml"
kubectl config view --flatten | Set-Content -Encoding ascii "$HOME\.kube\config.merged"
Move-Item -Force "$HOME\.kube\config.merged" "$HOME\.kube\config"
Remove-Item Env:KUBECONFIG
```

**Ouvrir le tunnel** (dans un terminal dédié, à laisser ouvert) :

```powershell
gcloud compute start-iap-tunnel k8s-cp 6443 --local-host-port=localhost:6443 --zone europe-west9-b
```

**Tester** (dans un autre terminal) :

```powershell
kubectl config use-context gcp-site-monitor
```

```powershell
kubectl get nodes
```

> `admin.conf` donne tous les droits sur le cluster : il ne doit jamais aller dans Git.

---

## 4. Installer Cilium (réseau des pods)

Tunnel ouvert, contexte `gcp-site-monitor` actif :

```powershell
helm repo add cilium https://helm.cilium.io/
```

```powershell
helm install cilium cilium/cilium --version 1.20.2 -n kube-system --set ipam.mode=kubernetes
```

```powershell
kubectl -n kube-system rollout status ds/cilium
```

`ipam.mode=kubernetes` : Cilium utilise le `podSubnet` de kubeadm (`10.244.0.0/16`) au lieu de `10.0.0.0/8`, qui chevaucherait le VPC.

`k8s-cp` doit passer en `Ready`.

---

## 5. Ajouter les workers

Sur `k8s-worker-1`, puis sur `k8s-worker-2` :

```powershell
gcloud compute ssh k8s-worker-1 --zone $Zone --tunnel-through-iap
```

Coller la commande worker de l'étape 2, avec `sudo` :

```bash
sudo kubeadm join 10.10.0.10:6443 --token <JETON> --discovery-token-ca-cert-hash sha256:<EMPREINTE>
```

Résultat attendu : `This node has joined the cluster`.

Si la commande est perdue ou le jeton expiré, en générer une nouvelle sur `k8s-cp` :

```bash
sudo kubeadm token create --print-join-command
```

Une fois les workers ajoutés, supprimer le jeton sur `k8s-cp` :

```bash
sudo kubeadm token list
```

```bash
sudo kubeadm token delete <ID_DU_JETON>
```

---

## 6. Vérifier

```powershell
kubectl get nodes -o wide
```

```powershell
kubectl get pods -n kube-system -o wide
```

```powershell
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --brief
```

Attendu : 3 nœuds `Ready`, un pod `cilium` et un `kube-proxy` par nœud, Cilium `OK`.

Test du réseau entre nœuds et du DNS :

```powershell
kubectl create deployment web --image=nginx:1.28 --replicas=2
kubectl expose deployment web --port=80
kubectl get pods -o wide
```

```powershell
kubectl run test --rm -it --image=busybox:1.36 -- wget -qO- web
```

La page de nginx doit s'afficher. Nettoyer :

```powershell
kubectl delete deployment,service web
```

---

## Au quotidien

Arrêter les VM le soir (le cluster est conservé) :

```powershell
gcloud compute instances stop k8s-cp k8s-worker-1 k8s-worker-2 --zone europe-west9-b
```

Les relancer :

```powershell
gcloud compute instances start k8s-cp k8s-worker-1 k8s-worker-2 --zone europe-west9-b
```

Attendre 1 à 2 minutes, rouvrir le tunnel (étape 3), puis `kubectl get nodes`.

---

## En cas d'échec uniquement : recommencer un nœud

⚠️ **Détruit Kubernetes sur le nœud.** Sur `k8s-cp`, cela détruit tout le cluster. À n'utiliser que si `init` ou `join` a échoué.

```bash
sudo kubeadm reset -f
```

```bash
sudo rm -rf /etc/cni/net.d ~/.kube
```

Puis relancer `kubeadm init` (et refaire les étapes 3, 4 et 5) ou `kubeadm join`.

| Symptôme | Cause probable | Solution |
|---|---|---|
| `$'\r': command not found` | Script en fins de ligne Windows | Réenregistrer en `LF` |
| `No such file or directory` après un `scp` | `~` dans le chemin distant (PSCP) | Chemin relatif : `k8s-cp:fichier` |
| `join` : `failure loading certificate for CA` | Commande avec `--control-plane` | Utiliser la commande worker |
| `x509: certificate is valid for ...` depuis le PC | `127.0.0.1` absent des `certSANs` | Corriger `kubeadm-config.yaml`, refaire l'init |
| `Unable to connect to the server` | Tunnel IAP fermé | Relancer `start-iap-tunnel` |
| Nœuds `NotReady` | Pas de CNI | Étape 4 |
| `kubeadm init` bloqué sur le kubelet | containerd mal configuré | Sur le nœud : `sudo journalctl -u kubelet -n 50` |
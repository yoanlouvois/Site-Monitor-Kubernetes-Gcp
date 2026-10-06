# Site-Monitor

Moniteur de disponibilité de sites web, conçu en **microservices** et déployé sur **Kubernetes** : un cluster kubeadm sur Google Cloud, provisionné avec Terraform, et un environnement local avec kind.

L'application vérifie chaque minute que les sites enregistrés répondent, conserve l'historique pour calculer leur disponibilité et envoie une **alerte Discord** dès qu'un site tombe ou revient.

<table>
  <tr>
    <td width="60%" align="center">
      <img src="https://github.com/user-attachments/assets/f9fecf38-01c5-4ac9-bc26-df9412b24e0d" alt="Interface de Site Monitor" />
      <br /><sub>Interface web : état et disponibilité des sites surveillés</sub>
    </td>
    <td width="40%" align="center">
      <img src="https://github.com/user-attachments/assets/754556a3-817b-40ab-a939-60a8d5e8dd92" alt="Notification Discord" />
      <br /><sub>Alerte Discord lors d'un changement d'état</sub>
    </td>
  </tr>
</table>

## Sommaire

- [Les services](#les-services)
- [Architecture GCP](#architecture-gcp)
- [Le cluster Kubernetes](#le-cluster-kubernetes)
- [Sécurité](#sécurité)
- [Lancer en local](#lancer-en-local)
- [Déployer sur GCP](#déployer-sur-gcp)
- [Tests et incident](#tests-et-incident)
- [Limites et compromis](#limites-et-compromis)
- [Évolutions possibles](#évolutions-possibles)
- [Arborescence du dépôt](#arborescence-du-dépôt)

## Les services

| Service | Rôle | Technologies |
|---|---|---|
| **frontend** | Interface web, proxy vers l'api | nginx (non privilégié), HTML/CSS/JS |
| **api** | Ajout, modification et suppression des sites, historique et disponibilité | Python, FastAPI |
| **checker** | Teste chaque site toutes les minutes et publie les changements d'état | Python, CronJob Kubernetes |
| **alerter** | Consomme les changements d'état et envoie les notifications | Python, Redis Streams, webhook Discord |
| **postgres** | Stocke les sites et l'historique des vérifications | PostgreSQL 16 |
| **redis** | File d'événements entre le checker et l'alerter (groupe de consommateurs, livraison au moins une fois) | Redis 7 |

## Architecture GCP

Toute l'infrastructure est décrite en **Terraform** (`infra/terraform/`) : elle se crée avec `terraform apply` et se supprime entièrement avec `terraform destroy`. Elle est déployée dans la région **europe-west9 (Paris)**.

<table align="center">
  <tr>
    <td align="center">
      <img src="https://github.com/user-attachments/assets/0546cef6-47d0-477a-884b-97651d170c59" alt="Architecture GCP de Site Monitor" width="700" />
      <br /><sub>Le load balancer est le seul point d'entrée public ; l'administration passe par IAP, la sortie Internet par Cloud NAT</sub>
    </td>
  </tr>
</table>

| Catégorie | Ressource | Rôle |
|---|---|---|
| **Réseau** | VPC et sous-réseau `10.10.0.0/24` | Réseau privé du cluster, avec Private Google Access (accès aux API Google sans passer par Internet) |
| | Cloud Router + Cloud NAT | Sortie vers Internet (images, sites surveillés, Discord) sans IP publique sur les VM |
| | Règles de pare-feu | Tout est fermé, sauf : le trafic interne, IAP (SSH et API Kubernetes) et les sondes du load balancer vers le NodePort |
| **Calcul** | 3 VM Shielded VM | 1 control plane et 2 workers, démarrage sécurisé (Secure Boot, vTPM) |
| **Accès administrateur** | IAP (Identity-Aware Proxy) | Accès SSH et `kubectl` à travers un tunnel authentifié par Google, sans IP publique ni bastion |
| | OS Login | Comptes SSH liés aux identités Google ; clés SSH du projet bloquées |
| **Exposition** | Application Load Balancer externe | Seul point d'entrée public : IP statique, health check, redirection vers les workers |
| | Certificat géré + politique SSL | HTTPS avec un certificat Google renouvelé automatiquement, TLS 1.2 minimum |
| **Stockage et images** | Persistent Disk (`pd-balanced`) | Données de Postgres, créées dynamiquement par le driver CSI |
| | Artifact Registry | Registre d'images privé, tags immuables |
| **Identités** | Comptes de service dédiés | Un pour les nœuds (lecture du registre uniquement), un pour le driver CSI (rôle personnalisé limité à l'attachement des disques) |

## Le cluster Kubernetes

Le cluster compte **3 nœuds** (1 control plane, 2 workers) installés avec kubeadm, avec containerd comme runtime. L'application tourne dans le namespace `site-monitor`.

| Composant | Choix | Pourquoi |
|---|---|---|
| **Installation** | kubeadm v1.37 | Contrôle complet sur les nœuds et la configuration du cluster (réseau, runtime, composants) |
| **Réseau des pods** | Cilium (eBPF) | CNI performant qui applique les NetworkPolicies |
| **Entrée HTTP** | Gateway API + Traefik | Successeur standard d'Ingress (ingress-nginx est en fin de vie) ; Traefik exposé en NodePort derrière le load balancer |
| **Stockage** | Driver CSI Persistent Disk | Volumes créés à la demande pour Postgres (StorageClass `pd-balanced`) |
| **Accès aux images** | Credential provider du kubelet | Les nœuds lisent le registre privé avec un jeton temporaire, sans aucune clé stockée |
| **Charges de travail** | Deployments, StatefulSet, CronJobs | api, frontend, alerter et redis en Deployment ; Postgres en StatefulSet (identité et disque stables) ; checker et nettoyage en CronJob |
| **Autoscaling** | metrics-server + HPA | L'api passe de 2 à 8 pods selon sa consommation CPU |
| **Déploiement** | Kustomize (base + overlays) | Un seul jeu de manifests ; les différences entre kind et GCP (registre, taille du disque) tiennent dans un overlay |


### Le trajet d'une requête

```
Navigateur ─HTTPS─▶ Load Balancer ─HTTP─▶ NodePort 30080 ─▶ Traefik ─▶ frontend ─/api/─▶ api ─▶ postgres
                    (TLS terminé ici)     (workers)         (Gateway API)  (nginx)
```

- **Nom de domaine et certificat** : un certificat géré par Google exige un nom de domaine. Le projet utilise **sslip.io**, un service DNS public qui transforme une adresse IP en nom de domaine (`34-1-2-3.sslip.io` → `34.1.2.3`). Il donne un domaine valide et gratuit pointant vers l'IP statique du load balancer, sans acheter de domaine.
- **HTTPS uniquement** : les requêtes HTTP sont redirigées vers HTTPS (301), et une politique SSL impose **TLS 1.2 minimum** avec des suites de chiffrement modernes.
- **Un seul point d'entrée** : seul le frontend est exposé via la Gateway. L'api n'est joignable qu'à travers le proxy nginx du frontend (`/api/`), jamais directement depuis Internet.

### Autoscaling

L'api est pilotée par un **HorizontalPodAutoscaler** : entre 2 et 8 pods, avec une cible de **60 % du CPU demandé** (`requests` de 100m par pod). Le nombre de replicas n'est volontairement **pas** défini dans le Deployment : le HPA en est le seul propriétaire, et un `kubectl apply` ne peut pas annuler sa décision.

**Test de charge** : 8 boucles de requêtes en parallèle sur `GET /sites`, lancées depuis un pod du cluster.

| Temps | CPU moyen / cible | Pods | Décision du HPA (événements Kubernetes) |
|---|---|---|---|
| Avant le test | 5 % / 60 % | 2 | Au repos, minimum garanti |
| Début de la charge | 232 % / 60 % | 2 | Cible dépassée, le HPA mesure |
| T | 355 % / 60 % | **4** | `New size: 4` : utilisation CPU au-dessus de la cible |
| T + 15 s | 181 % / 60 % | **8** | `New size: 8` : plafond `maxReplicas` atteint, le HPA s'arrête là |

<table align="center">
  <tr>
    <td width="50%" align="center">
      <img src="https://github.com/user-attachments/assets/067515d2-d0ee-4d49-ad04-1e6105ba03ad" alt="Suivi du HPA pendant le test de charge" />
      <br /><sub>Utilisation CPU et nombre de pods pendant le test</sub>
    </td>
    <td width="50%" align="center">
      <img src="https://github.com/user-attachments/assets/bcdb8546-f501-47b7-af47-d8e80642ccbe" alt="Événements de mise à l'échelle du HPA" />
      <br /><sub>Décisions du HPA : 2 → 4 → 8 pods en 15 secondes</sub>
    </td>
  </tr>
</table>

Après l'arrêt de la charge, le nombre de pods redescend à 2 au bout d'une **fenêtre de stabilisation de 5 minutes**, qui évite de supprimer des pods pour les recréer aussitôt si la charge revient. Le plafond de 8 pods empêche qu'un pic (ou une attaque) remplisse les nœuds. Le nombre de nœuds reste fixe : il n'y a pas de Cluster Autoscaler (voir [Limites](#limites-et-compromis)).

## Sécurité

| Couche | Mesures |
|---|---|
| **Infrastructure GCP** | Aucune IP publique sur les VM ; pare-feu fermé par défaut, chaque ouverture limitée à une source précise (IAP, sondes du load balancer) ; accès administrateur via IAP et OS Login ; Shielded VM ; comptes de service au moindre privilège |
| **Exposition** | Load balancer comme seul point d'entrée public ; HTTPS avec certificat géré, TLS 1.2 minimum ; l'api n'est jamais exposée directement |
| **Réseau Kubernetes** | NetworkPolicies : tout est interdit par défaut, chaque flux est autorisé un par un ; **protection anti-SSRF** du checker (serveur de métadonnées et plages privées bloqués) |
| **Pods** | Pod Security Standards `restricted` en mode `enforce` : non-root, `capabilities: drop ALL`, pas d'élévation de privilèges, seccomp ; système de fichiers en lecture seule |
| **Identités** | Un ServiceAccount par service, aucun jeton monté, aucun droit RBAC ; un Role en lecture seule (sans accès aux Secrets) pour les humains |
| **Application** | Requêtes SQL paramétrées ; CSP et `textContent` contre le XSS ; chaque service ne reçoit que les secrets dont il a besoin (l'alerter n'a pas le mot de passe de la base) |
| **Secrets** | Jamais versionnés (`.env`, `secret.yaml`, kubeconfig, état Terraform exclus de Git) ; modèles `.example` fournis |
| **Chaîne d'approvisionnement** | Registre d'images privé, tags immuables, scan des vulnérabilités avec Trivy |

### Analyse des vulnérabilités (Trivy)

```powershell
docker run --rm -v //var/run/docker.sock:/var/run/docker.sock aquasec/trivy image --severity HIGH,CRITICAL --ignore-unfixed <image>
```

Le scan de `postgres:16-alpine` illustre pourquoi un rapport de vulnérabilités doit être **analysé**, et pas seulement compté :

- **Système Alpine : 0 CVE.**
- **Binaire `gosu` : 22 CVE (dont 1 critique).** gosu est un petit utilitaire écrit en Go, utilisé par l'image pour passer de root à l'utilisateur `postgres` au démarrage. Toutes ses CVE se trouvent dans la **bibliothèque standard de Go** avec laquelle il a été compilé : `crypto/tls`, `net/http`, `net/mail`, `html/template`… gosu n'utilise aucun de ces paquets (il ne fait qu'un `setuid` puis un `exec`). Le code vulnérable est présent dans le binaire, mais **jamais atteignable**.
- **De plus, gosu n'est jamais exécuté dans ce déploiement.** Postgres démarre directement en utilisateur non-root (UID 70), donc l'image n'a pas besoin de changer d'utilisateur. Même lancé par un attaquant, gosu serait inutile : sans la capability `SETUID` et avec `allowPrivilegeEscalation: false`, il ne peut changer d'identité.

**Décision : risque accepté et documenté.** Le durcissement des pods neutralise une catégorie de risques que le scanner ne peut pas évaluer. En production, cette décision serait formalisée dans un fichier `.trivyignore` justifiant chaque exception, ou dans un document **VEX** (*Vulnerability Exploitability eXchange*), le format standard pour déclarer qu'une vulnérabilité présente n'est pas exploitable dans un contexte donné. Elle serait réévaluée à chaque nouvelle version de l'image.

## Lancer en local

L'application peut tourner de deux façons en local :

- **Docker Compose** : pour développer et tester le code rapidement ;
- **Kubernetes avec kind** : pour tester les manifests avant le déploiement sur GCP.

### Prérequis

- Docker Desktop
- Pour kind : `kind`, `kubectl` et `helm`

### Configuration

Les secrets ne sont pas versionnés. Avant le premier lancement, créer :

- `.env` à partir de `.env.example` (pour Compose) ;
- `k8s/base/config/secret.yaml` à partir de `k8s/base/config/secret.example.yaml` (pour Kubernetes).

Y renseigner le mot de passe de la base et l'URL du webhook Discord.

### Avec Docker Compose

```bash
docker compose up -d --build
```

- Interface : http://localhost:8080
- API (Swagger) : http://localhost:8000/docs

Le checker n'est pas planifié avec Compose : on le lance à la demande avec `docker compose run --rm checker`.

### Avec Kubernetes (kind)

```powershell
.\scripts\local-up.ps1
```

Le script crée un cluster de 3 nœuds, construit et charge les images, installe la Gateway API, Traefik et metrics-server, puis déploie l'application avec Kustomize (`kubectl apply -k k8s/overlays/local`). Il peut être relancé sans risque.

- Interface : http://localhost
- L'api n'est pas exposée : `kubectl port-forward service/api 8000:8000 -n site-monitor` pour accéder à Swagger.

Les versions des images sont définies dans `k8s/overlays/local/kustomization.yaml` (et dans `scripts/local-up.ps1`, qui construit les images).

## Déployer sur GCP

**Prérequis** : un projet GCP avec la facturation activée, `gcloud` (authentifié), `terraform`, `kubectl` et `helm`. Le guide détaillé, avec toutes les commandes, se trouve dans [`infra/kubeadm/README.md`](infra/kubeadm/README.md).

1. **Créer l'infrastructure** : renseigner `infra/terraform/terraform.tfvars` (identifiant du projet, zone), puis :

```powershell
   terraform -chdir=infra/terraform init
   terraform -chdir=infra/terraform apply
```

2. **Installer le cluster** : préparer les 3 VM (`prepare-node.sh`), initialiser le control plane avec `kubeadm init`, installer Cilium, puis faire rejoindre les workers avec `kubeadm join`. `kubectl` passe par un tunnel IAP vers l'API server.

3. **Installer les composants du cluster** (`infra/cluster/`) : le credential provider pour Artifact Registry (`setup-registry-auth.sh`), le driver CSI Persistent Disk et sa StorageClass, la Gateway API et Traefik, puis metrics-server.

4. **Publier les images** dans Artifact Registry :

```powershell
   gcloud auth configure-docker europe-west9-docker.pkg.dev
   docker tag site-monitor/api:0.1.0 europe-west9-docker.pkg.dev/<PROJET>/site-monitor/api:0.1.0
   docker push europe-west9-docker.pkg.dev/<PROJET>/site-monitor/api:0.1.0
```

   (même chose pour `checker`, `alerter` et `frontend`, avec les versions de `k8s/overlays/gcp/kustomization.yaml`)

5. **Déployer l'application** :

```powershell
   kubectl apply -k k8s/overlays/gcp
```

   L'URL HTTPS est affichée par `terraform -chdir=infra/terraform output url`. Le certificat géré peut mettre de 15 à 60 minutes à devenir actif.

6. **Tout supprimer** une fois terminé, pour arrêter la facturation :

```powershell
   terraform -chdir=infra/terraform destroy
```

> Pour une pause courte, arrêter les VM suffit (`gcloud compute instances stop ...`), mais les disques et le load balancer restent facturés.

## Tests et incident

### Tests réalisés

| Test | Méthode | Résultat |
|---|---|---|
| **Alerte de bout en bout** | Un site passe de UP à DOWN (domaine `.invalid`), puis revient | Alerte reçue sur Discord à chaque changement d'état ; toute la chaîne api → Postgres → checker → Redis → alerter fonctionne avec le durcissement en place |
| **Autoscaling** | 8 boucles de requêtes en parallèle sur l'api | 2 → 4 → 8 pods, plafond respecté (voir [Autoscaling](#autoscaling)) |
| **NetworkPolicies** | Pod sans label autorisé vers Postgres et l'api ; pod avec le label du checker vers le serveur de métadonnées | Connexions bloquées ; Internet public toujours accessible au checker |
| **Pod Security Standards** | Création d'un pod `busybox` qui tourne en root | Refusé : `violates PodSecurity "restricted:latest"` |
| **RBAC** | `kubectl auth can-i --as=system:serviceaccount:site-monitor:api` | Aucun droit ; le Role de lecture ne donne pas accès aux Secrets |
| **Lecture seule** | `touch /test` dans le conteneur de l'api | `Read-only file system` |

### Incident : la base de données perdue après un `terraform apply`

| | |
|---|---|
| **Symptôme** | L'interface affiche « liaison API perdue » et le load balancer renvoie des 504. Les logs de Postgres montrent des erreurs d'entrée/sortie : `could not open file "global/pg_filenode.map"`. |
| **Diagnostic** | Les premières pistes (réseau entre les nœuds, état de Cilium) étaient fausses. L'erreur venait du disque : le volume de Postgres n'était plus lisible, alors que le pod tournait toujours. |
| **Cause** | Le disque Persistent Disk est créé et attaché par le **driver CSI**, donc par Kubernetes. Terraform ne le connaissait pas : à l'`apply` suivant, il a vu un disque « en trop » sur `k8s-worker-1` et l'a **détaché** pour revenir à sa configuration. Le CSI l'a rattaché, mais le montage dans le pod était devenu invalide. |
| **Correction** | `lifecycle { ignore_changes = [attached_disk] }` sur les VM : Terraform ne gère plus les disques attachés. Puis suppression du pod `postgres-0`, recréé par le StatefulSet avec un montage propre. Aucune donnée perdue. |
| **Retour d'expérience** | **Chaque attribut doit avoir un seul propriétaire.** Deux outils qui gèrent la même chose finissent par s'annuler l'un l'autre. C'est le même principe qui a guidé l'autoscaling : `replicas` a été retiré du Deployment pour que le HPA soit seul à décider du nombre de pods. |

## Limites et compromis

| Limite | En production |
|---|---|
| **Un seul control plane** : s'il tombe, le cluster ne peut plus être modifié (les pods continuent de tourner) | 3 control planes sur plusieurs zones, ou un service managé (GKE) |
| **Postgres sur un seul pod**, sans réplica ni sauvegarde automatique | Cloud SQL, ou un opérateur (CloudNativePG) avec réplication et sauvegardes |
| **Redis sans persistance** : les alertes en attente sont perdues si le pod est supprimé | Un volume persistant, ou Memorystore |
| **Pas de Cluster Autoscaler** : le HPA ajuste les pods, mais le nombre de nœuds est fixe | Workers dans un Managed Instance Group avec Cluster Autoscaler |
| **Pas d'authentification** : l'application est publique | IAP ou Cloud Armor devant le load balancer |
| **`admin.conf`** (tous les droits) utilisé pour administrer le cluster | Une identité par personne (OIDC) avec des droits RBAC adaptés |
| **Checker limité aux ports 80 et 443** (protection anti-SSRF) : un site sur un autre port apparaît en panne | Compromis assumé ; ports supplémentaires à autoriser explicitement si besoin |

## Évolutions possibles

| Évolution | Apport |
|---|---|
| **GitOps avec Argo CD** | Le cluster se synchronise seul sur l'overlay versionné dans Git : chaque changement passe par une pull request relue, la dérive est détectée et corrigée, et aucun identifiant du cluster ne sort du cluster |
| **Secrets compatibles GitOps** (Sealed Secrets ou External Secrets Operator avec Google Secret Manager) | Plus aucun secret créé à la main : ils sont chiffrés dans Git, ou lus depuis un coffre-fort |
| **CI GitHub Actions** | Build et push des images à chaque commit, scan Trivy **bloquant** sur les vulnérabilités critiques, pull request automatique de mise à jour du tag |
| **Observabilité : Prometheus et Grafana** | Métriques de l'application et du cluster, tableaux de bord, alertes sur les erreurs et la latence |
| **IAP ou Cloud Armor** devant l'application | Authentification des utilisateurs, filtrage des requêtes (WAF) et limitation de débit |
| **Comparaison avec GKE Autopilot** | Mesurer ce que le service managé simplifie (control plane, nœuds, autoscaling) et ce qu'il coûte, par rapport au cluster kubeadm |

## Arborescence du dépôt

```
.
├── api/                  # Service api (FastAPI)
├── checker/              # Vérification des sites (CronJob)
├── alerter/              # Notifications Discord (consommateur Redis Streams)
├── common/               # Code partagé : configuration, accès Postgres et Redis
├── frontend/             # Interface web et proxy nginx
├── db/                   # Schéma SQL (init.sql), utilisé par Compose et Kubernetes
├── k8s/
│   ├── base/             # Manifests communs : applications, données, routage, sécurité
│   ├── overlays/         # Différences par environnement : local (kind) et gcp
│   └── local/            # Configuration de kind et de Traefik en local
├── infra/
│   ├── terraform/        # Infrastructure GCP
│   ├── kubeadm/          # Installation du cluster (scripts et guide)
│   └── cluster/          # Composants du cluster : StorageClass, Traefik, metrics-server
├── scripts/              # local-up.ps1 : environnement kind complet en une commande
├── k8s-sandbox/          # Exercices et essais Kubernetes (hors application)
└── docker-compose.yml    # Environnement de développement
```

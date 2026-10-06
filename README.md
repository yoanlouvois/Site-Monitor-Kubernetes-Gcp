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

<!-- Tableau par couche (défense en profondeur) :
     Infrastructure GCP / Réseau Kubernetes / Pods / Identités / Application / Chaîne d'approvisionnement -->

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

<!-- Étapes courtes + renvoi vers infra/kubeadm/README.md :
     1. terraform apply
     2. kubeadm + Cilium
     3. Composants du cluster (credential provider, CSI, Traefik, metrics-server)
     4. Push des images dans Artifact Registry
     5. kubectl apply -k k8s/overlays/gcp
     6. terraform destroy -->

## Tests et incident

<!-- Tests : alerte de bout en bout, test de charge HPA, blocages NetworkPolicies et PSS
     Incident : 504 → Terraform détachait le disque Postgres → ignore_changes
     → leçon : un seul propriétaire par ressource -->

## Limites et compromis

<!-- kubeadm plutôt que GKE, un seul control plane, Postgres sur un seul pod,
     metrics-server en insecure-tls, Redis sans persistance ni mot de passe,
     checker limité aux ports 80/443, TLS terminé au LB, audit non activé,
     pas d'authentification, images épinglées par tag et non par digest -->

## Évolutions possibles

<!-- GitOps avec Argo CD (+ Sealed Secrets / External Secrets), CI avec scan Trivy bloquant,
     Prometheus et Grafana, IAP ou Cloud Armor devant l'application, comparaison GKE Autopilot -->

## Arborescence du dépôt

<!-- tree simplifié sur 2 niveaux, un commentaire par dossier -->

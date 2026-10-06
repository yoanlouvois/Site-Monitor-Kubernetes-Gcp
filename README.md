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

<!-- Diagramme draw.io (image) : Internet → LB → VM → pods, IAP sur le côté pour l'admin -->
<!-- Phrase : toute l'infrastructure est décrite en Terraform (infra/terraform/) -->
<!-- Tableau Ressource / Rôle : VPC + sous-réseau privé, Cloud NAT, 3 VM Shielded,
     IAP, Application Load Balancer + certificat géré, Artifact Registry, Persistent Disk -->

## Le cluster Kubernetes

<!-- Tableau Composant / Choix / Pourquoi : kubeadm, Cilium, Gateway API + Traefik,
     CSI Persistent Disk, credential provider, metrics-server + HPA, Kustomize -->

### Le trajet d'une requête

<!-- Navigateur → HTTPS (sslip.io) → Load Balancer (TLS) → NodePort 30080 → Traefik → frontend → api
     sslip.io, certificat géré par Google, redirection HTTP→HTTPS, TLS 1.2+ -->

### Autoscaling

<!-- Résultat du test de charge : 2 → 4 → 8 pods en 45 s, plafond respecté, descente après 5 min -->

## Sécurité

<!-- Tableau par couche (défense en profondeur) :
     Infrastructure GCP /

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

Le script crée un cluster de 3 nœuds, construit et charge les images, installe la Gateway API et Traefik, puis déploie l'application avec Kustomize (`kubectl apply -k k8s/overlays/local`). Il peut être relancé sans risque.

- Interface : http://localhost
- L'api n'est pas exposée : `kubectl port-forward service/api 8000:8000 -n site-monitor` pour accéder à Swagger.

Les versions des images sont définies dans `k8s/overlays/local/kustomization.yaml` (et dans `scripts/local-up.ps1`, qui construit les images).

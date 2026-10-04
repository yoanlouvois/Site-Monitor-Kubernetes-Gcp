# Commandes Kubernetes utiles

## Cluster (kind)

Créer, supprimer et lister les clusters :

```bash
kind create cluster --name site-monitor --config k8s/local/kind-config.yaml
```

```bash
kind delete cluster --name site-monitor
```

```bash
kind get clusters
```

Mettre le cluster en pause, puis le relancer :

```bash
docker stop site-monitor-control-plane site-monitor-worker site-monitor-worker2
```

```bash
docker start site-monitor-control-plane site-monitor-worker site-monitor-worker2
```

Voir les nodes et leurs labels :

```bash
kubectl get nodes
```

```bash
kubectl get nodes --show-labels
```

Adresse de l'API server du cluster actuel :

```bash
kubectl cluster-info
```

Tous les pods de tous les namespaces (`-A`), dont les pods système dans `kube-system` :

```bash
kubectl get pods -A
```

## Contexte et namespace

Voir le contexte actuel, les lister, en changer :

```bash
kubectl config current-context
```

```bash
kubectl config get-contexts
```

```bash
kubectl config use-context <context>
```

Lister, créer et supprimer un namespace. La suppression supprime tout ce qu'il y a dedans (pods, deployments, services...) :

```bash
kubectl get namespaces
```

```bash
kubectl create namespace <namespace>
```

```bash
kubectl delete namespace <namespace>
```

Changer le namespace par défaut (pour ne plus taper `-n`). On revient à la normale en mettant `default` :

```bash
kubectl config set-context --current --namespace=<namespace>
```

## Manifests (valable pour tous les objets)

Appliquer un fichier, ou tout un dossier :

```bash
kubectl apply -f <fichier.yaml>
```

```bash
kubectl apply -f <dossier>/
```

Voir ce que le apply changerait, sans rien modifier :

```bash
kubectl diff -f <fichier.yaml>
```

Supprimer les objets décrits dans un fichier :

```bash
kubectl delete -f <fichier.yaml>
```

L'objet complet tel que le cluster le voit (avec le status) :

```bash
kubectl get <objet> <nom> -o yaml
```

La doc d'un champ directement dans le terminal :

```bash
kubectl explain deployment.spec
```

Tout ce qui tourne dans un namespace :

```bash
kubectl get all -n <namespace>
```

## Pod

Le pod c'est la plus petite unité dans Kubernetes : un ou plusieurs conteneurs qui tournent ensemble. Son IP change à chaque recréation et si on le supprime personne ne le recrée, c'est pour ça qu'on en crée rarement un seul à la main.

```bash
kubectl apply -f pod.yaml
```

Lister les pods :

```bash
kubectl get pods -n <namespace>
```

Avec l'IP du pod et le node où il tourne (`-o wide`) :

```bash
kubectl get pods -n <namespace> -o wide
```

Suivre les changements en direct (`-w`, Ctrl+C pour arrêter) :

```bash
kubectl get pods -n <namespace> -w
```

Le détail d'un pod. Regarder la partie Events en bas : c'est là qu'on trouve pourquoi un pod ne démarre pas.

```bash
kubectl describe pod <pod> -n <namespace>
```

Les logs, en continu (`-f`), ou ceux du conteneur précédent s'il a planté et redémarré (`--previous`) :

```bash
kubectl logs <pod> -n <namespace>
```

```bash
kubectl logs <pod> -n <namespace> -f
```

```bash
kubectl logs <pod> -n <namespace> --previous
```

Ouvrir un shell dans le pod (`-it` : session interactive, `sh` : le shell) :

```bash
kubectl exec -it <pod> -n <namespace> -- sh
```

Supprimer un pod :

```bash
kubectl delete pod <pod> -n <namespace>
```

Tous les événements récents du namespace :

```bash
kubectl get events -n <namespace> --sort-by=.lastTimestamp
```

## Deployment

Le Deployment gère un groupe de pods identiques : il garde le bon nombre de pods (si un pod meurt il en recrée un) et gère les mises à jour sans coupure. Le ReplicaSet est l'objet qui maintient réellement le nombre de pods. Le Deployment, lui, gère les versions : à chaque modification du template, il crée un nouveau ReplicaSet, ce qui permet de revenir en arrière.

```bash
kubectl apply -f deployment.yaml
```

```bash
kubectl get deployments -n <namespace>
```

```bash
kubectl get replicasets -n <namespace>
```

```bash
kubectl get pods -n <namespace> -o wide
```

Changer le nombre de pods. Rapide mais le fichier n'est plus à jour : mieux vaut modifier `replicas` dans le yaml et refaire un apply.

```bash
kubectl scale deployment <deployment> --replicas=3 -n <namespace>
```

Mise à jour : modifier l'image dans le yaml, puis apply. Le rollout status suit juste l'avancement, c'est le apply qui lance la mise à jour.

```bash
kubectl apply -f deployment.yaml
```

```bash
kubectl rollout status deployment <deployment> -n <namespace>
```

Voir les versions, et revenir à la précédente (penser à remettre le fichier à jour après) :

```bash
kubectl rollout history deployment <deployment> -n <namespace>
```

```bash
kubectl rollout undo deployment <deployment> -n <namespace>
```

Recréer tous les pods un par un (utile après un changement de ConfigMap ou de Secret) :

```bash
kubectl rollout restart deployment <deployment> -n <namespace>
```

## Service

Le Service répond au problème des IP qui changent : les pods ont une IP différente à chaque recréation, donc personne ne peut s'y connecter de façon fiable. Le Service leur donne une adresse fixe et un nom DNS (`<service>.<namespace>.svc.cluster.local`), et répartit les connexions entre eux. Il retrouve ses pods grâce aux labels (le selector).

```bash
kubectl apply -f service.yaml
```

```bash
kubectl get services -n <namespace>
```

Le détail du Service. La ligne Endpoints donne les IP des pods trouvés par le selector :

```bash
kubectl describe service <service> -n <namespace>
```

```bash
kubectl get endpointslices -n <namespace>
```

Pod temporaire pour tester depuis l'intérieur du cluster (supprimé à la sortie) :

```bash
kubectl run test --rm -it --image=busybox:1.36 -n <namespace> -- sh
```

Une fois dedans, appeler le Service par son nom, et voir son adresse :

```bash
wget -qO- <service>
```

```bash
nslookup <service>
```

Les logs de tous les pods qui ont un label (`-l`), avec le nom du pod devant chaque ligne (`--prefix`) :

```bash
kubectl logs -l app=<label> --prefix --tail=5 -n <namespace>
```

Accès depuis le navigateur sur http://localhost:8888 (pour debug seulement) :

```bash
kubectl port-forward service/<service> 8888:80 -n <namespace>
```
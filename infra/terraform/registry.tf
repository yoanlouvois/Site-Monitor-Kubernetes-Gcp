# Registre des images Docker de l'application
resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "site-monitor"
  format        = "DOCKER"
  description   = "Images de l'application site-monitor"

  docker_config {
    # Une version publiée ne peut plus jamais être écrasée
    immutable_tags = true
  }

  depends_on = [google_project_service.apis]
}

# Les nœuds peuvent LIRE les images de CE dépôt, et rien d'autre
resource "google_artifact_registry_repository_iam_member" "nodes_reader" {
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.nodes.member
}
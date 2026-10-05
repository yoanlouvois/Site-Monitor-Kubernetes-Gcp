provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# Les API nécessaires, activées par Terraform
locals {
  apis = [
    "compute.googleapis.com", # VM, réseau, pare-feu, NAT, disques
    "iap.googleapis.com",     # tunnel IAP pour SSH et l'API server
    "oslogin.googleapis.com", # SSH via IAM
    "iam.googleapis.com", # compte de service
    "artifactregistry.googleapis.com", # registre d'images
    "cloudresourcemanager.googleapis.com", # droits IAM au niveau du projet
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.apis)
  service  = each.value

  # Ne pas désactiver l'API au destroy : d'autres ressources pourraient encore en dépendre
  disable_on_destroy = false
}

# SSH via les identités IAM (OS Login) plutôt que des clés SSH déposées sur les VM
resource "google_compute_project_metadata_item" "oslogin" {
  key   = "enable-oslogin"
  value = "TRUE"

  depends_on = [google_project_service.apis]
}
locals {
  nodes = {
    "k8s-cp" = {
      machine_type = "e2-medium"
      ip           = "10.10.0.10"
      role         = "control-plane"
      tags         = ["k8s-node", "k8s-control-plane"]
    }
    "k8s-worker-1" = {
      machine_type = "e2-standard-2"
      ip           = "10.10.0.11"
      role         = "worker"
      tags         = ["k8s-node"]
    }
    "k8s-worker-2" = {
      machine_type = "e2-standard-2"
      ip           = "10.10.0.12"
      role         = "worker"
      tags         = ["k8s-node"]
    }
  }
}

resource "google_compute_instance" "nodes" {
  for_each = local.nodes

  name         = each.key
  machine_type = each.value.machine_type
  zone         = var.zone
  tags         = each.value.tags

  labels = {
    project = "site-monitor"
    role    = each.value.role
  }

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 30
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.nodes.id
    network_ip = each.value.ip
    # Pas de bloc access_config : aucune IP publique
  }

  service_account {
    email = google_service_account.nodes.email
    # Les droits réels sont limités par IAM (aucun rôle pour l'instant),
    # pas par les "scopes" : c'est la pratique recommandée par Google
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    # Seul OS Login (IAM) permet le SSH, pas les clés déposées dans le projet
    block-project-ssh-keys = "TRUE"
  }

  # Permet à Terraform d'arrêter la VM s'il doit changer son type
  allow_stopping_for_update = true

  lifecycle {
    ignore_changes = [
      # Ne pas recréer les nœuds à chaque nouvelle image Ubuntu publiée
      boot_disk[0].initialize_params[0].image,
      # Les disques des PVC sont attachés par le driver CSI de Kubernetes :
      # Terraform ne doit jamais les détacher
      attached_disk,
    ]
  }

  # Le NAT doit exister pour que les VM puissent installer des paquets
  depends_on = [google_compute_router_nat.nat]
}
# --- VPC ---------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = "site-monitor-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.apis]
}

# --- Sous-réseau des nœuds Kubernetes ----------------------------------
resource "google_compute_subnetwork" "nodes" {
  name          = "site-monitor-nodes"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.10.0.0/24"

  # Accès aux API Google (Artifact Registry...) par le réseau interne de Google
  private_ip_google_access = true
}

# --- Sortie vers Internet : Cloud Router + Cloud NAT --------------------
resource "google_compute_router" "router" {
  name    = "site-monitor-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "site-monitor-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.nodes.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# --- Pare-feu ----------------------------------------------------------
# Plage d'adresses utilisée par Google IAP pour joindre les VM
locals {
  iap_range = "35.235.240.0/20"
}

# 1. Trafic interne entre les nœuds (Kubernetes, réseau des pods Cilium)
resource "google_compute_firewall" "internal" {
  name      = "site-monitor-allow-internal"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"

  source_ranges = [google_compute_subnetwork.nodes.ip_cidr_range]
  target_tags   = ["k8s-node"]

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

# 2. SSH uniquement via le tunnel IAP
resource "google_compute_firewall" "iap_ssh" {
  name      = "site-monitor-allow-iap-ssh"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"

  source_ranges = [local.iap_range]
  target_tags   = ["k8s-node"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# 3. API server Kubernetes uniquement via le tunnel IAP, sur le control plane
resource "google_compute_firewall" "iap_apiserver" {
  name      = "site-monitor-allow-iap-apiserver"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"

  source_ranges = [local.iap_range]
  target_tags   = ["k8s-control-plane"]

  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# 4. Load balancer : les proxys et les health checks de Google vers le NodePort de Traefik
resource "google_compute_firewall" "lb_to_nodeport" {
  name      = "site-monitor-allow-lb-nodeport"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"

  # Plages documentées des proxys du load balancer et des health checks Google
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["k8s-node"]

  allow {
    protocol = "tcp"
    ports    = ["30080"]
  }
}
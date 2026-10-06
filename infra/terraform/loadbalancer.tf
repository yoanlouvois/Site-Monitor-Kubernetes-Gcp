locals {
  workers = ["k8s-worker-1", "k8s-worker-2"]
}

# --- IP publique fixe ---------------------------------------------------
resource "google_compute_global_address" "lb" {
  name = "site-monitor-lb-ip"
}

# --- Les VM qui reçoivent le trafic ---------------------------------------
# Groupe "non géré" : on y place nous-mêmes les workers existants
resource "google_compute_instance_group" "workers" {
  name      = "site-monitor-workers"
  zone      = var.zone
  instances = [for w in local.workers : google_compute_instance.nodes[w].self_link]

  # Le port nommé "http" correspond au NodePort de Traefik
  named_port {
    name = "http"
    port = 30080
  }
}

# --- Vérification de santé ------------------------------------------------
resource "google_compute_health_check" "traefik" {
  name                = "site-monitor-hc-traefik"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 30080
    request_path = "/"
  }
}

# --- Service de backend : répartition + santé ------------------------------
resource "google_compute_backend_service" "traefik" {
  name                  = "site-monitor-backend"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 30
  health_checks         = [google_compute_health_check.traefik.id]

  backend {
    group           = google_compute_instance_group.workers.id
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

# --- Routage : tout va vers le même backend --------------------------------
resource "google_compute_url_map" "web" {
  name            = "site-monitor-urlmap"
  default_service = google_compute_backend_service.traefik.id
}

resource "google_compute_target_http_proxy" "web" {
  name    = "site-monitor-http-proxy"
  url_map = google_compute_url_map.https_redirect.id
}

# --- Point d'entrée public : IP + port 80 ---------------------------------
resource "google_compute_global_forwarding_rule" "http" {
  name                  = "site-monitor-http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.lb.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.web.id
}

# --- HTTPS ----------------------------------------------------------------
locals {
  # sslip.io : 34.1.2.3 → 34-1-2-3.sslip.io (DNS automatique, sans domaine à acheter)
  domain = "${replace(google_compute_global_address.lb.address, ".", "-")}.sslip.io"
}

# Certificat géré par Google : émis et renouvelé automatiquement
resource "google_compute_managed_ssl_certificate" "web" {
  name = "site-monitor-cert"

  managed {
    domains = [local.domain]
  }
}

# Politique TLS : TLS 1.2 minimum, uniquement des chiffrements modernes
resource "google_compute_ssl_policy" "modern" {
  name            = "site-monitor-tls"
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
}

resource "google_compute_target_https_proxy" "web" {
  name             = "site-monitor-https-proxy"
  url_map          = google_compute_url_map.web.id
  ssl_certificates = [google_compute_managed_ssl_certificate.web.id]
  ssl_policy       = google_compute_ssl_policy.modern.id
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "site-monitor-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.lb.id
  port_range            = "443"
  target                = google_compute_target_https_proxy.web.id
}

# Port 80 : redirige toute requête HTTP vers HTTPS (code 301)
resource "google_compute_url_map" "https_redirect" {
  name = "site-monitor-https-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}
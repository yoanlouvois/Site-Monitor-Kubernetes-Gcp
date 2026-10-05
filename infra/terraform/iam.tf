# Identité des VM du cluster.
resource "google_service_account" "nodes" {
  account_id   = "k8s-nodes"
  display_name = "Noeuds Kubernetes site-monitor"
  description  = "Identite des VM du cluster kubeadm (moindre privilege)"

  depends_on = [google_project_service.apis]
}
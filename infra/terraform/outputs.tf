output "vpc" {
  value = google_compute_network.vpc.name
}

output "subnet_cidr" {
  value = google_compute_subnetwork.nodes.ip_cidr_range
}

output "nodes" {
  description = "IP internes des nœuds"
  value = {
    for name, vm in google_compute_instance.nodes :
    name => vm.network_interface[0].network_ip
  }
}

output "ssh_commands" {
  description = "Se connecter à un nœud via IAP"
  value = {
    for name, vm in google_compute_instance.nodes :
    name => "gcloud compute ssh ${name} --zone ${var.zone} --tunnel-through-iap"
  }
}

output "registry" {
  description = "Préfixe des images dans Artifact Registry"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}
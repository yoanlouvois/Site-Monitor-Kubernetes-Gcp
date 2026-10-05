# Identité des VM du cluster.
resource "google_service_account" "nodes" {
  account_id   = "k8s-nodes"
  display_name = "Noeuds Kubernetes site-monitor"
  description  = "Identite des VM du cluster kubeadm (moindre privilege)"

  depends_on = [google_project_service.apis]
}

# --- Driver CSI Persistent Disk --------------------------------------
# Identité du contrôleur CSI : crée, attache, détache et supprime les disques.
resource "google_service_account" "pd_csi" {
  account_id   = "pd-csi-driver"
  display_name = "Driver CSI Persistent Disk"
  description  = "Controleur CSI : gestion des disques persistants du cluster"

  depends_on = [google_project_service.apis]
}

# Attacher et détacher des disques aux VM, et lire leurs informations
resource "google_project_iam_custom_role" "pd_csi_attach" {
  role_id     = "pdCsiDriverAttach"
  title       = "PD CSI driver - attachement des disques"
  description = "Permissions minimales pour attacher et detacher les disques"
  permissions = [
    "compute.instances.get",
    "compute.instances.attachDisk",
    "compute.instances.detachDisk",
  ]
}

resource "google_project_iam_member" "pd_csi_attach" {
  project = var.project_id
  role    = google_project_iam_custom_role.pd_csi_attach.id
  member  = google_service_account.pd_csi.member
}

# Créer, lister et supprimer les disques
resource "google_project_iam_member" "pd_csi_storage" {
  project = var.project_id
  role    = "roles/compute.storageAdmin"
  member  = google_service_account.pd_csi.member
}

# Attacher un disque à une VM qui tourne sous k8s-nodes exige le droit
# d'"agir en tant que" ce compte, donné sur CE compte uniquement
resource "google_service_account_iam_member" "pd_csi_act_as_nodes" {
  service_account_id = google_service_account.nodes.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.pd_csi.member
}
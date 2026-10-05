variable "project_id" {
  description = "Identifiant du projet GCP"
  type        = string
}

variable "region" {
  type    = string
  default = "europe-west9"
}

variable "zone" {
  type    = string
  default = "europe-west9-a"
}
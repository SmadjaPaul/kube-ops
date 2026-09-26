variable "cert_manager_version" {
  description = "Cert Manager Helm chart version"
  type        = string
  default     = "v1.19.2"
}

variable "external_secrets_version" {
  description = "External Secrets Operator Helm chart version"
  type        = string
  default     = "1.2.0"
}

variable "argocd_version" {
  description = "Argo CD Helm chart version"
  type        = string
  default     = "9.2.3"
}

variable "doppler_token" {
  description = "Doppler service token for the cluster External Secrets compatibility store"
  type        = string
  sensitive   = true

  validation {
    condition     = var.doppler_token != ""
    error_message = "Doppler token must be provided. Set the 'doppler_token' variable or TF_VAR_doppler_token environment variable."
  }
}

variable "git_repository_url" {
  description = "Git repository URL for ArgoCD ApplicationSets"
  type        = string
  default     = "https://github.com/theepicsaxguy/homelab.git"
}

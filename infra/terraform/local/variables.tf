variable "kubeconfig_path" {
  description = "Chemin du kubeconfig utilisé par Terraform."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Contexte kubeconfig du cluster k3s local."
  type        = string
  default     = "default"
}

variable "namespaces" {
  description = <<-EOT
    Namespaces du socle. `pod_security` = niveau Pod Security Admission appliqué (enforce) :
    restricted (le plus strict), baseline, ou privileged (aucune restriction).
    `quota` = null pour ne pas poser de ResourceQuota/LimitRange.
  EOT
  type = map(object({
    pod_security = string
    quota = optional(object({
      requests_cpu    = string
      requests_memory = string
      limits_cpu      = string
      limits_memory   = string
      pods            = number
    }))
  }))

  default = {
    # Applications : niveau restricted (non-root, pas de privilèges, seccomp RuntimeDefault)
    "plateforme-dev" = {
      pod_security = "restricted"
      quota = {
        requests_cpu = "500m", requests_memory = "768Mi"
        limits_cpu   = "2", limits_memory = "1536Mi", pods = 10
      }
    }
    "plateforme-prod" = {
      pod_security = "restricted"
      quota = {
        requests_cpu = "1", requests_memory = "1Gi"
        limits_cpu   = "3", limits_memory = "2Gi", pods = 15
      }
    }
    # Argo CD : baseline (ses pods ne satisfont pas tous le niveau restricted selon les versions)
    "argocd" = { pod_security = "baseline" }
    # Supervision : node-exporter a besoin de hostNetwork/hostPID → privileged, à isoler
    "monitoring" = { pod_security = "privileged" }
  }

  validation {
    condition = alltrue([
      for ns in values(var.namespaces) : contains(["restricted", "baseline", "privileged"], ns.pod_security)
    ])
    error_message = "pod_security doit valoir restricted, baseline ou privileged."
  }
}

# Socle Kubernetes du cluster local : namespaces, Pod Security Admission, quotas.
# Terraform gère la « plateforme » (ce qui change rarement) ; Helm/Argo CD gèrent les applications.

resource "kubernetes_namespace_v1" "this" {
  for_each = var.namespaces

  metadata {
    name = each.key
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      # Pod Security Admission : `enforce` rejette les pods non conformes ;
      # `warn` et `audit` signalent ce qui ne passerait pas le niveau restricted.
      "pod-security.kubernetes.io/enforce" = each.value.pod_security
      "pod-security.kubernetes.io/warn"    = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
    }
  }
}

locals {
  quotas = { for name, ns in var.namespaces : name => ns.quota if ns.quota != null }
}

# Plafond global par namespace : une application défaillante (fuite mémoire, boucle de
# réplication) ne peut pas affamer le reste du cluster sur une VM à 2 vCPU.
resource "kubernetes_resource_quota_v1" "this" {
  for_each = local.quotas

  metadata {
    name      = "quota"
    namespace = kubernetes_namespace_v1.this[each.key].metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"    = each.value.requests_cpu
      "requests.memory" = each.value.requests_memory
      "limits.cpu"      = each.value.limits_cpu
      "limits.memory"   = each.value.limits_memory
      "pods"            = each.value.pods
    }
  }
}

# Valeurs par défaut : un conteneur sans requests/limits en reçoit automatiquement
# (sinon il serait refusé par le ResourceQuota ci-dessus).
resource "kubernetes_limit_range_v1" "this" {
  for_each = local.quotas

  metadata {
    name      = "defaults"
    namespace = kubernetes_namespace_v1.this[each.key].metadata[0].name
  }

  spec {
    limit {
      type = "Container"
      default_request = {
        cpu    = "50m"
        memory = "64Mi"
      }
      default = {
        cpu    = "250m"
        memory = "256Mi"
      }
    }
  }
}

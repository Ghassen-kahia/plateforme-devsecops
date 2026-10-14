output "namespaces" {
  description = "Namespaces créés et niveau Pod Security appliqué."
  value       = { for name, ns in kubernetes_namespace_v1.this : name => ns.metadata[0].labels["pod-security.kubernetes.io/enforce"] }
}

# Fixture: Terraform creates the namespace and sets no Pod Security label.
resource "kubernetes_namespace" "gibson" {
  metadata {
    name = "gibson"
  }
  lifecycle {
    ignore_changes = [
      metadata[0].labels["pod-security.kubernetes.io/enforce"],
    ]
  }
}

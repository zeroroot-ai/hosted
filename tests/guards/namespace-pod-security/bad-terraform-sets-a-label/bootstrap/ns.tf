# Fixture: a second place sets a Pod Security label on gibson.
resource "kubernetes_namespace" "gibson" {
  metadata {
    name = "gibson"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

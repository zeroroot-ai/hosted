# A second pin as a helm_release literal. The guard must reject it.
resource "helm_release" "cilium" {
  name    = "cilium"
  chart   = "cilium"
  version = "1.19.0"
}

# The same version as the pin, and a release of a different chart. Both pass.
resource "helm_release" "cilium" {
  name    = "cilium"
  chart   = "cilium"
  version = "1.20.2"
}

resource "helm_release" "other" {
  name    = "other"
  chart   = "other"
  version = "0.1.0"
}

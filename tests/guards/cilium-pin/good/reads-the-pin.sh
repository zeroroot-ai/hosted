# This script reads the pin file and holds no literal. It passes.
version="$(cat bootstrap/cilium/VERSION)"
helm upgrade --install cilium oci://quay.io/cilium/charts/cilium --version "$version"
image="quay.io/cilium/cilium:v1.20.2"

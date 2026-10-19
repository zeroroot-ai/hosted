helm upgrade --install toolhive-operator \
  oci://ghcr.io/stacklok/toolhive/toolhive-operator \
  --namespace toolhive-system --version "$TOOLHIVE_VERSION" \
  --values "$REPO/bootstrap/toolhive/values.yaml" \
  --wait --timeout 10m

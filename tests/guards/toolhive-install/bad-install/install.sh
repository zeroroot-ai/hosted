helm upgrade --install toolhive-operator \
  oci://ghcr.io/stacklok/toolhive/toolhive-operator \
  --namespace toolhive-system --version "$TOOLHIVE_VERSION" \
  --wait --timeout 10m
echo --values "$REPO/bootstrap/toolhive/values.yaml"

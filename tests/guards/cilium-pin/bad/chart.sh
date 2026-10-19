# A second pin as a chart version. The guard must reject it.
helm upgrade --install cilium oci://quay.io/cilium/charts/cilium --version 1.19.0

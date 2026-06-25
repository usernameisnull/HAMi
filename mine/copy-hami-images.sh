#!/usr/bin/env bash
set -euo pipefail
# 拷贝镜像到本地私有镜像仓库

# Target private HTTP registry
DEST_REGISTRY="10.6.178.191:5000"

# Allow insecure HTTP registry for regctl
regctl registry set "${DEST_REGISTRY}" --tls=disabled

# Required images for HAMi v2.9.0 on Kubernetes v1.30.14
# format: "source_image:tag destination_repo"
# registry.cn-hangzhou.aliyuncs.com/google_containers/kube-scheduler:v1.30.14有问题, 用原始的registry.k8s.io/kube-scheduler:v1.30.14替代
declare -a IMAGES=(
  "docker.io/projecthami/hami:v2.9.0 projecthami/hami"
  "docker.io/liangjw/kube-webhook-certgen:v1.1.1 liangjw/kube-webhook-certgen"
  "registry.k8s.io/kube-scheduler:v1.30.14 google_containers/kube-scheduler"
)

# Optional: uncomment if needed
# IMAGES+=(
#   "docker.io/projecthami/mock-device-plugin:1.0.1 projecthami/mock-device-plugin"
#   "ghcr.io/project-hami/k8s-dra-driver:main project-hami/k8s-dra-driver"
# )

FAILED=()

for entry in "${IMAGES[@]}"; do
  src="${entry%% *}"
  repo="${entry##* }"
  dest="${DEST_REGISTRY}/${repo}:${src##*:}"

  echo "==> Copying ${src} -> ${dest}"
  if regctl image copy --platform linux/amd64 "${src}" "${dest}"; then
    echo "    OK: ${dest}"
  else
    echo "    FAILED: ${src}"
    FAILED+=("${src}")
  fi
done

echo ""
echo "=========================================="
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "All images copied successfully."
else
  echo "Failed images:"
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi

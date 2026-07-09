# HAMi 安装与使用问答整理

## 1. HAMi 是什么

HAMi（Heterogeneous AI Computing Virtualization Middleware，异构 AI 计算虚拟化中间件）是一个 CNCF Sandbox 项目，提供 Kubernetes 环境下异构 AI 加速器（GPU、NPU、DCU、MLU 等）的虚拟化、共享、隔离和调度能力。

核心能力：

- **设备共享**：按显存、核心数或设备数量分配物理加速器的一部分。
- **资源隔离**：在支持的硬件后端上限制每个工作负载的显存和算力。
- **设备感知调度**：支持 binpack、spread、拓扑感知调度、动态 MIG 等策略。
- **异构集群管理**：统一管理 NVIDIA、昇腾、寒武纪、海光、天数智芯、沐曦、摩尔线程等加速器。
- **零应用改造**：使用标准 Kubernetes `resources.requests/limits`。

---

## 2. 代码模块主要作用

### `cmd/` — 可执行程序入口

| 目录 | 作用 |
|------|------|
| `cmd/scheduler/` | 调度器扩展（Scheduler Extender），扩展 kube-scheduler 的设备感知过滤、打分、绑定逻辑 |
| `cmd/device-plugin/` | 设备插件，向 kubelet 注册 vGPU 资源 |
| `cmd/vGPUmonitor/` | vGPU 监控器，监控容器 GPU 使用并执行资源限制 |

### `pkg/` — 核心库

| 目录 | 作用 |
|------|------|
| `pkg/device/` | 设备抽象层，每个子目录对应一个厂商后端（nvidia、ascend、cambricon、hygon 等） |
| `pkg/scheduler/` | 调度器扩展逻辑、节点过滤、打分、Webhook 处理 |
| `pkg/scheduler/policy/` | 调度策略：binpack、spread、节点级打分 |
| `pkg/device-plugin/` | NVIDIA Device Plugin 内部实现 |
| `pkg/monitor/` | 监控逻辑 |
| `pkg/metrics/` | Prometheus 指标 |
| `pkg/util/` | K8s 客户端、节点锁、Leader 选举等共享工具 |

### 其他目录

| 目录 | 作用 |
|------|------|
| `libvgpu/` | 容器内 vGPU 虚拟化库 |
| `charts/hami/` | Helm Chart |
| `docker/` | Dockerfile 与启动脚本 |
| `examples/` | 各厂商使用示例 |
| `hack/` | 构建、测试、静态检查脚本 |
| `test/` | 单元测试与 E2E 测试 |

---

## 3. 什么是 Device Plugin

**Device Plugin** 是 Kubernetes 提供的标准扩展机制，让第三方把节点上的特殊硬件资源（GPU、FPGA 等）暴露给 Pod。

HAMi 重新实现了 Device Plugin，实现更细粒度的资源抽象：

- 把物理 GPU 虚拟成多个 vGPU。
- 向 kubelet 注册 `nvidia.com/gpu` 等资源。
- 通过自定义资源（如 `nvidia.com/gpumem`、`nvidia.com/gpucores`）表达显存和算力需求。
- `Allocate()` 时读取 scheduler 写入 Pod annotations 的分配结果，注入容器环境变量和挂载。

**注意**：HAMi 必须使用自己的 Device Plugin，官方 NVIDIA Device Plugin 只支持整卡分配，不兼容 HAMi 的切片和共享机制。

---

## 4. 安装 HAMi 是否必须有 GPU

| 场景 | 是否需要 GPU |
|------|-------------|
| 安装 HAMi 控制面 | 不需要 |
| 实际分配/调度 GPU 工作负载 | 需要至少一个带 GPU 且已打标签的节点 |

没有 GPU 时，HAMi 的 scheduler、webhook 仍能运行，但 GPU Pod 会一直处于 Pending。

---

## 5. 节点上是否需要安装驱动

**是的**，必须在 GPU 节点上预装对应硬件的驱动和相关软件栈：

1. **硬件驱动**：如 NVIDIA driver >= 440、昇腾 NPU driver + CANN、寒武纪 CNML/CNRT 等。
2. **容器运行时配置**：NVIDIA 路径需要 `nvidia-docker` 2.0+ 并配置为 containerd/Docker/CRI-O 默认 runtime。
3. **节点标签**：`kubectl label nodes <gpu-node> gpu=on`。

HAMi 不替代驱动，它是在驱动和容器 GPU 支持已就绪的基础上做虚拟化、调度和隔离。

---

## 6. Helm 安装步骤

### 前置条件

- Kubernetes >= 1.23
- Helm >= 3.0
- GPU 节点已安装驱动和容器运行时

### 安装

```bash
# 1. 给 GPU 节点打标签
kubectl label nodes <gpu-node-name> gpu=on

# 2. 添加仓库
helm repo add hami-charts https://project-hami.github.io/HAMi/
helm repo update

# 3. 安装
helm install hami hami-charts/hami -n kube-system

# 4. 验证
kubectl get pods -n kube-system | grep hami
kubectl describe node <gpu-node> | grep nvidia.com/gpu
```

### 常用自定义配置

```bash
helm install hami hami-charts/hami -n kube-system \
  --set scheduler.defaultSchedulerPolicy.gpuSchedulerPolicy=binpack \
  --set devicePlugin.deviceSplitCount=10
```

---

## 7. 安装超时：timed out waiting for the condition

### 原因

通常是 pre-install hook（为 webhook 生成 TLS 证书的 Job）执行失败。

最常见原因：

- `docker.io/liangjw/kube-webhook-certgen:v1.1.1` 镜像拉取失败（国内网络问题）。
- 节点没有 `gpu=on` 标签时，Device Plugin 不会创建 Pod，但 pre-install hook 与标签无关。

### 排查

```bash
kubectl get pods -n hami -o wide
kubectl describe pod -n hami -l app.kubernetes.io/component=admission-webhook
```

### 解决方案

#### 方案 A：替换为国内/私有镜像

```yaml
scheduler:
  patch:
    imageNew:
      registry: "your-registry.com"
      repository: "kube-webhook-certgen"
      tag: "v1.1.1"
```

#### 方案 B：使用 cert-manager

```yaml
scheduler:
  certManager:
    enabled: true
  patch:
    enabled: false
```

#### 方案 C：手动导入镜像到节点

```bash
# 在外网机器下载
docker pull liangjw/kube-webhook-certgen:v1.1.1
docker save liangjw/kube-webhook-certgen:v1.1.1 -o certgen.tar

# 拷贝到每个节点并导入
ctr -n k8s.io images import certgen.tar
```

---

## 8. HAMi 镜像清单与私有仓库配置

### 默认镜像清单（v2.9.0，K8s v1.30.14）

| 组件 | 默认镜像 |
|------|----------|
| scheduler extender | `docker.io/projecthami/hami:v2.9.0` |
| device plugin | `docker.io/projecthami/hami:v2.9.0` |
| vGPU monitor | `docker.io/projecthami/hami:v2.9.0` |
| webhook certgen (K8s >= 1.22) | `docker.io/liangjw/kube-webhook-certgen:v1.1.1` |
| kube-scheduler sidecar | `registry.cn-hangzhou.aliyuncs.com/google_containers/kube-scheduler:v1.30.14` |
| mock device plugin（可选） | `docker.io/projecthami/mock-device-plugin:1.0.1` |
| DRA driver（可选） | `ghcr.io/project-hami/k8s-dra-driver:main` |

### 统一指定 Registry

```yaml
global:
  imageRegistry: "10.6.178.191:5000"
  imagePullSecrets:
    - my-registry-secret
```

`global.imageRegistry` 会替换所有镜像的 registry 前缀。

---

## 9. 使用 regctl 同步镜像到私有 HTTP 仓库

脚本已保存为 `mine/copy-hami-images.sh`。

```bash
#!/usr/bin/env bash
set -euo pipefail

DEST_REGISTRY="10.6.178.191:5000"

# 允许 insecure HTTP registry
regctl registry set "${DEST_REGISTRY}" --tls=disabled

declare -a IMAGES=(
  "docker.io/projecthami/hami:v2.9.0 projecthami/hami"
  "docker.io/liangjw/kube-webhook-certgen:v1.1.1 liangjw/kube-webhook-certgen"
  "registry.cn-hangzhou.aliyuncs.com/google_containers/kube-scheduler:v1.30.14 google_containers/kube-scheduler"
)

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
```

### 安装时使用私有仓库

```yaml
global:
  imageRegistry: "10.6.178.191:5000"
```

```bash
helm install hami hami-charts/hami -n hami -f values.yaml
```

---

## 10. 安装后只有 scheduler Pod

HAMi 默认包含：

- `hami-scheduler` Deployment：1 个 Pod。
- `hami-device-plugin` DaemonSet：每个 `gpu=on` 节点 1 个 Pod。

如果只看到 scheduler，通常是**节点没有打 `gpu=on` 标签**。

### 排查

```bash
# 检查节点标签
kubectl get nodes --show-labels | grep gpu

# 检查 DaemonSet
kubectl get ds -n hami

# 查看事件
kubectl get events -n hami --sort-by='.lastTimestamp'
```

### 修复

```bash
kubectl label nodes <gpu-node-name> gpu=on
```

打完标签后，Device Plugin DaemonSet 会自动创建 Pod。

如果 Device Plugin Pod 仍失败，检查镜像拉取：

```bash
kubectl describe pod -n hami -l app.kubernetes.io/component=device-plugin
```

---

## 11. HAMi 注册了哪些 Device Plugin 资源

HAMi 注册的资源因硬件后端而异。下面是 v2.9.0 默认注册的资源名。

### NVIDIA GPU

| 资源名 | 含义 |
|--------|------|
| `nvidia.com/gpu` | GPU 卡数（物理卡数量） |
| `nvidia.com/gpumem` | 显存配额（MiB） |
| `nvidia.com/gpumem-percentage` | 显存百分比 |
| `nvidia.com/gpucores` | 算力核心配额 |
| `nvidia.com/priority` | 调度优先级 |

### 昇腾 Ascend NPU

- `huawei.com/Ascend910A`、`huawei.com/Ascend910A-memory`、`huawei.com/Ascend910A-core`
- `huawei.com/Ascend910B2` / `B3` / `B4` / `B4-1` 及对应 memory/core
- `huawei.com/Ascend310P`
- `huawei.com/Ascend910C`

### 其他厂商

| 厂商 | 资源名 |
|------|--------|
| 寒武纪 MLU | `cambricon.com/vmlu`、`cambricon.com/mlu.smlu.vmemory`、`cambricon.com/mlu.smlu.vcore` |
| 海光 DCU | `hygon.com/dcunum`、`hygon.com/dcumem`、`hygon.com/dcucores` |
| 沐曦 MetaX | `metax-tech.com/sgpu`、`metax-tech.com/vcore`、`metax-tech.com/vmemory` |
| 燧原 Enflame | `enflame.com/drs-gcu`、`enflame.com/gcu-memory`、`enflame.com/gcu-core`、`enflame.com/gcu` |
| 昆仑芯 Kunlun | `kunlunxin.com/xpu`、`kunlunxin.com/vxpu`、`kunlunxin.com/vxpu-memory` |
| 天数智芯 Iluvatar | `iluvatar.ai/BI-V100-vgpu` / `.vCore` / `.vMem` 等 |
| AMD | `amd.com/gpu`、`amd.com/gpu-memory` |
| AWS Neuron | `aws.amazon.com/neuron`、`aws.amazon.com/neuroncore` |
| 摩尔线程 Mthreads | `mthreads.com/vgpu` |
| 壁仞 Biren | `birentech.com/gpu` |
| Vastai | `vastaitech.com/va` |

### 查看节点上注册的资源

```bash
kubectl describe node <node-name> | grep -E "nvidia.com|huawei.com|cambricon.com|hygon.com"
```

---

## 12. Device Plugin 具体是怎么实现的

HAMi 的 Device Plugin 基于 NVIDIA 官方 k8s-device-plugin 改造，位于 `pkg/device-plugin/nvidiadevice/` 和 `cmd/device-plugin/nvidia/`。

### 实现的标准接口

| 接口 | 作用 |
|------|------|
| `Register()` | 向 kubelet 注册资源名（如 `nvidia.com/gpu`） |
| `ListAndWatch()` | 通过 NVML 发现 GPU 并持续上报设备列表和健康状态 |
| `GetDevicePluginOptions()` | 声明支持 `GetPreferredAllocation` |
| `GetPreferredAllocation()` | 读取 Pod annotations 中 scheduler 的调度结果，建议 kubelet 选择对应设备 |
| `Allocate()` | 核心：为容器生成环境变量、挂载点、设备路径 |

### Allocate 核心流程

```text
1. 获取当前 Pending Pod
2. 从 Pod annotations 解析 scheduler 分配的设备 UUID、显存、核心
3. 生成基础响应：NVIDIA_VISIBLE_DEVICES、设备路径等
4. 注入 HAMi 限制环境变量：
   - CUDA_DEVICE_MEMORY_LIMIT_0=3000m
   - CUDA_DEVICE_SM_LIMIT=50
   - CUDA_DEVICE_MEMORY_SHARED_CACHE=...
5. 挂载容器内隔离库：
   - /usr/local/vgpu/libvgpu.so
   - /etc/ld.so.preload
   - /usr/local/vgpu/containers/<PodUID>_<ContainerName>/
```

### 与 Scheduler 的协作

Device Plugin **不自己做调度决策**，只执行 scheduler 的决策：

1. Scheduler 根据策略选择设备。
2. Scheduler 把结果写入 `hami.io/nvidia-devices-to-allocate`。
3. kubelet 调用 `Allocate()`。
4. Device Plugin 读取 annotations 并注入容器。

### 关键设计特点

- **vGPU 共享**：scheduler 切片，Device Plugin 注入限制。
- **硬隔离**：通过 `libvgpu.so` 拦截 CUDA 调用。
- **MIG 支持**：operatingMode = `mig` 时按 MIG 设备分配。
- **MPS 支持**：operatingMode = `mps` 时使用 CUDA MPS。
- **显存超售**：通过 `deviceMemoryScaling` 缩放上报显存。

---

## 13. cmd/vGPUmonitor 目录代码是做什么的

`cmd/vGPUmonitor/` 是 HAMi 的 **vGPU 监控与反馈控制组件**，以 DaemonSet 运行在 GPU 节点上。

### 主要职责

1. **采集容器 GPU 使用指标**
2. **暴露 Prometheus 指标**
3. **执行运行时反馈控制**（优先级抢占、利用率控制）

### 文件组成

| 文件 | 作用 |
|------|------|
| `main.go` | 入口，启动 metrics HTTP 服务和监控反馈循环 |
| `metrics.go` | 定义和暴露 Prometheus 指标 |
| `feedback.go` | 核心反馈控制逻辑 |
| `validation.go` | 校验必要环境变量 |

### 核心机制：共享内存监控

HAMi 容器内的 `libvgpu.so` 会把每个容器的 GPU 使用情况写入宿主机上的共享内存文件：

```text
/usr/local/vgpu/containers/<PodUID>_<ContainerName>/...
```

`vGPUmonitor` 通过 mmap 读取这些共享内存，获取每个容器的实时 GPU 使用数据。数据结构定义在 `pkg/monitor/nvidia/v1/spec.go`。

### 暴露的主要指标

- `hami_host_gpu_memory_used_bytes` — 物理 GPU 显存使用
- `hami_host_gpu_utilization_ratio` — 物理 GPU 利用率
- `hami_vgpu_memory_used_bytes` — 容器 vGPU 显存使用
- `hami_vgpu_memory_limit_bytes` — 容器 vGPU 显存限制
- `hami_container_device_utilization_ratio` — 容器 SM 利用率
- `hami_container_last_kernel_elapsed_seconds` — 容器最近 kernel 执行时间
- `hami_vgpu_memory_context_bytes` / `module_bytes` / `buffer_bytes`

### 反馈控制

`feedback.go` 通过 NVML 获取物理 GPU 上正在运行的进程 PID，结合容器共享内存中的优先级和利用率信息：

- 当高优先级容器需要 GPU 时，暂停或限流低优先级容器的 CUDA 调用。
- 实现 GPU 资源的公平共享和优先级抢占。

### 与 Device Plugin 的关系

| 组件 | 职责 |
|------|------|
| **Device Plugin** | Pod 启动时分配 GPU，注入 `libvgpu.so` 和环境变量 |
| **vGPUmonitor** | Pod 运行后持续监控使用情况，暴露指标，执行动态控制 |

简单说：**Device Plugin 负责“分配 GPU”，vGPUmonitor 负责“盯着怎么用，并在必要时限制”。**

---

## 14. HAMi 是怎么打包编译出镜像的

HAMi 镜像打包分两部分：**Go 二进制编译** 和 **Docker 多阶段镜像构建**。

### Go 二进制编译

`version.mk` 定义了构建目标：

```makefile
CMDS=scheduler vGPUmonitor
DEVICES=nvidia
OUTPUT_DIR=bin
```

默认编译出：

- `bin/scheduler`
- `bin/vGPUmonitor`
- `bin/nvidia-device-plugin`

编译命令：

```bash
make all VERSION=v2.9.0
```

实际执行的 Go 编译会注入版本信息：

```bash
go build -ldflags '-s -w \
  -X github.com/Project-HAMi/HAMi/pkg/version.version=v2.9.0 \
  -X github.com/Project-HAMi/HAMi/pkg/version.revision=<git-sha> \
  -X github.com/Project-HAMi/HAMi/pkg/version.buildDate=...' \
  -o bin/scheduler ./cmd/scheduler
```

### Docker 多阶段构建

主要 Dockerfile：`docker/Dockerfile`，分 3 个阶段：

```dockerfile
# 阶段 1：Go 编译
FROM golang:1.26.2-bookworm AS gobuild
ADD . /k8s-vgpu
RUN cd /k8s-vgpu && make all VERSION=$VERSION
RUN go install github.com/NVIDIA/mig-parted/cmd/nvidia-mig-parted@v0.12.2

# 阶段 2：编译 libvgpu.so（C/C++ 隔离库）
FROM nvidia/cuda:12.9.1-cudnn-devel-ubuntu20.04 AS nvbuild
COPY ./libvgpu /libvgpu
RUN apt-get install cmake git
RUN bash ./build.sh

# 阶段 3：运行镜像
FROM nvidia/cuda:13.3.0-base-ubuntu22.04
COPY --from=gobuild /k8s-vgpu/bin /k8s-vgpu/bin
COPY --from=nvbuild /libvgpu/build/libvgpu.so /k8s-vgpu/lib/nvidia/libvgpu.so.$VERSION
COPY ./docker/entrypoint.sh /k8s-vgpu/bin/entrypoint.sh
COPY ./docker/vgpu-init.sh /k8s-vgpu/bin/vgpu-init.sh
COPY ./lib /k8s-vgpu/lib
ENV PATH="/k8s-vgpu/bin:${PATH}"
ENTRYPOINT ["/bin/bash", "-c", "entrypoint.sh $DEST_DIR"]
```

构建命令：

```bash
make docker VERSION=v2.9.0
```

### 其他 Dockerfile

| Dockerfile | 用途 |
|-----------|------|
| `Dockerfile.hamicore` | 只编译 `libvgpu.so` |
| `Dockerfile.hamimaster` | 接受预构建 hami-core 镜像，只编译 Go 二进制 |
| `Dockerfile.withlib` | 接受预编译 `libvgpu.so` 文件 |

### 镜像里包含什么

```text
/k8s-vgpu/
├── bin/
│   ├── scheduler
│   ├── vGPUmonitor
│   ├── nvidia-device-plugin
│   ├── nvidia-mig-parted
│   ├── entrypoint.sh
│   └── vgpu-init.sh
├── lib/
│   └── nvidia/
│       ├── libvgpu.so.v2.9.0
│       └── ...
└── LICENSE
```

### `vgpu-init.sh` 的作用

Device Plugin 容器启动时通过 `postStart` 钩子执行：

```bash
/k8s-vgpu/bin/vgpu-init.sh /usr/local/vgpu/
```

它把镜像里的 `/k8s-vgpu/lib/nvidia/` 下的库文件按 MD5 比较后同步到宿主机 `/usr/local/vgpu/`，后续 Allocate 时再挂载到业务容器。

---

## 15. 其实只打出了一个镜像？

是的，**HAMi 自己最终只打出了一个运行时镜像**：`projecthami/hami`。

### 多阶段构建 ≠ 多个最终镜像

`docker/Dockerfile` 虽然有多个 `FROM`，但只有最后一个 `FROM` 是最终镜像。前面阶段（gobuild、nvbuild）只是中间产物。

### 一个镜像跑多个组件

HAMi 的 scheduler extender、device plugin、vGPU monitor 都**共用同一个 `projecthami/hami` 镜像**，只是启动命令不同：

| Pod | 容器 | 镜像 | 启动命令 |
|-----|------|------|---------|
| hami-scheduler | kube-scheduler | `google_containers/kube-scheduler:v1.30.14` | `kube-scheduler` |
| hami-scheduler | vgpu-scheduler-extender | `projecthami/hami:v2.9.0` | `scheduler` |
| hami-device-plugin | device-plugin | `projecthami/hami:v2.9.0` | `nvidia-device-plugin` |
| hami-device-plugin | vgpu-monitor | `projecthami/hami:v2.9.0` | `vGPUmonitor` |

### 为什么其他 Dockerfile 存在

`Dockerfile.hamicore`、`Dockerfile.hamimaster`、`Dockerfile.withlib` 是为了**拆分构建过程**、加速 CI/CD，不是为了产出多个最终镜像。例如：

- `libvgpu.so` 编译慢，可以单独构建一次后复用。
- Go 代码改动频繁，可以只重新编译 Go 部分。

### 总结

- **HAMi 发布的镜像只有 1 个**：`projecthami/hami`。
- **额外引用的镜像**：scheduler Pod 里的 kube-scheduler 容器使用 Kubernetes 官方镜像。
- 执行 `make docker` 只会生成一个最终镜像，这是正常的。

---

## 16. HAMi Scheduler 与 Webhook

HAMi 的调度核心由 Scheduler Extender 和 Mutating Webhook 组成。这部分内容较多，已单独整理到：

**[mine/hami-scheduler-webhook.md](./hami-scheduler-webhook.md)**

该文档包含：

- 为什么最终部署需要官方 kube-scheduler
- Scheduler Extender 是否影响集群默认 scheduler
- Scheduler Extender vs Scheduler Framework
- Scheduler Extender 的具体代码实现
- Mutating Webhook 的位置、拦截对象和修改内容



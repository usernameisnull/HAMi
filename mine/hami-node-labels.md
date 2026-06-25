# HAMi 节点标签（Node Label）要求

HAMi 通过 Kubernetes 节点标签来决定在哪些节点上部署 Device Plugin DaemonSet。如果标签不匹配，Device Plugin 不会创建 Pod，GPU/NPU 资源也不会被注册到集群中。

---

## 为什么需要节点标签

HAMi 的核心组件包括：

- **scheduler**：Deployment，运行在控制面节点，负责设备感知调度。
- **device-plugin**：DaemonSet，只在有 GPU/NPU 的节点上运行，向 kubelet 注册加速器资源。
- **vgpu-monitor**：通常和 device-plugin 同 Pod，负责容器内监控和隔离。

scheduler 是全局部署的，但 **device-plugin 是 DaemonSet，必须匹配 nodeSelector 才会在节点上创建 Pod**。因此，安装 HAMi 之前，必须给加速器节点打上正确的标签。

---

## 默认标签要求

### NVIDIA GPU 节点（最常用）

**必须**给 NVIDIA GPU 节点打上标签：

```bash
kubectl label nodes <gpu-node-name> gpu=on
```

HAMi 默认的 NVIDIA Device Plugin DaemonSet 使用 `gpu=on` 作为 nodeSelector：

```yaml
# charts/hami/values.yaml
devicePlugin:
  nvidiaNodeSelector:
    gpu: "on"
```

如果没有这个标签，Device Plugin 不会部署，节点也不会注册 `nvidia.com/gpu` 资源。

---

## 重点：可以单独设置 `nvidiaNodeSelector`

HAMi 允许你完全自定义 NVIDIA Device Plugin 的节点选择器。**你不一定非要用 `gpu=on`**，可以根据自己集群的规范修改。

### 示例 1：使用自定义标签

假设你想用 `accelerator=nvidia` 来标识 GPU 节点：

```yaml
# values.yaml
devicePlugin:
  nvidiaNodeSelector:
    accelerator: nvidia
```

给节点打标签：

```bash
kubectl label nodes <gpu-node-name> accelerator=nvidia
```

然后安装 HAMi：

```bash
helm install hami hami-charts/hami -n hami -f values.yaml
```

### 示例 2：结合多个标签

你也可以要求节点同时满足多个条件：

```yaml
devicePlugin:
  nvidiaNodeSelector:
    accelerator: nvidia
    gpu-ready: "true"
```

节点需要同时有这两个标签：

```bash
kubectl label nodes <gpu-node-name> accelerator=nvidia gpu-ready=true
```

### 示例 3：不设置 nodeSelector（在所有节点部署）

如果你把 `nvidiaNodeSelector` 留空，Device Plugin 会尝试在所有节点上运行：

```yaml
devicePlugin:
  nvidiaNodeSelector: {}
```

> **注意**：不建议这样做。没有 GPU 的节点上，Device Plugin Pod 会运行但注册 0 个设备，浪费资源且可能产生噪音日志。

---

## 昇腾 NPU 节点

如果启用了昇腾设备支持，默认使用 `ascend=on` 标签：

```yaml
# values.yaml
devices:
  ascend:
    enabled: true
    nodeSelector:
      ascend: "on"
```

给昇腾节点打标签：

```bash
kubectl label nodes <ascend-node-name> ascend=on
```

---

## 其他厂商

寒武纪、海光、天数智芯、沐曦、摩尔线程等厂商默认没有在 values.yaml 中配置 nodeSelector。Device Plugin 可能会部署到所有节点。

如果你只想在特定节点部署，可以手动修改对应 DaemonSet 的 nodeSelector，或者在 Helm 安装时为相关组件配置。

---

## Webhook 排除标签

HAMi 的 Mutating Webhook 默认会跳过带有以下标签的 Pod：

```yaml
hami.io/webhook: ignore
```

HAMi 自己的组件 Pod 会自动带上这个标签，避免被 webhook 重复处理。

如果你想让某个命名空间不受 HAMi webhook 影响：

```bash
kubectl label namespace <namespace-name> hami.io/webhook=ignore
```

---

## 排查命令

### 查看节点标签

```bash
kubectl get nodes --show-labels
```

只看 GPU 相关标签：

```bash
kubectl get nodes --show-labels | grep -E "gpu|ascend|accelerator"
```

### 查看 Device Plugin DaemonSet 状态

```bash
kubectl get ds -n hami
```

如果 `DESIRED=0`，说明没有节点匹配 nodeSelector，需要检查标签。

### 查看 Device Plugin 的 nodeSelector

```bash
kubectl get ds -n hami hami-device-plugin -o yaml | grep -A 5 nodeSelector
```

### 查看节点上注册的资源

```bash
kubectl describe node <node-name> | grep -E "nvidia.com/gpu|huawei.com/Ascend"
```

---

## 总结

| 硬件类型 | 默认节点标签 | 可配置项 | 说明 |
|---------|-------------|---------|------|
| **NVIDIA GPU** | `gpu=on` | `devicePlugin.nvidiaNodeSelector` | **重点：可以自定义为任意标签** |
| **昇腾 NPU** | `ascend=on` | `devices.ascend.nodeSelector` | 启用 ascend 时需要 |
| **其他厂商** | 无默认 | 需手动配置 | 默认可能部署到所有节点 |
| **Webhook 排除** | `hami.io/webhook=ignore` | 不可改 | 用于跳过 webhook 注入 |

**核心要点**：NVIDIA GPU 节点必须打标签，但标签名不一定是 `gpu=on`，可以通过 `devicePlugin.nvidiaNodeSelector` 自定义为任何你集群里已有的标签规范。

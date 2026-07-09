# HAMi Scheduler 与 Webhook 详解

HAMi 的调度核心由两部分组成：

1. **Scheduler Extender**：负责 GPU 感知调度（过滤、打分、绑定）。
2. **Mutating Webhook**：负责在 Pod 创建时自动注入 `schedulerName` 和其他 GPU 相关配置。

---

## 1. 为什么最终部署需要官方 kube-scheduler

**HAMi 本身不是完整的 Kubernetes 调度器，它只是一个 Scheduler Extender**。

### Scheduler Extender 机制

Kubernetes Scheduler Extender 允许外部 HTTP 服务扩展 kube-scheduler 的调度决策。HAMi 的 scheduler 就是这个外部 HTTP 服务，只实现了三个接口：

| 接口 | 作用 |
|------|------|
| `/filter` | 过滤不满足 GPU 资源需求的节点 |
| `/score`（在 HAMi 的 `/filter` 里合并实现） | 对候选节点打分 |
| `/bind` | 把调度决策写入 Pod annotations 并调用 K8s Bind API |

HAMi **不负责完整调度流程**，比如 CPU/内存/存储/亲和性/污点/抢占等，仍然需要官方 kube-scheduler 处理。

### 为什么放在同一个 Pod

`hami-scheduler` Pod 里有两个容器：

```yaml
containers:
  - name: kube-scheduler
    image: google_containers/kube-scheduler:v1.30.14
    command: ["kube-scheduler", "--config=/config/config.yaml"]

  - name: vgpu-scheduler-extender
    image: projecthami/hami:v2.9.0
    command: ["scheduler", "--http_bind=0.0.0.0:443"]
```

放同一个 Pod 的好处：

1. **本地通信**：kube-scheduler 通过 `127.0.0.1:443` 访问 HAMi extender。
2. **独立部署**：不依赖集群默认 kube-scheduler 是否配置 extender。
3. **版本匹配**：使用与 K8s 集群版本一致的 kube-scheduler，避免 API 不兼容。
4. **共享 Leader Election**：两者共享 leader election 实现高可用。

### 能不能不用官方 kube-scheduler

可以，有两种替代方案：

#### 方案 A：接入集群默认 kube-scheduler

```yaml
scheduler:
  kubeScheduler:
    enabled: false
```

然后手动修改集群默认 kube-scheduler 配置，把 HAMi extender 加进去。但需要：

- 修改 K8s 控制面配置
- 协调 schedulerName
- 升级 kube-scheduler 时同步维护 extender 配置

#### 方案 B：使用 Volcano

HAMi 也支持集成 Volcano 调度器。

### 版本为什么和 K8s 一致

`kube-scheduler` 是 K8s 核心组件，API 和配置格式随版本变化。HAMi chart 会根据 K8s 版本自动选择：

- K8s >= 1.22：`kubescheduler.config.k8s.io/v1beta2` 或 `v1`
- K8s < 1.22：旧的 `Policy` API

---

## 2. Scheduler Extender 是否影响集群默认 scheduler

**不会**。HAMi 不修改集群默认的 kube-scheduler，也不会导致它重启。

### HAMi 的做法：部署独立的 scheduler Pod

HAMi 不是去修改集群原有的 kube-scheduler，而是**自己部署一个独立的 kube-scheduler + HAMi extender 组合 Pod**。

```text
集群默认 kube-scheduler（不改动，继续运行）
  ↑
  │  默认 Pod 仍然走这里
  │
HAMi 自己部署的 Pod: hami-scheduler-xxx
  ├─ 容器 1: kube-scheduler:v1.30.14   ← 官方镜像
  └─ 容器 2: HAMi scheduler extender   ← projecthami/hami
       ↑
       └─ 只有 schedulerName=hami-scheduler 的 Pod 才会被它处理
```

### 通过 `schedulerName` 区分

HAMi 自带的 kube-scheduler 使用独立的 scheduler name：

```yaml
# charts/hami/templates/scheduler/configmap.yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
profiles:
- schedulerName: hami-scheduler
extenders:
- urlPrefix: "https://127.0.0.1:443"
  filterVerb: filter
  bindVerb: bind
  managedResources:
  - nvidia.com/gpu
  - nvidia.com/gpumem
  - nvidia.com/gpucores
```

只有 `schedulerName: hami-scheduler` 的 Pod 才会被这个 scheduler 调度。

### Webhook 自动注入 schedulerName

用户提交 GPU Pod 时，通常不会手动写 `schedulerName`。HAMi 的 Mutating Webhook 会自动为请求 GPU 资源的 Pod 注入：

```yaml
spec:
  schedulerName: hami-scheduler
```

### 集群默认 scheduler 完全不受影响

| 方面 | 影响 |
|------|------|
| 默认 Pod | 仍然由集群默认 kube-scheduler 调度 |
| 集群默认 scheduler 配置 | **不需要修改** |
| 集群默认 scheduler 进程 | **不需要重启** |
| 高可用 | HAMi scheduler 自己通过 Leader Election 实现多副本 |

---

## 3. HAMi 用的是 Scheduler Extender 还是 Scheduler Framework

**HAMi 目前使用的是 Scheduler Extender，而不是 Scheduler Framework**。

### 代码证据

`pkg/scheduler/routes/route.go` 使用 Kubernetes 官方 Extender 结构体：

```go
import extenderv1 "k8s.io/kube-scheduler/extender/v1"

func PredicateRoute(s *scheduler.Scheduler) httprouter.Handle {
    var extenderArgs extenderv1.ExtenderArgs
    var extenderFilterResult *extenderv1.ExtenderFilterResult
    // ...
    extenderFilterResult, err = s.Filter(extenderArgs)
}

func Bind(s *scheduler.Scheduler) httprouter.Handle {
    var extenderBindingArgs extenderv1.ExtenderBindingArgs
    var extenderBindingResult *extenderv1.ExtenderBindingResult
    // ...
    extenderBindingResult, err = s.Bind(extenderBindingArgs)
}
```

`charts/hami/templates/scheduler/configmap.yaml` 中配置的是 kube-scheduler 的 `extenders`：

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
profiles:
- schedulerName: hami-scheduler
extenders:
- urlPrefix: "https://127.0.0.1:443"
  filterVerb: filter
  bindVerb: bind
  nodeCacheCapable: true
  weight: 1
  httpTimeout: 30s
  managedResources:
  - nvidia.com/gpu
  - nvidia.com/gpumem
  - nvidia.com/gpucores
```

### Extender vs Framework 对比

| 特性 | Scheduler Extender | Scheduler Framework |
|------|-------------------|---------------------|
| 位置 | 调度器外部独立进程 | 编译进 kube-scheduler |
| 通信 | HTTP/gRPC | 进程内函数调用 |
| 部署 | 单独部署 Pod | 需要定制 kube-scheduler |
| 性能 | 有网络延迟 | 更高 |
| 扩展点 | filter、score、bind | PreFilter、Filter、PostFilter、Score、Reserve、Permit、PreBind、Bind 等 |
| 版本依赖 | 通过 HTTP 解耦 | 强依赖 kube-scheduler 代码版本 |

### 为什么 HAMi 选择 Extender

1. **不需要重新编译 kube-scheduler**：HAMi 可以单独部署、升级、回滚。
2. **版本兼容性好**：同一个 extender 可对接多个 K8s 版本。
3. **独立维护调度状态**：HAMi 需要自己维护节点 GPU 状态、Pod 分配缓存、节点锁等。
4. **历史原因**：HAMi 前身诞生于 Scheduler Framework 还不成熟的 K8s 1.9 时代。

### 缺点

- 每次调度 GPU Pod 都有 HTTP 调用开销。
- 扩展点有限，无法干预 Reserve/Permit/PreBind 等阶段。
- 需要自己实现缓存同步和 Leader Election。

---

## 4. Scheduler Extender 的具体代码实现

### 核心文件

| 文件 | 作用 |
|------|------|
| `cmd/scheduler/main.go` | 启动 HTTP server，注册路由 |
| `pkg/scheduler/routes/route.go` | HTTP handler，解析 kube-scheduler 请求 |
| `pkg/scheduler/scheduler.go` | `Scheduler.Filter()`、`Scheduler.Bind()` 核心逻辑 |
| `pkg/scheduler/score.go` | `calcScore()` 节点打分 |
| `pkg/scheduler/policy/node_policy.go` | 节点级策略（binpack/spread） |
| `pkg/scheduler/policy/gpu_policy.go` | GPU 级策略 |
| `pkg/scheduler/nodes.go` | 节点状态管理 |

### HTTP Server 入口

**`cmd/scheduler/main.go`**

```go
sher = scheduler.NewScheduler()
go sher.RegisterFromNodeAnnotations()
err = sher.Start()

// 注册路由
router := httprouter.New()
router.POST("/filter", routes.PredicateRoute(sher))
router.POST("/bind", routes.Bind(sher))
router.POST("/webhook", routes.WebHookRoute())
router.GET("/healthz", routes.HealthzRoute())
router.GET("/readyz", routes.ReadyzRoute(sher))

// 启动 HTTP/HTTPS
if len(tlsCertFile) == 0 || len(tlsKeyFile) == 0 {
    http.ListenAndServe(config.HTTPBind, router)
} else {
    server.ListenAndServeTLS("", "")
}
```

### `/filter` Handler

**`pkg/scheduler/routes/route.go`**

```go
func PredicateRoute(s *scheduler.Scheduler) httprouter.Handle {
    return func(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
        var extenderArgs extenderv1.ExtenderArgs
        var extenderFilterResult *extenderv1.ExtenderFilterResult

        json.NewDecoder(r.Body).Decode(&extenderArgs)
        synced := s.WaitForCacheSync(r.Context())
        extenderFilterResult, err = s.Filter(extenderArgs)

        resultBody, _ := json.Marshal(extenderFilterResult)
        w.WriteHeader(http.StatusOK)
        w.Write(resultBody)
    }
}
```

### `Scheduler.Filter()`

**`pkg/scheduler/scheduler.go`**

```go
func (s *Scheduler) Filter(args extenderv1.ExtenderArgs) (*extenderv1.ExtenderFilterResult, error) {
    // 1. 解析 Pod 资源请求
    resourceReqs := device.Resourcereqs(args.Pod)

    // 2. 如果没有 GPU 请求，返回所有节点
    if resourceReqTotal == 0 {
        return &extenderv1.ExtenderFilterResult{
            NodeNames: args.NodeNames,
        }, nil
    }

    // 3. 获取候选节点设备使用情况
    nodeUsage, failedNodes, err := s.getNodesUsage(args.NodeNames, args.Pod)

    // 4. 计算节点打分
    nodeScores, err := s.calcScore(nodeUsage, resourceReqs, args.Pod, failedNodes)

    // 5. 选择最高分节点
    sort.Sort(nodeScores)
    m := (*nodeScores).NodeList[len((*nodeScores).NodeList)-1]

    // 6. 生成 annotations，记录调度结果
    annotations := make(map[string]string)
    annotations[util.AssignedNodeAnnotations] = m.NodeID
    annotations[util.AssignedTimeAnnotations] = strconv.FormatInt(time.Now().Unix(), 10)

    // 7. 各设备后端写入自己的分配注解
    for _, val := range device.GetDevices() {
        val.PatchAnnotations(args.Pod, &annotations, m.Devices)
    }

    // 8. 更新本地 Pod 管理器和配额
    s.podManager.AddPod(args.Pod, m.NodeID, m.Devices)
    s.quotaManager.AddUsage(args.Pod, m.Devices)

    // 9. Patch Pod annotations
    util.PatchPodAnnotations(args.Pod, annotations)

    // 10. 返回选中的节点
    return &extenderv1.ExtenderFilterResult{NodeNames: &[]string{m.NodeID}}, nil
}
```

### `Scheduler.Bind()`

**`pkg/scheduler/scheduler.go`**

```go
func (s *Scheduler) Bind(args extenderv1.ExtenderBindingArgs) (*extenderv1.ExtenderBindingResult, error) {
    // 1. 构造 Binding 对象
    binding := &corev1.Binding{
        ObjectMeta: metav1.ObjectMeta{Name: args.PodName, UID: args.PodUID},
        Target:     corev1.ObjectReference{Kind: "Node", Name: args.Node},
    }

    // 2. 获取 Pod 和 Node
    current, _ := s.podLister.Pods(args.PodNamespace).Get(args.PodName)
    node, _ := s.nodeLister.Get(args.Node)

    // 3. 加节点锁
    for _, val := range device.GetDevices() {
        val.LockNode(node, current)
    }

    // 4. Patch annotations 标记正在分配
    tmppatch := map[string]string{
        util.DeviceBindPhase:     "allocating",
        util.BindTimeAnnotations: strconv.FormatInt(time.Now().Unix(), 10),
    }
    util.PatchPodAnnotations(current, tmppatch)

    // 5. 调用 K8s API 绑定 Pod
    s.kubeClient.CoreV1().Pods(args.PodNamespace).Bind(context.Background(), binding, metav1.CreateOptions{})

    // 6. 成功
    return &extenderv1.ExtenderBindingResult{Error: ""}, nil
}
```

### 打分逻辑

**`pkg/scheduler/score.go`**

```go
func (s *Scheduler) calcScore(nodes *map[string]*NodeUsage, resourceReqs device.PodDeviceRequests, task *corev1.Pod, failedNodes map[string]string) (*policy.NodeScoreList, error) {
    for nodeID, node := range *nodes {
        // 1. 检查节点是否满足资源需求
        fit, err := val.Fit(...)
        if !fit {
            failedNodes[nodeID] = err.Error()
            continue
        }

        // 2. 设备打分
        score, err := val.ScoreNode(...)

        // 3. 节点级策略 + GPU 级策略
        nodeScore := policy.CalculateNodeScore(...)
        gpuScore := policy.CalculateGPUScore(...)

        // 4. 汇总
        totalScore := nodeScore + gpuScore + deviceScore
        nodeScores.NodeList = append(nodeScores.NodeList, &policy.NodeScore{
            NodeID:  nodeID,
            Score:   totalScore,
            Devices: devices,
        })
    }
    return &nodeScores, nil
}
```

### 完整调度数据流

```text
用户提交 Pod（请求 nvidia.com/gpu）
  ↓
kube-scheduler 初步过滤（CPU/内存/污点等）
  ↓
kube-scheduler POST /filter -> HAMi extender
  ↓
HAMi 解析资源请求 -> 获取节点设备状态 -> 打分
  ↓
返回最高分节点 + 写入 Pod annotations
  ↓
kube-scheduler 决定用该节点
  ↓
kube-scheduler POST /bind -> HAMi extender
  ↓
HAMi 加节点锁 -> Patch annotations -> 调用 K8s Bind API
  ↓
Pod 绑定到节点
  ↓
kubelet 调用 Device Plugin Allocate()
  ↓
Device Plugin 读取 annotations -> 注入 env/mounts
```

---

## 5. Mutating Webhook 详解

### Webhook 位置

| 文件 | 作用 |
|------|------|
| `pkg/scheduler/webhook.go` | Webhook 核心处理逻辑 |
| `pkg/scheduler/routes/route.go:WebHookRoute()` | HTTP 路由注册 |
| `charts/hami/templates/scheduler/webhook.yaml` | K8s MutatingWebhookConfiguration |

### K8s 配置

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: hami-scheduler-webhook
webhooks:
  - name: vgpu.hami.io
    clientConfig:
      service:
        name: hami-scheduler
        namespace: hami
        path: /webhook
        port: 80
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
    namespaceSelector:
      matchExpressions:
      - key: hami.io/webhook
        operator: NotIn
        values: ["ignore"]
    objectSelector:
      matchExpressions:
      - key: hami.io/webhook
        operator: NotIn
        values: ["ignore"]
    failurePolicy: Ignore
    sideEffects: None
```

### 拦截对象

- **资源**：Pod
- **操作**：CREATE

即：**每次创建 Pod 时，都会触发这个 webhook**。

### 排除条件

1. 命名空间带有 `hami.io/webhook=ignore` 标签
2. Pod 带有 `hami.io/webhook=ignore` 标签
3. 在白名单命名空间中
4. Pod 已经指定了其他 schedulerName（除非开启 `ForceOverwriteDefaultScheduler`）

### Webhook 具体修改内容

#### 1. 注入环境变量

如果 Pod 请求了 `nvidia.com/priority`：

```go
ctr.Env = append(ctr.Env, corev1.EnvVar{
    Name:  "CUDA_DEVICE_TASK_PRIORITY",
    Value: fmt.Sprint(priority.Value()),
})
```

如果配置了 `GPUCorePolicy`：

```go
ctr.Env = append(ctr.Env, corev1.EnvVar{
    Name:  "CUDA_DEVICE_CORE_LIMIT_SWITCH",
    Value: string(dev.config.GPUCorePolicy),
})
```

#### 2. 自动补充 GPU 数量

如果只写了显存或核心数，没写 GPU 数量：

```yaml
resources:
  limits:
    nvidia.com/gpumem: 3000
```

自动补充为：

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
    nvidia.com/gpumem: 3000
```

#### 3. 自动设置独占核心

当请求了 `nvidia.com/gpu` 且满足独占条件时，自动设置 `nvidia.com/gpucores: 100`。

#### 4. 设置 RuntimeClassName

如果配置了 RuntimeClassName 且 Pod 没设置，自动注入。

#### 5. 设置 schedulerName

如果 Pod 请求了任何 HAMi 管理的资源：

```go
if hasResource && len(config.SchedulerName) > 0 {
    pod.Spec.SchedulerName = config.SchedulerName  // 默认 "hami-scheduler"
}
```

这是 Webhook 最关键的作用，让 GPU Pod 自动路由到 HAMi scheduler。

#### 6. 资源配额检查

```go
if !fitResourceQuota(pod) {
    return admission.Denied("exceeding resource quota")
}
```

目前只支持 NVIDIA 的配额检查。

### 为什么只拦截 CREATE

对于 HAMi 的核心需求来说，**只拦截 Pod 的 CREATE 基本够用**：

- Pod 调度是一次性决策，创建时确定 schedulerName 后不会重新调度。
- K8s 中 Pod 的 `spec` 大部分字段创建后不可变，修改 GPU 资源通常需要删除重建。
- Deployment/StatefulSet/Job 等控制器最终也是创建 Pod，会被 CREATE 拦截。

不够的场景：

- Pod UPDATE 操作不会被拦截。
- 缺少 Validating Webhook，无法拒绝非法请求。
- 不拦截控制器资源（Deployment 等），无法在控制器层面提前校验。
- 非 NVIDIA 设备的配额检查未在 Webhook 中实现。

---

## 6. 总结

| 组件 | 作用 | 关键文件 |
|------|------|---------|
| **Scheduler Extender** | GPU 感知调度：过滤、打分、绑定 | `pkg/scheduler/scheduler.go`、`pkg/scheduler/score.go` |
| **独立 kube-scheduler** | 处理完整调度流程，调用 Extender | `charts/hami/templates/scheduler/configmap.yaml` |
| **Mutating Webhook** | Pod 创建时自动注入 schedulerName 和 GPU 配置 | `pkg/scheduler/webhook.go`、`charts/hami/templates/scheduler/webhook.yaml` |

HAMi 通过 **独立 scheduler + Extender + Webhook** 的组合，实现了：

1. **不修改集群默认 kube-scheduler**。
2. **用户无需手动写 `schedulerName`**。
3. **GPU Pod 自动路由到 HAMi scheduler 进行设备感知调度**。

---

## 7. scheduler 挂载的 config 怎么保证和当前 K8s 集群配置一致

**HAMi 不保证和它所在集群的默认 kube-scheduler 配置完全一致，它只保证"能正常工作"**。

### HAMi 的 config 内容

`charts/hami/templates/scheduler/configmap.yaml` 生成的配置非常精简：

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
leaderElection:
  leaderElect: true
  resourceName: hami-scheduler
  resourceNamespace: hami
profiles:
- schedulerName: hami-scheduler
extenders:
- urlPrefix: "https://127.0.0.1:443"
  filterVerb: filter
  bindVerb: bind
  nodeCacheCapable: true
  weight: 1
  httpTimeout: 30s
  managedResources:
  - nvidia.com/gpu
  - nvidia.com/gpumem
  - nvidia.com/gpucores
```

只定义了 leaderElection、一个空 profile 和 HAMi extender，其他全部使用 kube-scheduler 默认值。

### HAMi 如何保证能正常工作

| 方面 | 做法 |
|------|------|
| **API 版本匹配** | Helm 根据 `.Capabilities.KubeVersion.Minor` 自动选择 `v1`、`v1beta2` 或 legacy `Policy` |
| **镜像版本一致** | kube-scheduler 镜像版本与集群 K8s 版本一致，如 `v1.30.14` |
| **最小化配置** | 只配置 HAMi 需要的部分，其他用默认值，避免版本兼容问题 |

### 不保证一致的场景

如果集群默认 kube-scheduler 有自定义配置（自定义插件、优先级策略、拓扑策略等），HAMi 的独立 scheduler **不会继承**这些配置。这可能导致 GPU Pod 和非 GPU Pod 的调度行为不一致。

### 解决方案

| 方案 | 说明 |
|------|------|
| 手动编辑 HAMi ConfigMap | 把集群默认配置复制进去，但 Helm 升级会被覆盖 |
| 关闭 HAMi 自带 kube-scheduler | `scheduler.kubeScheduler.enabled=false`，接入集群默认 scheduler |
| 使用 Helm values | 只能调整 HAMi 自己的 GPU 调度策略，不能改 kube-scheduler 默认插件 |

---

## 8. `cmd/scheduler/main.go:62` 的 `init()` 里 `PersistentFlags()` 的作用

`PersistentFlags()` 是 Cobra 命令行库提供的机制，表示**持久标志**。与 `Flags()` 的区别：

| 类型 | 作用范围 |
|------|---------|
| `Flags()` | 只对当前命令有效 |
| `PersistentFlags()` | 对当前命令及其所有子命令都有效 |

### 具体代码

```go
func init() {
    rootCmd.Flags().SortFlags = false
    rootCmd.PersistentFlags().SortFlags = false

    // scheduler 专属参数，局部标志
    rootCmd.Flags().StringVar(&config.HTTPBind, "http_bind", "127.0.0.1:8080", "...")
    rootCmd.Flags().StringVar(&config.SchedulerName, "scheduler-name", "", "...")
    // ...

    // 全局 Go flags，持久标志
    rootCmd.PersistentFlags().AddGoFlagSet(config.GlobalFlagSet())

    // 子命令
    rootCmd.AddCommand(version.VersionCmd)

    // klog flags，局部标志
    rootCmd.Flags().AddGoFlagSet(util.InitKlogFlags())
}
```

### 为什么用 PersistentFlags

`rootCmd.PersistentFlags().AddGoFlagSet(config.GlobalFlagSet())` 把 HAMi 全局 Go flags 注册为持久标志，这样：

- `scheduler --xxx` 主命令可以使用。
- `scheduler version --xxx` 子命令也可以使用。

如果改用 `rootCmd.Flags().AddGoFlagSet(config.GlobalFlagSet())`，则子命令 `version` 无法识别这些全局参数。

### 总结

`PersistentFlags()` 在这里的作用就是：

> **把 `config.GlobalFlagSet()` 中的全局配置参数注册为持久标志，让 `scheduler` 主命令及其子命令都能识别和使用。**

# NVML 详细说明

## 1. 什么是 NVML

NVML（NVIDIA Management Library，NVIDIA 管理库）是 NVIDIA 提供的一套用于查询和管理 NVIDIA GPU 的 C API。

NVML 不是 GPU 计算库，而是 NVIDIA 驱动对外提供的管理接口。`nvidia-smi`、DCGM、部分 Kubernetes GPU 组件以及 HAMi 的 NVIDIA 设备模块，都可能通过 NVML 获取 GPU 信息。

在 Linux 中，NVML 通常由以下动态库提供：

```text
libnvidia-ml.so
libnvidia-ml.so.1
```

在 Windows 中通常对应：

```text
nvml.dll
```

NVML 动态库通常由 NVIDIA 驱动包提供，而不是由 CUDA Toolkit 单独提供。

## 2. NVML 的调用链

典型的调用关系如下：

```text
应用程序
   ├── nvidia-smi
   ├── DCGM
   ├── HAMi / device plugin
   └── 自定义监控程序
          │
          ▼
      NVML API
          │
          ▼
  libnvidia-ml.so / nvml.dll
          │
          ▼
  NVIDIA 内核驱动模块
          │
          ▼
        GPU 硬件
```

应用程序通过 NVML API 请求信息，NVML 再通过 NVIDIA 驱动与 GPU 硬件交互。

## 3. NVML 的主要功能

### 3.1 查询 GPU 基本信息

NVML 可以查询：

- GPU 数量
- GPU 型号
- GPU UUID
- PCI Bus ID
- 显存总量
- NVIDIA 驱动版本
- 固件版本
- 设备序列号

常见 API 包括：

```c
nvmlDeviceGetCount()
nvmlDeviceGetName()
nvmlDeviceGetUUID()
nvmlDeviceGetPciInfo()
nvmlDeviceGetMemoryInfo()
```

### 3.2 查询 GPU 实时状态

NVML 可以查询：

- GPU 利用率
- 显存利用率
- GPU 温度
- 功耗
- 风扇转速
- SM、显存等部件的时钟频率
- 性能状态
- ECC 错误

常见 API 包括：

```c
nvmlDeviceGetUtilizationRates()
nvmlDeviceGetTemperature()
nvmlDeviceGetPowerUsage()
nvmlDeviceGetClockInfo()
nvmlDeviceGetPerformanceState()
```

这些数据常用于 Prometheus exporter、GPU 监控平台和调度系统。

### 3.3 查询 GPU 上运行的进程

NVML 可以查询正在使用 GPU 的进程，例如：

- 进程 PID
- 进程使用的显存
- CUDA 计算进程
- 图形进程

常见 API 包括：

```c
nvmlDeviceGetComputeRunningProcesses()
nvmlDeviceGetGraphicsRunningProcesses()
```

在容器环境中，进程可见性还可能受到 PID namespace、权限和驱动配置的影响。

### 3.4 GPU 管理操作

对于支持这些功能的 GPU，NVML 还可以执行部分管理操作，例如：

- 设置功耗上限
- 设置应用时钟
- 设置持久化模式
- 修改计算模式
- 查询或管理 MIG 配置相关信息
- 查询 GPU 分区或实例信息

这些操作通常需要 root 权限，而且是否可用取决于 GPU 型号、驱动版本和当前设备配置。

## 4. NVML 与 CUDA 的区别

| 项目 | CUDA | NVML |
| --- | --- | --- |
| 主要用途 | 使用 GPU 进行计算 | 查询和管理 GPU |
| 典型用户 | PyTorch、TensorFlow、CUDA 应用 | `nvidia-smi`、DCGM、监控程序、调度器 |
| 是否执行 CUDA kernel | 是 | 否 |
| 是否读取温度和功耗 | 不是主要功能 | 是 |
| 是否查询 GPU 进程 | 不是主要功能 | 是 |
| 典型接口 | `cudaMalloc()`、kernel launch | `nvmlDeviceGetMemoryInfo()` |

可以简单理解为：

```text
CUDA：让程序使用 GPU
NVML：让程序了解和管理 GPU
```

## 5. `nvidia-smi` 与 NVML 的关系

`nvidia-smi` 不是直接读取显卡硬件，而是通过 NVML 查询 NVIDIA 驱动状态。

其工作过程可以简化为：

```text
nvidia-smi
  ├── nvmlInit()
  ├── nvmlDeviceGetCount()
  ├── nvmlDeviceGetName()
  ├── nvmlDeviceGetMemoryInfo()
  ├── nvmlDeviceGetUtilizationRates()
  └── nvmlShutdown()
```

因此，如果 NVML 初始化失败，`nvidia-smi` 通常也无法正常工作。

## 6. 一个简单的 NVML C 示例

下面的程序初始化 NVML，并打印第一块 GPU 的名称和显存信息：

```c
#include <stdio.h>
#include <nvml.h>

int main(void) {
    nvmlReturn_t result;
    nvmlDevice_t device;
    char name[NVML_DEVICE_NAME_V2_BUFFER_SIZE];
    nvmlMemory_t memory;

    result = nvmlInit();
    if (result != NVML_SUCCESS) {
        fprintf(stderr, "nvmlInit failed: %s\n", nvmlErrorString(result));
        return 1;
    }

    result = nvmlDeviceGetHandleByIndex(0, &device);
    if (result == NVML_SUCCESS) {
        nvmlDeviceGetName(device, name, sizeof(name));
        nvmlDeviceGetMemoryInfo(device, &memory);

        printf("GPU: %s\n", name);
        printf("Memory: %llu MiB / %llu MiB\n",
               (unsigned long long)(memory.used / 1024 / 1024),
               (unsigned long long)(memory.total / 1024 / 1024));
    }

    nvmlShutdown();
    return 0;
}
```

编译时通常需要链接 NVML：

```bash
gcc example.c -o example -lnvidia-ml
```

实际编译还需要系统中安装 NVIDIA 驱动提供的头文件和动态库。

## 7. `Driver/library version mismatch` 的含义

当出现下面的错误时：

```text
Failed to initialize NVML: Driver/library version mismatch
NVML library version: 595.58
```

通常表示：

```text
用户态 NVML 动态库版本 != 当前已加载的 NVIDIA 内核驱动版本
```

例如：

```text
磁盘上的 libnvidia-ml.so：595.58
当前运行的内核模块：570.xx
```

常见原因包括：

- 升级 NVIDIA 驱动后没有重启机器
- 系统中存在多个版本的 NVIDIA 库
- 容器挂载了与宿主机不匹配的 NVML 库
- 宿主机驱动和容器 NVIDIA runtime 组合异常
- 内核模块来自旧驱动，用户态库来自新驱动
- 驱动包安装或升级过程不完整

可以分别检查用户态库和内核模块版本：

```bash
# 当前已经加载到内核中的 NVIDIA 驱动版本
cat /proc/driver/nvidia/version

# 磁盘上的 NVIDIA 内核模块信息
modinfo nvidia | grep -E 'version|filename'

# NVML 动态库的搜索结果
ldconfig -p | grep libnvidia-ml

# 当前实际解析到的 NVML 文件
readlink -f "$(ldconfig -p | awk '/libnvidia-ml.so.1/{print $NF; exit}')"
```

其中，`/proc/driver/nvidia/version` 更能反映当前已经加载并正在运行的驱动版本；`modinfo nvidia` 反映的是磁盘上的模块信息，两者不一定相同。

## 8. NVML 在 Kubernetes 和 HAMi 中的作用

在 Kubernetes GPU 环境中，NVML 常参与以下流程：

```text
节点 GPU 发现
    ↓
读取 GPU 型号、UUID、显存等信息
    ↓
设备插件注册 GPU 资源
    ↓
调度器根据设备状态进行调度
    ↓
监控程序读取利用率、显存和进程信息
```

在 HAMi 中，NVML 可能用于：

- 发现节点上的 NVIDIA GPU
- 获取 GPU 总显存和可用显存
- 获取 GPU UUID 或 PCI 信息
- 读取 GPU 利用率和显存占用
- 监控容器中的 GPU 使用情况
- 辅助判断 GPU 是否可以继续分配
- 支持部分 NVIDIA vGPU、MIG 或设备隔离逻辑

因此，NVML 出现问题时，影响可能不只是 `nvidia-smi`，还可能包括：

- NVIDIA device plugin 无法注册资源
- HAMi 无法识别 GPU
- GPU 监控指标缺失
- 调度器获取不到 GPU 状态
- 容器无法正确分配 GPU

## 9. NVML 是否等于 NVIDIA 驱动

不完全等于。NVIDIA 驱动体系通常包含多个部分：

```text
NVIDIA 驱动
├── 内核模块
├── 用户态运行库
├── NVML 库
├── CUDA 相关库
└── nvidia-smi 等工具
```

NVML 是 NVIDIA 驱动体系中的一个用户态管理接口。它必须与能够兼容的 NVIDIA 内核驱动配合使用。

## 10. NVML 失败时的替代检查方法

即使 NVML 不能初始化，也可以通过 PCI 和 sysfs 查询 GPU 的基本信息。

### 10.1 使用 `lspci`

```bash
lspci -nn | grep -iE 'vga|3d|display|nvidia|amd|intel'
```

查看完整设备信息：

```bash
lspci -vnn -s 01:00.0
```

NVIDIA 的 PCI 厂商 ID 通常是：

```text
10de
```

### 10.2 查看 NVIDIA procfs 信息

```bash
cat /proc/driver/nvidia/version
cat /proc/driver/nvidia/gpus/*/information
```

### 10.3 查看内核模块

```bash
lsmod | grep nvidia
modinfo nvidia | grep -E 'version|filename'
```

### 10.4 查看设备节点

```bash
ls -l /dev/nvidia*
```

这些方法通常可以确认 GPU 型号、PCI 信息或驱动是否加载，但不能完整替代 NVML 提供的温度、功耗、利用率和进程显存等实时监控能力。

## 11. 容器环境中的注意事项

如果命令是在 Kubernetes 容器或 `node-shell` 容器中执行，需要注意：

- 容器中的 `libnvidia-ml.so` 可能来自容器镜像
- NVIDIA 内核模块始终运行在宿主机内核中
- 容器中的用户态库必须与宿主机驱动兼容
- `lspci` 可能因为容器权限或 namespace 看不到宿主机 PCI 设备
- `/proc/driver/nvidia` 和 `/dev/nvidia*` 是否挂载会影响诊断

可以检查：

```bash
ls -l /proc/driver/nvidia
ls -l /dev/nvidia*
cat /proc/driver/nvidia/version
```

如果容器内 NVML 版本与宿主机内核驱动不一致，通常需要检查 NVIDIA Container Toolkit、驱动挂载配置以及宿主机驱动安装状态。

## 12. 总结

NVML 是 NVIDIA GPU 的管理和监控 API，核心特点如下：

- 由 NVIDIA 驱动体系提供
- `nvidia-smi` 通过 NVML 工作
- 可以查询 GPU 型号、显存、温度、功耗、利用率和进程
- 可以执行部分 GPU 管理操作
- CUDA 负责 GPU 计算，NVML 负责 GPU 管理
- Kubernetes device plugin、DCGM 和 HAMi 等组件可能依赖 NVML
- `Driver/library version mismatch` 通常表示用户态 NVML 库与已加载的内核驱动版本不一致


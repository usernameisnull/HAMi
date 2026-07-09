## DCE5里hami叫nvidia-vgpu
在DCE5的`集群列表`里点击`GPU 调度配置`, 提示:
```txt
使用 Nvidia 虚拟化模式需要预先安装 gpu-operator 和 nvidia-vgpu 。
```
gpu-operator就是[`NVIDIA GPU Operator`](https://github.com/nvidia/gpu-operator) 

## DCE5部署后
- device-plugin: 是ds部署的, 里面有2个container对应的代码: `cmd/device-plugin`和`cmd/vGPUmonitor`
- scheduler: 是deployment部署的, 使用了k8s官方的kube-scheduler, 版本与部署的k8s集群的版本一致
```bash
➜ kgp -A |grep -i hami
nvidia-vgpu-281       nvidia-vgpu-hami-device-plugin-jdr9s                                    2/2     Running                  0                 32h
nvidia-vgpu-281       nvidia-vgpu-hami-scheduler-7c6fb475f9-dx4sz                             2/2     Running                  0                 32h
```

## build
1. 只打包出一个镜像, 镜像里包含了`cmd`目录下的源代码build出来的二进制
2. 使用了k8s官方的kube-scheduler

## Scheduler Extender
hami-scheduler这个pod里用了官方的kube-scheduler  

Scheduler Extender 是 Kubernetes 早期提供的一种调度扩展机制，允许用户在 不修改 kube-scheduler 源码 的情况下，将一部分调度逻辑交给外部 HTTP 服务完成。  

Scheduler Extender 已经属于较老的扩展方式，目前官方更推荐使用 Scheduler Framework（调度框架）编写插件  

`Scheduler Extender`是需要更改k8s集群的`/etc/kubernetes/kubescheduler-config.yaml`然后会重启这个pod, 但是hami用了`Mutating Webhook`

把Create pod导向了hami的`scheduler`, hami的scheduler用了一个自定义的配置文件, 这个配置文件里用`urlPrefix: "https://127.0.0.1:443"`指定了`Scheduler Extender`


## 其他
### MAKEFILE_LIST
Makefile.defs里的`ROOT_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))`  
```txt
MAKEFILE_LIST 是 GNU Make 的一个内置自动变量。
它包含了到目前为止 Make 解析过的所有 Makefile 文件名列表，按读取顺序排列，用空格分隔
```
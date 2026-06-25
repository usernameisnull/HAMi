## DCE5里hami叫nvidia-vgpu
在DCE5的`集群列表`里点击`GPU 调度配置`, 提示:
```txt
使用 Nvidia 虚拟化模式需要预先安装 gpu-operator 和 nvidia-vgpu 。
```
gpu-operator就是[`NVIDIA GPU Operator`](https://github.com/nvidia/gpu-operator) 

## DCE5部署后
- device-plugin: 是ds部署的, 里面有2个container对应的代码: `cmd/device-plugin`和`cmd/vGPUmonitor`
- scheduler: 是deployment部署的
```bash
➜ kgp -A |grep -i hami
nvidia-vgpu-281       nvidia-vgpu-hami-device-plugin-jdr9s                                    2/2     Running                  0                 32h
nvidia-vgpu-281       nvidia-vgpu-hami-scheduler-7c6fb475f9-dx4sz                             2/2     Running                  0                 32h
```

## 其他
### MAKEFILE_LIST
Makefile.defs里的`ROOT_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))`  
```txt
MAKEFILE_LIST 是 GNU Make 的一个内置自动变量。
它包含了到目前为止 Make 解析过的所有 Makefile 文件名列表，按读取顺序排列，用空格分隔
```
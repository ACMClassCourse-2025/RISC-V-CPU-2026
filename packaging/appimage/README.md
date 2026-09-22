# AppImage 构建指南

我们提供了预编译好的 `cpu2026-tools-x86_64.AppImage` 工具包，**通常情况下你无需自行构建，直接下载并在项目根目录下使用即可**。

如果你希望自行定制工具链（例如调整工具版本、打补丁），或希望为其他处理器架构（如 **aarch64 / ARM64**）构建，可以按照本指南自行构建。

---

## 1. 构建机制与原理

AppImage 将 Verilator 5.020、Yosys、ABC、OpenSTA 以及 ASAP7 7.5-track 标准单元库打包为一个独立的单文件可执行包：

1. **基础环境构建（Dockerfile）**：
   项目根目录下的 [Dockerfile](../../Dockerfile) 负责锁定各工具源码版本并完成编译安装，构建出包含完整工具链环境的基础 Docker 镜像（默认标签为 `cpu2026`）。
2. **依赖收集与私有隔离（[bundle.py](bundle.py)）**：
   在容器内部执行，提取各工具二进制、头文件与标准库文件。利用 `ldd` 递归解析所有动态链接库并复制到私有 `lib/` 目录中。各工具的包装入口使用独立的 ELF 动态链接器（如 x86-64 下的 `ld-linux-x86-64.so.2`）启动，使得工具包运行时与宿主机的 glibc、C++ 运行时完全解耦，互不干扰。
3. **AppImage 打包（[build.sh](build.sh)）**：
   在宿主机上驱动 Docker 运行 `bundle.py` 生成 `CPU2026-Tools.AppDir` 目录，并调用 `appimagetool` 将其压缩打包为 AppImage。

---

## 2. 构建前准备

构建必须在 **Linux** 环境下进行（支持物理机 Linux 及 WSL2）：

### (1) 安装与启动 Docker
构建过程需要使用 Docker 来提供受控的编译与依赖提取环境。

### (2) 构建基础 Docker 镜像
在框架根目录下执行以下命令，构建基础镜像：

```sh
docker build -t cpu2026 .
```

### (3) 下载 `appimagetool`
AppImage 打包需要用到官方打包工具 `appimagetool`：

```sh
# 下载与当前系统架构对应的 appimagetool（以 x86-64 为例）
curl -L -o appimagetool-x86_64.AppImage \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage

# 赋予执行权限
chmod +x appimagetool-x86_64.AppImage
```

---

## 3. 执行构建命令

在项目根目录下，指定 `APPIMAGETOOL` 路径并运行打包脚本：

```sh
APPIMAGETOOL="$PWD/appimagetool-x86_64.AppImage" packaging/appimage/build.sh
```

### 可选环境变量配置

如需定制构建行为，可在运行脚本前设置以下环境变量：

| 环境变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `APPIMAGETOOL` | - | `appimagetool` 可执行文件的绝对路径 |
| `CPU2026_BUILD_IMAGE` | `cpu2026` | Docker 镜像的名称 |
| `CPU2026_DIST_DIR` | `build/appimage` | 打包产物的输出目录路径 |

---

## 4. 构建产物

构建成功后，所有产物将输出在 `build/appimage/` 目录下：

```text
build/appimage/
├── cpu2026-tools-x86_64.AppImage   # 最终生成的单文件 AppImage 工具包
├── SHA256SUMS                      # AppImage 的 SHA-256 校验和文件
├── CPU2026-Tools.AppDir/           # 解包状态的目录
├── build-image-id.txt              # 构建所使用的 Docker 镜像 ID
└── appimagetool-SHA256SUMS         # 所使用的 appimagetool SHA-256
```

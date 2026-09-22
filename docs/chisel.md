# Chisel 集成

Chisel 模板包含严格匹配课程要求的 `student_top` 接口与课程 SRAM 适配器。编辑 [`chisel/src/StudentTop.scala`](../chisel/src/StudentTop.scala)，并将其他 CPU 模块放在 `chisel/src/` 下。初始模板仅输出空闲信号，需要实现 CPU 后才能通过正确性测试或得到有意义的面积与时序结果。

使用 Mill **1.1.2**、Scala **2.13.18**、Chisel 及其编译器插件 **7.7.0**；Chisel 自动获取匹配的 **firtool 1.139.0**。

本地生成需要安装 JDK 21 与 Mill 1.1.2。请按照 [Mill 安装指南](https://mill-build.org/mill/cli/installation-ide.html) 安装，并通过 `mill --version` 确认版本与 `.mill-version` 一致。

### 在 GitHub 上生成 RTL

1. 编辑 Chisel 源码，并将修改推送到自己的 Fork。
2. 按提示启用 Actions，选择 **Actions → Generate Verilog → Run workflow**，选定分支并运行。工作流文件需要先出现在仓库的默认分支上，才会显示手动运行按钮。
3. 工作流安装固定版本的 Mill，生成 `verilog/generated/student_top.sv`，将其加入 `verilog/filelist.f`，并编译课程仿真器。输出有变化时，将这两个文件提交回所选分支。
4. 本地测试前先拉取生成的提交，向 OJ 提交包含生成 RTL 的版本。工作流成功表示生成与编译通过，CPU 正确性仍需通过 `make test` 检查。

工作流检查分支是否仍处于启动时的版本，跳过空提交，并且不强制推送。若运行期间分支有新提交，请重新运行工作流。若分支保护或组织设置禁止机器人推送，请选择可写开发分支，或在本地生成并提交。普通可写 Fork 不需要个人访问令牌。

### 本地生成与提交

在仓库根目录执行 `mill chisel.run`，再运行常规的 `make build`、`make test`、`make synth`。
运行 `mill chisel.run build/chisel-export` 可以导出到独立目录

生成器只管理 `verilog/generated/student_top.sv`，将所有 Chisel 模块输出到该文件，并在 `verilog/filelist.f` 中补充对应条目。已有注释与其他 RTL 条目会保留。从手写 Verilog CPU 迁移时，请移除旧顶层模块条目，确保只有一个 `student_top` 定义。

修改源码后必须重新生成，可以本地生成或使用提供的github action。OJ 与普通 `make` 目标直接使用生成的 RTL，请确保在OJ提交前生成过Verilog。

### 课程 SRAM

需要课程 SRAM 模型和独立面积估算时，使用 `cpu2026.SRAM`；`SyncReadMem` 不会自动映射为 `sram_fakeram`。上面的示例创建了深度 1024、位宽 32、按字节写使能的 SRAM：`addr` 是字索引，`wmask` 为 4 位。SRAM 是单端口同步读存储，没有全局复位，完整语义见 [SRAM 文档](sram.md)。

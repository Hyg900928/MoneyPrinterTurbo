# scripts 目录说明

本目录存放项目维护和打包脚本。

## Windows 一键启动包

`build-windows-portable.ps1` 用于在 Windows 上生成便携版压缩包。生成结果包含项目源码、锁定依赖生成的 `.venv`、`start.bat` 和 `update.bat`。

默认不会复制本机 `config.toml`、`storage`、`logs`、`models`、`.git` 和本地 Agent 配置文件，避免把密钥、任务产物、大模型文件或个人配置打进分发包。

运行方式：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-windows-portable.ps1
```

输出文件：

```text
dist\MoneyPrinterTurbo-windows-portable.zip
```

解压后双击 `start.bat` 启动 WebUI。需要让 `update.bat` 支持 `git pull` 时，打包命令增加 `-IncludeGit`。

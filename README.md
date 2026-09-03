# SAG fnOS 原生 FPK

本项目把 Zleap-AI/SAG 打包为飞牛 fnOS x86_64 原生 FPK，使用 Next.js standalone 前端和 PyInstaller 后端，不依赖 Docker。

## 自动构建

工作流文件：.github/workflows/build-fpk.yml

- 每天北京时间 10:00 检查 Zleap-AI/SAG 的正式 GitHub Release。
- 自动排除 draft、prerelease、beta 和 rc 版本。
- 发现上游新版本后自动编译、校验并发布 GitHub Pre-release。
- 也可以在 Actions 中手动运行，填写 upstream_tag；`force=true` 会强制重编译，并为同一上游创建新的本地修订号，便于已安装旧包时直接升级。
- 工作流需要仓库设置允许 Actions 使用 GITHUB_TOKEN 写入内容和创建 Release。
- 后端编译固定使用 `ubuntu-22.04`，避免 `ubuntu-latest` 的新 glibc 进入 PyInstaller 程序。
- 打包前会检查后端 ELF 的 glibc 版本需求，超过 `GLIBC_2.35` 会直接停止发布。

GitHub Actions 的 cron 使用 UTC，因此北京时间 10:00 对应 02:00。

## 版本规则

FPK manifest 中的 version 使用本地版本号：

    0.1.0 → 0.1.1 → … → 0.1.9 → 0.2.0

version.json 保存最近一次成功构建的上游版本和本地版本。第一次构建使用 0.1.0，后续每个新的上游正式版本递增一次；同一上游使用 force 重编译时也递增一个本地修订号。

构建产物同时包含上游版本和本地版本，例如：

    SAG_1.8.6_0.1.0_fnOS_x86.fpk

Release 标题和说明也会显示上游版本、本地包版本、上游提交和 SHA256SUMS。

## fnOS 运行约定

- 架构：x86_64，manifest platform=x86。
- 默认 WebUI 端口：18088，可在应用中心修改。
- 运行依赖：nodejs_v22。
- FastAPI 后端仅监听 127.0.0.1:18089。
- WebUI 通过 fnOS Unix socket 网关访问 /app/SAG/。
- 配置、SQLite、LanceDB、上传文件和日志保存在持久化数据目录。
- 升级时保留持久化数据；卸载回调只停止服务，不主动删除数据。

## 手动本地构建

准备 Node.js 22、Python 3.12、uv、ImageMagick 和 GNU tar 后执行：

    UPSTREAM_TAG=v1.8.6 LOCAL_VERSION=0.1.0 ./scripts/build-fpk.sh

脚本会自动拉取对应上游 tag，应用 patches/sag-fnos.patch，编译前后端，生成 FPK、build-info.json、README.md 和 SHA256SUMS。

本地诊断时可以指定已有的上游工作树：

    SAG_SOURCE_DIR=/path/to/SAG SAG_SKIP_PATCH=1 SAG_SKIP_BUILD=1 \
      UPSTREAM_TAG=v1.8.6 LOCAL_VERSION=0.1.0 ./scripts/build-fpk.sh

## 目录说明

- fpk：fnOS FPK 外壳、生命周期脚本和应用中心配置。
- patches：上游 SAG 的 fnOS 路径和同源代理适配补丁。
- scripts/build-fpk.sh：完整编译和打包脚本。
- scripts/next-version.sh：本地版本滚动规则。
- version.json：最近一次成功构建状态。

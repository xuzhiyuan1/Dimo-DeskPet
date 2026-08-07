# 迪莫桌宠维护说明

## 项目位置

- App 源码：`assets/app-source/macOS/Sources/main.swift`（单文件 SwiftUI + AppKit）。
- App 信息：`assets/app-source/macOS/Info.plist`。
- 图片与图标：`assets/app-source/macOS/Resources/`。
- 构建脚本：`assets/build-scripts/build-macos.sh`。
- 版本号与更新记录：`assets/versioning/VERSION`、`assets/versioning/CHANGELOG.md`。

## 重要约束

- 这是 Apple Silicon（arm64）macOS 13+ App；不要添加 Intel 构建，除非用户明确要求。
- App 名称保持“迪莫桌宠”，Bundle ID 必须保持 `com.codex.dimopet`，否则用户已有 Todo 数据会丢失。
- Todo 和桌宠位置通过 `UserDefaults` 本地保存。改动 `TodoItem` 时必须兼容已有 JSON；新增可选字段使用 `decodeIfPresent`。
- 用户偏好：迪莫固定在桌面角落、可拖动；不使用系统风格的丑下拉日期时间选择器；提醒无铃声但置顶，直到完成或重新设定提醒时间。
- 清单只应在点击清单外部时收起。勾选、编辑、日期选择和提醒交互不能触发收起。
- 不要在调试时修改用户的 Todo；如必须操作，结束前恢复原状。

## 发布流程

1. 更新 `Info.plist`、`VERSION`、`CHANGELOG.md` 和 README 中的当前版本与下载链接。
2. 将原来的 `Dimo-DeskPet-<旧版本>-macOS-arm64.zip` 移入 `history/`。
3. 执行 `./assets/build-scripts/build-macos.sh`，生成仓库根目录的当前安装包。
4. 覆盖安装 `/Applications/迪莫桌宠.app` 时保留 Bundle ID，Todo 数据会自动保留。
5. 清理本次在 `/private/tmp` 创建的 `dimo-pet-build.*` 和 `dimo-pet-install.*` 临时目录，避免 Spotlight/应用搜索出现重复的迪莫桌宠。
6. 更新 README 后提交并推送 `main`。

## 仓库布局

- 根目录只保留：`README.md`、`AGENTS.md`、`assets/`、`history/`、当前版本 zip。
- GitHub 中的文件和文件夹使用英文命名；README 与 App 面向用户的文字使用中文。

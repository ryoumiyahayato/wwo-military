# WWO 军事仓库：外部宿主依赖的只读源码快照

来源：私有 `ryoumiyahayato/wwo`，`archive/military-full-20261024`，固定提交 `3c48266b335cfa448953d26b9698abb6dd207a34`。

本目录是为军事研发提供**可核对的依赖备份**，不是把正式 WWO 宿主、经济算法或全球地图移入军事运行态。本次保存了 **13 份**与当前军事适配器、权限、时间、空间及正式存档关系密切的原始文件；每份内容与原仓库 Git Blob SHA-1 完全相同。具体路径、字节数及 SHA 见 `SNAPSHOT_MANIFEST.json`。

## 严格边界

- `snapshot/**` 中的原 GDScript 特意使用 `.gd.txt` 后缀，原 `project.godot` 使用 `.txt` 后缀。**这只是文本备份，不得让 Godot 执行或自动注册其 class_name。**
- 正式世界的 `WorldState`、`SimulationStep`、`GameClock`、`FormalPersistence`、`OrganizationState`、`AuthorizationCheck`、`VNextSpatialWorld` 等仍由正式 WWO 提供。军事侧不得新建与之并行的权威世界、账户、人物或库存。
- 原 `WorldBootstrap` 和 `FormalWorldApplication` 也只作为调用/入口接口的历史依据，并非迁入经济或全球地图的可运行副本。
- 宿主升级时应生成新的固定快照和变更对照，不直接悄悄替换这些旧字节；先核实军事端实际消耗的接口契约。
- 不把这份快照混入 `military-godot/`、不填充 `res://scripts/world`、不改正式 WWO、经济仓库、旧归档或用户存档。

## 恢复环境事实

当前 `research/m-v9/` 是独立军事实验源码备份，**开发阶段 v9 / 运行态 war-environment-runtime-v8**；`military-godot/` 是军事源码摘录。当前新库**没有可独立启动的完整 Godot 项目资源链**，也没有可在此直接恢复的完整军事私有运行状态。原正式宿主可用时，军事适配器仍需由宿主提供合法接口。

引擎以 **Godot 4.6.3、Compatibility** 为复现版本；这里没有附引擎二进制、Android SDK、商业模型库或签名密钥。本次没有进行 Godot 导入、GUI、Android 或功能回归。存档、private_state、密钥和受许可限制的外部资料不得提交到源码树。

## 尚未迁入（不要误认为完成）

原 WWO 私有草稿 Release 的 **18 个逻辑 ZIP／114 个附件，共 7,192,143,243 字节**仍在旧库，`provenance/ARCHIVE_GAPS.json` 仍标记未镜像。当前新库中的 M v9 源码已按历史归档恢复校验，但**那不等于完整历史和当前军事环境资源都可从新库单独恢复**。不得在二进制归档搬迁和云端回读验证前删除旧 Release 或分支。

## 如何校验

可在新库克隆后执行 `git hash-object "provenance/external-host-api/snapshot/scripts/world/world_state.gd.txt"`，应得到 `02aee9634a9b10e3da5042bbf84772c7a8057b63`。其余文件同理比对 `SNAPSHOT_MANIFEST.json` 的 `git_blob_sha1` 字段。内容全部是只读原字节，不应在对照快照上直接修补业务代码。

**阶段裁决：核心接口源码参考备份完成；新库可独立运行与7.19GB历史归档独立化仍未完成。**

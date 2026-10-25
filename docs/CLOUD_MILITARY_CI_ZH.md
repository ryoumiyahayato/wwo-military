# 第一阶段：云端独立军事验证

工作流：[Military Godot CI](https://github.com/ryoumiyahayato/wwo-military/actions/workflows/military-ci.yml)。在仓库 **Actions → Military Godot CI → Run workflow**，选择 `main` 手动运行。也可使用已获本仓库 Actions 写权限的 GitHub CLI：

```sh
gh workflow run military-ci.yml --repo ryoumiyahayato/wwo-military --ref main
gh run list --repo ryoumiyahayato/wwo-military --workflow military-ci.yml
```

目前只有 `workflow_dispatch`；提交或 PR 不自动启动。GitHub 托管 `ubuntu-24.04`、Python **3.12.14**，只用标准库。作业的 `GITHUB_TOKEN` 只有 `contents: read`；检出后不保留 Git 凭据。同一 ref 串行执行、不取消已开始的运行，作业上限 60 分钟。

## 固定引擎与源码装配

`tools/ci/install_godot.sh` 从官方 `godotengine/godot-builds` 的 `4.6.3-stable` Release 下载 **标准 Linux x86_64 编辑器**，同时取得 `SHA512-SUMS.txt`。发布清单中的目标摘要须与脚本固定摘要一致，再用 SHA-512 校验下载内容。TLS 验证始终开启。完整版本必须精确为：

```text
4.6.3.stable.official.7d41c59c4
```

该 ZIP 的官方 SHA-512：

```text
a035258da32b77f966a5376f9fa29c30a6adde826a85ba918e1605bd1fc9823eba7d85f1dd5e748956bd2ba72827c0025ffa11bb82aec91128c407a2e723c99c
```

`tools/ci/validate_military.py` 在仓库外的新建临时目录生成自己的 `project.godot`，把 `research/m-v9/` 中的 GDScript、UID 和场景/资源文件逐字节复制到 `experiments/war_resolver/`，校验并记录源文件 SHA-256。完成后再次比较两侧文件，检测意外写入。原始研究代码、`military-godot/project.godot` 均不修改。临时运行数据使用独立 XDG 目录。

M v9 是开发阶段；运行态格式仍是 **`war-environment-runtime-v8`**。CI 不转换快照、不创建正式宿主，也不执行 `provenance/external-host-api/snapshot/**`。

## 实际执行范围

以下命令中的 `$GODOT` 是下载并校验的编辑器；`$PROJECT` 是临时项目根：

```sh
"$GODOT" --headless --version
"$GODOT" --headless --editor --path "$PROJECT" --quit
"$GODOT" --headless --path "$PROJECT" --script res://experiments/war_resolver/tests.gd
"$GODOT" --headless --path "$PROJECT" --script res://experiments/war_resolver/role_tests.gd
"$GODOT" --headless --path "$PROJECT" --script res://experiments/war_resolver/attachment_continuity/tests.gd -- --tactical-continuity
"$GODOT" --headless --path "$PROJECT" --script res://experiments/war_resolver/replay_probe.gd
"$GODOT" --headless --path "$PROJECT" --script res://experiments/war_resolver/role_replay_probe.gd
```

每个回放探针分别启动两个独立进程，严格提取并比较其原有 SHA-256 输出。结论只覆盖这些探针的指定输入，不代表全部战斗、时间切段、平台或存档语义一致。

resolver/roles 各限 900 秒；附件测试使用现有 `--tactical-continuity` 有限入口，限 240 秒；resolver/roles 回放进程分别限 180/240 秒。首轮本地完整测试分别实测约 594/563 秒，role 回放在原 120 秒限制到限，因此提高有界时限以容纳实际负载和运行器差异，不删场景、不改断言。不会调用历史 `validate.py --regressions`：该脚本的根目录、原项目工具及正式宿主回归夹具不属于当前提取仓库。原有 Python 交互客户端可用于人工研究，但其默认 Windows 引擎路径和旧工程根不能直接用作本 CI 启动入口。

## 结果与失败语义

在对应 Actions Run 的 **Artifacts** 下载 `military-ci-<run_id>-<attempt>`，保留 14 天。内含：

- `results/results.json`：提交、Python/引擎版本、引擎二进制摘要、每条完整命令、退出码、检查/失败数量、超时/诊断、回放哈希和源文件不变检查。
- `results/*.log`：实际导入、测试、两次独立回放的原始输出。
- `results/source-sha256.json`：临时项目使用的源码摘要清单。
- `results/summary.md`：可读表格；同样写入 Actions Summary。
- `bootstrap/`：官方下载/校验日志、发布校验清单、固定摘要、实际版本和初始磁盘情况。

测试必须退出码为 0、无致命诊断，并具有**非零检查数量、零失败**的原有总结才算 `PASSED`。超时、输出上限、断言失败、缺总结、零测试和回放缺哈希/不一致均不能通过。单项失败后继续收集其他测试，最终进程返回 1，使 Actions 真实失败；不使用 `continue-on-error`。

- `FAILED`：测试/断言/引擎诊断失败、超时或验证契约未满足。
- `BLOCKED_BY_DEPENDENCY`：实际缺少引擎或日志明确报告临时项目缺资源；保留路径和日志，不能据此直接判定算法错误。
- `NOT_RUN`：前提未通过而未启动的步骤，以及明确排除的正式宿主回归；不计入通过。

单进程日志上限 16 MiB，临时项目磁盘上限 256 MiB；超限杀掉所属进程组，明确失败。开始前要求至少 2 GiB 可用空间。Artifact 只上传列明的 CI 日志及合成测试元数据，不上传工作目录、运行态/人物存档、环境变量、凭据、Git 配置或引擎压缩包。

本地复现，所有输出位于仓库外，路径必须全新：

```sh
bash tools/ci/install_godot.sh /tmp/wwo-godot-4.6.3
python3 -B tools/ci/validate_military.py \
  --godot /tmp/wwo-godot-4.6.3/Godot_v4.6.3-stable_linux.x86_64 \
  --work-dir /tmp/wwo-military-project \
  --output /tmp/wwo-military-results \
  --test-timeout 900
```

## 已知边界与下一阶段清单

建设时本地完整 resolver 测试得到 **1875 checks、12 failures、exit 1**，涉及聚合段数、弹药、同时到达/控制及退眠扫描断言；roles 得到 **3762 checks、1 failure、exit 1**，为 `division command preserves aggregate interval/work`。附件限定测试得到 **209 checks、3 failures、exit 1**：`incapacity actual dose and survivor`、`surviving squad moves and expiry restores`、`body cannot borrow moved squad position`。这是未修改源码中的真实失败；CI 应保留失败。另行运行的 continuous suite 得到 **60 checks、2 failures**，涉及 quota 完成时间和物理/顺序/随机抽样一致性；不把这项未列入首批流水线的结果冒充通过。所有远端结果以实际 Run Artifact 为准。

恢复完整沙盒需要另行确定并验证：

1. **入口与资源**：选择现存 `research/m-v9/sandbox/sandbox.tscn` 或明确军事场景，补足其传递依赖；`military-godot/` 没有默认正式场景。3D 物理测试已确认缺 `assets/user_derived/models/user_rifleman_armed.glb`；还须按各场景核对模型、地形、材质、媒体及其导入资源和使用许可。
2. **正式宿主契约**：`WorldState`、`GameClock`、`SimulationStep`、人物/人口/组织、权限、空间及正式存档仍由原宿主独占；13 份 `.txt` 快照仅用于接口参考。需在原合法宿主中装配军事适配器，不能注册第二份权威对象或将快照改后缀直接执行。
3. **测试夹具**：先恢复合法宿主及原 `tests/vnext`、`tests/formal`、`tools/run_validation.ps1` 等传递依赖，再决定正式集成、持久化往返、GUI/沙盒和完整回归范围。当前 CI 不宣称这些验证通过。
4. **研究缺陷**：独立复现并定位聚合步长/工作量、退眠扫描、弹药守恒、同时到达/控制事件、身体/伤亡/归属和 quota 断言失败；核对当前契约与历史测试的差异。修复属于后续算法任务，不在本轮修改核心或放宽测试。
5. **归档**：`provenance/ARCHIVE_GAPS.json` 所列 18 个逻辑 ZIP、114 个附件、7,192,143,243 字节仍在原归档。本阶段不下载、迁移、清理或向 Git 历史添加这些包。

本阶段不提供 APK、完整 3D 恢复或经济集成。以每次实际 Run 的结果为准，工作流文件存在或显示绿色本身不构成军事算法验证完成。

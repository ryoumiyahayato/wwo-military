# 原生隔离训练嵌入

本模块只适配初始化、显示、会话生命周期、单敌车部署/实体炮弹接线与地形所有权。坦克/炮塔驾驶、GroundSupport、VehicleContacts、车组上下车、唯一有限弹药池、原炮口/炮手/装填、实体炮弹飞行碰撞与 Combat 伤损仍由原军事源码执行。不安装独立大军、工程支援、诊断宿主、性能采集器或全局渲染/模拟速率 helper。

## 嵌入 API

`controller.gd` 是 Node。主仓入口为 `res://military_runtime/native/modules/isolated_training/controller.gd`。

```gdscript
controller.prepared.connect(on_prepared) # status: Dictionary
controller.failed.connect(on_failed) # reason: String
controller.observer_requested.connect(show_observer)
controller.start({"viewport": observer_viewport, "world_root": optional_identity_root, "provider": layered_terrain})
```

- viewport 必须是现有、已入树且 own_world_3d=true 的观察 SubViewport。模块不替换 World3D，不新建环境/灯光，不接正式人物或 WorldState。
- world_root 可省略。提供时须在该视口内，global_transform 为单位变换；原生米制空间不能另行缩放/平移。
- provider 必须实现 `create_surface_material(options)` 与 `set_external_native_owner(bool)`。close/far 直接使用共享材质 factory。接已有 changed 信号唤醒纹理异步更新。
- `pause()`/`resume()` 保留同一 battle、车组字典、弹药池、弹丸、靶损、地形编辑和位置。pause 先清零全部 native collider 的 layer/mask，再交还观察地面；resume 先撤观察近景，再还原 native 碰撞。不会改 SceneTree.paused。
- `close()` 才明确结束会话。返回观察、地图切换或菜单不会创建新 battle。准备中的 pause 延后到原五人绑定及 install 完成，不重复安装。
- `set_input_exclusions(Array[Rect2])` 使用该 viewport 坐标。输入仍由原 mobile_battle 处理。
- `request_frame()` 只请求 UPDATE_ONCE。移动/转炮/视角变化、原装填、实体弹飞行、VFX、烟幕、地形流入/编辑期间逐帧请求，静止后停止。最后一帧负责清除已结束效果。
- `get_status()` 是事实副本：state/ready/paused、world_position、crew/registry、native_ammo（完整 canonical snapshot）、ammo（主炮状态）、target.modules/crew、shot_audit/incoming_audit、driving/ground_support 等。`formal_world_player=false`。
- `get_native_battle()` / `get_native_camera()` 仅供手动 driver/debug 读取原生对象、投影和原坐标；不属于正式世界控制接口。

## 不变边界

原 default_request 安装一次。五个稳定 person_id，车长 HP7/左臂 injured，AP6/HE2/smoke1 已消耗，原40主炮弹剩31。所有 garage/reset/select_unit/select_catalog/cycle_target/cycle_terrain/load_display/clear_stage 与弹药恢复入口被锁；不写正式存档或外部租约返回文件。

保留原 Kestrel 的外装 layer1、内部乘员 layer2。仅撤销 skirmish 的 blanket hide，继续使用原 LOS/天气/烟幕。它在准备阶段被同一对抗适配接管，不复制模型、Combat 或三名靶乘员。没有强制命中，不改 forced_roll。

近景唯一 owner 为原 Ridgevale + streamed_battle_terrain，包含 actor/固定靶流式 anchor、collision、support、形变及原事务。4m 原场双线性生成1m顶点，sample_height 与同1m碰撞三角使用相同对角重心插值；不抬平或改原高程。

## 主仓快照与资源

主仓 `military_runtime/native/` 是本次受控军事源码/配置快照。既有源码仅统一 res 前缀；Ridgevale terrain/world/heightfield 的运行时近景资源统一复用主仓 `assets/terrain/region_slice/`，不重装已有地形二进制。依赖闭包中的原小型 JSON 元数据保留为源码快照，不另建地形 owner。原目录的非嵌入可选宿主可能保留在依赖快照中，但本模块不安装或调用它们。

17个原资产从既有恢复 staging 复制到相同 native relative 路径；JSON 只变换 res 路径，不改原元数据/既有 source_sha 等字段。8个 GLB 由 .gitignore 排除，raw staging 不动。原 armor_collision 运行时 source 检查完整保留；导出须保持其原始 GLB 可由 FileAccess 读取，不可只留下 imported remap。

军事 canonical 另从 raw staging 原字节恢复九个必要 JSON：rifleman hitboxes、两份 armor geometry、catalog 及代理、车辆 manifest 及代理、metric 代理、MLRS manifest；原 res 路径和元数据不变，不逆算 prefixed JSON，也不复制八个 GLB。

## 2026-10-27 单敌车有限对抗（主宿主有限实测，非独立启动）

`opponent.gd` 继承原 `ai_armor/armor_host.gd`，只把既有 Kestrel/同 Combat 三乘员接入一次。准备阶段放置于既有 central_saddle 道路 (0,110)m、距入场玩家约117m；原高程、GroundSupport 与真实空间检查通过后才启用。失败不强行放置，暂停/返回观察不重生。

- 原 think/move/aim、0.65s 观察节奏、±65°光学视场、量化距离/角度、0.85s fresh、12s 记忆、天气/烟幕/实体 LOS、驾驶/炮手能力与移动接触不变。记忆只引导搜索，不准许记忆开火；瞄准不读取遮挡后的实时玩家位置或速度。
- 原5s初始击发等待、1–3s光学获取、0.45s稳定瞄准与原散布保留。轻车缺装填手按原8s周期，有限40 AP及300 MG来自同一 `vehicle_ammo`，不加无限弹药或伤害豁免。
- 敌主炮改接同一原 `artillery_shell`，使用原160m/s、重力12、射程260m配置。重力抬高只由量化观察距离经原 `tank_ballistics` 求得；发射前排除本车碰撞并通过原友军安全门，合法扣弹一次，实际飞行接触后才经原 `apply_ai_hit`/Combat结算。射出后不追踪，不以发射安全射线预结算。MG保留原即时炮口射线，不冒称实体弹。
- 原 `armor_host` 仅增加两个默认行为不变的覆盖点：`_aim_point` 支持以上观察点重力校正；`_advance_unit_combat` 避免同一 target Combat 同时由 main 与 AI 重复推进、缩短原烟幕时间。原九车部署及更大模块未删减。
- `get_status().encounter` 保存单敌车当前位置、乘员/模块、有限弹药、观察/记忆和原 shot audit，仅供本地事实/driver。它不是 UI 情报源；模型、原敌情小地图和弹着反馈继续受原合法观察限制。主车五个 person/Actor 与原座不替换；HP7只是入场伤情，真实来袭可使其继续受伤或死亡，不免费治伤/补弹。
- 敌车/炮塔/后坐/可见性实际变化及敌炮飞行唤醒 UPDATE_ONCE；暂停冻结同一节点、记忆、弹药与飞行，结局冻结的 flying 记录不永久唤醒画面。scenery 第二参数 `route_dressing=true` 由 Lead 的兼容 world 接口配套。

新增原源码依赖：`modules/ai_armor/{armor_host,combat_audit,deployment_terrain,gunnery_solution,vehicle_damage_feedback,visual_contact}.gd`、`modules/ai_safety/friendly_safety.gd`。Shell/ballistics、role capability、GroundSupport、weapon VFX、font 与上述模型均复用已有资源，不新增 GLB。主仓 namespace 同步、来源记录与下述有限实机由Lead完成；实现子任务未运行引擎/测试/Git，不把主宿主结果扩称军事工程独立启动。

## 2026-10-26 主宿主窗口有限事实

作者实现阶段未自行运行引擎、测试或 Git。以下是增加上述敌车前，Lead 在主线宿主 `battle-main-final` 静态训练窗口的既有 driver 报告；没有独立启动军事工程引擎，也不是新对抗能力的验收。

- 两发 AP，主炮余弹 31→30→29。第一发 blocked（左侧50未穿透）；第二发命中 rear35 并 penetrated，靶车 rear integrity 100→85，三名靶乘员 HP 10/10/10→7/6/8。
- 原车长 HP7、左臂 injured 未被治好。经原 UI 下车，实走位移3.446m，离原车达6.310m，再步行返回并占回原 seat0；上下车未补回弹药。
- sameActor、sameSession、同载具实例、暂停恢复状态保留及正式世界快照不变，均为既有 driver 比较报告，不是此文重新运行或独立重算；不能据此宣称全部军事能力通过或用户已验收。

## 2026-10-27 主宿主对抗事实

运行源码提交`01caf7907a8fe063e89ad16baf2e96f27f56abef`，通过主仓确定性namespace/resource同步使用。主宿主Godot4.6.3 Compatibility正常菜单/世界进入，成功轮退出0，无SCRIPT ERROR/ERROR，保留原两类warning。

- 首个独立会话先冲近暴露侧面，敌第二发真实穿透并使我方车长阵亡；未算完整通过，不降低AI伤害、不复活该会话。
- 新独立会话使用原标尺真实点击0→50→100m、短瞄首射和短程正面接近。玩家/敌车实驶20.263/55.691m；玩家2发实飞105.076m/0.657463s、51.731m/0.323464s。敌front完整度100→85→78，一发穿透、一发被挡；厚度不变。三crew10/10/10→0/6/7，炮手/驾驶员仍有效，各毁伤全失能标志false，不宣称胜利。
- 敌两发fresh年龄0.45/.0167s，实飞后命中我方front/turret_front，等效328.294/120.021挡110；我方front100→90、炮塔完整度未降，五crew仍7/10/10/10/10。敌扣2发40→38；玩家31→29，AP既耗6→8，HE/SMK不变。
- 同一原车长实走3.286m、离车6.283m，原UI返seat0同Actor，HP7伤臂未治好。原菜单、主机暂停、恢复和原菜单返回实际点击；敌状态/弹药/记忆在暂停冻结。回同正式世界及完整快照/人物/相机选择是driver比较结果，不是独立重算或用户接受。
- `get_player_status()`仅提供本车薄状态给2Hz横幅；`get_status().encounter`不作为隐藏敌情HUD。敌炮口效果不使用player priority，避免污染玩家准星反馈。

原167.555ms仍未重现/归因，局部native碰撞构建优化不证明整体稳定。NOT_RUN：HE、MG、smoke、拒绝负例、长时运行、正式部署、存读。正式保存、export、合并均未执行。

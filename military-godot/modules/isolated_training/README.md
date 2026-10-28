# 原生隔离训练嵌入

本模块适配初始化、显示、会话生命周期、部署/实体炮弹接线与地形所有权。默认保留单敌车；显式 `profile="field_170"` 增加下述尚未达标的满规模场景配置，不另建军事实体算法。坦克/炮塔驾驶、GroundSupport、VehicleContacts、车组上下车、唯一有限弹药池、原炮口/炮手/装填、实体炮弹飞行碰撞与 Combat 伤损仍由原军事源码执行。不安装工程支援、独立诊断宿主、常驻性能采集器或全局渲染/模拟速率 helper。

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

原167.555ms仍未重现/归因，局部native碰撞构建优化不证明整体稳定。该单敌车轮 NOT_RUN：HE、MG、smoke、拒绝负例、长时运行、正式部署、存读。正式保存、export、合并均未执行。

## 2026-10-27 满规模基线：明确未通过

- `profile="field_170"` 在同一原5km地形分三路部署：玩家1＋原AI19（9蓝/10红）共20车；另150个原Actor/Brain/person/有限武器，30个5人小队。57名AI车组与原玩家5人另计62，实际registry座位关系独立于150人。只作分批创建、地形注册等待及显式统一激活，不以镜头停掉远方战斗。
- `51e3d59` 真窗口初150人全部存活、独立ID且physics active，20车/62crew成立；19 AI车各移动40–99m、部分真实消弹交火。玩家原伤臂HP7、实走3.400m、返原座、暂停和同会话恢复保留。**步兵150人均0枪**：仅24蓝获得自己的LOS，51蓝与全部红被原贪心64ray预算饿死；车队报告只引导搜索，不能冒称步兵获准射击。
- 原始活动阶段1.822–2.069FPS，P95约500–591ms，最高611.363ms；初末完整流程只推进约25秒模拟；所测活动阶段合计约60秒墙时，另有输入/上下车等待，不能把两个范围直接当倍率。慢render帧含8个physics tick，不能把8次合计当单tick：Actor最高405.925ms（motor193.079/nav97.886/sense72.630/other98.524为各段各自峰），pose仅6.982ms；仅7次路径plan，不把nav成本归咎大量A*。Armor每physics平均14.119ms，move8.873/aim4.866/think0.287。CPU约占满一核，整卡GPU均值约1–4%且含桌面，不是进程GPU执行时间。
- `080003f` 仅作实时RID的native树遍历、同sweep的Barrel/RID/query复用，不减少形状、4.5cm子步、查询或接触回调。受控同规模开场1.845FPS、P95 600.558ms（开场尾帧反而更差）；Armor平均13.144ms。收益小，**不能声称解决或4倍提升**。步兵仍0枪。玩家确实消耗AP1/HE1，smoke0，不把按了选择钮算烟弹发射；经真实25km上级图/5km重入仍保留同实例/弹药/伤损。正式世界、人物及相机选择快照比较未变。
- 旧167.555ms定位到旧观察步行阶段，不是170战斗；旧51.777ms是观察地形的碰撞安装最大区间，不是本轮native碰撞构建，也不等于先前51.447ms worker等待。旧报告没有同帧子段，仍不能确定历史尖峰的细分原因。
- `64192cd` 细段诊断首次窗口因新增条件表达式的Variant类型推断失败，没有有效physics数据；保留失败，不当性能轮。显式类型修复后，`4822e46` 满规模实窗无SCRIPT ERROR/ERROR；150兵均获自己的实际ray（蓝612–716次，红最少81次含早期伤亡），150兵全有>1m水平位移，无ID/实例替换；registry实数62、双向座位62、车辆20，含步兵共212独立人员。原配额饿死已消除，但蓝0枪/红3枪、74蓝/69红存活，仍**没有持续接战通过**。
- `4822e46` 活动1.733–1.991FPS、最高674.005ms，不能说公平即提速。一个完整8tick慢帧motor solve154.832ms、heading2.874ms，nav73.787ms、sense118.256ms、other58.251ms；motor是原真实求解大头，不能归咎姿态。Armor诊断平均15.651ms/tick，support2.430、move/aim capture2.288/1.853、resolve4.498/2.754；细计时有开销，不能据此量化相对未诊断轮的退化。Resolver lifetime(含所有调用者)中layout4.271s、shape/path4.144s，而49万次intersect合计.575s、36万次cast合计.304s；不做额外broadphase去优化小头。父子是inclusive，不相加。
- `d447d8d` 只在本人fresh自见目标中优先可接战范围，未用世界最近敌真相。39射手74枪，蓝红均实际开火；20车/62座/212人、150ID/实例与移动成立，但活动仅1.501–1.873FPS，玩家AP1/HE1/SMK0。结构cache20项、54498次跨physics capture命中；ownRID约25.58→4.16µs，capture/layout没有下降，不能把命中率当提速。
- `3ccfdbe` 只field150明确启用20/60Hz原运动/nav，原五人及玩家路径保留60；Brain/感知/伤弹/fire逐tick不降。真窗147人有低风险服务，239916callbacks/181983solves/57933deferred，平均45.49Hz（20.68–60），未知支撑100890次退60；max结算.05sim/pending.0333，不丢累计时、无速度加成。原native velocity仅在求解内适配，立即恢复m/s。开场2.079FPS/P95 509.004ms、持续2.261/P95 474.306；phase模拟/墙时仅.252–.314，仍远未达标。
- `3ccfdbe` 49射手106真枪、两队各53，150ID/实例不变；末50蓝/42红存活，不能拿伤亡减载称初始满载通过。一个完整8tick慢帧Actor327.086ms：solve113.422/nav40.457/sense74.651/other82.228；sense候选20.901/shared17.516/ray8.028ms，小地图lifetime1.307s/100call/87906ray，先削数据整理而不降合法感知。原车长往返、HP7伤臂/伤弹、25km→5km同会话及正式世界比较保留；驾驶2.972m、SMK0仍令整体玩法失败。日志无SCRIPT ERROR/ERROR，原两类warning保留。
- `f1f5a09` 尝试精确活读后复用不可变local record/path；同开场无伤亡/零步兵枪的capture99.47→112.58µs、layout61.39→70.76µs，shape_pose约20.68→20.59µs，未证实净收益，`2baf779` 已回退该层。未用额外缓存掩盖失败。
- `a48bc75` 原native完整本体test_move补支撑证据，32255次全命中原静态terrain，未知支撑门未放松；实际平均28.17Hz（20.32–50.94），全部150人曾低风险，结算仍max.05sim。36射手76枪、150身份/移动/本人ray与20车/62座/212人保持；但测得仅1.304–1.526FPS，默认关闭诊断的同源码轮也只有1.129–1.426FPS、36射手67枪，均明确失败。该两轮墙时范围与19:39:38启动的外部3-worker地形采样重叠；OS快照还见第二个Godot与约237%单核等量Python负载，未停止他线。它们不能作干净算法AB，也不能用并行负载解释此前已存在的约2FPS失败。默认关闭的诊断不能算作零ray，报告已区分counter unavailable。
- `a48bc75` 诊断完整8tick慢帧other179.490ms中risk77.997/brain44.318/aim-fire4.432/sync3.752，native support30.488ms属motor；新风险索引本身已有明显成本，不因求解率下降就宣称收益。下一步梳理此热循环与原运动/车辆接触大头，在不与外部地形采样争资源的窗口复核，不猜地面、不改视觉预算或射击条件。不以自然伤亡、空弹、全会话主动暂停的60FPS当完整负载通过。不合并、不导出、不发布Release。

## 本轮成本收敛与延长窗口：未达30FPS

- 先核对正式宿主、军事计算、隔离初始化及历史研究：没有可删的第二套crew/ammo/health owner，registry保留同Combat.crew/person refs；Armor think已有0.65s门，Actor局部planner按阻塞/重试/全Host最多一次/physics预算执行，不是150份每帧完整5km图。原细节LOD只换共享Mesh/pose interval，不冻结远方physics/fire。研究/诊断源码不因本入口未安装而删。
- `a20df84`仅[Actor](../infantry_ai/infantry_actor.gd)/[Host](../infantry_ai/infantry_host.gd)同call风险读取与即时几何去重；`0490c8e`仅[Resolver](../../scripts/vehicle_contact_resolver.gd)每capture紧凑fresh Transform/整数路径，去逐节点record与逐shape path快照容器。不跨capture比较/COW，不改原插值/形状/.045步长/query/callback，旧pose/失效结构保持独立。无新通用平台。
- 既有主宿主driver延长30s运动/30s玩家静止AI活动/30s接战/60sHE/30s烟/60s持续，记录P99和每phase存活/physics/弹药。`0490c8e`默认关闭诊断约247.65s活动采样；20车/150兵/62双向座/212人起步，150全移动>1m、19AI车全移动/16实射。双方69步兵射手154枪，末仍150ID/实例、57活兵、17AI车活。原HP7伤臂车长同Actor实走返seat0；后续真实受伤至3，不治疗/重置。AP1/HE3/SMK1真实消耗；驾驶仅1.322m，玩法失败。
- 默认开场1.165FPS/P95 1034.489/P99 1073.738ms，玩家静止1.105/1061.497/1125.734，接战1.295/912.870/954.539，HE1.232/962.184/1035.569，持续1.421/845.245/896.630。CPU约一核99–101%，工作集1323–1351MiB、private1738–1775MiB，整卡GPU1–4%含桌面，不是进程GPU帧时间。模拟/墙时约.132–.190。默认HE阶段仅2发，不称爆炸密集已通过；诊断轮3发实际达成但FPS仍失败。
- 开场风险81.985→39.481→69.282µs/callback，同时未改的车辆控制组32.763→16.993ms/physics；未证实稳定净增益，不拿行数/容器压缩/原始减半归因。`a20df84`尾44–60FPS时车长阵亡、battle_finished且physics-active=0，已作无效失败，绝不是承载通过。后续原部署密度、自然伤亡/空弹/全局结束都不能替代初始负载。
- 当前native terrain保留64阈值事件中main_update最大49.481ms（同次两块build42.479），单块最大35.003ms含mesh_data16.888/shape_set_faces8.673/space_registration7.761；不是旧观察51.777ms同帧归因，旧167.555ms仍未关闭。无SCRIPT ERROR/ERROR，仍原两类warning；正式世界/人物/相机与同会话重入比较保留。不合并、导出或发布。详表与四轮原始本地报告位置在主仓既有[说明](https://github.com/ryoumiyahayato/wwo/blob/feat/layered-military-region-20261026/docs/maps/layered_military_region.md)。

## 原热路径第二轮：局部候选不等于净收益

- `f0ab400`曾以单weight parent-first active world数组替代每shape父链查表，保留原矩阵顺序/全部形状/子步/query。串行开场shape均值20.070→17.680µs，但capture97.637→102.579、resolve178.562→180.706、父段合计276.199→283.285µs；未改Actor风险也37.909→39.261µs/callback。全军运动1.980→1.899FPS、P99 564.250→665.258ms，不宣称净收益；`e3b2bcc`已完整回退，最终不保留该active表。原150人身份/移动仍成立，不用末21/26活兵减载称通过。
- `a6b279c`只在原时钟已保证本tick服务时跳过无决策作用的邻格分类：保留[Actor](../infantry_ai/infantry_actor.gd)原精确pending/phase谓词、全部标量门及[Host](../infantry_ai/infantry_host.gd)原ensure/terrain/epoch/自身shape时机，非mandatory仍全live风险。`scheduled_unclassified_solves`单列，不混入low/high或risk_counts；原服务delta、完整native运动/支撑、Brain/fire/感知/伤弹不变。不是把未知邻居当安全，不是降服务频率。
- 未实施零输入/零Euler接触快门、尸体/远AI睡眠、部署稀释或HeightMap后端替换，也未把每physics已统一建格误判为每Actor全重建。性能保留与验收仍看父段和完整真实窗口，不以helper/容器数量或诊断标签下降代替。
- `a6b279c` RTX诊断首次样本17953次mandatory分类未求值，solves=0 classified-low+4973 classified-high+17953 scheduled；服务max.05sim、pending max.0333，150人计数恒等式成立。但开场1.446/P99 1080.156ms、持续1.515/1138.110，未改Armor控制组也变慢，稳定净收益未证实。77射手180枪，HE段2发/驾驶1.322m仍失败。
- 同源码默认轮实际adapter是**Intel Iris Xe**，不是RTX；NVIDIA整卡0%/0MiB不能当游戏GPU数据，不作RTX关闭诊断AB/验收。245.827s活动采样仍1.091–1.405FPS，150ID保留且全部移动、19AI车全移动/实射；63射手159枪，末59活兵/144physics，原车长HP7同Actor伤弹保留。驾驶1.321m、HE段2发，观察步行collision检查也false；Intel/进程GPU未采到。详表与设备漂移边界见主仓既有说明，不用结束/自然减员或设备混比过线。

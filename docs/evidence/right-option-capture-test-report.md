# 右 Option 默认截图快捷键

2026-09-28，用户授权将默认截图快捷键设为单独轻按右 Option。

- 新缺省值为 rightOption（raw 3）；保留既有显式 0/1/2/3 设置。安装前核实本机没有保存该偏好，因此将使用新默认。
- 复用现有 HotkeyMonitor 事件 tap：右 Option 按下后 0.45 秒内释放，且无其他键、修饰键、鼠标操作时才触发。原事件不吞掉；按住已有按键/鼠标（0..<32）也不触发。
- 输入监控、辅助功能、tap 状态、语音同键冲突及语音/截图忙碌都参与检查；异步执行前重新检查。菜单和设置有权限/冲突提示。仅用户点击恢复入口时请求输入监控。
- 新增9项纯测试；连同路由3项、语音状态机10项共22项/3组全部通过。结果：`/tmp/prosio-option-tap-tests-r3-20260928.xcresult`。
- 签名构建 `/tmp/prosio-option-capture-build-r2.log` 成功；安装前后 deep/strict 验签通过。
- 正常退出旧进程，旧包保留 `build/Prosio-before-option-capture-20260928.app`；安装并启动 `/Applications/Prosio.app`，新PID2743。
- 运行文件与最终构建 SHA256 相同：`086dd2ad7521d2025be60fe9bcae03cabc61a140a380c08a1d92bac51167a460`。

限制：未模拟真实键盘/鼠标操作，也未变更系统权限。纯逻辑测试与签名检查不能替代本机 CGEventTap 事件投递及 TCC 实测。

## 16:10 真实授权故障修复

用户反馈输入监控开关已开但右 Option 无反应。主任务读取系统设置原生 AX 确认开关为 on，Prosio PID2979 日志却为 inputMonitoring denied（辅助功能 granted）。tccd 明确记录 ListenEvent 校验失败：旧 cdhash `c84c0fd456602d307979f71ed3852396859e489c` 与当前稳定证书 requirement 不匹配。

仅对 `app.prosio.mac` 执行标准 `tccutil reset ListenEvent`，通过系统设置重新添加 `/Applications/Prosio.app` 并点击“退出并重新打开”。PID3272 在 16:10:50 明确记录 inputMonitoring granted，tap installed。其他权限未修改；本轮未修改生产源码或重新构建。

原生自动化拒绝发送仅右Option的按键（keyPressIncludedNoNonModifierKeys）；因此已请用户轻按释放确认端到端，不将授权恢复等同于实际截图测试通过。

## 16:18 真实按键记录定位第二处故障

授权恢复后用户仍反馈无反应。签名诊断版PID3690采集到三次真实右Option：keycode61，按下deviceBits64、释放deviceBits0，持续148/115/127ms。权限/热键选择/忙碌/物理按键与鼠标均通过，唯独释放时 `leftOption=true` 导致 eligible=false。

错误来自回调内 `CGEventSource.keyState(.combinedSessionState, key:58)` 与当前事件设备位不一致。修复以当前 flagsChanged 的左Option设备位0x20为唯一判据，移除这次不可靠的修饰键轮询；仍保留真正左Option和其他修饰键/普通键/鼠标中断。新增回归覆盖记录中的deviceBits序列。

## 16:22 修复安装

修复已通过25项/3组定向测试，结果 `/tmp/prosio-option-tap-leftbit-20260928.xcresult`；签名构建 `/tmp/prosio-option-release-fix-build` 通过。安装至 `/Applications/Prosio.app` 并启动PID4373，日志确认AX/输入监控均granted、tap healthy。保留短诊断，等待用户实际轻按确认选区出现。

## 用户端到端确认

修复后第一次重试仅收到keycode58（左Option），故按设计不触发。说明左右键位置后，用户明确确认：“右侧 Option 已能截图”。默认右Option真实截图入口验收通过。

## 16:32 用户要求左右Option均可用

raw3扩展为左右任一Option单独轻按，UI名称“Option（左右均可）”；旧0/1/2偏好保持。按住对侧、左右交叉/同时按、组合键/鼠标/长按继续阻断，依然只读当前事件device bits判断Option。

29项/3组回归通过，结果 `/tmp/prosio-option-either-20260928.xcresult`。签名构建 `/tmp/prosio-both-option-build` 已安装并启动PID5096；输入监控与辅助功能granted、tap healthy。安装binary SHA256 `dd67e0af2b97b7686a1cde8de001efa8fdf146b7164f6446627f24c2d5eeff60`匹配构建。左侧新增行为通过逻辑回归，尚未取得用户实际左键截图确认。

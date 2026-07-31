import os

/// 诊断日志。实时查看：
///   log stream --predicate 'subsystem == "com.zhanghui.aiinput"' --level info
/// 回看最近记录：
///   log show --last 10m --predicate 'subsystem == "com.zhanghui.aiinput"' --info
enum Log {
    static let flow = Logger(subsystem: "com.zhanghui.aiinput", category: "flow")
}

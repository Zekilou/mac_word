import Foundation

/// sidecar 可执行定位：打包态（App Bundle Resources/agents-sidecar 单文件）优先，开发态（venv python + sidecar.py）回退。
/// @ai: Task 7 pyinstaller 打包后单文件置于 Resources；开发期直接跑源码（无需打包）。
enum AgentSidecarLocator {

    /// 返回 (executable, scriptPath?)，找不到返回 nil（调用方回退现有管线）。
    static func resolve() -> (executable: URL, script: URL?)? {
        // 1) 打包态：App Bundle Resources 下的单文件 agents-sidecar
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("agents-sidecar")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return (bundled, nil)
            }
        }
        // 2) 开发态：项目根 external_src 下的 sidecar.py + venv python
        //    venv 为本地大体积虚拟环境，可被归档到 _archive/（见 _gitignore），故两处都探测。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Agent
            .deletingLastPathComponent()   // WordRecitingApp（Swift 模块名，与品牌名无关，保持不变）
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // 项目根
        let script = root.appendingPathComponent("external_src/agent_sidecar/sidecar.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        let pythons = [
            root.appendingPathComponent("external_src/agent-venv/bin/python3.12"),
            root.appendingPathComponent("_archive/agent-venv/bin/python3.12"),
        ]
        for python in pythons where FileManager.default.fileExists(atPath: python.path) {
            return (python, script)
        }
        return nil
    }
}

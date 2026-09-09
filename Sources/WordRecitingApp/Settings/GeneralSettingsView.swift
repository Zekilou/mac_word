import SwiftUI
import AppKit

/// 设置-通用（spec §4.3）：复习调度 + 生成默认 + 选词默认 + 关于。
/// @ai: 设置即时写入 AppSettings（UserDefaults）；纯配置页，不依赖业务。
struct GeneralSettingsView: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                schedulingSection
                generationDefaultsSection
                wordDefaultsSection
                aboutSection
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    // MARK: - 复习调度

    private var schedulingSection: some View {
        section("复习调度") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("调度算法", selection: $settings.schedulerID) {
                    ForEach(SchedulerID.allCases, id: \.rawValue) { sid in
                        Text(label(for: sid)).tag(sid)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                if settings.schedulerID == .fsrsV4 {
                    Text("FSRS 接入中，当前仍用 SM-2")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func label(for sid: SchedulerID) -> String {
        switch sid {
        case .sm2: return "SM-2（当前）"
        case .sm2Frequency: return "SM-2 + 词频调制"
        case .fsrsV4: return "FSRS v4（开发中）"
        }
    }

    // MARK: - 生成默认

    private var generationDefaultsSection: some View {
        section("生成默认") {
            VStack(alignment: .leading, spacing: 10) {
                stepper("默认目标词数量", value: $settings.defaultTargetCount, in: 1...100)
                stepper("默认文章字数", value: $settings.defaultArticleLength, in: 100...2000, step: 50)
            }
        }
    }

    // MARK: - 选词默认

    private var wordDefaultsSection: some View {
        section("选词默认") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("默认过滤范围", selection: $settings.defaultWordFilter) {
                    ForEach(WordFilter.allCases) { f in
                        Text(f.label).tag(f.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                stepper("默认随机数量", value: $settings.defaultRandomCount, in: 1...100)
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        section("关于") {
            VStack(alignment: .leading, spacing: 8) {
                infoRow("名称", "wordincontxt · 纯本地背单词")
                infoRow("版本", appVersion)
                infoRow("版权", "© 2026 本项目 · 个人学习用途")
                Text("开源致谢：GRDB（数据库）、llama.swift（进程内推理）、HFMirror（国内镜像）。")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    openDataDirectory()
                } label: {
                    Label("打开数据目录", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text("数据目录：~/Library/Application Support/\(AppIdentity.supportDirName)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version)（\(build)）"
    }

    private func infoRow(_ name: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption)
            Spacer()
        }
    }

    private func openDataDirectory() {
        if let dir = try? AppIdentity.ensureSupportDirectory() {
            NSWorkspace.shared.open(dir)
        }
    }

    // MARK: - 复用

    private func stepper(_ title: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption)
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue)")
                    .font(.body.monospacedDigit())
                    .frame(width: 48, alignment: .trailing)
            }
            .labelsHidden()
            Spacer()
        }
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.5), lineWidth: 1))
    }
}

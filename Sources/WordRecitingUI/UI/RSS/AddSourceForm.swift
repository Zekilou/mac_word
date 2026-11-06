import SwiftUI
import WordRecitingCore

/// 添加自定义源表单（标题 + URL），用于 RSS 源管理页 sheet。
/// @ai: 结构与样式全部走设计系统（`Section` / `DTextField` / `DButton` / `InlineError`），
///      不自绘 padding 与按钮样式。
struct AddSourceForm: View {
    let onAdd: (_ title: String, _ url: String) -> Bool
    @State private var title = ""
    @State private var url = ""
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            Section(
                title: "添加自定义 RSS 源",
                note: "填入源地址，标题可留空（会自动取域名）"
            ) {
                VStack(spacing: Space.m) {
                    DTextField(placeholder: "标题（可选）", text: $title)
                    DTextField(placeholder: "RSS 链接（https://…）", text: $url,
                               icon: "link", monospaced: true)
                }
            }

            if let msg = errorMessage {
                InlineError(message: msg)
            }

            HStack(spacing: Space.s) {
                Spacer(minLength: 0)
                DButton("取消", rank: .quiet) { dismiss() }
                DButton("添加", rank: .primary) {
                    if onAdd(title, url) {
                        dismiss()
                    } else {
                        errorMessage = "链接无效（需 http/https 且含域名）"
                    }
                }
            }
        }
        .padding(Space.page)
        .frame(width: Size.sheetNarrow)
    }
}

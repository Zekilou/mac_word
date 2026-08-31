import SwiftUI

/// 添加自定义源表单（标题 + URL），用于 RSS 源管理页 sheet。
struct AddSourceForm: View {
    let onAdd: (_ title: String, _ url: String) -> Bool
    @State private var title = ""
    @State private var url = ""
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加自定义 RSS 源").font(.headline)
            TextField("标题（可选）", text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("RSS 链接（https://...）", text: $url)
                .textFieldStyle(.roundedBorder)
            if let msg = errorMessage {
                Text(msg).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                Button("添加") {
                    if onAdd(title, url) {
                        dismiss()
                    } else {
                        errorMessage = "链接无效（需 http/https 且含域名）"
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

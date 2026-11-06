#if os(tvOS)
import SwiftUI
import CoreImage.CIFilterBuiltins

struct TVUpdateView: View {
    let model: TVUpdateModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var checkFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            HStack(spacing: 36) {
                Button { dismiss() } label: { Label("返回", systemImage: "chevron.left").font(.system(size: 28)).padding(20) }
                    .buttonStyle(TVFocusStyle()).focusEffectDisabled()
                Text("软件更新").font(.system(size: 60, weight: .semibold)).accessibilityIdentifier("updates.title")
                Spacer()
                if model.preview { Text("界面预览 · 示例数据").font(.system(size: 26)).foregroundStyle(TVTheme.secondary) }
            }
            HStack(alignment: .top, spacing: 90) {
                VStack(alignment: .leading, spacing: 28) {
                    Text("当前版本 \(model.version)（\(model.build)）").font(.system(size: 30)).foregroundStyle(TVTheme.secondary)
                    Text(model.checking ? "正在检查更新…" : model.headline).font(.system(size: 40, weight: .semibold))
                        .accessibilityIdentifier("updates.status")
                    Text(model.detail).font(.system(size: 25)).foregroundStyle(TVTheme.secondary)
                        .accessibilityIdentifier("updates.source")
                    if let date = model.checkedAt {
                        Text("检查于 \(date.formatted(date: .abbreviated, time: .standard))").font(.system(size: 24)).foregroundStyle(TVTheme.secondary)
                    }
                    Button { Task { await model.check() } } label: {
                        TVActionLabel(title: model.checking ? "正在检查…" : "检查更新", symbol: "arrow.clockwise")
                    }.buttonStyle(TVFocusStyle(kind: .primary)).focusEffectDisabled().disabled(model.checking)
                        .focused($checkFocused).accessibilityIdentifier("updates.check")
                    if !model.preview {
                        Button { model.automaticallyChecks.toggle() } label: {
                            HStack {
                                Text("自动检查更新"); Spacer()
                                Text(model.automaticallyChecks ? "已开启" : "已关闭")
                            }.font(.system(size: 29)).padding(26)
                        }.buttonStyle(TVFocusStyle(kind: .tile)).focusEffectDisabled().accessibilityIdentifier("updates.automatic")
                        Text("回到 App 前台时检查，两次自动检查至少间隔六小时。")
                            .font(.system(size: 24)).foregroundStyle(TVTheme.secondary)
                    }
                    Text("自签版通过已配对的 Mac 安装新版，保留原有设备与家庭桥接数据。")
                        .font(.system(size: 26)).foregroundStyle(TVTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(width: 640).frame(maxHeight: .infinity, alignment: .top).focusSection()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let release = model.release {
                            Text("更新说明 · \(release.version)（\(release.build)）").font(.system(size: 34, weight: .semibold))
                            Text(release.notes.isEmpty ? "此版本没有额外的更新说明。" : release.notes)
                                .font(.system(size: 28)).fixedSize(horizontal: false, vertical: true)
                            if !model.preview, let image = qrCode(release.releaseURL.absoluteString) {
                                Image(uiImage: image).interpolation(.none).resizable().frame(width: 260, height: 260)
                                    .padding(16).background(.white).accessibilityLabel("发行说明二维码")
                            }
                            Text(model.preview ? "示例版本信息，未发布安装包。" : "用手机扫描二维码查看发行说明与安装包。")
                                .font(.system(size: 24)).foregroundStyle(TVTheme.secondary)
                        } else {
                            ContentUnavailableView("保持 TV 版本更新", systemImage: "arrow.down.circle",
                                description: Text("发现新版本后，这里会显示更新说明和发行页面二维码。"))
                                .frame(maxWidth: .infinity, minHeight: 430)
                        }
                    }.padding(16)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).focusable().focusEffectDisabled().focusSection()
            }
        }.padding(.horizontal, 90).padding(.vertical, 65).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TVTheme.background).preferredColorScheme(.dark)
            .defaultFocus($checkFocused, true).onExitCommand { dismiss() }
    }

    private func qrCode(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
#endif

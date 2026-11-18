import SwiftUI
import Translation

@main
struct BridgeTalkApp: App {
    var body: some Scene { WindowGroup { ConversationView() } }
}

struct ConversationView: View {
    @StateObject private var model = ConversationModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("translationPrepared") private var prepared = false
    @State private var appeared = false
    @State private var showHistory = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("两种语言，一场对话。")
                        .font(.largeTitle.bold())
                    Text("停顿后翻译 · 译文播完再说下一句")
                        .foregroundStyle(.secondary)
                    VStack {
                        Picker("语言 A", selection: $model.languageA) {
                            ForEach(AppLanguage.allCases) { Text($0.name).tag($0) }
                        }
                        Picker("语言 B", selection: $model.languageB) {
                            ForEach(AppLanguage.allCases) { Text($0.name).tag($0) }
                        }
                    }.disabled(model.running || model.preparing)
                    Picker("翻译方向", selection: $model.direction) {
                        ForEach(Direction.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .disabled(model.running || model.preparing)

                    VStack(spacing: 14) {
                        Image(systemName: model.running ? "waveform.circle.fill" : "mic.circle")
                            .font(.system(size: 78))
                            .foregroundStyle(.cyan)
                            .accessibilityHidden(true)
                        ProgressView(value: Double(model.level)).tint(.cyan)
                        Text(model.status).font(.callout).multilineTextAlignment(.center)
                            .accessibilityLabel("当前状态：\(model.status)")
                    }.frame(maxWidth: .infinity).padding(24)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))

                    if !model.source.isEmpty { caption("原文", text: model.source) }
                    if !model.translated.isEmpty { caption("译文", text: model.translated) }
                    ForEach(model.candidates) { candidate in
                        Button { model.choose(candidate) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("按\(candidate.languageName)翻译")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(candidate.text)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.bordered)
                    }
                    if !model.candidates.isEmpty {
                        Button("都不对，重新听") { model.skip() }.buttonStyle(.bordered)
                    }
                    Button {
                        if model.running || model.preparing { model.stop() } else { model.start() }
                    } label: {
                        Label(model.running || model.preparing ? "暂停" : "开始对话", systemImage: model.running || model.preparing ? "pause.fill" : "mic.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).tint(.cyan).foregroundStyle(.black)

                    DisclosureGroup("首次使用与收音设置") {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("1. 选择两种语言，联网准备该语言组合的翻译资源。\n2. 在系统中准备对应听写资源和高品质朗读声音。\n3. 关闭 VPN，测试两个方向；不要求打开飞行模式。")
                            Button("准备 / 重试下载翻译资源") { model.prepare() }
                                .disabled(model.running || model.preparing)
                            Text("收音门槛：\(Int(model.threshold)) dB。轻声漏掉就调低，环境嘈杂就调高。")
                            Slider(value: $model.threshold, in: -55 ... -20, step: 1)
                                .disabled(model.running || model.preparing)
                                .accessibilityLabel("收音门槛")
                            Text(model.voiceDescription)
                            Text("朗读语速：\(model.speechRate, specifier: "%.2f")")
                            Slider(value: $model.speechRate, in: 0.35 ... 0.60, step: 0.01)
                                .disabled(model.running || model.preparing)
                                .accessibilityLabel("朗读语速")
                            Text("优先选本机高品质声音。与 GPT 语音不同，实际音色和自然程度请试听确认。")
                            Text("自动判断只在所选两种语言之间进行。短句、人名、相近语言和混合语句容易误判，固定方向更可控。各语言能否使用取决于手机本地资源和系统支持。仅前台运行。")
                            Text("对话只保留本次打开期间最近 20 条，不写入历史文件。临时录音识别后删除。")
                        }.font(.footnote).foregroundStyle(.secondary).padding(.top, 12)
                    }
                }.padding(24)
            }
            .background(Color(red: 0.035, green: 0.055, blue: 0.085))
            .navigationTitle("BridgeTalk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("本次记录") { showHistory = true } }
            .sheet(isPresented: $showHistory) {
                NavigationStack {
                    List {
                        if model.history.isEmpty { Text("暂无记录") }
                        ForEach(Array(model.history.enumerated()), id: \.offset) { _, text in
                            Text(text).textSelection(.enabled)
                        }
                        Button("清空本次记录", role: .destructive) { model.history = [] }
                    }.navigationTitle("本次记录")
                        .toolbar { Button("关闭") { showHistory = false } }
                }
            }
        }
        .preferredColorScheme(.dark)
        .translationTask(model.configuration) { session in await model.translate(using: session) }
        .onAppear {
            guard !appeared else { return }
            appeared = true
            if prepared { model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Permission/download system sheets may make the scene inactive. Stop only in background.
            if phase == .background { model.stop(message: "切到后台已暂停，返回后点开始继续。") }
        }
    }

    private func caption(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.title3).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

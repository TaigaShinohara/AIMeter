import SwiftUI

// MARK: - Help & QA View
struct HelpView: View {
    var onBack: () -> Void

    @State private var expandedQAIds: Set<String> = ["qa-1", "qa-2"]
    @State private var searchText: String = ""

    struct QAItem: Identifiable {
        let id: String
        let category: String
        let question: String
        let answer: String
    }

    private let qaItems: [QAItem] = [
        QAItem(
            id: "qa-1",
            category: "集計・仕組み",
            question: "使用量はどのように集計されていますか？",
            answer: "AIMeter は外部サーバーを介さず、お使いの Mac 内に各 AI ツール（Cursor, Windsurf, Claude Code, Copilot, Codex, Gemini など）が保存しているローカルセッションログやキャッシュデータベースを安全に直接読み取り、タイムスタンプに基づいて 2時間 / 5時間 / 1日 / 7日 / 30日 ごとに自動合算しています。"
        ),
        QAItem(
            id: "qa-2",
            category: "集計・仕組み",
            question: "ブラウザ版（Web）やスマホでの会話は反映されますか？",
            answer: "反映されません。AIMeter は Mac ローカル内のファイルのみを集計対象としているため、「その Mac 上のエディタやターミナルで作業した分」のみがメーターに反映されます。※クラウド組織全体の API 利用量を合算したい場合は、設定画面から OpenAI Admin Key や GCP Project ID を登録することで同期可能です。"
        ),
        QAItem(
            id: "qa-3",
            category: "トラブルシューティング",
            question: "使っているツールが「未検出」と表示される場合は？",
            answer: "ポータブル版エディタや非標準のディレクトリにインストールしている場合、設定画面または初期セットアップ画面の「パス指定」ボタンから、ログファイル（.jsonl や state.vscdb）または保存先フォルダを直接指定できます。「検証 & 適用」を押して検証に成功すると即座に読み込まれます。"
        ),
        QAItem(
            id: "qa-4",
            category: "セキュリティ",
            question: "コードやプロンプトが外部に送信される心配はありませんか？",
            answer: "一切ありません。AIMeter のローカルログ集計処理はすべて Mac 内（ローカル完結）で動作しており、生成された集計ファイル (~/.ai_meter_usage.json) もパーミッション 0600（ご自身のアカウントのみ読み書き可能）で保護されています。外部への通信は、ご自身で設定した公式 API キーでの残高取得時のみ行われます。"
        ),
        QAItem(
            id: "qa-5",
            category: "使い方",
            question: "表示枠（2h / 5h / 1d / 7d / 30d）の切り替えや上限変更は？",
            answer: "ウィジェット上部の「すべて / 2時間 / 5時間 / 1日 / 週次 / 月次」セグメントで瞬時に表示を切り替えられます。また、右上の「設定」ボタンから、各サービスごとにどの枠を常時表示するか（表示枠トグル）や、トークン/リクエスト上限値を自由に変更できます。"
        ),
        QAItem(
            id: "qa-6",
            category: "使い方",
            question: "メニューバーに表示されるパーセントは何を表していますか？",
            answer: "各サービスの「現在もっとも逼迫している（残量が少ない）制限枠の残りパーセント」を表しています。たとえば 2時間枠や週次枠のいずれかが上限に近づくと、その枠の残量に応じて数値が下がり、注意色（黄色・赤色）で警告します。"
        ),
        QAItem(
            id: "qa-7",
            category: "使い方",
            question: "デスクトップウィジェットとして画面上に常時表示できますか？",
            answer: "メニューバーのカード下部にある「ウィジェットを表示」ボタンをクリックすると、デスクトップ上にドラッグ移動可能なフローティングカードウィンドウが表示されます。"
        ),
        QAItem(
            id: "qa-8",
            category: "集計・仕組み",
            question: "複数台の Mac を使っている場合はどうなりますか？",
            answer: "それぞれの Mac 内にあるログを集計するため、端末ごとの消費量が表示されます。たとえば職場の Mac と自宅の Mac で作業を分担している場合、各 Mac で消費した分がそれぞれの AIMeter で確認できます。"
        )
    ]

    private var filteredQAs: [QAItem] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return qaItems
        }
        return qaItems.filter {
            $0.question.localizedCaseInsensitiveContains(searchText) ||
            $0.answer.localizedCaseInsensitiveContains(searchText) ||
            $0.category.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top Bar
            HStack(spacing: 8) {
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("戻る")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("ヘルプ & よくある質問")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Text("v1.1.0")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            // About AIMeter Card
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.needle.fill")
                        .foregroundStyle(.tint)
                    Text("AIMeter について")
                        .font(.system(size: 12, weight: .bold))
                }

                Text("Mac 内で利用中の各 AI ツール（Cursor, Windsurf, Claude Code, GitHub Copilot, Gemini, OpenAI 等）のローカルログを直接解析し、リアルタイムの使用量・残量メーターと利用額を可視化するメニューバー＆ウィジェットアプリです。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 0.5)
                    )
            )

            // Search Filter
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("質問やキーワードを検索...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )

            // Q&A List
            ScrollView {
                VStack(spacing: 8) {
                    if filteredQAs.isEmpty {
                        Text("該当する質問が見つかりませんでした。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(filteredQAs) { item in
                            qaRowView(item: item)
                        }
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 290)
        }
        .padding(14)
        .frame(width: 380)
    }

    @ViewBuilder
    private func qaRowView(item: QAItem) -> some View {
        let isExpanded = expandedQAIds.contains(item.id)

        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded {
                        expandedQAIds.remove(item.id)
                    } else {
                        expandedQAIds.insert(item.id)
                    }
                }
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Text("Q.")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.tint)

                    Text(item.question)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                HStack(alignment: .top, spacing: 6) {
                    Text("A.")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)

                    Text(item.answer)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.top, 2)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        )
    }
}

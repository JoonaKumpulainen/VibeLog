import SwiftUI
import UIKit
import VLCore

struct LogView: View {
    @ObservedObject private var log = Log.shared
    @Environment(\.dismiss) private var dismiss
    @State private var previous: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if let previous {
                            Text(previous).foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(log.lines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .foregroundStyle(color(line))
                                    .id(index)
                            }
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                }
                .onAppear {
                    reader.scrollTo(log.lines.count - 1, anchor: .bottom)
                }
            }
            .navigationTitle(previous == nil ? "Log" : "Previous session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(previous == nil ? "Previous" : "Current") { togglePrevious() }
                        .disabled(log.previousFileURL == nil)
                    Button("Copy") { UIPasteboard.general.string = previous ?? log.text() }
                    ShareLink(item: log.fileURL)
                }
            }
        }
    }

    private func togglePrevious() {
        if previous != nil {
            previous = nil
        } else if let url = log.previousFileURL {
            previous = (try? String(contentsOf: url, encoding: .utf8)) ?? "Could not read the file"
        }
    }

    private func color(_ line: String) -> Color {
        if line.contains(" E ") { return .red }
        if line.contains(" W ") { return .yellow }
        return .primary
    }
}

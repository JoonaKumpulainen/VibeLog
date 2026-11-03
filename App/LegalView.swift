import SwiftUI

/// VibeLog's own license, the third-party code it carries with their notices, and what VibeLog
/// isn't. The license files ship inside the app, since the BSD and Academy licenses ask for their
/// notices to travel with it.
struct LegalView: View {
    private struct Notice: Identifiable {
        let title: String
        let detail: String
        let file: String
        var id: String { file }
    }

    private static let notices = [
        Notice(
            title: "VibeLog",
            detail: "Copyright (C) 2026 JoonaKumpulainen. Free software under the GNU General Public License, version 3.",
            file: "LICENSE"),
        Notice(
            title: "ACES 2.0 look",
            detail: "Ported from OpenColorIO's ACES 2.0 output transform. Copyright Contributors to the OpenColorIO Project, BSD 3-Clause license.",
            file: "LICENSES/OpenColorIO-BSD-3-Clause.txt"),
        Notice(
            title: "ACES 2.0 algorithm",
            detail: "The Academy Color Encoding System 2.0 output transform, by the Academy of Motion Picture Arts and Sciences, Apache License 2.0.",
            file: "LICENSES/ACES-Apache-2.0.txt"),
        Notice(
            title: "ACES 1.3 look",
            detail: "Ported from the Academy's ACES 1.3 reference code. Copyright © 2015 Academy of Motion Picture Arts and Sciences (A.M.P.A.S.). Portions contributed by others as indicated. All rights reserved.",
            file: "LICENSES/ACES-1.3-AMPAS.txt"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.notices) { notice in
                    NavigationLink {
                        LicenseText(title: notice.title, file: notice.file)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notice.title)
                            Text(notice.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Licenses")
            }
            Section("Notices") {
                Text("VibeLog is an independent project. It isn't affiliated with, endorsed by or certified by Apple, Sony, ARRI, Canon, the Academy of Motion Picture Arts and Sciences, the Academy Software Foundation or the OpenColorIO Project. Its ACES looks are its own implementation, checked against OpenColorIO, and aren't an ACES Logo product.")
                Text("Apple, iPhone, Apple Log and ProRes are trademarks of Apple Inc. ACES is a trademark of the Academy of Motion Picture Arts and Sciences. Sony, ARRI and Canon, and the names of their log curves and color spaces, such as S-Log3, LogC4 and Canon Log 3, may be trademarks of their owners. Gyroflow, DaVinci Resolve and other names belong to their owners. All are used only to say what VibeLog works with.")
                Text("Log curves and color spaces follow the makers' published formulas and primaries. LUTs you import stay under their own licenses.")
                Text("VibeLog comes with no warranty, to the extent the law allows. Check important footage before relying on it.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Legal")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseText: View {
    let title: String
    let file: String

    private var text: String {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(file),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "The license text is missing from this build. It's in the VibeLog repository as \(file)." }
        return text
    }

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

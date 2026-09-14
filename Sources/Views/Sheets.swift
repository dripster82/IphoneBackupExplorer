import SwiftUI

struct PasswordSheet: View {
    @EnvironmentObject var model: AppModel
    let device: BackupDevice
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield").font(.system(size: 36)).foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text("Encrypted Backup").font(.headline)
                    Text("Enter the password used to encrypt the backup of “\(device.title)”.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            SecureField("Backup password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
                .disabled(model.isLoadingFiles)
            if let err = model.passwordError {
                Label(err, systemImage: "xmark.octagon").font(.callout).foregroundStyle(.red)
            }
            HStack {
                if model.isLoadingFiles {
                    ProgressView().controlSize(.small)
                    Text(model.loadedCount == 0 ? "Deriving keys…" : "Reading manifest… \(model.loadedCount)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.cancelPassword() }.keyboardShortcut(.cancelAction)
                Button("Unlock", action: submit).keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || model.isLoadingFiles)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        model.submitPassword(password)
    }
}

struct ExportProgressSheet: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.exportProgress ?? ExportProgress()
        VStack(alignment: .leading, spacing: 12) {
            Text("Exporting…").font(.headline)
            ProgressView(value: p.fraction)
            HStack {
                Text("\(p.completed) of \(p.total)").monospacedDigit()
                Spacer()
                Text(p.currentFile).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            .font(.callout)
            if !p.failures.isEmpty {
                Text("\(p.failures.count) failed so far").font(.caption).foregroundStyle(.red)
            }
            HStack { Spacer(); Button("Cancel") { model.cancelExport() } }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct CopyProgressSheet: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.copyProgress ?? CopyProgress()
        VStack(alignment: .leading, spacing: 12) {
            Text("Copying backup of “\(p.deviceTitle)”…").font(.headline)
            if p.total == 0 {
                ProgressView().controlSize(.small)
                Text("Scanning files…").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView(value: p.fraction)
                HStack {
                    Text("\(p.completed) of \(p.total) files").monospacedDigit()
                    Spacer()
                    Text("\(AppModel.formatSize(p.copiedBytes)) of \(AppModel.formatSize(p.totalBytes))")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                Text(p.currentFile).font(.caption).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Cancel") { model.cancelCopy() } }
        }
        .padding(20)
        .frame(width: 440)
    }
}

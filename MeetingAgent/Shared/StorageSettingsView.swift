import SwiftUI

/// Shared settings view for choosing storage mode (iCloud vs local) and folder.
struct StorageSettingsView: View {
    @ObservedObject var storage = StorageManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("STORAGE SETTINGS")
                    .font(NBDesign.headlineFont)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.plain)
                .padding(8)
                .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
            }
            .padding(NBDesign.padding)
            .background(NBDesign.surface)
            .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))

            ScrollView {
                VStack(alignment: .leading, spacing: NBDesign.padding) {
                    storageModeSection
                    iCloudSubfolderSection
                    #if os(macOS)
                    localFolderSection
                    #endif
                    currentPathSection
                }
                .padding(NBDesign.padding)
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 300)
        #endif
    }

    // MARK: - Storage Mode

    private var storageModeSection: some View {
        VStack(alignment: .leading, spacing: NBDesign.smallPadding) {
            Text("STORAGE MODE")
                .font(NBDesign.captionFont)
                .foregroundStyle(.secondary)

            HStack(spacing: NBDesign.smallPadding) {
                modeButton(
                    label: "iCLOUD",
                    icon: "icloud.fill",
                    mode: .iCloud
                )
                #if os(macOS)
                modeButton(
                    label: "LOCAL",
                    icon: "folder.fill",
                    mode: .local
                )
                #endif
            }

            if storage.storageMode == .iCloud && !storage.iCloudAvailable {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("iCloud not available. Check your Apple ID in System Settings.")
                        .font(NBDesign.captionFont)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .nbCard()
    }

    private func modeButton(label: String, icon: String, mode: StorageManager.StorageMode) -> some View {
        Button {
            storage.storageMode = mode
        } label: {
            HStack {
                Image(systemName: icon)
                Text(label)
                    .font(NBDesign.buttonFont)
            }
            .frame(maxWidth: .infinity)
            .padding(NBDesign.smallPadding)
        }
        .buttonStyle(.plain)
        .background(storage.storageMode == mode ? NBDesign.foreground : NBDesign.surface)
        .foregroundStyle(storage.storageMode == mode ? NBDesign.background : NBDesign.border)
        .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
    }

    // MARK: - iCloud Subfolder

    private var iCloudSubfolderSection: some View {
        VStack(alignment: .leading, spacing: NBDesign.smallPadding) {
            Text("iCLOUD FOLDER NAME")
                .font(NBDesign.captionFont)
                .foregroundStyle(.secondary)

            Text("Recordings sync to this folder in iCloud Drive.")
                .font(NBDesign.captionFont)
                .foregroundStyle(.secondary)

            TextField("MeetingAgent", text: $storage.iCloudSubfolder)
                .font(NBDesign.bodyFont)
                .textFieldStyle(.plain)
                .padding(NBDesign.smallPadding)
                .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
        }
        .nbCard()
        .opacity(storage.storageMode == .iCloud ? 1.0 : 0.5)
        .disabled(storage.storageMode != .iCloud)
    }

    // MARK: - Local Folder (macOS only)

    #if os(macOS)
    private var localFolderSection: some View {
        VStack(alignment: .leading, spacing: NBDesign.smallPadding) {
            Text("LOCAL FOLDER")
                .font(NBDesign.captionFont)
                .foregroundStyle(.secondary)

            HStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: 16, weight: .bold))
                Text(storage.localBookmarkURL?.lastPathComponent ?? "No Folder Selected")
                    .font(NBDesign.bodyFont)
                    .lineLimit(1)
                Spacer()
                Button("CHOOSE") {
                    storage.selectLocalFolder()
                }
                .font(NBDesign.captionFont)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
            }
        }
        .nbCard()
        .opacity(storage.storageMode == .local ? 1.0 : 0.5)
        .disabled(storage.storageMode != .local)
    }
    #endif

    // MARK: - Current Path

    private var currentPathSection: some View {
        VStack(alignment: .leading, spacing: NBDesign.smallPadding) {
            Text("ACTIVE SAVE PATH")
                .font(NBDesign.captionFont)
                .foregroundStyle(.secondary)

            if let url = storage.rootURL {
                Text(url.path)
                    .font(NBDesign.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("Not configured")
                    .font(NBDesign.captionFont)
                    .foregroundStyle(.red)
            }
        }
        .nbCard()
    }
}

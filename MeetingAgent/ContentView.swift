import SwiftUI

struct ContentView: View {
    // This creates the link to the Engine
    @StateObject var manager = MeetingManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Storage settings")
                .font(.headline)
            HStack {
                Image(systemName: "folder.badge.plus")
                
                VStack(alignment: .leading) {
                    Text("Save Transcripts To:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(manager.savedFolderURL?.lastPathComponent ?? "No Folder Selected")
                        .font(.body)
                        .fontWeight(.medium)
                    
                }
                
                Spacer()
                
                Button("Change...") {
                    manager.selectFolder()
                }
            }
            Spacer()
            Text(manager.statusMessage)
            // Inside your ContentView body
            if manager.isRecording {
                VoiceVisualizer(amplitudes: manager.amplitudes)
                    .transition(.opacity)
            }

            // In your Button Task
            if manager.isRecording {
                await manager.stopAndTranscribe()
                manager.stopMonitoring()
            } else {
                await manager.start()
                manager.startMonitoring()
            }
            Spacer()
            Button(manager.isRecording ? "Stop" : "Start") {
                Task {
                    if manager.isRecording {
                        await manager.stopAndTranscribe()
                    } else {
                        // This triggers the code in MeetingManager
                        await manager.start()
                    }
                }
            }
        }
        .frame(width: 300, height: 200)
    }
}

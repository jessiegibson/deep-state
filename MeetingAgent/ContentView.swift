import SwiftUI

struct ContentView: View {
    // This creates the link to the Engine
    @StateObject var manager = MeetingManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image("deep-state-logo")  // Add image to Assets.xcassets first
                        .resizable()
                        .scaledToFit()
                        .frame(height: 40)
                    
            Text("Choose Location")
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
            
            // Voice visualizer - only show when recording
            if manager.isRecording {
                VoiceVisualizer(amplitudes: manager.amplitudes)
                    .transition(.opacity)
            }
            
            Spacer()
            
            Button(manager.isRecording ? "Stop" : "Start") {
                Task {
                    if manager.isRecording {
                        await manager.stopAndTranscribe()
                        manager.stopMonitoring()
                    } else {
                        await manager.start()
                        manager.startMonitoring()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(manager.isRecording ? Color.blue.opacity(0.1) : Color.clear)
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding(20)
        .frame(width: 320, height: 240)
    }
}

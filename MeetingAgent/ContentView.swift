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
            
            Divider()
            
            // Live Transcript Display
            if manager.isRecording {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "record.circle.fill")
                            .foregroundStyle(.red)
                        Text("Recording in progress...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    // Voice visualizer
                    VoiceVisualizer(amplitudes: manager.amplitudes)
                }
                .transition(.opacity)
            } else {
                Spacer()
                Text(manager.statusMessage)
                Spacer()
            }
            
            Button(manager.isRecording ? "Stop & Save" : "Start Recording") {
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
            .background(manager.isRecording ? Color.red.opacity(0.1) : Color.blue.opacity(0.1))
            .buttonStyle(.borderedProminent)
            .tint(manager.isRecording ? .red : .blue)
        }
        .padding(20)
        .frame(width: 400, height: 380)
    }
}

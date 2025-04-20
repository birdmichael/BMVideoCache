import SwiftUI
import BMVideoCache

struct VideoListView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var cacheStatusMap: [UUID: (isCached: Bool, isComplete: Bool, cachedSize: UInt64, expectedSize: UInt64?)] = [:]
    
    var body: some View {
        List {
            ForEach(viewModel.videos) { video in
                NavigationLink {
                    PlayerView(video: video)
                } label: {
                    VideoItemView(
                        video: video,
                        cacheStatus: cacheStatusMap[video.id],
                        isPreloading: viewModel.preloadingVideos.contains(video.url),
                        progress: viewModel.preloadProgress[video.url] ?? 0
                    )
                }
                .task {
                    await updateCacheStatus(for: video)
                }
            }
        }
        .refreshable {
            for video in viewModel.videos {
                await updateCacheStatus(for: video)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task {
                        await viewModel.cancelAllPreloads()
                    }
                } label: {
                    Image(systemName: "stop.circle")
                }
                .disabled(viewModel.preloadingVideos.isEmpty)
            }
        }
    }
    
    private func updateCacheStatus(for video: VideoModel) async {
        let status = await viewModel.isVideoCached(video)
        await MainActor.run {
            cacheStatusMap[video.id] = status
        }
    }
}

struct VideoItemView: View {
    let video: VideoModel
    let cacheStatus: (isCached: Bool, isComplete: Bool, cachedSize: UInt64, expectedSize: UInt64?)?
    let isPreloading: Bool
    let progress: Double
    
    @EnvironmentObject private var viewModel: AppViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(video.title)
                    .font(.headline)
                
                Spacer()
                
                HStack(spacing: 8) {
                    if let status = cacheStatus, status.isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else if isPreloading {
                        Button {
                            Task {
                                await viewModel.cancelPreload(for: video)
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                        
                        Text(Formatters.formatPercent(progress))
                            .font(.caption)
                            .foregroundColor(.blue)
                    } else {
                        Button {
                            Task {
                                await viewModel.preloadVideo(video)
                            }
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            
            if let status = cacheStatus {
                HStack {
                    Text(status.isComplete ? "已缓存" : (status.isCached ? "部分缓存" : "未缓存"))
                        .font(.caption)
                        .foregroundColor(status.isComplete ? .green : (status.isCached ? .orange : .secondary))
                    
                    Spacer()
                    
                    if status.isCached, let expectedSize = status.expectedSize, expectedSize > 0 {
                        Text("\(Formatters.formatBytes(status.cachedSize))/\(Formatters.formatBytes(expectedSize))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            if isPreloading {
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(height: 4)
                    .animation(.easeInOut, value: progress)
            }
        }
        .padding(.vertical, 4)
    }
}

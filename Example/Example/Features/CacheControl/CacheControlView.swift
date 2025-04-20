import SwiftUI
import BMVideoCache

struct CacheControlView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    CacheStatsCard(title: "缓存使用情况", icon: "externaldrive.fill") {
                        if viewModel.cacheStatistics != nil {
                            HStack {
                                Text("已使用: \(Formatters.formatBytes(viewModel.currentCacheSize))")
                                Spacer()
                                Text("总容量: \(Formatters.formatBytes(viewModel.maxCacheSize))")
                            }
                            .font(.caption)
                            
                            ProgressView(
                                value: min(Double(viewModel.currentCacheSize), Double(viewModel.maxCacheSize)), 
                                total: Double(max(viewModel.maxCacheSize, 1))
                            )
                            .progressViewStyle(.linear)
                            .frame(height: 8)
                        } else {
                            Text("加载统计信息中...")
                                .font(.caption)
                        }
                    }
                    
                    CacheStatsCard(title: "缓存项目", icon: "film.fill") {
                        if let stats = viewModel.cacheStatistics {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("视频数量")
                                        .font(.caption)
                                    Text("\(stats.totalItemCount)")
                                        .font(.title3)
                                        .fontWeight(.bold)
                                }
                                
                                Spacer()
                                
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text("平均大小")
                                        .font(.caption)
                                    if stats.totalItemCount > 0 {
                                        Text(Formatters.formatBytes(viewModel.currentCacheSize / UInt64(stats.totalItemCount)))
                                            .font(.title3)
                                            .fontWeight(.bold)
                                    } else {
                                        Text("0")
                                            .font(.title3)
                                            .fontWeight(.bold)
                                    }
                                }
                            }
                        } else {
                            Text("加载统计信息中...")
                                .font(.caption)
                        }
                    }
                    
                    CacheStatsCard(title: "内存压力", icon: "memorychip") {
                        HStack {
                            Text("当前级别: ")
                                .font(.caption)
                            
                            Picker("内存压力", selection: $viewModel.memoryPressureLevel) {
                                Text("低").tag(BMVideoCache.MemoryPressureLevel.low)
                                Text("中").tag(BMVideoCache.MemoryPressureLevel.medium)
                                Text("高").tag(BMVideoCache.MemoryPressureLevel.high)
                                Text("极高").tag(BMVideoCache.MemoryPressureLevel.critical)
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: viewModel.memoryPressureLevel) { _, newLevel in
                                viewModel.setMemoryPressureLevel(newLevel)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            } header: {
                Text("缓存统计")
            }
            
            Section {
                Button(role: .destructive) {
                    Task {
                        await viewModel.clearLowPriorityCache()
                    }
                } label: {
                    Label("清除低优先级缓存", systemImage: "trash")
                }
                
                Button(role: .destructive) {
                    Task {
                        await viewModel.clearCache()
                    }
                } label: {
                    Label("清除所有缓存", systemImage: "trash.fill")
                }
            } header: {
                Text("缓存操作")
            }
            
            if !viewModel.preloadingVideos.isEmpty {
                Section {
                    ForEach(
                        viewModel.videos.filter { viewModel.preloadingVideos.contains($0.url) },
                        id: \.self
                    ) { video in
                        VStack(alignment: .leading) {
                            HStack {
                                Text(video.title)
                                    .font(.headline)
                                
                                Spacer()
                                
                                Text(Formatters.formatPercent(viewModel.preloadProgress[video.url] ?? 0))
                                    .font(.subheadline)
                                    .foregroundColor(.blue)
                                
                                Button {
                                    Task {
                                        await viewModel.cancelPreload(for: video)
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                            
                            ProgressView(value: viewModel.preloadProgress[video.url] ?? 0, total: 1.0)
                                .progressViewStyle(.linear)
                                .frame(height: 4)
                        }
                    }
                    
                    Button(role: .destructive) {
                        Task {
                            await viewModel.cancelAllPreloads()
                        }
                    } label: {
                        Text("取消所有预加载")
                    }
                } header: {
                    Text("预加载队列")
                } footer: {
                    Text("当前正在预加载 \(viewModel.preloadingVideos.count) 个视频")
                }
            }
        }
        .refreshable {
            await viewModel.loadCacheStatistics()
        }
    }
}

struct CacheStatsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.headline)
                
                Text(title)
                    .font(.headline)
            }
            
            content
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
    }
}

import SwiftUI
import BMVideoCache

struct SettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    
    @State private var selectedCacheSize: UInt64 = 0
    @State private var cacheSizeOptions: [UInt64] = [
        UInt64(100 * 1024 * 1024),     // 100MB
        UInt64(500 * 1024 * 1024),     // 500MB
        UInt64(1024 * 1024 * 1024),    // 1GB
        UInt64(2 * 1024 * 1024 * 1024) // 2GB
    ]
    
    @State private var cacheDirectory: String = ""
    @State private var isShowingInfo = false
    
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("最大缓存大小")
                        .font(.headline)
                    
                    Picker("最大缓存大小", selection: $selectedCacheSize) {
                        ForEach(cacheSizeOptions, id: \.self) { size in
                            Text(Formatters.formatBytes(size)).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedCacheSize) { _, newValue in
                        if newValue != viewModel.maxCacheSize {
                            Task {
                                await viewModel.updateCacheSize(newValue)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
                
                Button {
                    isShowingInfo.toggle()
                } label: {
                    HStack {
                        Text("缓存目录")
                        Spacer()
                        Text(cacheDirectory)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .sheet(isPresented: $isShowingInfo) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("缓存目录信息")
                            .font(.headline)
                        
                        Text(cacheDirectory)
                            .font(.body)
                            .textSelection(.enabled)
                        
                        Spacer()
                        
                        Button("关闭") {
                            isShowingInfo = false
                        }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
            } header: {
                Text("缓存设置")
            }
            
            Section {
                HStack {
                    Text("内存压力管理")
                    
                    Spacer()
                    
                    Picker("内存压力", selection: $viewModel.memoryPressureLevel) {
                        Text("低压力").tag(BMVideoCache.MemoryPressureLevel.low)
                        Text("中压力").tag(BMVideoCache.MemoryPressureLevel.medium)
                        Text("高压力").tag(BMVideoCache.MemoryPressureLevel.high)
                        Text("危急").tag(BMVideoCache.MemoryPressureLevel.critical)
                    }
                    .onChange(of: viewModel.memoryPressureLevel) { _, newLevel in
                        viewModel.setMemoryPressureLevel(newLevel)
                    }
                }
                
                HStack {
                    Text("当前缓存使用")
                    Spacer()
                    Text(Formatters.formatBytes(viewModel.currentCacheSize))
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("可用存储空间")
                    Spacer()
                    Text(
                        viewModel.maxCacheSize > viewModel.currentCacheSize ? 
                        Formatters.formatBytes(viewModel.maxCacheSize - viewModel.currentCacheSize) : 
                        "0 B"
                    )
                    .foregroundColor(.secondary)
                }
            } header: {
                Text("系统状态")
            }
            
            Section {
                Button {
                    Task {
                        await BMVideoCache.shared.ensureInitialized()
                        await viewModel.loadCacheStatistics()
                        await viewModel.loadCacheConfiguration()
                    }
                } label: {
                    Label("重新加载缓存", systemImage: "arrow.clockwise")
                }
                
                Button(role: .destructive) {
                    Task {
                        await viewModel.clearCache()
                    }
                } label: {
                    Label("清除并重置", systemImage: "trash")
                }
            } header: {
                Text("维护")
            }
            
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BMVideoCache 示例应用")
                        .font(.headline)
                    
                    Text("版本 1.0.0")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("这是BMVideoCache库的示例应用，展示了视频缓存和预加载功能")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
                .padding(.vertical, 8)
            } header: {
                Text("关于")
            }
        }
        .task {
            await loadConfiguration()
        }
    }
    
    private func loadConfiguration() async {
        await viewModel.loadCacheConfiguration()
        selectedCacheSize = viewModel.maxCacheSize
        
        // 我们无法通过API获取缓存目录，所以使用一个默认值
        cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("BMVideoCache").path
    }
}

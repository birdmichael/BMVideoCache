import SwiftUI
import AVKit
import BMVideoCache

struct PlayerView: View {
    let video: VideoModel
    
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var player: AVPlayer?
    @State private var cacheStatus: (isCached: Bool, isComplete: Bool, cachedSize: UInt64, expectedSize: UInt64?)?
    @StateObject private var playerObserver = PlayerObserver()
    
    var body: some View {
        VStack {
            if let player = player {
                VideoPlayerView(player: player)
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay(
                        playerObserver.isLoading ? 
                            AnyView(ProgressView("加载中...").background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))) : 
                            AnyView(EmptyView())
                    )
            } else {
                Rectangle()
                    .fill(Color.black.opacity(0.1))
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay(
                        ProgressView("准备播放器...")
                    )
            }
            
            if let status = cacheStatus {
                HStack {
                    Image(systemName: status.isComplete ? "externaldrive.fill.badge.checkmark" : "externaldrive")
                        .foregroundColor(status.isComplete ? .green : .orange)
                    
                    Text(status.isComplete ? "已完全缓存" : (status.isCached ? "部分缓存" : "未缓存"))
                        .font(.caption)
                    
                    Spacer()
                    
                    if status.isCached, let expectedSize = status.expectedSize {
                        Text("\(Formatters.formatBytes(status.cachedSize)) / \(Formatters.formatBytes(expectedSize))")
                            .font(.caption)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            
            Spacer()
        }
        .navigationTitle(video.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    if let status = cacheStatus, !status.isComplete {
                        if viewModel.preloadingVideos.contains(video.url) {
                            Button {
                                Task {
                                    await viewModel.cancelPreload(for: video)
                                }
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundColor(.red)
                            }
                        } else {
                            Button {
                                Task {
                                    await viewModel.preloadVideo(video)
                                }
                            } label: {
                                Image(systemName: "arrow.down.circle")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }
        }
        .task {
            playerObserver.isLoading = true
            
            await BMVideoCache.shared.ensureInitialized()
            await updateCacheStatus()
            
            // 先尝试使用缓存资源，如果失败则直接使用原始URL
            let assetResult = await BMVideoCache.shared.asset(for: video.url)
            
            let playerItem: AVPlayerItem
            switch assetResult {
            case .success(let asset):
                // 设置预加载选项，使播放更流畅
                asset.resourceLoader.preloadsEligibleContentKeys = true
                playerItem = AVPlayerItem(asset: asset)
                
                // 配置播放选项
                playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
                playerItem.preferredForwardBufferDuration = 10.0
                
            case .failure(let error):
                BMLogger.shared.error("Failed to get cached asset: \(error)")
                // 使用原始URL创建新的AVURLAsset
                let urlAsset = AVURLAsset(url: video.url)
                playerItem = AVPlayerItem(asset: urlAsset)
            }
            
            // 配置AVPlayer
            let newPlayer = AVPlayer(playerItem: playerItem)
            
            // 防止视频返回时的卡顿问题
            newPlayer.automaticallyWaitsToMinimizeStalling = false // 修改为false以确保立即开始播放
            
            // 在创建播放器后直接尝试播放，而不等待状态改变
            Task { @MainActor in
                // 确保加载状态显示
                playerObserver.isLoading = true
                newPlayer.play()
            }
            
            // 使用改进的 playerObserver 来监测播放器状态
            playerObserver.observePlayer(newPlayer) { status in
                if status == .readyToPlay {
                    // 当播放器准备就绪时播放
                    Task { @MainActor in
                        // 确保已准备好继续播放
                        if newPlayer.timeControlStatus != .playing {
                            newPlayer.play()
                        }
                        // 只有当确实开始播放或缓冲区足够时才关闭加载指示器
                        if newPlayer.timeControlStatus == .playing || newPlayer.currentItem?.isPlaybackLikelyToKeepUp == true {
                            playerObserver.isLoading = false
                        }
                    }
                }
            }
            
            // 添加通知中心观察来监听播放完成事件
            let observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { notification in
                // 播放结束时确保加载指示器关闭
                Task { @MainActor [playerObserver] in
                    playerObserver.isLoading = false
                }
            }
            
            // 将观察者存储起来，以便于之后移除
            playerObserver.storeNotificationObserver(observer)
            player = newPlayer
        }
        .onDisappear {
            // 确保完全停止播放器
            player?.pause()
            player?.replaceCurrentItem(with: nil)  // 强制释放当前项
            playerObserver.stopObserving()
            player = nil
            
            // 立即取消预加载，避免异步任务的延迟
            if viewModel.preloadingVideos.contains(video.url) {
                Task {
                    await viewModel.cancelPreload(for: video)
                }
            }
            
            // 移除通知中心观察者
            playerObserver.removeAllNotificationObservers()
        }
    }
    
    private func updateCacheStatus() async {
        cacheStatus = await viewModel.isVideoCached(video)
    }
}

@MainActor
final class PlayerObserver: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var isLoading = true
    
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var loadedTimeRangesObservation: NSKeyValueObservation?
    private var isPlaybackBufferEmptyObservation: NSKeyValueObservation?
    private var isPlaybackLikelyToKeepUpObservation: NSKeyValueObservation?
    
    // 存储通知中心观察者
    private var notificationObservers: [NSObjectProtocol] = []
    
    func observePlayer(_ player: AVPlayer, statusChanged: @escaping (AVPlayer.Status) -> Void) {
        stopObserving()
        self.player = player
        self.playerItem = player.currentItem
        
        // 监测播放器状态
        statusObservation = player.observe(\AVPlayer.status, options: [.new, .initial]) { [weak self] player, change in
            guard let self = self, let status = change.newValue else { return }
            
            Task { @MainActor in
                statusChanged(status)
                
                if status == .readyToPlay {
                    // 不管缓冲区状态如何，都先尝试播放
                    if player.timeControlStatus != .playing {
                        player.play()
                    }
                    
                    // 只有当确实在播放时才关闭加载指示器
                    if player.timeControlStatus == .playing || player.currentItem?.isPlaybackLikelyToKeepUp == true {
                        self.isLoading = false
                    }
                } else if status == .failed {
                    self.isLoading = false
                }
            }
        }
        
        // 监测播放控制状态(暂停/播放)
        timeControlStatusObservation = player.observe(\AVPlayer.timeControlStatus, options: [.new, .initial]) { [weak self] player, change in
            guard let self = self, let timeControlStatus = change.newValue else { return }
            
            Task { @MainActor in
                switch timeControlStatus {
                case .playing:
                    print("DEBUG: 播放器状态变为播放中")
                    self.isPlaying = true
                    // 如果缓冲区有足够数据或正在流畅播放，则关闭加载指示器
                    if player.currentItem?.isPlaybackLikelyToKeepUp == true {
                        self.isLoading = false
                    }
                case .paused:
                    print("DEBUG: 播放器状态变为暂停")
                    self.isPlaying = false
                    self.isLoading = false  // 暂停时不显示加载
                case .waitingToPlayAtSpecifiedRate:
                    print("DEBUG: 播放器状态变为等待播放")
                    self.isPlaying = false
                    self.isLoading = true   // 等待播放时始终显示加载
                    
                    // 尝试再次播放
                    player.play()
                @unknown default:
                    break
                }
            }
        }
        
        // 监测当前播放项的状态
        if let playerItem = player.currentItem {
            itemStatusObservation = playerItem.observe(\AVPlayerItem.status, options: [.new, .initial]) { [weak self] item, change in
                guard let self = self, let status = change.newValue else { return }
                
                DispatchQueue.main.async {
                    if status == .readyToPlay {
                        if item.isPlaybackLikelyToKeepUp {
                            self.isLoading = false
                        }
                    } else if status == .failed {
                        self.isLoading = false
                    }
                }
            }
            
            // 监测缓冲区状态
            isPlaybackBufferEmptyObservation = playerItem.observe(\AVPlayerItem.isPlaybackBufferEmpty, options: [.new, .initial]) { [weak self] item, change in
                guard let self = self, let isEmpty = change.newValue else { return }
                
                Task { @MainActor in
                    if isEmpty {
                        self.isLoading = true  // 缓冲区空时显示加载
                        
                        // 尝试重新播放
                        if player.timeControlStatus != .playing {
                            player.play()
                        }
                    }
                }
            }
            
            // 监测是否可能流畅播放
            isPlaybackLikelyToKeepUpObservation = playerItem.observe(\AVPlayerItem.isPlaybackLikelyToKeepUp, options: [.new, .initial]) { [weak self] item, change in
                guard let self = self, let isLikelyToKeepUp = change.newValue else { return }
                
                Task { @MainActor in
                    if isLikelyToKeepUp {
                        // 当缓冲状态良好时关闭加载指示器
                        self.isLoading = false
                        
                        // 如果正在等待播放，但已有足够的缓冲数据，则尝试播放
                        if player.timeControlStatus != .playing {
                            player.play()
                        }
                    } else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                        // 正在等待播放且缓冲区不足时显示加载
                        self.isLoading = true
                    }
                }
            }
        }
    }
    
    func stopObserving() {
        // 在主线程上执行安全的清理
        // 失效所有观察器
        statusObservation?.invalidate()
        timeControlStatusObservation?.invalidate()
        itemStatusObservation?.invalidate()
        loadedTimeRangesObservation?.invalidate()
        isPlaybackBufferEmptyObservation?.invalidate()
        isPlaybackLikelyToKeepUpObservation?.invalidate()
        
        // 重置所有观察器
        statusObservation = nil
        timeControlStatusObservation = nil
        itemStatusObservation = nil
        loadedTimeRangesObservation = nil
        isPlaybackBufferEmptyObservation = nil
        isPlaybackLikelyToKeepUpObservation = nil
        
        // 重置状态
        isPlaying = false
        isLoading = false  // 确保退出时加载指示器关闭
        
        // 重置播放器相关资源
        playerItem = nil
        player = nil
    }
    
    // 存储通知中心观察者
    func storeNotificationObserver(_ observer: NSObjectProtocol) {
        notificationObservers.append(observer)
    }
    
    // 移除所有通知中心观察者
    func removeAllNotificationObservers() {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }
    
    // deinit中不能安全地调用actor-isolated方法，所以我们依赖onDisappear来清理资源
}

struct VideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

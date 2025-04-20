import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    
    var body: some View {
        TabView {
            NavigationView {
                VideoListView()
                    .navigationTitle("视频列表")
            }
            .tabItem {
                Label("视频", systemImage: "play.rectangle")
            }
            
            NavigationView {
                CacheControlView()
                    .navigationTitle("缓存管理")
            }
            .tabItem {
                Label("缓存", systemImage: "externaldrive")
            }
            
            NavigationView {
                SettingsView()
                    .navigationTitle("设置")
            }
            .tabItem {
                Label("设置", systemImage: "gear")
            }
        }
    }
}

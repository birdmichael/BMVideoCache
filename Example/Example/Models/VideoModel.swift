import Foundation
import BMVideoCache

struct VideoModel: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let url: URL
    
    static let samples = [
        VideoModel(title: "大雄兔", url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!),
        VideoModel(title: "大象梦想", url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4")!),
        VideoModel(title: "火光", url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4")!),
        VideoModel(title: "逃脱", url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4")!),
        VideoModel(title: "乐趣", url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4")!),
        VideoModel(title: "快乐时光", url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4")!),
        VideoModel(title: "Sintel", url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4")!),
        VideoModel(title: "斯巴鲁", url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/SubaruOutbackDrive.mp4")!),
        VideoModel(title: "钢铁之泪", url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4")!)
    ]
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: VideoModel, rhs: VideoModel) -> Bool {
        lhs.id == rhs.id
    }
}

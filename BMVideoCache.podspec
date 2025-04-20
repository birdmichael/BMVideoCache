Pod::Spec.new do |s|
  s.name             = 'BMVideoCache'
  s.version          = ENV['GITHUB_REF_NAME'] || '1.0.0'
  s.summary          = 'A high-performance video caching and preloading library for iOS, macOS, iPadOS, and visionOS.'

  s.description      = <<-DESC
BMVideoCache is a high-performance video caching and preloading library for iOS, macOS, iPadOS, and visionOS platforms.
It provides efficient caching of HTTP/HTTPS video streams, video preloading, cache prioritization, expiration policies,
and flexible cache cleanup strategies.
                       DESC

  s.homepage         = 'https://github.com/birdmichael/BMVideoCache'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'birdmichael' => 'birdmichael126@gmail.com' }
  # 在本地验证时使用本地路径
  s.source           = { :git => '.', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '15.0'
  s.tvos.deployment_target = '15.0'
  s.visionos.deployment_target = '1.0'
  s.swift_version = '5.0'

  s.source_files = 'Sources/BMVideoCache/**/*'

  s.frameworks = 'Foundation', 'AVKit'
end

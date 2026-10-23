Pod::Spec.new do |s|
  s.name             = 'dogcodes_video'
  s.version          = '0.1.0'
  s.summary          = 'Hardware H.264 decoding into a Flutter texture.'
  s.homepage         = 'https://dog.codes'
  s.license          = { :type => 'Proprietary' }
  s.author           = 'DogCodes'
  s.source           = { :path => '.' }
  s.source_files     = 'dogcodes_video/Sources/dogcodes_video/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.frameworks       = 'VideoToolbox', 'CoreMedia', 'CoreVideo'
  s.swift_version    = '5.0'
end

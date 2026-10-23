Pod::Spec.new do |s|
  s.name             = 'dogcodes_clipboard'
  s.version          = '0.1.0'
  s.summary          = 'Manual image clipboard access.'
  s.homepage         = 'https://dog.codes'
  s.license          = { :type => 'Proprietary' }
  s.author           = 'DogCodes'
  s.source           = { :path => '.' }
  s.source_files     = 'dogcodes_clipboard/Sources/dogcodes_clipboard/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.frameworks       = 'UIKit', 'ImageIO'
  s.swift_version    = '5.0'
end

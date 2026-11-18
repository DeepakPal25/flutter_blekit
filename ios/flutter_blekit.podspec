#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_blekit.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_blekit'
  s.version          = '0.1.0'
  s.summary          = 'A testable Bluetooth LE layer for Flutter, ported from SwiftBLEKit.'
  s.description      = <<-DESC
Automatic reconnection with exponential backoff, a declarative GATT profile
DSL, typed standard profiles, and hardware-free test doubles for Flutter,
with iOS backed directly by SwiftBLEKit's Core Bluetooth adapter
(https://github.com/DeepakPal25/SwiftBLEKit).
                       DESC
  s.homepage         = 'https://github.com/DeepakPal25/flutter_blekit'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'DeepakPal25' => 'noreply@example.com' }
  s.source           = { :path => '.' }

  # Our bridging code plus SwiftBLEKit's vendored sources (see
  # SwiftBLEKit/README in this directory), compiled into a single module so
  # the plugin depends on SwiftBLEKit's actual Core Bluetooth adapter rather
  # than reimplementing it.
  s.source_files = 'Classes/**/*.swift', 'SwiftBLEKit/Sources/SwiftBLEKit/**/*.swift'

  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'

  s.resource_bundles = {'flutter_blekit_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end

Pod::Spec.new do |s|
  s.name             = 'tunnel_interface'
  s.version          = '0.2.0'
  s.summary          = 'Runtime-only native tunnel boundary for Zagros VPN.'
  s.description      = <<-DESC
A typed Pigeon bridge with a real Apple Personal VPN IKEv2 adapter.
                       DESC
  s.homepage         = 'https://github.com/ZagrosGM/Zagros-VPN'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Zagros' => 'security@zagros.ai' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*', '../darwin/Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '12.0'
  s.swift_version    = '5.9'
  s.frameworks       = 'NetworkExtension', 'Security'
  s.static_framework = true
end

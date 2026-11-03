#!/usr/bin/env ruby
require 'xcodeproj'
require 'pathname'
root=Pathname.new(__dir__).parent
project=Xcodeproj::Project.open(root.join('ios/Runner.xcodeproj'))
runner=project.targets.find{|t|t.name=='Runner'}
extension=project.targets.find{|t|t.name=='PacketTunnel'} || project.new_target(:app_extension,'PacketTunnel',:ios,'16.0')
shared=project.main_group.find_subpath('Shared',true);shared.set_source_tree('<group>');shared.set_path('Shared')
runner_group=project.main_group.find_subpath('Runner',true)
extension_group=project.main_group.find_subpath('PacketTunnel',true);extension_group.set_path('PacketTunnel')
frameworks=project.main_group.find_subpath('Frameworks',true);frameworks.set_path('Frameworks')
add_source=lambda{|group,path,targets|
 ref=group.files.find{|f|f.path==path} || group.new_file(path)
 targets.each{|target|target.add_file_references([ref]) unless target.source_build_phase.files_references.include?(ref)}
}
add_source.call(shared,'TunnelSecrets.swift',[runner,extension])
add_source.call(shared,'ProbeHost.swift',[runner])
add_source.call(runner_group,'QingzhouRuntime.swift',[runner])
add_source.call(extension_group,'PacketTunnelProvider.swift',[extension])
ref=frameworks.files.find{|f|f.path=='Mobile.xcframework'} || frameworks.new_file('Mobile.xcframework')
[runner,extension].each do |target|
 target.frameworks_build_phase.add_file_reference(ref) unless target.frameworks_build_phase.files_references.include?(ref)
 target.build_configurations.each do |config|
  settings=config.build_settings
  settings['IPHONEOS_DEPLOYMENT_TARGET']='16.0'
  settings['SWIFT_VERSION']='5.0'
  settings['CODE_SIGN_ENTITLEMENTS']="#{target.name}/#{target.name}.entitlements"
  settings['FRAMEWORK_SEARCH_PATHS']=['$(inherited)','$(PROJECT_DIR)/Frameworks']
  settings['PRODUCT_BUNDLE_IDENTIFIER']=target==runner ? 'cn.qingzhou.qingzhou' : 'cn.qingzhou.qingzhou.PacketTunnel'
  settings['QINGZHOU_KEYCHAIN_GROUP']='$(AppIdentifierPrefix)cn.qingzhou.shared'
  settings['CURRENT_PROJECT_VERSION']='$(QINGZHOU_BUILD)'
  settings['MARKETING_VERSION']='$(QINGZHOU_VERSION)'
  if target==extension
   settings['INFOPLIST_FILE']='PacketTunnel/Info.plist'
   settings['SKIP_INSTALL']='YES'
   settings['APPLICATION_EXTENSION_API_ONLY']='YES'
   settings['LD_RUNPATH_SEARCH_PATHS']=['$(inherited)','@executable_path/Frameworks','@executable_path/../../Frameworks']
   config.base_configuration_reference=project.main_group.files.find{|f|f.path=='Version.xcconfig'} || project.main_group.new_file('Version.xcconfig')
  end
 end
end
runner.add_dependency(extension) unless runner.dependencies.any?{|d|d.target==extension}
embed=runner.copy_files_build_phases.find{|p|p.name=='Embed App Extensions'} || runner.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec='13'
unless embed.files_references.include?(extension.product_reference)
 build=embed.add_file_reference(extension.product_reference);build.settings={'ATTRIBUTES'=>['RemoveHeadersOnCopy']}
end
project.save

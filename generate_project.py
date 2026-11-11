"""Regenerate the checked-in project without third-party tools. Not a build prerequisite."""
from pathlib import Path
import hashlib
import plistlib

root = Path(__file__).resolve().parent
objects = {}
def uid(key):
    return hashlib.sha256(key.encode()).hexdigest()[:24].upper()
def add(key, body):
    objects[uid(key)] = body
    return uid(key)
def ref(path):
    kind = {'.swift':'sourcecode.swift', '.xcassets':'folder.assetcatalog', '.ttf':'file'}.get(Path(path).suffix, 'text.plist.xml')
    return add('ref:' + path, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = "{path}"; sourceTree = SOURCE_ROOT;')
def build(path, target):
    return add('build:' + target + ':' + path, f'isa = PBXBuildFile; fileRef = {ref(path)};')
def array(items):
    return '(' + ', '.join(items) + (',' if items else '') + ')'
app = sorted(str(p.relative_to(root)) for p in (root/'RunesIOS').rglob('*.swift'))
shared = ['Shared/BandActivityAttributes.swift', 'Shared/LucideData.swift', 'Shared/MuscleFigure.swift', 'Shared/ProfileIcon.swift', 'Shared/SVGPath.swift']
widget = ['RunesActivity/RunesActivity.swift']
fonts = sorted(str(p.relative_to(root)) for p in (root/'RunesIOS/Resources/Fonts').glob('*.ttf'))
resources = {'app': ['RunesIOS/Resources/Assets.xcassets'] + fonts, 'widget': []}
app_product = add('product-app', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = RunesIOS.app; sourceTree = BUILT_PRODUCTS_DIR;')
widget_product = add('product-widget', 'isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = RunesActivity.appex; sourceTree = BUILT_PRODUCTS_DIR;')
for name, files in [('app', app + shared), ('widget', widget + shared)]:
    add('sources-' + name, f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {array([build(p, name) for p in files])}; runOnlyForDeploymentPostprocessing = 0;')
    add('frameworks-' + name, 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    add('resources-' + name, f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {array([build(p, name) for p in resources[name]])}; runOnlyForDeploymentPostprocessing = 0;')
embed_file = add('embed-file', f'isa = PBXBuildFile; fileRef = {widget_product}; settings = {{ ATTRIBUTES = (RemoveHeadersOnCopy,); }};')
embed = add('embed', f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ({embed_file},); name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0;')
proxy = add('proxy', f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("target-widget")}; remoteInfo = RunesActivity;')
dependency = add('dependency', f'isa = PBXTargetDependency; target = {uid("target-widget")}; targetProxy = {proxy};')
for scope in ['project', 'app', 'widget']:
    configs = []
    for config in ['Debug', 'Release']:
        settings = {'IPHONEOS_DEPLOYMENT_TARGET':'26.0', 'SDKROOT':'iphoneos', 'SWIFT_VERSION':'5.0', 'CLANG_ENABLE_MODULES':'YES', 'CLANG_ENABLE_OBJC_ARC':'YES', 'ENABLE_USER_SCRIPT_SANDBOXING':'YES'}
        if scope == 'project':
            settings.update({'DEBUG_INFORMATION_FORMAT': 'dwarf' if config == 'Debug' else 'dwarf-with-dsym', 'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if config == 'Debug' else '-O', 'SWIFT_COMPILATION_MODE':'singlefile' if config == 'Debug' else 'wholemodule'})
            if config == 'Debug': settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG $(inherited)'
        else:
            name = 'RunesIOS' if scope == 'app' else 'RunesActivity'
            settings.update({'PRODUCT_NAME':'$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER':'com.runes.RunesIOS' + ('.activity' if scope == 'widget' else ''), 'INFOPLIST_FILE':name + '/Info.plist', 'GENERATE_INFOPLIST_FILE':'NO', 'TARGETED_DEVICE_FAMILY':'1', 'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator', 'SUPPORTS_MACCATALYST':'NO', 'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD':'NO', 'CODE_SIGN_STYLE':'Automatic', 'DEVELOPMENT_TEAM':'JG9474JW32', 'CURRENT_PROJECT_VERSION':'1', 'MARKETING_VERSION':'0.1.0', 'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks' + (' @executable_path/../../Frameworks' if scope == 'widget' else '')})
            if scope == 'widget': settings.update({'APPLICATION_EXTENSION_API_ONLY':'YES', 'SKIP_INSTALL':'YES'})
            else: settings.update({'CODE_SIGN_ENTITLEMENTS':'RunesIOS/RunesIOS.entitlements', 'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon'})
        body = ' '.join(f'{key} = "{value}";' for key,value in settings.items())
        configs.append(add('config-' + scope + config, f'isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {config};'))
    add('config-list-' + scope, f'isa = XCConfigurationList; buildConfigurations = {array(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
for name, product in [('app', app_product), ('widget', widget_product)]:
    display = 'RunesIOS' if name == 'app' else 'RunesActivity'
    phases = [uid('sources-' + name), uid('frameworks-' + name), uid('resources-' + name)] + ([embed] if name == 'app' else [])
    add('target-' + name, f'isa = PBXNativeTarget; buildConfigurationList = {uid("config-list-" + name)}; buildPhases = {array(phases)}; buildRules = (); dependencies = {array([dependency] if name == "app" else [])}; name = {display}; productName = {display}; productReference = {product}; productType = "com.apple.product-type.' + ('application' if name == 'app' else 'app-extension') + '";')
products = add('products', f'isa = PBXGroup; children = ({app_product}, {widget_product},); name = Products; sourceTree = "<group>";')
source_refs = [uid('ref:' + path) for path in app + shared + widget + resources['app']]
source_refs += [ref('RunesIOS/Info.plist'), ref('RunesActivity/Info.plist')]
main = add('main-group', f'isa = PBXGroup; children = {array(source_refs + [products])}; sourceTree = "<group>";')
add('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600; }}; buildConfigurationList = {uid("config-list-project")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base,); mainGroup = {main}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({uid("target-app")}, {uid("target-widget")},);')
project = root/'RunesIOS.xcodeproj'
project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(f'{key} = {{ {body} }};' for key,body in objects.items()) + f'\n}}; rootObject = {uid("project")}; }}\n')
plist_common = {'CFBundleDevelopmentRegion':'$(DEVELOPMENT_LANGUAGE)', 'CFBundleExecutable':'$(EXECUTABLE_NAME)', 'CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)', 'CFBundleInfoDictionaryVersion':'6.0', 'CFBundleName':'$(PRODUCT_NAME)', 'CFBundleShortVersionString':'$(MARKETING_VERSION)', 'CFBundleVersion':'$(CURRENT_PROJECT_VERSION)'}
app_info = dict(plist_common, CFBundleDisplayName='Runes', CFBundlePackageType='APPL', LSRequiresIPhoneOS=True, NSCameraUsageDescription='Runes scans the band identity QR code displayed on your Mac.', NSMicrophoneUsageDescription='Runes records a voice note while you hold a finger on your band or the record button.', NSSpeechRecognitionUsageDescription='Runes writes your voice notes down on this iPhone. Nothing is sent anywhere.', NSBluetoothAlwaysUsageDescription='Runes connects to your Meta Neural Band to receive gestures, including during an active background session.', UIBackgroundModes=['audio', 'bluetooth-central'], NSSupportsLiveActivities=True, UIAppFonts=[Path(f).name for f in fonts], UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes':False}, UILaunchScreen={}, UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'])
widget_info = dict(plist_common, CFBundleDisplayName='Runes Session', CFBundlePackageType='XPC!', NSExtension={'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'})
for path, info in [('RunesIOS/Info.plist', app_info), ('RunesActivity/Info.plist', widget_info), ('RunesIOS/RunesIOS.entitlements', {})]:
    (root/path).write_bytes(plistlib.dumps(info, sort_keys=False))
entry = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target-app")}" BuildableName="RunesIOS.app" BlueprintName="RunesIOS" ReferencedContainer="container:RunesIOS.xcodeproj"/>'
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="NO" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{entry}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{entry}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{entry}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
(project/'xcshareddata/xcschemes').mkdir(parents=True, exist_ok=True)
(project/'xcshareddata/xcschemes/RunesIOS.xcscheme').write_text(scheme)

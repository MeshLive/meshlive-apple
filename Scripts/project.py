#!/usr/bin/env python3
"""Generate a small deterministic Xcode project without external tooling. No user signing data is written.

Default: the Android-compatible app (App/ + NearbyMedia + CNearbyVPX compiled into the app target,
NearbyCore as a static library). `--v1-experiment` instead generates the retained, default-off
standalone Noise XX v1 app (Experimental/V1App + Sources/NearbyV1Experimental)."""
from pathlib import Path
import hashlib, sys
v1 = "--v1-experiment" in sys.argv

root = Path(__file__).resolve().parent.parent
project = root / "NearbyIntercom.xcodeproj"
project.mkdir(exist_ok=True)
def uid(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def quote(s): return '"' + str(s).replace('\\', '\\\\').replace('"', '\\"') + '"'
objects = []
def obj(name, value): objects.append(f'{uid(name)} = {{ {value} }};'); return uid(name)
if v1:
    app_dirs = [root / "Experimental/V1App", root / "Sources/NearbyV1Experimental"]
    sources = sorted(p.relative_to(root).as_posix() for d in app_dirs for p in d.rglob("*") if p.suffix == ".swift")
    sources.append("App/Media/NativeAudio.c")
else:
    app_dirs = [root / "App", root / "Sources/NearbyMedia", root / "Sources/CNearbyVPX"]
    sources = sorted(p.relative_to(root).as_posix() for d in app_dirs for p in d.rglob("*") if p.suffix in (".swift", ".c"))
coresources = sorted(p.relative_to(root).as_posix() for p in (root / "Sources/NearbyCore").glob("*.swift"))
buildfiles, corefiles, children, resources = [], [], [], []
assets = ["App/Assets.xcassets"] if (root / "App/Assets.xcassets").exists() and not v1 else []
for path in sources + coresources + ["App/Info.plist", "App/PrivacyInfo.xcprivacy"] + assets:
    ext = Path(path).suffix
    kind = {".swift":"sourcecode.swift", ".c":"sourcecode.c.c", ".plist":"text.plist.xml", ".xcprivacy":"text.plist.xml", ".xcassets":"folder.assetcatalog"}[ext]
    ref = obj(path, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {quote(path)}; sourceTree = SOURCE_ROOT;')
    children.append(ref)
    if path in sources: buildfiles.append(obj("build:"+path, f'isa = PBXBuildFile; fileRef = {ref};'))
    elif path in coresources: corefiles.append(obj("build:"+path, f'isa = PBXBuildFile; fileRef = {ref};'))
    elif ext in (".xcprivacy", ".xcassets"): resources.append(obj("build:"+path, f'isa = PBXBuildFile; fileRef = {ref};'))
product = obj("product", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = NearbyIntercom.app; sourceTree = BUILT_PRODUCTS_DIR;')
coreproduct = obj("core-product", 'isa = PBXFileReference; explicitFileType = archive.ar; path = libNearbyCore.a; sourceTree = BUILT_PRODUCTS_DIR;')
core = obj("core-link", f'isa = PBXBuildFile; fileRef = {coreproduct};')
frameworks = [core]
opus = root / "Vendor/Opus.xcframework"
if opus.exists():
    ref = obj("opus-ref", 'isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = Vendor/Opus.xcframework; sourceTree = SOURCE_ROOT;')
    children.append(ref); frameworks.append(obj("opus-link", f'isa = PBXBuildFile; fileRef = {ref};'))
vpx = root / "Vendor/VPX.xcframework"
if vpx.exists() and not v1:
    ref = obj("vpx-ref", 'isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = Vendor/VPX.xcframework; sourceTree = SOURCE_ROOT;')
    children.append(ref); frameworks.append(obj("vpx-link", f'isa = PBXBuildFile; fileRef = {ref};'))
group = obj("group", f'isa = PBXGroup; children = ({",".join(children+[product,coreproduct])}); sourceTree = "<group>";')
srcphase = obj("sources", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(buildfiles)}); runOnlyForDeploymentPostprocessing = 0;')
linkphase = obj("frameworks", f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({",".join(frameworks)}); runOnlyForDeploymentPostprocessing = 0;')
resphase = obj("resources", f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(resources)}); runOnlyForDeploymentPostprocessing = 0;')
configs = []
coreconfigs = []
for name in ["Debug", "Release"]:
    settings = {
        "PRODUCT_NAME":"NearbyIntercom", "PRODUCT_BUNDLE_IDENTIFIER":"io.github.meshlive.app",
        "IPHONEOS_DEPLOYMENT_TARGET":"16.0", "SDKROOT":"iphoneos", "TARGETED_DEVICE_FAMILY":"1",
        "SUPPORTED_PLATFORMS":"iphoneos iphonesimulator", "SWIFT_VERSION":"5.0",
        "INFOPLIST_FILE":"App/Info.plist", "SWIFT_OBJC_BRIDGING_HEADER":"Experimental/V1App/BridgingHeader.h" if v1 else "App/BridgingHeader.h",
        "CODE_SIGN_STYLE":"Automatic", "ENABLE_USER_SCRIPT_SANDBOXING":"YES",
        "SWIFT_OPTIMIZATION_LEVEL":"-Onone" if name == "Debug" else "-O",
        "DEBUG_INFORMATION_FORMAT":"dwarf", "CLANG_ENABLE_MODULES":"YES", "CLANG_C_LANGUAGE_STANDARD":"gnu11",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS":"DEBUG" if name == "Debug" else "",
        "ASSETCATALOG_COMPILER_APPICON_NAME":"AppIcon" if assets else "",
    }
    device_headers, simulator_headers = ["$(inherited)", "$(SRCROOT)/Sources/CNearbyVPX/include"], ["$(inherited)", "$(SRCROOT)/Sources/CNearbyVPX/include"]
    if opus.exists():
        device_headers.append("$(SRCROOT)/Vendor/Opus.xcframework/ios-arm64/Headers")
        simulator_headers.append("$(SRCROOT)/Vendor/Opus.xcframework/ios-arm64_x86_64-simulator/Headers")
    # VPX headers (with their module map) are provided by Xcode's XCFramework processing; adding them
    # here as well would define module VPX twice.
    settings['"HEADER_SEARCH_PATHS[sdk=iphoneos*]"'] = " ".join(device_headers)
    settings['"HEADER_SEARCH_PATHS[sdk=iphonesimulator*]"'] = " ".join(simulator_headers)
    values = " ".join(f'{k} = {quote(v)};' for k,v in settings.items())
    configs.append(obj("config:"+name, f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ {values} }};'))
    ca = {k:v for k,v in settings.items() if k not in ["INFOPLIST_FILE", "SWIFT_OBJC_BRIDGING_HEADER", "PRODUCT_BUNDLE_IDENTIFIER"]}
    ca.update(PRODUCT_NAME="NearbyCore", PRODUCT_MODULE_NAME="NearbyCore", DEFINES_MODULE="YES", SKIP_INSTALL="YES", SWIFT_INSTALL_OBJC_HEADER="NO", MACH_O_TYPE="staticlib")
    corevalues = " ".join(f'{k} = {quote(v)};' for k,v in ca.items())
    coreconfigs.append(obj("core-config:"+name, f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ {corevalues} }};'))
configlist = obj("config-list", f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;')
coreconfiglist = obj("core-config-list", f'isa = XCConfigurationList; buildConfigurations = ({",".join(coreconfigs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;')
corephase = obj("core-sources", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(corefiles)}); runOnlyForDeploymentPostprocessing = 0;')
coretarget = obj("core-target", f'isa = PBXNativeTarget; name = NearbyCore; productName = NearbyCore; productReference = {coreproduct}; productType = "com.apple.product-type.library.static"; buildConfigurationList = {coreconfiglist}; buildPhases = ({corephase}); dependencies = ();')
dependency = obj("core-dependency", f'isa = PBXTargetDependency; target = {coretarget};')
target = obj("target", f'isa = PBXNativeTarget; name = NearbyIntercom; productName = NearbyIntercom; productReference = {product}; productType = "com.apple.product-type.application"; buildConfigurationList = {configlist}; buildPhases = ({srcphase},{linkphase},{resphase}); dependencies = ({dependency});')
# Device UI scenarios (XCUITest, screenshots per step): UITests/*.swift, run by Scripts/run-uitest.sh.
uitargets = []
uitest_testable = ""
if not v1 and (root / "UITests").exists():
    uisources = sorted(p.relative_to(root).as_posix() for p in (root / "UITests").glob("*.swift"))
    uibuild = []
    for path in uisources:
        ref = obj("ui:" + path, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(path)}; sourceTree = SOURCE_ROOT;')
        children.append(ref); uibuild.append(obj("ui-build:" + path, f'isa = PBXBuildFile; fileRef = {ref};'))
    uiproduct = obj("ui-product", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = NearbyIntercomUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
    uiphase = obj("ui-sources", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(uibuild)}); runOnlyForDeploymentPostprocessing = 0;')
    uiconfigs = []
    for name in ["Debug", "Release"]:
        us = {"PRODUCT_NAME": "NearbyIntercomUITests", "PRODUCT_BUNDLE_IDENTIFIER": "io.github.meshlive.app.uitests", "TEST_TARGET_NAME": "NearbyIntercom",
              "GENERATE_INFOPLIST_FILE": "YES", "IPHONEOS_DEPLOYMENT_TARGET": "16.0", "SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
              "TARGETED_DEVICE_FAMILY": "1", "SWIFT_VERSION": "5.0", "CODE_SIGN_STYLE": "Automatic", "SWIFT_OPTIMIZATION_LEVEL": "-Onone"}
        uvalues = " ".join(f'{k} = {quote(v)};' for k, v in us.items())
        uiconfigs.append(obj("ui-config:" + name, f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ {uvalues} }};'))
    uiconfiglist = obj("ui-config-list", f'isa = XCConfigurationList; buildConfigurations = ({",".join(uiconfigs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;')
    uidep = obj("ui-dependency", f'isa = PBXTargetDependency; target = {target};')
    uitarget = obj("ui-target", f'isa = PBXNativeTarget; name = NearbyIntercomUITests; productName = NearbyIntercomUITests; productReference = {uiproduct}; productType = "com.apple.product-type.bundle.ui-testing"; buildConfigurationList = {uiconfiglist}; buildPhases = ({uiphase}); dependencies = ({uidep});')
    uitargets = [uitarget]
    uitest_testable = f'<Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uitarget}" BuildableName="NearbyIntercomUITests.xctest" BlueprintName="NearbyIntercomUITests" ReferencedContainer="container:NearbyIntercom.xcodeproj"/></TestableReference></Testables>'
    group_obj = [o for o in objects if o.startswith(uid("group"))][0]
    objects.remove(group_obj)
    group = obj("group", f'isa = PBXGroup; children = ({",".join(children+[product,coreproduct,uiproduct])}); sourceTree = "<group>";')
proj = obj("project", f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {configlist}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {group}; projectDirPath = ""; projectRoot = ""; targets = ({",".join([target, coretarget] + uitargets)});')
(project / "project.pbxproj").write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+"\n".join(objects)+f'\n}}; rootObject = {proj}; }}\n')
scheme = project / "xcshareddata/xcschemes"
scheme.mkdir(parents=True, exist_ok=True)
(scheme / "NearbyIntercom.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="NearbyIntercom.app" BlueprintName="NearbyIntercom" ReferencedContainer="container:NearbyIntercom.xcodeproj"/></BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn" shouldUseLaunchSchemeArgsEnv="YES">{uitest_testable}</TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="NearbyIntercom.app" BlueprintName="NearbyIntercom" ReferencedContainer="container:NearbyIntercom.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release"/>
<AnalyzeAction buildConfiguration="Debug"/>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print("Generated NearbyIntercom.xcodeproj" + (" (EXPERIMENTAL standalone v1 app)" if v1 else "") + (" with pinned Opus" if opus.exists() else " (Opus absent)")
      + ("" if v1 else (" and libvpx" if vpx.exists() else " (libvpx absent: video unavailable)")))

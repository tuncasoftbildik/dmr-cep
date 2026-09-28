QT += quick quickcontrols2 network multimedia core gui concurrent
//QT += xlsx

unix:!ios:QT += serialport
win32:QT += serialport
!win32:LIBS += -ldl
win32:LIBS += -lws2_32
win32:QMAKE_LFLAGS += -static
QMAKE_LFLAGS_WINDOWS += --enable-stdcall-fixup
RC_ICONS = images/droidstar.ico
ICON = images/droidstar.icns
macx:LIBS += -framework AVFoundation
macx:QMAKE_MACOSX_DEPLOYMENT_TARGET = 12.0
macx:QMAKE_INFO_PLIST = Info.plist.mac
ios:LIBS += -framework AVFoundation -framework AudioToolbox -framework UIKit -framework MobileCoreServices -framework MediaPlayer -lz
ios:QMAKE_IOS_DEPLOYMENT_TARGET=15.0
# Qt 6.8+ defaults to the FFmpeg multimedia backend on iOS; the native Darwin one is enough here.
ios:QTPLUGIN.multimedia = darwinmediaplugin
ios:QMAKE_TARGET_BUNDLE_PREFIX = org.dudetronics
ios:QMAKE_BUNDLE = droidstar
ios:VERSION = 0.44.16
ios:Q_ENABLE_BITCODE.name = ENABLE_BITCODE
ios:Q_ENABLE_BITCODE.value = NO
ios:QMAKE_MAC_XCODE_SETTINGS += Q_ENABLE_BITCODE
ios:QMAKE_ASSET_CATALOGS += Images.xcassets
ios:QMAKE_INFO_PLIST = Info.plist
ios:QMAKE_IOS_LAUNCH_SCREEN = $$PWD/LaunchScreen.storyboard
VERSION_BUILD='$(shell cd $$PWD;git rev-parse --short HEAD)'
DEFINES += VERSION_NUMBER=\"\\\"$${VERSION_BUILD}\\\"\"
DEFINES += QT_DEPRECATED_WARNINGS
#DEFINES += QT_DEBUG_PLUGINS=1
#DEFINES += VOCODER_PLUGIN
#DEFINES += USE_FLITE
#DEFINES += USE_EXTERNAL_CODEC2
#DEFINES += USE_MD380_VOCODER

SOURCES += \
        CRCenc.cpp \
        vuidupdater.cpp \
        iosshare.mm \
        rxrecorder.cpp \
        LogHandler.cpp \
       Golay24128.cpp \
        M17Convolution.cpp \
        SHA256.cpp \
        YSFConvolution.cpp \
        YSFFICH.cpp \
        audioengine.cpp \
        cbptc19696.cpp \
        cgolay2087.cpp \
        chamming.cpp \
        crs129.cpp \
        dcs.cpp \
        dmr.cpp \
        droidstar.cpp \
        phonegps.cpp \
        httpmanager.cpp \
        iax.cpp \
        imbe_vocoder/aux_sub.cc \
        imbe_vocoder/basicop2.cc \
        imbe_vocoder/ch_decode.cc \
        imbe_vocoder/ch_encode.cc \
        imbe_vocoder/dc_rmv.cc \
        imbe_vocoder/decode.cc \
        imbe_vocoder/dsp_sub.cc \
        imbe_vocoder/encode.cc \
        imbe_vocoder/imbe_vocoder.cc \
        imbe_vocoder/imbe_vocoder_impl.cc \
        imbe_vocoder/math_sub.cc \
        imbe_vocoder/pe_lpf.cc \
        imbe_vocoder/pitch_est.cc \
        imbe_vocoder/pitch_ref.cc \
        imbe_vocoder/qnt_sub.cc \
        imbe_vocoder/rand_gen.cc \
        imbe_vocoder/sa_decode.cc \
        imbe_vocoder/sa_encode.cc \
        imbe_vocoder/sa_enh.cc \
        imbe_vocoder/tbls.cc \
        imbe_vocoder/uv_synt.cc \
        imbe_vocoder/v_synt.cc \
        imbe_vocoder/v_uv_det.cc \
        m17.cpp \
        main.cpp \
        mode.cpp \
        nxdn.cpp \
        p25.cpp \
        ref.cpp \
        xrf.cpp \
        ysf.cpp \
        LiveActivityQtBridge.cpp
# Android-specific source files
android:SOURCES += androidserialport.cpp

# Non-iOS source files
!ios:SOURCES += serialambe.cpp serialmodem.cpp

# Objective-C source files for macOS and iOS
macx:OBJECTIVE_SOURCES += micpermission.mm
ios:OBJECTIVE_SOURCES += micpermission.mm AudioSessionManager.mm
ios:OBJECTIVE_SOURCES += ios_live_activity.mm
ios:OBJECTIVE_SOURCES += PushToTalkManager.mm
# Phone position as DMR hotspot location (CoreLocation; Qt Positioning is not in the iOS kit).
# The permission text is NSLocationWhenInUseUsageDescription in Info.plist.
ios:OBJECTIVE_SOURCES += phonegps_ios.mm
ios:LIBS += -framework CoreLocation
ios:HEADERS += PushToTalkManager.h
# PushToTalk is iOS 16+; weak link so the app still starts on iOS 14/15 (feature hidden there).
ios:LIBS += -weak_framework PushToTalk
ios:PTT_ENTITLEMENTS.name = CODE_SIGN_ENTITLEMENTS
ios:PTT_ENTITLEMENTS.value = $$PWD/DroidStar.entitlements
ios:QMAKE_MAC_XCODE_SETTINGS += PTT_ENTITLEMENTS

# Enable background audio mode for iOS
ios:QMAKE_MAC_XCODE_SETTINGS += QMAKE_IOS_BACKGROUND_MODES = YES
ios:QMAKE_INFO_PLIST_EXTRA += "<key>UIBackgroundModes</key>"
ios:QMAKE_INFO_PLIST_EXTRA += "<array>"
ios:QMAKE_INFO_PLIST_EXTRA += "    <string>audio</string>"
ios:QMAKE_INFO_PLIST_EXTRA += "    <string>push-to-talk</string>"
ios:QMAKE_INFO_PLIST_EXTRA += "</array>"
ios:QMAKE_CXXFLAGS += -fobjc-arc

# Live Activities / Dynamic Island (see docs/live-activity-build.md).
# App side: the Swift files below are compiled into the main target. qmake's Xcode generator
# only puts files with a known source extension into "Compile Sources" (otherwise they are
# listed but never built, and NSClassFromString(@"LiveActivityManager") fails at runtime),
# so .swift is registered as a source extension here. Xcode picks the Swift compiler by type.
LA_SWIFT_SOURCES = LiveActivityManager.swift DroidStarActivityAttributes.swift
ios:SOURCES += $$LA_SWIFT_SOURCES
ios:QMAKE_EXT_CPP += .swift
# ...which types them as C++ in the project file. This preprocess step (part of
# qt_preprocess.mak, so it runs right after qmake) retypes them as Swift. It re-runs whenever
# qmake rewrites the project file.
ios {
    swift_filetype.input = LA_SWIFT_SOURCES
    swift_filetype.output = $$OUT_PWD/.swift_filetype.stamp
    swift_filetype.depends = $$OUT_PWD/$${TARGET}.xcodeproj/project.pbxproj
    swift_filetype.commands = /bin/bash $$shell_quote($$PWD/scripts/xcodeproj_swift_filetype.sh) $$shell_quote($$OUT_PWD/$${TARGET}.xcodeproj) && touch ${QMAKE_FILE_OUT}
    swift_filetype.CONFIG = combine no_link target_predeps
    swift_filetype.variable_out = LA_UNUSED
    QMAKE_EXTRA_COMPILERS += swift_filetype
}

# Xcode build settings must be name/value pairs; "KEY=VALUE" strings are written verbatim
# as bogus setting names and have no effect.
ios {
    LA_SWIFT_VERSION.name = SWIFT_VERSION
    LA_SWIFT_VERSION.value = 5.0
    LA_CLANG_MODULES.name = CLANG_ENABLE_MODULES
    LA_CLANG_MODULES.value = YES
    LA_EMBED_SWIFT.name = ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES
    LA_EMBED_SWIFT.value = NO
    LA_SWIFT_MODULE.name = PRODUCT_MODULE_NAME
    LA_SWIFT_MODULE.value = DroidStar
    QMAKE_MAC_XCODE_SETTINGS += LA_SWIFT_VERSION LA_CLANG_MODULES LA_EMBED_SWIFT LA_SWIFT_MODULE

    # UI side: the WidgetKit extension (ios/LiveActivityExtension) is a separate XcodeGen
    # project. This post-link phase builds it with the same team/configuration and copies the
    # signed .appex into DroidStar.app/PlugIns before Xcode signs the app.
    # Set LIVEACTIVITY_SKIP=1 in the environment to build without it.
    QMAKE_POST_LINK += /bin/bash $$shell_quote($$PWD/scripts/embed_live_activity_extension.sh)
}


                         


resources.files = main.qml AboutTab.qml HostsTab.qml LogTab.qml MainTab.qml SettingsTab.qml fontawesome-webfont.ttf QsoTab.qml \
                  qtquickcontrols2.conf \
                  sounds/connected.wav \
                  fonts/DSEG7Classic-Bold.ttf \
                  translations/droidstar_tr.qm \
                  images/droidstar.png \
                  images/dmrcep.png \
                  qml/AppShell.qml \
                  qml/theme/Theme.qml \
                  qml/components/AppCard.qml \
                  qml/components/IconTabButton.qml \
                  ui2026/App2026.qml \
                  ui2026/theme/Tokens.qml \
                  ui2026/components/AppCard.qml \
                  ui2026/components/DrawerItem.qml \
                  ui2026/components/CollapsibleSection.qml \
                  ui2026/components/ReplayList.qml \
                  ui2026/components/SignalBars.qml \
                  ui2026/components/ChannelsSheet.qml \
                  ui2026/pages/MainPage.qml \
                  ui2026/pages/SettingsPage.qml \
                  ui2026/pages/QsoPage.qml \
                  ui2026/pages/LogPage.qml \
                  ui2026/pages/HostsPage.qml \
                  ui2026/pages/AboutPage.qml
resources.prefix = /$${TARGET}
RESOURCES += resources

# Additional import path used to resolve QML modules in Qt Creator's code model
QML_IMPORT_PATH =

# Additional import path used to resolve QML modules just for Qt Quick Designer
QML_DESIGNER_IMPORT_PATH =

# Default rules for deployment.
qnx: target.path = /tmp/$${TARGET}/bin
else: unix:!android: target.path = /opt/$${TARGET}/bin
!isEmpty(target.path): INSTALLS += target

HEADERS += \
	CRCenc.h \
	DMRDefines.h \
	vuidupdater.h \
	LogHandler.h \
	AudioSessionManager.h \
     Golay24128.h \
	M17Convolution.h \
	M17Defines.h \
	MMDVMDefines.h \
	SHA256.h \
	YSFConvolution.h \
	YSFFICH.h \
	audioengine.h \
	cbptc19696.h \
	cgolay2087.h \
	chamming.h \
	crs129.h \
	dcs.h \
	dmr.h \
	dmrposition.h \
	talkeralias.h \
	droidstar.h \
	phonegps.h \
	httpmanager.h \
	iax.h \
	iaxdefines.h \
	imbe_vocoder/aux_sub.h \
	imbe_vocoder/basic_op.h \
	imbe_vocoder/ch_decode.h \
	imbe_vocoder/ch_encode.h \
	imbe_vocoder/dc_rmv.h \
	imbe_vocoder/decode.h \
	imbe_vocoder/dsp_sub.h \
	imbe_vocoder/encode.h \
	imbe_vocoder/globals.h \
	imbe_vocoder/imbe.h \
	imbe_vocoder/imbe_vocoder.h \
	imbe_vocoder/imbe_vocoder_api.h \
	imbe_vocoder/imbe_vocoder_impl.h \
	imbe_vocoder/math_sub.h \
	imbe_vocoder/pe_lpf.h \
	imbe_vocoder/pitch_est.h \
	imbe_vocoder/pitch_ref.h \
	imbe_vocoder/qnt_sub.h \
	imbe_vocoder/rand_gen.h \
	imbe_vocoder/sa_decode.h \
	imbe_vocoder/sa_encode.h \
	imbe_vocoder/sa_enh.h \
	imbe_vocoder/tbls.h \
	imbe_vocoder/typedef.h \
	imbe_vocoder/typedefs.h \
	imbe_vocoder/uv_synt.h \
	imbe_vocoder/v_synt.h \
	imbe_vocoder/v_uv_det.h \
	m17.h \
	mode.h \
	nxdn.h \
	p25.h \
	ref.h \
	vocoder_plugin.h \
	xrf.h \
	ysf.h \
        LiveActivityQtBridge.h \
        ios_live_activity.h \
        rxrecorder.h \
        languagemanager.h

!contains(DEFINES, USE_EXTERNAL_CODEC2){
HEADERS += \
	codec2/codec2_api.h \
	codec2/codec2_internal.h \
	codec2/defines.h \
	codec2/kiss_fft.h \
	codec2/lpc.h \
	codec2/nlp.h \
	codec2/qbase.h \
	codec2/quantise.h
SOURCES += \
	codec2/codebooks.cpp \
	codec2/codec2.cpp \
	codec2/kiss_fft.cpp \
	codec2/lpc.cpp \
	codec2/nlp.cpp \
	codec2/pack.cpp \
	codec2/qbase.cpp \
	codec2/quantise.cpp
}
contains(DEFINES, USE_EXTERNAL_CODEC2){
LIBS += -lcodec2
}
!contains(DEFINES, VOCODER_PLUGIN){
HEADERS += \
	mbe/ambe3600x2400_const.h \
	mbe/ambe3600x2450_const.h \
	mbe/ecc_const.h \
	mbe/mbelib.h \
	mbe/mbelib_const.h \
	mbe/mbelib_parms.h \
	mbe/vocoder_plugin.h \
	mbe/vocoder_plugin_api.h \
	mbe/vocoder_tables.h
SOURCES += \
	mbe/ambe3600x2400.c \
	mbe/ambe3600x2450.c \
	mbe/ecc.c \
	mbe/mbelib.c \
	mbe/vocoder_plugin.cpp
}

android:HEADERS += androidserialport.h
macx:HEADERS += micpermission.h
!ios:HEADERS += serialambe.h serialmodem.h
android:ANDROID_VERSION_CODE = 79
android:QT_ANDROID_MIN_SDK_VERSION = 31

contains(ANDROID_TARGET_ARCH,armeabi-v7a) {
	ANDROID_PACKAGE_SOURCE_DIR = $$PWD/android
}

contains(ANDROID_TARGET_ARCH,arm64-v8a) {
	ANDROID_PACKAGE_SOURCE_DIR = $$PWD/android
}

contains(DEFINES, USE_FLITE){
	LIBS += -lflite_cmu_us_slt -lflite_cmu_us_kal16 -lflite_cmu_us_awb -lflite_cmu_us_rms -lflite_usenglish -lflite_cmulex -lflite -lasound
}
contains(DEFINES, USE_MD380_VOCODER){
	LIBS += -lmd380_vocoder -Xlinker --section-start=.firmware=0x0800C000 -Xlinker  --section-start=.sram=0x20000000
}

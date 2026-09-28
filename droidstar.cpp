/*
    Copyright (C) 2019-2021 Doug McLain
    Modification Copyright (C) 2024 Rohith Namboothiri

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

#include "droidstar.h"
#include "httpmanager.h"
#include "rxrecorder.h"
#include "dmrposition.h"
#include <QUrl>
#include <QGuiApplication>
#include <QTimer>
#include <QDateTime>
#include <QNetworkInformation>
#ifdef Q_OS_ANDROID
#include <QCoreApplication>
#include <QJniObject>
#endif
#ifdef Q_OS_IOS
#include "micpermission.h"
#include "AudioSessionManager.h"
#include "PushToTalkManager.h"
#include "ios_live_activity.h"
#include "HardwareButtonPTT.h"
#endif
#include <QStandardPaths>
#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QFont>
#include <QFontDatabase>
#include <cstring>
#include <stdio.h>
#include <fcntl.h>
#include <iostream>

#ifdef Q_OS_IOS
// Static instance for PTT callbacks from remote commands (headphones, Control Center)
static DroidStar *s_droidStarInstance = nullptr;

static void pttPressCallback() {
    if (s_droidStarInstance) {
        QMetaObject::invokeMethod(s_droidStarInstance, "press_tx", Qt::QueuedConnection);
    }
}

static void pttReleaseCallback() {
    if (s_droidStarInstance) {
        QMetaObject::invokeMethod(s_droidStarInstance, "release_tx", Qt::QueuedConnection);
    }
}

// PushToTalk framework callbacks arrive on the iOS main queue; hop onto the Qt thread.
static void pttSystemBeginCallback() {
    if (s_droidStarInstance) {
        QMetaObject::invokeMethod(s_droidStarInstance, "ptt_system_begin_tx", Qt::QueuedConnection);
    }
}

static void pttSystemEndCallback() {
    if (s_droidStarInstance) {
        QMetaObject::invokeMethod(s_droidStarInstance, "ptt_system_end_tx", Qt::QueuedConnection);
    }
}

// Volume buttons and the Action Button intent (HardwareButtonPTT.mm). Called on the main thread,
// which is the Qt GUI thread on iOS, so the result can be returned synchronously.
static int hwPttHandler(int action, const char *source) {
    DroidStar *d = s_droidStarInstance;
    if (!d) return -1;
    const QString src = QString::fromUtf8(source ? source : "?");
    if (QThread::currentThread() == d->thread()) return d->hw_ptt_action(action, src);
    int r = -1;
    QMetaObject::invokeMethod(d, [d, action, src]() { return d->hw_ptt_action(action, src); },
                              Qt::BlockingQueuedConnection, &r);
    return r;
}

static void hwPttLog(const char *line) {
    const QString l = QString::fromUtf8(line ? line : "");
    qDebug().noquote() << "[HWPTT]" << l;
    if (s_droidStarInstance) {
        QMetaObject::invokeMethod(s_droidStarInstance, "hw_ptt_log", Qt::QueuedConnection, Q_ARG(QString, l));
    }
}

static void pttAudioActivatedCallback() {
    if (s_droidStarInstance) {
        QMetaObject::invokeMethod(s_droidStarInstance, "ptt_audio_activated", Qt::QueuedConnection);
    }
}

static void pttStatusCallback(const char *message) {
    if (s_droidStarInstance) {
        const QString m = QString::fromUtf8(message);
        QMetaObject::invokeMethod(s_droidStarInstance, [m]() {
            if (s_droidStarInstance) emit s_droidStarInstance->update_log(m);
        }, Qt::QueuedConnection);
    }
}
#endif

DroidStar::DroidStar(QObject *parent) :
    QObject(parent),
    m_dmrid(0),
    m_essid(0),
    m_dmr_destid(0),
    m_outlevel(0),
    m_mdirect(false),
    m_tts(0),
    m_reconnectTimer(new QTimer(this)),
    m_keepAliveTimer(new QTimer(this)),
     m_audioEngine(new AudioEngine("defaultInputDevice", "defaultOutputDevice")) // Instantiate AudioEngine


{
    // Connect the audio device list update signal to a slot
      connect(m_audioEngine, &AudioEngine::audioDeviceListChanged, this, &DroidStar::updateDeviceListInQML);

      // Discover initial audio devices
      QStringList playbackDevices = m_audioEngine->discover_audio_devices(1);  // 1 for playback devices
      QStringList captureDevices = m_audioEngine->discover_audio_devices(0);   // 0 for capture devices

    
    qRegisterMetaType<Mode::MODEINFO>("Mode::MODEINFO");
    m_settings_processed = false;
    m_modelchange = false;
    connect_status = Mode::DISCONNECTED;
    m_settings = new QSettings(QSettings::IniFormat, QSettings::UserScope, "dudetronics", "droidstar", this);
    qDebug() << "QSettings file:" << m_settings->fileName()
             << "exists:" << QFileInfo(m_settings->fileName()).exists();
    config_path = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation);
   
        connect(m_reconnectTimer, &QTimer::timeout, this, &DroidStar::attempt_reconnect);
        connect(m_keepAliveTimer, &QTimer::timeout, this, &DroidStar::send_keep_alive);

  


        // Start timers
        m_reconnectTimer->setInterval(5000);
        m_reconnectTimer->setSingleShot(true);
        m_keepAliveTimer->setInterval(30000);

        // A connect attempt that gets no answer (dead network) would otherwise sit in CONNECTING forever.
        m_connectTimeoutTimer = new QTimer(this);
        m_connectTimeoutTimer->setSingleShot(true);
        m_connectTimeoutTimer->setInterval(15000);
        connect(m_connectTimeoutTimer, &QTimer::timeout, this, &DroidStar::on_connect_timeout);

        // Re-sends the Live Activity state now and then so a quiet link does not look stale.
        m_laRefreshTimer = new QTimer(this);
        m_laRefreshTimer->setInterval(5 * 60 * 1000);
        connect(m_laRefreshTimer, &QTimer::timeout, this, [this]() { live_activity_sync(true); });
#ifdef Q_OS_IOS
        // A previous run may have been killed with its card still on the lock screen.
        ios_live_activity_end_all();
#endif

        if (QNetworkInformation::loadDefaultBackend() && QNetworkInformation::instance()) {
            QNetworkInformation *ni = QNetworkInformation::instance();
            connect(ni, &QNetworkInformation::reachabilityChanged, this, &DroidStar::on_network_state_changed);
            connect(ni, &QNetworkInformation::transportMediumChanged, this, &DroidStar::on_transport_medium_changed);
            qDebug() << "Network information backend:" << ni->backendName();
        } else {
            qDebug() << "Network information backend not available";
        }

#if !defined(Q_OS_ANDROID) && !defined(Q_OS_WIN)
    config_path += "/dudetronics";
#endif
#if defined(Q_OS_ANDROID)
    keepScreenOn();
    m_USBmonitor = &AndroidSerialPort::GetInstance();
    connect(m_USBmonitor, SIGNAL(devices_changed()), this, SLOT(discover_devices()));
#endif
    m_phoneGps = new PhoneGps(this);
    connect(m_phoneGps, &PhoneGps::status_changed, this, &DroidStar::gps_status_changed);
    connect(m_phoneGps, &PhoneGps::position_changed, this, &DroidStar::on_phone_position);
    m_gpsThrottleTimer = new QTimer(this);
    m_gpsThrottleTimer->setSingleShot(true);
    connect(m_gpsThrottleTimer, &QTimer::timeout, this, &DroidStar::on_phone_position);

    check_host_files();
    discover_devices();
    process_settings();

    qDebug() << "CPU arch: " << QSysInfo::currentCpuArchitecture();
    qDebug() << "Build ABI: " << QSysInfo::buildAbi();
    qDebug() << "boot ID: " << QSysInfo::bootUniqueId();
    qDebug() << "Pretty name: " << QSysInfo::prettyProductName();
    qDebug() << "Type: " << QSysInfo::productType();
    qDebug() << "Version: " << QSysInfo::productVersion();
    qDebug() << "Kernel type: " << QSysInfo::kernelType();
    qDebug() << "Kernel version: " << QSysInfo::kernelVersion();
    qDebug() << "Software version: " << VERSION_NUMBER;
    
#ifdef Q_OS_IOS
    // Register this instance for PTT callbacks from remote commands (headphones, Control Center)
    s_droidStarInstance = this;
    setPTTCallbacks(pttPressCallback, pttReleaseCallback);
    setRemotePTTEnabled(m_headphonePtt);
    hwptt_set_handler(hwPttHandler);
    hwptt_set_log(hwPttLog);
    hwptt_configure(m_hwPttButtons, m_hwPttMode);
    // Volume buttons are only captured while connected; otherwise they stay plain volume keys.
    connect(this, &DroidStar::connect_status_changed, this, [this](int c) {
        if (c != 2) m_txOn = false;
        hwptt_set_armed(c == 2);
    });
    ptt_set_callbacks(pttSystemBeginCallback, pttSystemEndCallback, pttStatusCallback, pttAudioActivatedCallback);
#endif
}

DroidStar::~DroidStar()
{
#ifdef Q_OS_IOS
    s_droidStarInstance = nullptr;
    setAudioConnectionState(false, "", "");
#endif
    delete m_reconnectTimer;
    delete m_keepAliveTimer;
    delete m_audioEngine;
}
#ifdef Q_OS_ANDROID
void DroidStar::keepScreenOn()
{
    char const * const action = "addFlags";
    QNativeInterface::QAndroidApplication::runOnAndroidMainThread([action](){
    QJniObject activity = QNativeInterface::QAndroidApplication::context();
    if (activity.isValid()) {
        QJniObject window = activity.callObjectMethod("getWindow", "()Landroid/view/Window;");

        if (window.isValid()) {
            const int FLAG_KEEP_SCREEN_ON = 128;
            window.callMethod<void>("addFlags", "(I)V", FLAG_KEEP_SCREEN_ON);
        }
    }});

    QMicrophonePermission microphonePermission;
    if (qApp->checkPermission(microphonePermission) != Qt::PermissionStatus::Granted) {
        qApp->requestPermission(microphonePermission, this, &DroidStar::keepScreenOn);
    }
}

void DroidStar::reset_connect_status()
{
    if(connect_status == Mode::CONNECTED_RW){
        connect_status = Mode::CONNECTING;
        process_connect();
    }
}
#endif

void DroidStar::updateDeviceListInQML()
{
    // Update the playback and capture devices
    m_playbackDevices = m_audioEngine->discover_audio_devices(1);  // 1 for playback devices
    m_captureDevices = m_audioEngine->discover_audio_devices(0);   // 0 for capture devices

    // Emit signals to notify QML of the changes
    emit playbackDevicesChanged();
    emit captureDevicesChanged();
    //emit audioEngineChanged();
}


void DroidStar::discover_devices()
{
    m_playbacks.clear();
    m_captures.clear();
    m_vocoders.clear();
    m_modems.clear();
    m_playbacks.append("OS Default");
    m_captures.append("OS Default");
    m_vocoders.append("Software vocoder");
    m_modems.append("None");
    m_playbacks.append(m_audioEngine->discover_audio_devices(AUDIO_OUT));
    m_captures.append(m_audioEngine->discover_audio_devices(AUDIO_IN));
#if !defined(Q_OS_IOS)
    QMap<QString, QString> l = SerialAMBE::discover_devices();
    QMap<QString, QString>::const_iterator i = l.constBegin();

    while (i != l.constEnd()) {
        m_vocoders.append(i.value());
        m_modems.append(i.value());
        ++i;
    }
    emit update_devices();
#endif
}

void DroidStar::download_file(QString f, bool u)
{
    HttpManager *http = new HttpManager(f, u);
    QThread *httpThread = new QThread;
    http->moveToThread(httpThread);
    connect(httpThread, SIGNAL(started()), http, SLOT(process()));
    if(u){
        connect(http, SIGNAL(file_downloaded(QString)), this, SLOT(url_downloaded(QString)));
    }
    else{
        connect(http, SIGNAL(file_downloaded(QString)), this, SLOT(file_downloaded(QString)));
    }
    connect(httpThread, SIGNAL(finished()), http, SLOT(deleteLater()));
    httpThread->start();
}

void DroidStar::url_downloaded(QString url)
{
    emit update_log("Downloaded " + url);
}

void DroidStar::file_downloaded(QString filename)
{
    emit update_log("Updated " + filename);
    bool hostsChangedForCurrentMode = false;
    if(filename == "dplus.txt" && m_protocol == "REF"){
        process_dstar_hosts(m_protocol);
        hostsChangedForCurrentMode = true;
    }
    else if(filename == "dextra.txt" && m_protocol == "XRF"){
        process_dstar_hosts(m_protocol);
        hostsChangedForCurrentMode = true;
    }
    else if(filename == "dcs.txt" && m_protocol == "DCS"){
        process_dstar_hosts(m_protocol);
        hostsChangedForCurrentMode = true;
    }
    else if(filename == "YSFHosts.txt" && m_protocol == "YSF"){
        process_ysf_hosts();
        hostsChangedForCurrentMode = true;
    }
    else if(filename == "FCSHosts.txt" && m_protocol == "FCS"){
        process_fcs_rooms();
        hostsChangedForCurrentMode = true;
    }
    else if(filename == "P25Hosts.txt" && m_protocol == "P25"){
        process_p25_hosts();
        hostsChangedForCurrentMode = true;
    }
    else if(filename == "DMRHosts.txt" && m_protocol == "DMR"){
        process_dmr_hosts();
        hostsChangedForCurrentMode = true;
    }
    else if(filename == "NXDNHosts.txt" && m_protocol == "NXDN"){
        process_nxdn_hosts();
        hostsChangedForCurrentMode = true;
    }
    else if(filename == "M17Hosts-full.csv" && m_protocol == "M17"){
        process_m17_hosts();
        hostsChangedForCurrentMode = true;
    }
    else if(filename == "DMRIDs.dat"){
        process_dmr_ids();
    }
    else if(filename == "NXDN.csv"){
        process_nxdn_ids();
    }

    // Critical: when host files are downloaded/updated asynchronously, refresh QML bindings.
    // Legacy UI effectively refreshed hosts on mode change; new UI needs an explicit signal.
    if (hostsChangedForCurrentMode) {
        emit mode_changed();
    }
}

void DroidStar::dtmf_send_clicked(QString dtmf)
{
    QByteArray tx(dtmf.simplified().toUtf8(), dtmf.simplified().size());
    emit send_dtmf(tx);
}

void DroidStar::tts_changed(QString tts)
{
    if(tts == "Mic"){
        m_tts = 0;
    }
    else if(tts == "TTS1"){
        m_tts = 1;
    }
    else if(tts == "TTS2"){
        m_tts = 2;
    }
    else if(tts == "TTS3"){
        m_tts = 3;
    }
    else{
        m_tts = 0;
    }
    emit input_source_changed(m_tts, m_ttstxt);
}

void DroidStar::tts_text_changed(QString ttstxt)
{
    m_ttstxt = ttstxt;
    emit input_source_changed(m_tts, m_ttstxt);
}

void DroidStar::process_connect()
{
    qDebug() << "process_connect() called:"
             << "connect_status=" << connect_status
             << "protocol=" << m_protocol
             << "callsign=" << m_callsign
             << "dmrid=" << m_dmrid
             << "module=" << QChar(m_module)
             << "saved_dmrhost=" << m_saved_dmrhost;

    // Whatever the user (or a reconnect) does with the link, launch auto-connect is off now.
    m_launchAutoConnectUsed = true;

    if((connect_status == Mode::DISCONNECTED) && m_autoReconnect && m_reconnectTimer->isActive()){
        // Waiting between automatic attempts; the UI shows "Cancel", so this click cancels.
        m_reconnectTimer->stop();
        m_autoReconnect = false;
        m_reconnectAttempt = 0;
#ifdef Q_OS_IOS
        ptt_leave();
        m_pttTalker.clear();
#endif
        emit connect_status_changed(0);
#ifdef Q_OS_IOS
        setAudioReconnectHold(false);
#endif
        emit update_log("Auto-reconnect cancelled");
        live_activity_sync();
        return;
    }
    if(connect_status != Mode::DISCONNECTED){
#ifdef Q_OS_IOS
        if (!m_keepPttChannel) {
            ptt_leave();
            m_pttTalker.clear();
        }
#endif
        m_autoReconnect = false;
        m_reconnectAttempt = 0;
        m_reconnectTimer->stop();
        m_connectTimeoutTimer->stop();
        connect_status = Mode::DISCONNECTED;
        m_modethread->quit();
        m_data1.clear();
        m_data2.clear();
        m_data3.clear();
        m_data4.clear();
        m_data5.clear();
        m_data6.clear();
#ifdef Q_OS_IOS
        // Notify audio session manager of disconnection (clears Now Playing).
        // m_keepPttChannel is only set when the link died and a reconnect follows.
        setAudioReconnectHold(m_keepPttChannel);
        setAudioConnectionState(false, "", "");
#endif
        emit connect_status_changed(0);
        emit update_log("Disconnected");
        // An automatic reconnect keeps the card up (it switches to "reconnecting" below).
        if (!m_keepPttChannel) live_activity_sync();
    }
    else{
#ifdef Q_OS_IOS
        MicPermission::check_permission();
        // Set up audio session EARLY so background mode is configured before audio starts.
        setupAVAudioSession();
#endif
        if(m_protocol == "REF"){
            m_refname = m_saved_refhost;
        }
        else if(m_protocol == "DCS"){
            m_refname = m_saved_dcshost;
        }
        else if(m_protocol == "XRF"){
            m_refname = m_saved_xrfhost;
        }
        else if(m_protocol == "YSF"){
            m_refname = m_saved_ysfhost;
        }
        else if(m_protocol == "FCS"){
            m_refname = m_saved_fcshost;
        }
        else if(m_protocol == "DMR"){
            m_refname = m_saved_dmrhost;
        }
        else if(m_protocol == "P25"){
            m_refname = m_saved_p25host;
        }
        else if(m_protocol == "NXDN"){
            m_refname = m_saved_nxdnhost;
        }
        else if(m_protocol == "M17"){
            m_refname = m_saved_m17host;
        }
        else if(m_protocol == "IAX"){
            m_refname = m_saved_iaxhost;
        }

        qDebug() << "process_connect() using refname=" << m_refname
                 << "hostmap_contains=" << m_hostmap.contains(m_refname)
                 << "hostsmodel_count=" << m_hostsmodel.size();

        m_keepAliveTimer->start();
        m_reconnectTimer->stop();
        m_autoReconnect = true;
        emit connect_status_changed(1);
        connect_status = Mode::CONNECTING;
        m_connectTimeoutTimer->start();
        QStringList sl;

        m_host = m_hostmap[m_refname];
        sl = m_host.split(',');

        if( (m_protocol == "M17") && !m_mdirect && (m_ipv6) && (sl.size() > 2) && (sl.at(2) != "none") ){
            m_host = sl.at(2).simplified();
            m_port = sl.at(1).toInt();
        }
        else if(sl.size() > 1){
            m_host = sl.at(0).simplified();
            m_port = sl.at(1).toInt();
        }
        else if( (m_protocol == "M17") && m_mdirect ){
            qDebug() << "Going MMDVM_DIRECT";
        }
        else{
            m_errortxt = "Invalid host selection";
            emit update_log(m_errortxt);
            connect_status = Mode::DISCONNECTED;
            emit connect_status_changed(5);
            return;
        }

        QString vocoder = "";
        if( (m_vocoder != "Software vocoder") && (m_vocoder.contains(':')) ){
            QStringList vl = m_vocoder.split(':');
            vocoder = vl.at(1);
        }
        QString modem = "";
        if( (m_modem != "None") && (m_modem.contains(':')) ){
            QStringList ml = m_modem.split(':');
            modem = ml.at(1);
        }

        const bool txInvert = true;
        const bool rxInvert = false;
        const bool pttInvert = false;
        const bool useCOSAsLockout = 0;
        const uint32_t ysfTXHang = 4;
        const float pocsagTXLevel = 50;
        const float m17TXLevel = 50;
        const bool duplex = m_modemRxFreq.toUInt() != m_modemTxFreq.toUInt();
        const int rxfreq = m_modemRxFreq.toInt() + m_modemRxOffset.toInt();
        const int txfreq = m_modemTxFreq.toInt() + m_modemTxOffset.toInt();

        emit update_log("Connecting to " + m_host + ":" + QString::number(m_port) + "...");

        uint16_t nxdnid = m_nxdnids.key(m_callsign);

        m_mode = Mode::create_mode(m_protocol);
        m_modethread = new QThread;
        m_mode->moveToThread(m_modethread);

        if(m_protocol == "IAX"){
            QString iaxuser = sl.at(2).simplified();
            QString iaxpass = sl.at(3).simplified();
            m_mode->set_iax_params(iaxuser, iaxpass, m_refname, m_host, m_port);
            connect(this, SIGNAL(send_dtmf(QByteArray)), m_mode, SLOT(send_dtmf(QByteArray)));
        }

        m_mode->init(m_callsign, m_dmrid, nxdnid, m_module, m_refname, m_host, m_port, m_ipv6, vocoder, modem, m_capture, m_playback, m_mdirect);
        m_mode->set_modem_flags(rxInvert, txInvert, pttInvert, useCOSAsLockout, duplex);
        m_mode->set_modem_params(m_modemBaud.toUInt(), rxfreq, txfreq, m_modemTxDelay.toInt(), m_modemRxLevel.toFloat(), m_modemRFLevel.toFloat(), ysfTXHang, m_modemCWIdTxLevel.toFloat(), m_modemDstarTxLevel.toFloat(), m_modemDMRTxLevel.toFloat(), m_modemYSFTxLevel.toFloat(), m_modemP25TxLevel.toFloat(), m_modemNXDNTxLevel.toFloat(), pocsagTXLevel, m17TXLevel);

        connect(this, SIGNAL(module_changed(char)), m_mode, SLOT(module_changed(char)));
        connect(m_mode, SIGNAL(update(Mode::MODEINFO)), this, SLOT(update_data(Mode::MODEINFO)));
        connect(m_mode, SIGNAL(update_log(QString)), this, SLOT(updatelog(QString)));
        connect(m_mode, SIGNAL(connection_lost(QString)), this, SLOT(handle_connection_lost(QString)));
        connect(m_mode, SIGNAL(recording_saved(QString)), this, SIGNAL(recordings_changed()));
        update_link_quality(-1, -1, -1, -1, -1, -1);   // nothing measured on this link yet
        connect(m_mode, SIGNAL(link_quality(int,int,int,int,int,int)), this, SLOT(update_link_quality(int,int,int,int,int,int)));
        connect(m_mode, SIGNAL(update_output_level(unsigned short)), this, SLOT(update_output_level(unsigned short)));
        connect(m_modethread, SIGNAL(started()), m_mode, SLOT(begin_connect()));
        connect(m_modethread, SIGNAL(finished()), m_mode, SLOT(deleteLater()));
        connect(this, SIGNAL(input_source_changed(int,QString)), m_mode, SLOT(input_src_changed(int,QString)));
        connect(this, SIGNAL(swrx_state_changed(int)), m_mode, SLOT(swrx_state_changed(int)));
        connect(this, SIGNAL(swtx_state_changed(int)), m_mode, SLOT(swtx_state_changed(int)));
        connect(this, SIGNAL(agc_state_changed(int)), m_mode, SLOT(agc_state_changed(int)));
        connect(this, SIGNAL(tx_clicked(bool)), m_mode, SLOT(toggle_tx(bool)));
        connect(this, SIGNAL(tx_pressed()), m_mode, SLOT(start_tx()));
        connect(this, SIGNAL(tx_released()), m_mode, SLOT(stop_tx()));
        connect(this, SIGNAL(restart_capture_requested()), m_mode, SLOT(restart_capture()));
        connect(this, SIGNAL(roger_beep_changed(int)), m_mode, SLOT(set_roger_beep(int)));
        QMetaObject::invokeMethod(m_mode, "set_roger_beep", Qt::QueuedConnection, Q_ARG(int, m_rogerBeep));
        connect(this, SIGNAL(tx_tone_changed(int)), m_mode, SLOT(set_tx_tone(int)));
        QMetaObject::invokeMethod(m_mode, "set_tx_tone", Qt::QueuedConnection, Q_ARG(int, m_txTone));
        connect(this, SIGNAL(talker_alias_changed(QString)), m_mode, SLOT(set_talker_alias(QString)));
        QMetaObject::invokeMethod(m_mode, "set_talker_alias", Qt::QueuedConnection, Q_ARG(QString, effective_talker_alias()));
        connect(this, SIGNAL(in_audio_vol_changed(qreal)), m_mode, SLOT(in_audio_vol_changed(qreal)));
        connect(this, SIGNAL(mycall_changed(QString)), m_mode, SLOT(mycall_changed(QString)));
        connect(this, SIGNAL(urcall_changed(QString)), m_mode, SLOT(urcall_changed(QString)));
        connect(this, SIGNAL(rptr1_changed(QString)), m_mode, SLOT(rptr1_changed(QString)));
        connect(this, SIGNAL(rptr2_changed(QString)), m_mode, SLOT(rptr2_changed(QString)));
        connect(this, SIGNAL(usrtxt_changed(QString)), m_mode, SLOT(usrtxt_changed(QString)));
        connect(this, SIGNAL(debug_changed(bool)), m_mode, SLOT(debug_changed(bool)));
        emit module_changed(m_module);
        emit mycall_changed(m_mycall);
        emit urcall_changed(m_urcall);
        emit rptr1_changed(m_rptr1);
        emit rptr2_changed(m_rptr2);
        emit usrtxt_changed(m_dstarusertxt);

        if(m_protocol == "DMR"){
            QString dmrpass = sl.at(2).simplified();

            if((m_refname.size() > 2) && (m_refname.left(2) == "BM")){
                if(!m_bm_password.isEmpty()){
                    dmrpass = m_bm_password;
                }
            }

            if((m_refname.size() > 4) && (m_refname.left(4) == "TGIF")){
                if(!m_tgif_password.isEmpty()){
                    dmrpass = m_tgif_password;
                }
            }
            QString dmrlat, dmrlon;
            dmr_login_position(dmrlat, dmrlon);
            m_mode->set_dmr_params(m_essid, dmrpass, dmrlat, dmrlon, m_location, m_description, m_freq, m_url, m_swid, m_pkgid, m_dmropts);
            connect(this, SIGNAL(dmr_position_changed(QString,QString)), m_mode, SLOT(send_position(QString,QString)));
            connect(m_mode, SIGNAL(position_update_rejected()), this, SLOT(on_rptg_rejected()));
            connect(this, SIGNAL(dmr_tgid_changed(int)), m_mode, SLOT(dmr_tgid_changed(int)));
            connect(this, SIGNAL(dmrpc_state_changed(int)), m_mode, SLOT(dmrpc_state_changed(int)));
            connect(this, SIGNAL(slot_changed(int)), m_mode, SLOT(slot_changed(int)));
            connect(this, SIGNAL(cc_changed(int)), m_mode, SLOT(cc_changed(int)));
            emit dmr_tgid_changed(m_dmr_destid);
            emit dmrpc_state_changed(m_pc);
        }

        if(m_protocol == "M17"){
            connect(this, SIGNAL(m17_rate_changed(int)), m_mode, SLOT(rate_changed(int)));
            connect(this, SIGNAL(m17_can_changed(int)), m_mode, SLOT(can_changed(int)));
            if(m_mdirect){
                connect(this, SIGNAL(dst_changed(QString)), m_mode, SLOT(dst_changed(QString)));
            }
        }

        m_modethread->start();

    }
/*
    qDebug() << "process_connect called m_callsign == " << m_callsign;
    qDebug() << "process_connect called m_dmrid == " << m_dmrid;
    qDebug() << "process_connect called m_bm_password == " << m_bm_password;
    qDebug() << "process_connect called m_tgif_password == " << m_tgif_password;
    qDebug() << "process_connect called m_dmropts == " << m_dmropts;
    qDebug() << "process_connect called m_refname == " << m_refname;
    qDebug() << "process_connect called m_host == " << m_host;
    qDebug() << "process_connect called m_module == " << m_module;
    qDebug() << "process_connect called m_protocol == " << m_protocol;
    qDebug() << "process_connect called m_port == " << m_port;
*/
}


void DroidStar::attempt_reconnect()
{
    if((connect_status == Mode::DISCONNECTED) && m_autoReconnect) {
        emit update_log("Reconnecting (attempt " + QString::number(m_reconnectAttempt) + ")...");
        process_connect();
    }
}

// Backoff 5, 10, 20, 40, 60, 60... s so a long outage does not hammer the master.
void DroidStar::schedule_reconnect(const QString &reason, int delayMs)
{
    if(delayMs < 0){
        delayMs = qMin(5000 << qMin(m_reconnectAttempt, 4), 60000);
    }
    m_reconnectAttempt++;
    qDebug() << "Reconnect scheduled:" << reason << "in" << delayMs << "ms, attempt" << m_reconnectAttempt;
    emit update_log(reason + " - retrying in " + QString::number(delayMs / 1000) + " s (" +
                    QString::number(m_reconnectAttempt) + "/" + QString::number(kMaxReconnectAttempts) + ")");
    m_reconnectTimer->start(delayMs);
#ifdef Q_OS_IOS
    setAudioReconnectHold(true);
#endif
    // Keep the UI in "connecting" so the button reads Cancel during the wait.
    emit connect_status_changed(1);
    live_activity_sync();
}

// Link was up and died underneath us. Tear down like a manual disconnect, then re-arm.
void DroidStar::handle_connection_lost(QString reason)
{
    if(connect_status != Mode::CONNECTED_RW) return;
    qDebug() << "Connection lost:" << reason;
    m_keepPttChannel = true;
    process_connect();
    m_keepPttChannel = false;
    m_autoReconnect = true;
    schedule_reconnect("Connection lost (" + reason + ")");
}

void DroidStar::update_link_quality(int bars, int rtt, int rttAvg, int pingLoss, int rxLoss, int jitter)
{
    m_lqBars = bars;
    m_lqRtt = rtt;
    m_lqRttAvg = rttAvg;
    m_lqPingLoss = pingLoss;
    m_lqRxLoss = rxLoss;
    m_lqJitter = jitter;
    emit link_quality_changed();
}

QVariantMap DroidStar::get_link_quality() const
{
    QVariantMap m;
    m["bars"] = m_lqBars;
    m["rtt"] = m_lqRtt;
    m["rttAvg"] = m_lqRttAvg;
    m["pingLoss"] = m_lqPingLoss;
    m["rxLoss"] = m_lqRxLoss;
    m["jitter"] = m_lqJitter;
    return m;
}

void DroidStar::on_connect_timeout()
{
    if(connect_status == Mode::CONNECTING){
        connect_failed("Connection timed out");
    }
}

// A connect attempt did not reach CONNECTED_RW. Retry only if this was an automatic attempt;
// a failed manual connect is usually a config/password problem and should just be shown.
void DroidStar::connect_failed(const QString &reason)
{
    const bool autoAttempt = m_autoReconnect && (m_reconnectAttempt > 0);
    const bool retry = autoAttempt && (m_reconnectAttempt < kMaxReconnectAttempts);
    qDebug() << "Connect failed:" << reason << "auto" << autoAttempt << "retry" << retry;
    m_errortxt = autoAttempt && !retry
        ? reason + " (gave up after " + QString::number(m_reconnectAttempt) + " reconnect attempts)"
        : reason;
    m_connectTimeoutTimer->stop();
    connect_status = Mode::DISCONNECTED;
    if (m_modethread) {
        m_modethread->quit();
    }
    m_data1.clear();
    m_data2.clear();
    m_data3.clear();
    m_data4.clear();
    m_data5.clear();
    m_data6.clear();
#ifdef Q_OS_IOS
    setAudioReconnectHold(retry);
    setAudioConnectionState(false, "", "");
#endif
    emit update_log(m_errortxt);
    if(retry){
        // No error dialog for each automatic attempt; only when we give up.
        schedule_reconnect(reason);
    }
    else{
        m_autoReconnect = false;
        m_reconnectAttempt = 0;
#ifdef Q_OS_IOS
        ptt_leave();
        m_pttTalker.clear();
#endif
        emit connect_status_changed(5);
        live_activity_sync();
    }
}

// Function to start the keep-alive mechanism
void DroidStar::start_keep_alive()
{
    if (!m_keepAliveTimer->isActive()) {
        m_keepAliveTimer->start(30000);  // 30,000 milliseconds = 30 seconds
        emit update_log("Keep-alive timer started");
    }
}

// Function to stop the keep-alive mechanism
void DroidStar::stop_keep_alive()
{
    if (m_keepAliveTimer->isActive()) {
        m_keepAliveTimer->stop();
        emit update_log("Keep-alive timer stopped");
    }
}

// Slot to send the keep-alive packet
void DroidStar::send_keep_alive()
{
    if (connect_status == Mode::CONNECTED_RW) {
        // Emit a keep-alive packet or ping command
        emit update_log("Sending keep-alive packet");
        // Call an appropriate function to send a small data packet or ping
        // This could be a simple command to the host/server
        if (m_mode) {
            //m_mode->send_keep_alive();
        }
    } else {
        // Stop the timer if not connected
        stop_keep_alive();
    }
}

void DroidStar::process_host_change(const QString &h)
{
    if(m_protocol == "REF"){
        m_saved_refhost = h.simplified();
    }
    if(m_protocol == "DCS"){
        m_saved_dcshost = h.simplified();
    }
    if(m_protocol == "XRF"){
        m_saved_xrfhost = h.simplified();
    }
    if(m_protocol == "YSF"){
        m_saved_ysfhost = h.simplified();
    }
    if(m_protocol == "FCS"){
        m_saved_fcshost = h.simplified();
    }
    if(m_protocol == "DMR"){
        m_saved_dmrhost = h.simplified();
    }
    if(m_protocol == "P25"){
        m_saved_p25host = h.simplified();
    }
    if(m_protocol == "NXDN"){
        m_saved_nxdnhost = h.simplified();
    }
    if(m_protocol == "M17"){
        m_saved_m17host = h.simplified();
    }
    if(m_protocol == "IAX"){
        m_saved_iaxhost = h.simplified();
    }
    save_settings();
}

void DroidStar::process_mode_change(const QString &m)
{
    m_protocol = m;
    if((m == "REF") || (m == "DCS") || (m == "XRF")){
        process_dstar_hosts(m);
        m_label1 = "MYCALL";
        m_label2 = "URCALL";
        m_label3 = "RPTR1";
        m_label4 = "RPTR2";
        m_label5 = "Stream ID";
        m_label6 = "User txt";
    }
    if(m == "YSF"){
        process_ysf_hosts();
        m_label1 = "Gateway";
        m_label2 = "Callsign";
        m_label3 = "Dest";
        m_label4 = "Type";
        m_label5 = "Path";
        m_label6 = "Frame#";
    }
    if(m == "FCS"){
        process_fcs_rooms();
        m_label1 = "Gateway";
        m_label2 = "Callsign";
        m_label3 = "Dest";
        m_label4 = "Type";
        m_label5 = "Path";
        m_label6 = "Frame#";
    }
    if(m == "DMR"){
        process_dmr_hosts();
        //process_dmr_ids();
        m_label1 = "Callsign";
        m_label2 = "SrcID";
        m_label3 = "DestID";
        m_label4 = "GWID";
        m_label5 = "Info";
        m_label6 = "";
    }
    if(m == "P25"){
        process_p25_hosts();
        m_label1 = "Callsign";
        m_label2 = "SrcID";
        m_label3 = "DestID";
        m_label4 = "GWID";
        m_label5 = "Seq#";
        m_label6 = "";
    }
    if(m == "NXDN"){
        process_nxdn_hosts();
        m_label1 = "Callsign";
        m_label2 = "SrcID";
        m_label3 = "DestID";
        m_label4 = "GWID";
        m_label5 = "Seq#";
        m_label6 = "";
    }
    if(m == "M17"){
        process_m17_hosts();
        m_label1 = "SrcID";
        m_label2 = "DstID";
        m_label3 = "Type";
        m_label4 = "Frame#";
        m_label5 = "StreamID";
        m_label6 = "";
    }
    if(m == "IAX"){
        process_iax_hosts();
        m_label1 = "";
        m_label2 = "";
        m_label3 = "";
        m_label4 = "";
        m_label5 = "";
        m_label6 = "";
    }
    // IMPORTANT:
    // During startup, process_settings() calls process_mode_change() while other fields
    // (CALLSIGN/DMRID/DMRHOST/etc) have not yet been loaded into member variables.
    // Calling save_settings() here would overwrite the existing ini with empty defaults.
    if (m_settings_processed) {
        save_settings();
    }
    emit mode_changed();
}

void DroidStar::save_settings()
{
    // Ensure a sane module gets persisted (avoid writing NUL which later becomes "@String(\\0)")
    if (m_module == 0) m_module = 'A';

    //m_settings->setValue("PLAYBACK", ui->comboPlayback->currentText());
    //m_settings->setValue("CAPTURE", ui->comboCapture->currentText());
    m_settings->setValue("IPV6", m_ipv6 ? "true" : "false");
    m_settings->setValue("MODE", m_protocol);
    m_settings->setValue("REFHOST", m_saved_refhost);
    m_settings->setValue("DCSHOST", m_saved_dcshost);
    m_settings->setValue("XRFHOST", m_saved_xrfhost);
    m_settings->setValue("YSFHOST", m_saved_ysfhost);
    m_settings->setValue("FCSHOST", m_saved_fcshost);
    m_settings->setValue("DMRHOST", m_saved_dmrhost);
    m_settings->setValue("P25HOST", m_saved_p25host);
    m_settings->setValue("NXDNHOST", m_saved_nxdnhost);
    m_settings->setValue("M17HOST", m_saved_m17host);
    m_settings->setValue("IAXHOST", m_saved_iaxhost);
    m_settings->setValue("MODULE", QString(m_module));
    m_settings->setValue("CALLSIGN", m_callsign);
    m_settings->setValue("DMRID", m_dmrid);
    m_settings->setValue("ESSID", m_essid);
    m_settings->setValue("BMPASSWORD", m_bm_password);
    m_settings->setValue("TGIFPASSWORD", m_tgif_password);
    m_settings->setValue("DMRTGID", m_dmr_destid);
    m_settings->setValue("DMRLAT", m_latitude);
    m_settings->setValue("DMRLONG", m_longitude);
    m_settings->setValue("DMRLOC", m_location);
    m_settings->setValue("DMRDESC", m_description);
    m_settings->setValue("DMRFREQ", m_freq);
    m_settings->setValue("DMRURL", m_url);
    m_settings->setValue("DMRSWID", m_swid);
    m_settings->setValue("DMRPKGID", m_pkgid);
    m_settings->setValue("DMROPTS", m_dmropts);
    m_settings->setValue("MYCALL", m_mycall);
    m_settings->setValue("URCALL", m_urcall);
    m_settings->setValue("RPTR1", m_rptr1);
    m_settings->setValue("RPTR2", m_rptr2);
    m_settings->setValue("TXTIMEOUT", m_txtimeout);
    m_settings->setValue("TXTOGGLE", m_toggletx ? "true" : "false");
    m_settings->setValue("PTTFRAMEWORK", m_pttFramework ? "true" : "false");
    m_settings->setValue("HEADPHONEPTT", m_headphonePtt ? "true" : "false");
    m_settings->setValue("HWPTTBUTTONS", m_hwPttButtons);
    m_settings->setValue("HWPTTMODE", m_hwPttMode);
    m_settings->setValue("USEPHONEGPS", m_usePhoneGps ? "true" : "false");
    m_settings->setValue("AUTOCONNECT", m_autoConnect ? "true" : "false");
    m_settings->setValue("ROGERBEEP", m_rogerBeep);
    m_settings->setValue("TXTONE", m_txTone);
    m_settings->setValue("TALKERALIAS", m_talkerAlias);
    m_settings->setValue("TALKERALIASON", m_talkerAliasOn ? "true" : "false");
    m_settings->setValue("XRF2REF", m_xrf2ref ? "true" : "false");
    m_settings->setValue("USRTXT", m_dstarusertxt);

    m_settings->setValue("ModemRxFreq", m_modemRxFreq);
    m_settings->setValue("ModemTxFreq", m_modemTxFreq);
    m_settings->setValue("ModemRxOffset", m_modemRxOffset);
    m_settings->setValue("ModemTxOffset", m_modemTxOffset);
    m_settings->setValue("ModemRxDCOffset", m_modemRxDCOffset);
    m_settings->setValue("ModemTxDCOffset", m_modemTxDCOffset);
    m_settings->setValue("ModemRxLevel", m_modemRxLevel);
    m_settings->setValue("ModemTxLevel", m_modemTxLevel);
    m_settings->setValue("ModemRFLevel", m_modemRFLevel);
    m_settings->setValue("ModemTxDelay", m_modemTxDelay);
    m_settings->setValue("ModemCWIdTxLevel", m_modemCWIdTxLevel);
    m_settings->setValue("ModemDstarTxLevel", m_modemDstarTxLevel);
    m_settings->setValue("ModemDMRTxLevel", m_modemDMRTxLevel);
    m_settings->setValue("ModemYSFTxLevel", m_modemYSFTxLevel);
    m_settings->setValue("ModemP25TxLevel", m_modemP25TxLevel);
    m_settings->setValue("ModemNXDNTxLevel", m_modemNXDNTxLevel);
    m_settings->setValue("ModemBaud", m_modemBaud);
    m_settings->setValue("ModemM17CAN", m_modemM17CAN);
    m_settings->setValue("ModemTxInvert", m_modemTxInvert ? "true" : "false");
    m_settings->setValue("ModemRxInvert", m_modemRxInvert ? "true" : "false");
    m_settings->setValue("ModemPTTInvert", m_modemPTTInvert ? "true" : "false");

    // Force flush to disk so iOS reliably persists immediately.
    m_settings->sync();
}

void DroidStar::process_settings()
{
    // Ensure we read the latest values from disk (important on mobile sandboxes).
    m_settings->sync();

    // We are loading settings now; prevent write-back until fully loaded.
    m_settings_processed = false;

    m_ipv6 = (m_settings->value("IPV6").toString().simplified() == "true") ? true : false;
    process_mode_change(m_settings->value("MODE").toString().simplified());
    m_saved_refhost = m_settings->value("REFHOST").toString().simplified();
    m_saved_dcshost =m_settings->value("DCSHOST").toString().simplified();
    m_saved_xrfhost = m_settings->value("XRFHOST").toString().simplified();
    m_saved_ysfhost = m_settings->value("YSFHOST").toString().simplified();
    m_saved_fcshost = m_settings->value("FCSHOST").toString().simplified();
    m_saved_dmrhost = m_settings->value("DMRHOST").toString().simplified();
    m_saved_p25host = m_settings->value("P25HOST").toString().simplified();
    m_saved_nxdnhost = m_settings->value("NXDNHOST").toString().simplified();
    m_saved_m17host = m_settings->value("M17HOST").toString().simplified();
    m_saved_iaxhost = m_settings->value("IAXHOST").toString().simplified();
    {
        const QString moduleStr = m_settings->value("MODULE", "A").toString();
        if (!moduleStr.isEmpty() && moduleStr.at(0).unicode() != 0) m_module = moduleStr.toStdString()[0];
        else m_module = 'A';
    }
    m_callsign = m_settings->value("CALLSIGN").toString().simplified();
    m_dmrid = m_settings->value("DMRID").toString().simplified().toUInt();
    m_essid = m_settings->value("ESSID").toString().simplified().toUInt();
    m_bm_password = m_settings->value("BMPASSWORD").toString().simplified();
    m_tgif_password = m_settings->value("TGIFPASSWORD").toString().simplified();
    m_latitude = m_settings->value("DMRLAT", "0").toString().simplified();
    m_longitude = m_settings->value("DMRLONG", "0").toString().simplified();
    m_location = m_settings->value("DMRLOC").toString().simplified();
    m_description = m_settings->value("DMRDESC", "").toString().simplified();
    m_freq = m_settings->value("DMRFREQ", "438800000").toString().simplified();
    m_url = m_settings->value("DMRURL", "www.qrz.com").toString().simplified();
    m_swid = m_settings->value("DMRSWID", "20200922").toString().simplified();
    m_pkgid = m_settings->value("DMRPKGID", "MMDVM_MMDVM_HS_Hat").toString().simplified();
    m_dmropts = m_settings->value("DMROPTS").toString().simplified();
    m_dmr_destid = m_settings->value("DMRTGID", "4000").toString().simplified().toUInt();
    m_mycall = m_settings->value("MYCALL").toString().simplified();
    m_urcall = m_settings->value("URCALL", "CQCQCQ").toString().simplified();
    m_rptr1 = m_settings->value("RPTR1").toString().simplified();
    m_rptr2 = m_settings->value("RPTR2").toString().simplified();
    m_txtimeout = m_settings->value("TXTIMEOUT", "300").toString().simplified().toUInt();
    // IMPORTANT: On a fresh install (no settings yet), default to TX toggle mode enabled.
    m_toggletx = (m_settings->value("TXTOGGLE", "true").toString().simplified() == "true") ? true : false;
    m_pttFramework = (m_settings->value("PTTFRAMEWORK", "false").toString().simplified() == "true");
    m_headphonePtt = (m_settings->value("HEADPHONEPTT", "false").toString().simplified() == "true");
    m_hwPttButtons = qBound(0, m_settings->value("HWPTTBUTTONS", 0).toInt(), 3);
    m_hwPttMode = qBound(0, m_settings->value("HWPTTMODE", 0).toInt(), 1);
    m_usePhoneGps = (m_settings->value("USEPHONEGPS", "false").toString().simplified() == "true");
    m_autoConnect = (m_settings->value("AUTOCONNECT", "true").toString().simplified() == "true");
    m_rogerBeep = m_settings->value("ROGERBEEP", 2).toInt();
    m_txTone = m_settings->value("TXTONE", 1).toInt();
    m_talkerAlias = m_settings->value("TALKERALIAS").toString().simplified();
    m_talkerAliasOn = (m_settings->value("TALKERALIASON", "true").toString().simplified() == "true");
    m_dstarusertxt = m_settings->value("USRTXT").toString().simplified();
    m_xrf2ref = (m_settings->value("XRF2REF").toString().simplified() == "true") ? true : false;
    m_localhosts = m_settings->value("LOCALHOSTS").toString();

    // Treat empty-but-present values as missing (QSettings defaults apply only to missing keys).
    if (m_latitude.isEmpty()) m_latitude = "0";
    if (m_longitude.isEmpty()) m_longitude = "0";
    if (m_freq.isEmpty() || m_freq.toUInt() == 0) m_freq = "438800000";
    if (m_url.isEmpty()) m_url = "www.qrz.com";
    if (m_swid.isEmpty()) m_swid = "20200922";
    if (m_pkgid.isEmpty()) m_pkgid = "MMDVM_MMDVM_HS_Hat";

    m_modemRxFreq = m_settings->value("ModemRxFreq", "438800000").toString().simplified();
    m_modemTxFreq = m_settings->value("ModemTxFreq", "438800000").toString().simplified();
    m_modemRxOffset = m_settings->value("ModemRxOffset", "0").toString().simplified();
    m_modemTxOffset = m_settings->value("ModemTxOffset", "0").toString().simplified();
    m_modemRxDCOffset = m_settings->value("ModemRxDCOffset", "0").toString().simplified();
    m_modemTxDCOffset = m_settings->value("ModemTxDCOffset", "0").toString().simplified();
    m_modemRxLevel = m_settings->value("ModemRxLevel", "50").toString().simplified();
    m_modemTxLevel = m_settings->value("ModemTxLevel", "50").toString().simplified();
    m_modemRFLevel = m_settings->value("ModemRFLevel", "100").toString().simplified();
    m_modemTxDelay = m_settings->value("ModemTxDelay", "100").toString().simplified();
    m_modemCWIdTxLevel = m_settings->value("ModemCWIdTxLevel", "50").toString().simplified();
    m_modemDstarTxLevel = m_settings->value("ModemDstarTxLevel", "50").toString().simplified();
    m_modemDMRTxLevel = m_settings->value("ModemDMRTxLevel", "50").toString().simplified();
    m_modemYSFTxLevel = m_settings->value("ModemYSFTxLevel", "50").toString().simplified();
    m_modemP25TxLevel = m_settings->value("ModemP25TxLevel", "50").toString().simplified();
    m_modemNXDNTxLevel = m_settings->value("ModemNXDNTxLevel", "50").toString().simplified();
    m_modemBaud = m_settings->value("ModemBaud", "115200").toString().simplified();
    m_modemM17CAN = m_settings->value("ModemM17CAN", "0").toString().simplified();
    m_modemTxInvert = (m_settings->value("ModemTxInvert", "true").toString().simplified() == "true") ? true : false;
    m_modemRxInvert = (m_settings->value("ModemRxInvert", "false").toString().simplified() == "true") ? true : false;
    m_modemPTTInvert = (m_settings->value("ModemPTTInvert", "false").toString().simplified() == "true") ? true : false;

    qDebug() << "process_settings loaded:"
             << "CALLSIGN=" << m_callsign
             << "DMRID=" << m_dmrid
             << "MODE=" << m_protocol
             << "DMRHOST=" << m_saved_dmrhost;
    m_settings_processed = true;
    apply_phone_gps();
    emit update_settings();
}

void DroidStar::update_custom_hosts(QString h)
{
    m_settings->setValue("LOCALHOSTS", h);
    m_localhosts = m_settings->value("LOCALHOSTS").toString();
}

void DroidStar::process_dstar_hosts(QString m)
{
    m_hostmap.clear();
    m_hostsmodel.clear();
    QString filename, port;
    if(m == "REF"){
        filename = "dplus.txt";
        port = "20001";
    }
    else if(m == "DCS"){
        filename = "dcs.txt";
        port = "30051";
    }
    else if(m == "XRF"){
        filename = "dextra.txt";
        port = "30001";
    }

    QFileInfo check_file(config_path + "/" + filename);

    if(check_file.exists() && check_file.isFile()){
        QFile f(config_path + "/" + filename);
        if(f.open(QIODevice::ReadOnly)){
            while(!f.atEnd()){
                QString l = f.readLine();
                if(l.at(0) == '#'){
                    continue;
                }
                QStringList ll = l.split('\t');
                if(ll.size() > 1){
                    m_hostmap[ll.at(0).simplified()] = ll.at(1).simplified() + "," + port;
                }
            }

            m_customhosts = m_localhosts.split('\n');
            for (const auto& i : std::as_const(m_customhosts)){
                QStringList line = i.simplified().split(' ');

                if(line.at(0) == m){
                    m_hostmap[line.at(1).simplified()] = line.at(2).simplified() + "," + line.at(3).simplified();
                }
            }

            QMap<QString, QString>::const_iterator i = m_hostmap.constBegin();
            while (i != m_hostmap.constEnd()) {
                m_hostsmodel.append(i.key());
                ++i;
            }
        }
        f.close();
    }
    else{
        download_file("/" + filename);
    }
}

void DroidStar::process_ysf_hosts()
{
    m_hostmap.clear();
    m_hostsmodel.clear();
    QFileInfo check_file(config_path + "/YSFHosts.txt");
    if(check_file.exists() && check_file.isFile()){
        QFile f(config_path + "/YSFHosts.txt");
        if(f.open(QIODevice::ReadOnly)){
            while(!f.atEnd()){
                QString l = f.readLine();
                if(l.at(0) == '#'){
                    continue;
                }
                QStringList ll = l.split(';');
                if(ll.size() > 4){
                    m_hostmap[ll.at(1).simplified()] = ll.at(3) + "," + ll.at(4);
                }
            }

            m_customhosts = m_localhosts.split('\n');
            for (const auto& i : std::as_const(m_customhosts)){
                QStringList line = i.simplified().split(' ');

                if(line.at(0) == "YSF"){
                    m_hostmap[line.at(1).simplified()] = line.at(2).simplified() + "," + line.at(3).simplified();
                }
            }

            QMap<QString, QString>::const_iterator i = m_hostmap.constBegin();
            while (i != m_hostmap.constEnd()) {
                m_hostsmodel.append(i.key());
                ++i;
            }
        }
        f.close();
    }
    else{
        download_file("/YSFHosts.txt");
    }
}

void DroidStar::process_fcs_rooms()
{
    m_hostmap.clear();
    m_hostsmodel.clear();
    QFileInfo check_file(config_path + "/FCSHosts.txt");
    if(check_file.exists() && check_file.isFile()){
        QFile f(config_path + "/FCSHosts.txt");
        if(f.open(QIODevice::ReadOnly)){
            while(!f.atEnd()){
                QString l = f.readLine();
                if(l.at(0) == '#'){
                    continue;
                }
                QStringList ll = l.split(';');
                if(ll.size() > 4){
                    if(ll.at(1).simplified() != "nn"){
                        m_hostmap[ll.at(0).simplified() + " - " + ll.at(1).simplified()] = ll.at(2).left(6).toLower() + ".xreflector.net,62500";
                    }
                }
            }

            m_customhosts = m_localhosts.split('\n');
            for (const auto& i : std::as_const(m_customhosts)){
                QStringList line = i.simplified().split(' ');

                if(line.at(0) == "FCS"){
                    m_hostmap[line.at(1).simplified()] = line.at(2).simplified() + "," + line.at(3).simplified();
                }
            }

            QMap<QString, QString>::const_iterator i = m_hostmap.constBegin();
            while (i != m_hostmap.constEnd()) {
                m_hostsmodel.append(i.key());
                ++i;
            }
        }
        f.close();
    }
    else{
        download_file("/FCSHosts.txt");
    }
}

void DroidStar::process_dmr_hosts()
{
    m_hostmap.clear();
    m_hostsmodel.clear();
    QFileInfo check_file(config_path + "/DMRHosts.txt");
    if(check_file.exists() && check_file.isFile()){
        QFile f(config_path + "/DMRHosts.txt");
        if(f.open(QIODevice::ReadOnly)){
            while(!f.atEnd()){
                QString l = f.readLine();
                if(l.at(0) == '#'){
                    continue;
                }
                QStringList ll = l.simplified().split(' ');
                if(ll.size() > 4){
                    if( (ll.at(0).simplified() != "DMRGateway")
                     && (ll.at(0).simplified() != "DMR2YSF")
                     && (ll.at(0).simplified() != "DMR2NXDN"))
                    {
                        m_hostmap[ll.at(0).simplified()] = ll.at(2) + "," + ll.at(4) + "," + ll.at(3);
                    }
                }
            }

            m_customhosts = m_localhosts.split('\n');
            for (const auto& i : std::as_const(m_customhosts)){
                QStringList line = i.simplified().split(' ');

                if(line.at(0) == "DMR"){
                    m_hostmap[line.at(1).simplified()] = line.at(2).simplified() + "," + line.at(3).simplified() + "," + line.at(4).simplified();
                }
            }

            QMap<QString, QString>::const_iterator i = m_hostmap.constBegin();
            while (i != m_hostmap.constEnd()) {
                m_hostsmodel.append(i.key());
                ++i;
            }
        }
        f.close();
    }
    else{
        download_file("/DMRHosts.txt");
    }
}

void DroidStar::process_p25_hosts()
{
    m_hostmap.clear();
    m_hostsmodel.clear();
    QFileInfo check_file(config_path + "/P25Hosts.txt");
    if(check_file.exists() && check_file.isFile()){
        QFile f(config_path + "/P25Hosts.txt");
        if(f.open(QIODevice::ReadOnly)){
            while(!f.atEnd()){
                QString l = f.readLine();
                if(l.at(0) == '#'){
                    continue;
                }
                QStringList ll = l.simplified().split(' ');
                if(ll.size() > 2){
                    m_hostmap[ll.at(0).simplified()] = ll.at(1) + "," + ll.at(2);
                }
            }

            m_customhosts = m_localhosts.split('\n');
            for (const auto& i : std::as_const(m_customhosts)){
                QStringList line = i.simplified().split(' ');

                if(line.at(0) == "P25"){
                    m_hostmap[line.at(1).simplified()] = line.at(2).simplified() + "," + line.at(3).simplified();
                }
            }

            QMap<QString, QString>::const_iterator i = m_hostmap.constBegin();
            while (i != m_hostmap.constEnd()) {
                m_hostsmodel.append(i.key());
                ++i;
            }
            QMap<int, QString> m;
            for (auto s : m_hostsmodel) m[s.toInt()] = s;
            m_hostsmodel = QStringList(m.values());
        }
        f.close();
    }
    else{
        download_file("/P25Hosts.txt");
    }
}

void DroidStar::process_nxdn_hosts()
{
    m_hostmap.clear();
    m_hostsmodel.clear();
    QFileInfo check_file(config_path + "/NXDNHosts.txt");
    if(check_file.exists() && check_file.isFile()){
        QFile f(config_path + "/NXDNHosts.txt");
        if(f.open(QIODevice::ReadOnly)){
            while(!f.atEnd()){
                QString l = f.readLine();
                if(l.at(0) == '#'){
                    continue;
                }
                QStringList ll = l.simplified().split(' ');
                if(ll.size() > 2){
                    m_hostmap[ll.at(0).simplified()] = ll.at(1) + "," + ll.at(2);
                }
            }

            m_customhosts = m_localhosts.split('\n');
            for (const auto& i : std::as_const(m_customhosts)){
                QStringList line = i.simplified().split(' ');

                if(line.at(0) == "NXDN"){
                    m_hostmap[line.at(1).simplified()] = line.at(2).simplified() + "," + line.at(3).simplified();
                }
            }

            QMap<QString, QString>::const_iterator i = m_hostmap.constBegin();
            while (i != m_hostmap.constEnd()) {
                m_hostsmodel.append(i.key());
                ++i;
            }
            QMap<int, QString> m;
            for (auto s : m_hostsmodel) m[s.toInt()] = s;
            m_hostsmodel = QStringList(m.values());
        }
        f.close();
    }
    else{
        download_file("/NXDNHosts.txt");
    }
}

void DroidStar::process_m17_hosts()
{
    m_hostmap.clear();
    m_hostsmodel.clear();

    QFileInfo check_file(config_path + "/M17Hosts-full.csv");
    if(check_file.exists() && check_file.isFile()){
        QFile f(config_path + "/M17Hosts-full.csv");
        if(f.open(QIODevice::ReadOnly)){
            while(!f.atEnd()){
                QString l = f.readLine();
                if(l.at(0) == '#'){
                    continue;
                }
                QStringList ll = l.simplified().split(',');
                if(ll.size() > 3){
                    m_hostmap[ll.at(0).simplified()] = ll.at(2) + "," + ll.at(4) + "," + ll.at(3);
                }
            }

            m_customhosts = m_localhosts.split('\n');
            for (const auto& i : std::as_const(m_customhosts)){
                QStringList line = i.simplified().split(' ');

                if(line.at(0) == "M17"){
                    m_hostmap[line.at(1).simplified()] = line.at(2).simplified() + "," + line.at(3).simplified();
                }
            }
            if(m_mdirect){
                m_hostmap["ALL"] = "ALL";
                m_hostmap["UNLINK"] = "UNLINK";
                m_hostmap["ECHO"] = "ECHO";
                m_hostmap["INFO"] = "INFO";
            }
            QMap<QString, QString>::const_iterator i = m_hostmap.constBegin();
            while (i != m_hostmap.constEnd()) {
                m_hostsmodel.append(i.key());
                ++i;
            }
        }
        f.close();
    }
    else{
        download_file("/M17Hosts-full.csv");
    }
}

void DroidStar::process_iax_hosts()
{
    m_hostmap.clear();
    m_hostsmodel.clear();
    m_customhosts = m_localhosts.split('\n');
    for (const auto& i : std::as_const(m_customhosts)){
        QStringList line = i.simplified().split(' ');
        if(line.at(0) == "IAX"){
            m_hostmap[line.at(1).simplified()] = line.at(2).simplified() + "," + line.at(3).simplified() + "," + line.at(4).simplified() + "," + line.at(5).simplified();
        }
    }

    QMap<QString, QString>::const_iterator i = m_hostmap.constBegin();
    while (i != m_hostmap.constEnd()) {
        m_hostsmodel.append(i.key());
        ++i;
    }
}

void DroidStar::process_dmr_ids()
{
    QFileInfo check_file(config_path + "/DMRIDs.dat");
    if(check_file.exists() && check_file.isFile()){
        QFile f(config_path + "/DMRIDs.dat");
        if(f.open(QIODevice::ReadOnly)){
            while(!f.atEnd()){
                QString lids = f.readLine();
                if(lids.at(0) == '#'){
                    continue;
                }
                QStringList llids = lids.simplified().split(' ');

                if(llids.size() >= 2){
                                    if(llids.size() == 3){
                                         m_dmrids[llids.at(0).toUInt()] = llids.at(1) + " - " + llids.at(2);
                                    }
                                    else{
                                        m_dmrids[llids.at(0).toUInt()] = llids.at(1);
                                    }
                                }
                            }
                        }
                        f.close();
                    }
                    else{
                        download_file("/DMRIDs.dat");
                    }
}

void DroidStar::update_dmr_ids()
{
    QFileInfo check_file(config_path + "/DMRIDs.dat");
    if(check_file.exists() && check_file.isFile()){
        QFile f(config_path + "/DMRIDs.dat");
        f.remove();
    }
    process_dmr_ids();
    update_nxdn_ids();
}

void DroidStar::process_nxdn_ids()
{
    QFileInfo check_file(config_path + "/NXDN.csv");
    if(check_file.exists() && check_file.isFile()){
        QFile f(config_path + "/NXDN.csv");
        if(f.open(QIODevice::ReadOnly)){
            while(!f.atEnd()){
                QString lids = f.readLine();
                if(lids.at(0) == '#'){
                    continue;
                }
                QStringList llids = lids.simplified().split(',');

                if(llids.size() > 1){
                    m_nxdnids[llids.at(0).toUInt()] = llids.at(1);
                }
            }
        }
        f.close();
    }
    else{
        download_file("/NXDN.csv");
    }
}

void DroidStar::update_nxdn_ids()
{
    QFileInfo check_file(config_path + "/NXDN.csv");
    if(check_file.exists() && check_file.isFile()){
        QFile f(config_path + "/NXDN.csv");
        f.remove();
    }
    process_nxdn_ids();
}

void DroidStar::update_host_files()
{
    m_update_host_files = true;
    check_host_files();
}

void DroidStar::check_host_files()
{
    if(!QDir(config_path).exists()){
        QDir().mkdir(config_path);
    }

    QFileInfo check_file(config_path + "/dplus.txt");
    if( (!check_file.exists() && !(check_file.isFile())) || m_update_host_files ){
        download_file("/dplus.txt");
    }

    check_file.setFile(config_path + "/dextra.txt");
    if( (!check_file.exists() && !check_file.isFile() ) || m_update_host_files  ){
        download_file("/dextra.txt");
    }

    check_file.setFile(config_path + "/dcs.txt");
    if( (!check_file.exists() && !check_file.isFile()) || m_update_host_files ){
        download_file( "/dcs.txt");
    }

    check_file.setFile(config_path + "/YSFHosts.txt");
    if( (!check_file.exists() && !check_file.isFile()) || m_update_host_files ){
        download_file("/YSFHosts.txt");
    }

    check_file.setFile(config_path + "/FCSHosts.txt");
    if( (!check_file.exists() && !check_file.isFile()) || m_update_host_files ){
        download_file("/FCSHosts.txt");
    }

    check_file.setFile(config_path + "/DMRHosts.txt");
    if( (!check_file.exists() && !check_file.isFile()) || m_update_host_files ){
        download_file("/DMRHosts.txt");
    }

    check_file.setFile(config_path + "/P25Hosts.txt");
    if( (!check_file.exists() && !check_file.isFile()) || m_update_host_files ){
        download_file("/P25Hosts.txt");
    }

    check_file.setFile(config_path + "/NXDNHosts.txt");
    if((!check_file.exists() && !check_file.isFile()) || m_update_host_files ){
        download_file("/NXDNHosts.txt");
    }

    check_file.setFile(config_path + "/M17Hosts-full.csv");
    if( (!check_file.exists() && !check_file.isFile()) || m_update_host_files ){
        download_file("/M17Hosts-full.csv");
    }

    check_file.setFile(config_path + "/DMRIDs.dat");
    if(!check_file.exists() && !check_file.isFile()){
        download_file("/DMRIDs.dat");
    }
    else {
        process_dmr_ids();
    }

    check_file.setFile(config_path + "/NXDN.csv");
    if(!check_file.exists() && !check_file.isFile()){
        download_file("/NXDN.csv");
    }
    else{
        process_nxdn_ids();
    }
    m_update_host_files = false;
    //process_mode_change(ui->modeCombo->currentText().simplified());
/*
#if defined(Q_OS_ANDROID)
    QString vocname = "/vocoder_plugin." + QSysInfo::productType() + "." + QSysInfo::currentCpuArchitecture();
#else
    QString vocname = "/vocoder_plugin." + QSysInfo::kernelType() + "." + QSysInfo::currentCpuArchitecture();
#endif
    QString newvoc = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation) + vocname;
    QString voc = config_path + vocname;
    check_file.setFile(newvoc);
    qDebug() << "newvoc == " << newvoc;
    qDebug() << "voc == " << voc;
    if(check_file.exists() && check_file.isFile()){
        qDebug() << newvoc << " found";
        if(QFile::exists(voc)){
            qDebug() << voc << " found";
            if(QFile::remove(voc)){
                qDebug() << voc << " deleted";
            }
            else{
                qDebug() << voc << " not deleted";
            }
        }
        if(QFile::copy(newvoc, voc)){
            qDebug() << newvoc << " copied";
        }
        else{
            qDebug() << "Could not copy " << newvoc;
        }
    }
    else{
        qDebug() << newvoc << " not found";
    }
*/
}

void DroidStar::update_data(Mode::MODEINFO info)
{
    // Helpful status tracing for debugging connect/TX issues
    if (connect_status == Mode::CONNECTING) {
        qDebug() << "update_data: CONNECTING, mode_status=" << info.status;
    }
    // If the Mode reports DISCONNECTED while we are trying to connect, treat it as a connect failure.
    // The previous behavior called process_connect(), which toggled into a normal "Disconnected" path
    // and hid the actual failure from the UI.
    if ((connect_status == Mode::CONNECTING) && (info.status == Mode::DISCONNECTED)) {
        qDebug() << "Connect attempt failed (Mode returned DISCONNECTED)";
        connect_failed("Connection failed");
        return;
    }

    if( (connect_status == Mode::CONNECTING) && ( info.status == Mode::CONNECTED_RW)){
        connect_status = Mode::CONNECTED_RW;
        m_connectTimeoutTimer->stop();
        m_reconnectAttempt = 0;
        ptt_sync_channel();
        emit connect_status_changed(2);
        emit in_audio_vol_changed(0.5);
        emit swtx_state(!m_mode->get_hwtx());
        emit swrx_state(!m_mode->get_hwrx());
        emit rptr2_changed(m_refname + " " + m_module);
        if(m_mycall.isEmpty()) set_mycall(m_callsign);
        if(m_urcall.isEmpty()) set_urcall("CQCQCQ");
        if(m_rptr1.isEmpty()) set_rptr1(m_callsign + " " + m_module);
        emit update_log("Connected to " + m_protocol + " " + m_refname + " " + m_host + ":" + QString::number(m_port));
        // A phone fix that arrived during the login handshake was not in RPTC.
        QTimer::singleShot(0, this, &DroidStar::on_phone_position);
#ifdef Q_OS_IOS
        // Notify audio session manager of connection (enables Now Playing & keep-alive)
        setAudioConnectionState(true, m_refname.toUtf8().constData(), m_protocol.toUtf8().constData());
        setAudioReconnectHold(false);
#endif

        if(info.sw_vocoder_loaded){
            emit update_log("Vocoder plugin loaded");
        }
        else{
            emit update_log("Vocoder plugin not loaded");
            emit open_vocoder_dialog();
        }
    }

    m_netstatustxt = "Connected ping cnt: " + QString::number(info.count);
    m_ambestatustxt = "AMBE: " + (info.ambeprodid.isEmpty() ? "No device" : info.ambeprodid);
    m_mmdvmstatustxt = "MMDVM: ";

    if(info.mmdvm.isEmpty()){
        m_mmdvmstatustxt += "No device";
    }

    QStringList verlist = info.ambeverstr.split('.');
    if(verlist.size() > 7){
        m_ambestatustxt += " " + verlist.at(0) + " " + verlist.at(5) + " " + verlist.at(6);
    }

    verlist = info.mmdvm.split(' ');
    if(verlist.size() > 3){
        m_mmdvmstatustxt += verlist.at(0) + " " + verlist.at(1);
    }

    if(info.stream_state == Mode::STREAM_IDLE){
        m_data1.clear();
        m_data2.clear();
        m_data3.clear();
        m_data4.clear();
        m_data5.clear();
        m_data6.clear();
    }
    else if (m_protocol == "REF" || m_protocol == "XRF" || m_protocol == "DCS"){
        m_data1 = info.src;
        m_data2 = info.dst;
        m_data3 = info.gw;
        m_data4 = info.gw2;
        m_data5 = QString::number(info.streamid, 16) + " " + QString("%1").arg(info.frame_number, 2, 16, QChar('0'));
        m_data6 = info.usertxt;
    }
    else if (m_protocol == "YSF" || m_protocol == "FCS"){
        m_data1 = info.gw;
        m_data2 = info.src;
        m_data3 = info.dst;

        if(info.type == 0){
            m_data4 = "V/D mode 1";
        }
        else if(info.type == 1){
            m_data4 = "Data Full Rate";
        }
        else if(info.type == 2){
            m_data4 = "V/D mode 2";
        }
        else if(info.type == 3){
            m_data4 = "Voice Full Rate";
        }
        else{
            m_data4 = "";
        }
        if(info.type >= 0){
            m_data5 = info.path  ? "Internet" : "Local";
            m_data6 = QString::number(info.frame_number) + "/" + QString::number(info.frame_total);
        }
        else{
            m_data5 = m_data6 = "";
        }
    }
    else if(m_protocol == "DMR"){
        m_data1 = m_dmrids[info.srcid];
        m_data2 = info.srcid ? QString::number(info.srcid) : "";
        m_data3 = info.dstid ? QString::number(info.dstid) : "";
        m_data4 = info.gwid ? QString::number(info.gwid) : "";
        m_data6 = info.usertxt;   // received Talker Alias, empty until complete
        QString s = "Slot" + QString::number(info.slot);
        QString flco;

        switch( (info.slot & 0x40) >> 6){
        case 0:
            flco = "Group";
            break;
        case 3:
            flco = "Private";
            break;
        case 8:
            flco = "GPS";
            break;
        default:
            flco = "Unknown";
            break;
        }

        if(info.frame_number){
            QString n = s + " " + flco + " " + QString("%1").arg(info.frame_number, 2, 16, QChar('0'));
            m_data5 = n;
        }
    }
    else if(m_protocol == "P25"){
        m_data1 = m_dmrids[info.srcid];
        m_data2 = info.srcid ? QString::number(info.srcid) : "";
        m_data3 = info.dstid ? QString::number(info.dstid) : "";
        m_data4 = info.srcid ? QString::number(info.srcid) : "";
        if(info.frame_number){
            QString n = QString("%1").arg(info.frame_number, 2, 16, QChar('0'));
            m_data5 = n;
        }
    }
    else if(m_protocol == "NXDN"){
        if(info.srcid){
            m_data1 = m_nxdnids[info.srcid];
            m_data2 = QString::number(info.srcid);
        }
        m_data3 = QString::number(info.dstid);

        if(info.frame_number){
            QString n = QString("%1").arg(info.frame_number, 4, 16, QChar('0'));
            m_data5 = n;
        }
    }
    else if(m_protocol == "M17"){
        m_data1 = info.src;
        m_data2 = info.dst + " " + info.module;
        m_data3 = info.type ? "3200 Voice" : "1600 V/D";
        if(info.frame_number){
            QString n = QString("%1").arg(info.frame_number, 4, 16, QChar('0'));
            m_data4 = n;
        }
        m_data5 = QString::number(info.streamid, 16);
    }
    else if(m_protocol == "IAX"){

    }
    QString t = QDateTime::fromMSecsSinceEpoch(info.ts).toString("yyyy.MM.dd hh:mm:ss.zzz");
    if((m_protocol == "DMR") || (m_protocol == "P25") || (m_protocol == "NXDN")){
        if(info.stream_state == Mode::STREAM_NEW){
            emit update_log(t + " " + m_protocol + " RX started id: " + " srcid: " + QString::number(info.srcid) + " dstid: " + QString::number(info.dstid));
        }
        if(info.stream_state == Mode::STREAM_END){
            emit update_log(t + " " + m_protocol + " RX ended id: " + " srcid: " + QString::number(info.srcid) + " dstid: " + QString::number(info.dstid));
        }
        if(info.stream_state == Mode::STREAM_LOST){
            emit update_log(t + " " + m_protocol + " RX lost id: " + " srcid: " + QString::number(info.srcid) + " dstid: " + QString::number(info.dstid));
        }
    }
    else{
        if(info.stream_state == Mode::STREAM_NEW){
            emit update_log(t + " " + m_protocol + " RX started id: " + QString::number(info.streamid, 16) + " src: " + info.src + " dst: " + info.gw2);
        }
        if(info.stream_state == Mode::STREAM_END){
            emit update_log(t + " " + m_protocol + " RX ended id: " + QString::number(info.streamid, 16) + " src: " + info.src + " dst: " + info.gw2);
        }
        if(info.stream_state == Mode::STREAM_LOST){
            emit update_log(t + " " + m_protocol + " RX lost id: " + QString::number(info.streamid, 16) + " src: " + info.src + " dst: " + info.gw2);
        }
    }
    
#ifdef Q_OS_IOS
    // Update Now Playing / Lock Screen with current RX info
    if (m_pttFramework && ptt_is_joined()) {
        QString talker;
        if ((info.stream_state == Mode::STREAM_NEW) || (info.stream_state == Mode::STREAMING)) {
            talker = m_data1.isEmpty() ? QString::number(info.srcid) : m_data1;
        }
        if (talker != m_pttTalker) {
            m_pttTalker = talker;
            ptt_set_remote_talker(talker.toUtf8().constData());
        }
    }
    if (info.stream_state == Mode::STREAM_IDLE) {
        clearAudioRXState();
    } else if (!m_data1.isEmpty()) {
        // m_data1 typically contains callsign, pass it to Now Playing
        // Note: Name and country lookups happen in QML, this is for basic callsign display
        setAudioRXState(m_data1.toUtf8().constData(), "", "");
    }
#endif

    // Track the talker for the Live Activity; the card keeps the last one while idle.
    if ((info.stream_state == Mode::STREAM_NEW) || (info.stream_state == Mode::STREAMING)) {
        QString talker = m_data1.trimmed();
        if (talker.isEmpty()) talker = m_data2.trimmed();
        if (!talker.isEmpty()) {
            if (!m_laRxActive || talker != m_laTalker) m_laSinceMs = QDateTime::currentMSecsSinceEpoch();
            m_laRxActive = true;
            m_laTalker = talker;
            const bool hasTg = (m_protocol == "DMR") || (m_protocol == "P25") || (m_protocol == "NXDN")
                || (m_protocol == "YSF") || (m_protocol == "FCS");
            m_laTg = hasTg ? m_data3.trimmed() : QString();
        }
    }
    else if (m_laRxActive) {
        m_laRxActive = false;
        m_laSinceMs = QDateTime::currentMSecsSinceEpoch();
    }
    live_activity_sync();

    emit update_data();
}

void DroidStar::updatelog(QString s)
{
    emit update_log(s);
}

void DroidStar::set_input_volume(qreal v)
{
    emit in_audio_vol_changed(v);
    //audioin->setVolume(v * 0.01);
}

void DroidStar::press_tx()
{
    qDebug() << "TX press (app button / headphone)";
    m_txOn = true;
    if (m_hwTxSafetyTimer) m_hwTxSafetyTimer->stop();   // TX now owned by another source
#ifdef Q_OS_IOS
    setAudioTXState(true);
    if (m_pttFramework) ptt_app_tx(true);
#endif
    emit tx_pressed();
    live_activity_set_tx(true);
}

void DroidStar::release_tx()
{
    qDebug() << "TX release (app button / headphone)";
    m_txOn = false;
    if (m_hwTxSafetyTimer) m_hwTxSafetyTimer->stop();   // TX now owned by another source
#ifdef Q_OS_IOS
    setAudioTXState(false);
    if (m_pttFramework) ptt_app_tx(false);
#endif
    emit tx_released();
    live_activity_set_tx(false);
}

void DroidStar::click_tx(bool tx)
{
    qDebug() << "TX toggle (app button):" << tx;
    m_txOn = tx;
    if (m_hwTxSafetyTimer) m_hwTxSafetyTimer->stop();   // TX now owned by another source
#ifdef Q_OS_IOS
    if (m_pttFramework) ptt_app_tx(tx);
#endif
    emit tx_clicked(tx);
    live_activity_set_tx(tx);
}

// TX requested by the system PTT UI or a handsfree button: do the TX without echoing it back.
void DroidStar::ptt_system_begin_tx()
{
    qDebug() << "TX begin from system PTT, connected:" << (connect_status == Mode::CONNECTED_RW);
    if (connect_status != Mode::CONNECTED_RW) return;
    m_txOn = true;
    if (m_hwTxSafetyTimer) m_hwTxSafetyTimer->stop();   // TX now owned by another source
#ifdef Q_OS_IOS
    setAudioTXState(true);
#endif
    emit tx_pressed();
    emit system_tx_changed(true);
    live_activity_set_tx(true);
}

void DroidStar::ptt_system_end_tx()
{
    qDebug() << "TX end from system PTT";
    m_txOn = false;
    if (m_hwTxSafetyTimer) m_hwTxSafetyTimer->stop();   // TX now owned by another source
#ifdef Q_OS_IOS
    setAudioTXState(false);
#endif
    emit tx_released();
    emit system_tx_changed(false);
    live_activity_set_tx(false);
}

// The system just activated the audio session; if we are transmitting, the mic opened before
// that may be dead, so reopen it.
void DroidStar::ptt_audio_activated()
{
    if (connect_status == Mode::CONNECTED_RW) emit restart_capture_requested();
}

bool DroidStar::ptt_framework_available() const
{
#ifdef Q_OS_IOS
    return ptt_is_available();
#else
    return false;
#endif
}

QString DroidStar::ptt_channel_name() const
{
    // The PTT UI already shows the app name; keep the channel short so it isn't truncated.
    QString name = m_refname;
    if ((m_protocol == "DMR") && m_dmr_destid) {
        name += " \u00b7 TG " + QString::number(m_dmr_destid);
    }
    return name;
}

// Join / rename / leave the PushToTalk channel to match settings and connection state.
void DroidStar::ptt_sync_channel()
{
#ifdef Q_OS_IOS
    if (m_pttFramework && (connect_status == Mode::CONNECTED_RW)) {
        ptt_join(ptt_channel_name().toUtf8().constData());
    } else if (!m_pttFramework) {
        ptt_leave();
        m_pttTalker.clear();
    }
#endif
}

void DroidStar::set_ptt_framework(bool on)
{
    m_pttFramework = on;
    save_settings();
    ptt_sync_channel();
}

void DroidStar::set_tx_tone(int tone)
{
    m_txTone = qBound(0, tone, 2);
    save_settings();
    emit tx_tone_changed(m_txTone);
}

void DroidStar::set_talker_alias(const QString &text)
{
    m_talkerAlias = text.simplified().left(27);
    save_settings();
    emit talker_alias_changed(effective_talker_alias());
}

void DroidStar::set_talker_alias_on(bool on)
{
    m_talkerAliasOn = on;
    save_settings();
    emit talker_alias_changed(effective_talker_alias());
}

QString DroidStar::effective_talker_alias() const
{
    if(!m_talkerAliasOn){
        return QString();
    }
    QString src = m_talkerAlias.simplified();
    if(src.isEmpty()){
        src = m_callsign.simplified();
    }
    // Sent as ISO 8-bit; keep it plain ASCII so every radio renders it.
    static const QString from = QStringLiteral("\u011F\u011E\u015F\u015E\u0131\u0130\u00F6\u00D6\u00FC\u00DC\u00E7\u00C7");
    static const QString to   = QStringLiteral("gGsSiIoOuUcC");
    QString out;
    for(const QChar c : src){
        const qsizetype i = from.indexOf(c);
        if(i >= 0){
            out += to.at(i);
            continue;
        }
        const QString base = QString(c).normalized(QString::NormalizationForm_D);
        for(const QChar b : base){
            const ushort u = b.unicode();
            if(u >= 0x20 && u < 0x7F){
                out += b;
            }
        }
    }
    return out.simplified().left(27);
}

void DroidStar::set_roger_beep(int mode)
{
    m_rogerBeep = qBound(0, mode, 4);
    save_settings();
    emit roger_beep_changed(m_rogerBeep);
}

void DroidStar::set_use_phone_gps(bool on)
{
    if(on == m_usePhoneGps){
        return;
    }
    m_usePhoneGps = on;
    save_settings();
    apply_phone_gps();
    emit gps_status_changed();
}

void DroidStar::set_auto_connect(bool on)
{
    if(on == m_autoConnect){
        return;
    }
    m_autoConnect = on;
    save_settings();
}

bool DroidStar::take_launch_auto_connect()
{
    if(!m_autoConnect || m_launchAutoConnectUsed || (connect_status != Mode::DISCONNECTED) || m_autoReconnect){
        return false;
    }
    m_launchAutoConnectUsed = true;
    return true;
}

// Same as the Connect button, but counted as an automatic attempt: right after launch the
// network may still be coming up, so a failure goes through the reconnect backoff instead of
// an error dialog. Without a network we just wait; on_network_state_changed() fires it early.
void DroidStar::process_auto_connect()
{
    if(connect_status != Mode::DISCONNECTED){
        return;
    }
    emit update_log("Auto-connecting on launch");
    QNetworkInformation *ni = QNetworkInformation::instance();
    if(ni && (ni->reachability() == QNetworkInformation::Reachability::Disconnected)){
        m_autoReconnect = true;
        schedule_reconnect("Auto-connect: no network");
        return;
    }
    m_reconnectAttempt = 1;
    process_connect();
}

QString DroidStar::get_gps_status() const
{
    if(!m_usePhoneGps || !m_phoneGps){
        return "Off";
    }
    return m_phoneGps->status_text();
}

void DroidStar::apply_phone_gps()
{
    if(!m_phoneGps){
        return;
    }
    if(m_usePhoneGps){
        m_phoneGps->start();
    }
    else{
        m_phoneGps->stop();
        m_gpsThrottleTimer->stop();
    }
}

// Position for the RPTC login packet: the phone fix when enabled and available, else the
// manual settings. Remembered as the last position the master knows about.
void DroidStar::dmr_login_position(QString &lat, QString &lon)
{
    m_gpsThrottleTimer->stop();
    m_gpsSentMs = QDateTime::currentMSecsSinceEpoch();
    if(m_usePhoneGps && m_phoneGps && m_phoneGps->has_fix()){
        m_gpsSentLat = m_phoneGps->latitude();
        m_gpsSentLon = m_phoneGps->longitude();
        m_gpsSentFromPhone = true;
        lat = QString::number(m_gpsSentLat, 'f', 4);
        lon = QString::number(m_gpsSentLon, 'f', 4);
        emit update_log("DMR: using phone position " + lat + ", " + lon);
        return;
    }
    lat = m_latitude;
    lon = m_longitude;
    m_gpsSentLat = m_latitude.toDouble();
    m_gpsSentLon = m_longitude.toDouble();
    m_gpsSentFromPhone = false;
    if(m_usePhoneGps){
        emit update_log("DMR: no phone position yet, logging in with the manual location");
    }
}

// Live position update while linked. RPTG goes to BrandMeister only (the network DMRGateway
// enables it for); other masters get the phone position at the next login.
void DroidStar::on_phone_position()
{
    if(!m_usePhoneGps || !m_phoneGps || !m_phoneGps->has_fix()){
        return;
    }
    if((connect_status != Mode::CONNECTED_RW) || (m_protocol != "DMR") || !m_mode){
        return;
    }
    if(!m_refname.startsWith("BM") || (m_rptgRejectedHost == m_host)){
        return;
    }
    const double lat = m_phoneGps->latitude();
    const double lon = m_phoneGps->longitude();
    if(dmr_distance_m(m_gpsSentLat, m_gpsSentLon, lat, lon) < kGpsUpdateMinMeters){
        return;
    }
    // Replacing the manual login position with the first phone fix is not throttled.
    if(m_gpsSentFromPhone){
        const qint64 wait = m_gpsSentMs + kGpsUpdateMinMs - QDateTime::currentMSecsSinceEpoch();
        if(wait > 0){
            if(!m_gpsThrottleTimer->isActive()){
                m_gpsThrottleTimer->start(int(wait) + 1000);
            }
            return;
        }
    }
    m_gpsSentLat = lat;
    m_gpsSentLon = lon;
    m_gpsSentMs = QDateTime::currentMSecsSinceEpoch();
    m_gpsSentFromPhone = true;
    emit dmr_position_changed(QString::number(lat, 'f', 4), QString::number(lon, 'f', 4));
}

void DroidStar::on_rptg_rejected()
{
    m_rptgRejectedHost = m_host;
    m_gpsThrottleTimer->stop();
}

void DroidStar::set_hw_ptt_buttons(int buttons)
{
    m_hwPttButtons = qBound(0, buttons, 3);
    qDebug() << "HW PTT buttons set to" << m_hwPttButtons;
    save_settings();
#ifdef Q_OS_IOS
    hwptt_configure(m_hwPttButtons, m_hwPttMode);
#endif
}

void DroidStar::set_hw_ptt_mode(int mode)
{
    m_hwPttMode = qBound(0, mode, 1);
    qDebug() << "HW PTT mode set to" << (m_hwPttMode ? "hold" : "toggle");
    save_settings();
#ifdef Q_OS_IOS
    hwptt_configure(m_hwPttButtons, m_hwPttMode);
#endif
}

int DroidStar::hw_ptt_action(int action, const QString &source)
{
    const bool connected = (connect_status == Mode::CONNECTED_RW);
    const bool want = (action == 2) ? !m_txOn : (action == 1);
    qDebug() << "HW PTT event from" << source << "action" << action << "tx" << m_txOn << "->" << want
             << "connected" << connected;
    if (m_debugLog) {
        emit update_log(QString("PTT button: %1 action %2, TX %3 -> %4%5").arg(source).arg(action)
                        .arg(m_txOn ? "on" : "off").arg(want ? "on" : "off").arg(connected ? "" : " (not connected)"));
    }
    if (!connected) {
        m_txOn = false;
        return (action == 0) ? 0 : -1;
    }
    if (want != m_txOn) set_tx_from_hw(want, source);
    return m_txOn ? 1 : 0;
}

void DroidStar::hw_ptt_log(const QString &line)
{
    if (m_debugLog) emit update_log("PTT button: " + line);
}

// Same path as the in-app key (press_tx/release_tx) plus system_tx_changed so the UI mirrors it.
void DroidStar::set_tx_from_hw(bool on, const QString &source)
{
    m_txOn = on;
#ifdef Q_OS_IOS
    setAudioTXState(on);
    if (m_pttFramework) ptt_app_tx(on);
#endif
    if (on) emit tx_pressed(); else emit tx_released();
    emit system_tx_changed(on);
    live_activity_set_tx(on);

    if (!m_hwTxSafetyTimer) {
        m_hwTxSafetyTimer = new QTimer(this);
        m_hwTxSafetyTimer->setSingleShot(true);
        connect(m_hwTxSafetyTimer, &QTimer::timeout, this, [this]() {
            if (!m_txOn) return;
            qDebug() << "HW PTT: TX timeout" << m_txtimeout << "s reached, stopping TX";
            emit update_log(QString("TX stopped after %1 s (side button TX timeout)").arg(m_txtimeout));
            set_tx_from_hw(false, "tx-timeout");
        });
    }
    if (on && m_txtimeout > 0) m_hwTxSafetyTimer->start(int(m_txtimeout) * 1000);
    else m_hwTxSafetyTimer->stop();
    qDebug() << "HW PTT: TX" << (on ? "ON" : "OFF") << "by" << source;
}

void DroidStar::set_headphone_ptt(bool on)
{
    m_headphonePtt = on;
    save_settings();
#ifdef Q_OS_IOS
    setRemotePTTEnabled(on);
#endif
}

void DroidStar::addRecentTGID(const QString& tgid) {
    QSettings settings;
    settings.beginGroup("RecentTGIDs");
    QStringList tgids = settings.value("tgids").toStringList();

    if (!tgids.contains(tgid)) {
        tgids.prepend(tgid);  // Add new TGID at the beginning of the list
        if (tgids.size() > 10)  // Let's assume you want to keep at most 10 entries
            tgids.removeLast();
    }

    settings.setValue("tgids", tgids);
    settings.endGroup();
}

void DroidStar::live_activity_set_tx(bool tx)
{
    if (tx == m_laTx) return;
    m_laTx = tx;
    m_laSinceMs = QDateTime::currentMSecsSinceEpoch();
    live_activity_sync();
}

// Mirrors the link state onto the iOS Live Activity: starts it once connected, updates it on
// RX/TX changes and ends it on disconnect. Cheap when nothing changed (update_data calls this
// for every voice frame).
void DroidStar::live_activity_sync(bool force)
{
#ifdef Q_OS_IOS
    const bool linked = (connect_status == Mode::CONNECTED_RW);
    const bool relinking = !linked && m_autoReconnect
        && (m_reconnectTimer->isActive() || (connect_status == Mode::CONNECTING));

    if (!linked && !relinking) {
        m_laTx = false;
        m_laRxActive = false;
        m_laTalker.clear();
        m_laTg.clear();
        m_laRefreshTimer->stop();
        if (!m_laMode.isEmpty()) {
            m_laMode.clear();
            m_laKey.clear();
            ios_live_activity_end();
        }
        return;
    }

    QString status = m_protocol;
    QString ref = m_refname;
    ref.replace('_', ' ');
    ref = ref.simplified();
    if (!ref.isEmpty()) {
        if ((m_protocol == "REF") || (m_protocol == "XRF") || (m_protocol == "DCS") || (m_protocol == "M17")) {
            ref += " " + QString(QChar(m_module));
        }
        status += QString::fromUtf8(" · ") + ref;
    }

    QString mode, callsign, name, country, tg;
    if (!linked) {
        mode = "LINK";
    }
    else if (m_laTx) {
        mode = "TX";
        callsign = m_callsign;
        if (m_protocol == "DMR") tg = m_dmr_destid ? QString::number(m_dmr_destid) : QString();
    }
    else {
        mode = m_laRxActive ? "RX" : "IDLE";
        callsign = m_laTalker;
        tg = m_laTg;
        if (tg.isEmpty() && (m_protocol == "DMR") && m_dmr_destid) tg = QString::number(m_dmr_destid);
        if (!m_laTalker.isEmpty() && (m_laNameFor.compare(m_laTalker, Qt::CaseInsensitive) == 0)) {
            name = m_laName;
            country = m_laCountry;
        }
    }

    if (mode != m_laMode && (mode == "LINK" || m_laMode.isEmpty() || m_laMode == "LINK")) {
        m_laSinceMs = QDateTime::currentMSecsSinceEpoch();
    }
    if (m_laSinceMs == 0) m_laSinceMs = QDateTime::currentMSecsSinceEpoch();

    const QString key = QStringList{mode, callsign, name, country, tg, status, m_callsign,
                                    QString::number(m_laSinceMs)}.join('\x1f');
    if (!force && key == m_laKey) return;
    m_laKey = key;
    m_laMode = mode;
    if (!m_laRefreshTimer->isActive()) m_laRefreshTimer->start();

    ios_live_activity_update(mode.toUtf8().constData(),
                             callsign.toUtf8().constData(),
                             name.toUtf8().constData(),
                             country.toUtf8().constData(),
                             tg.toUtf8().constData(),
                             status.toUtf8().constData(),
                             m_callsign.toUtf8().constData(),
                             m_laSinceMs / 1000.0);
#else
    Q_UNUSED(force);
#endif
}

void DroidStar::updateNowPlayingRX(const QString& callsign, const QString& name, const QString& country)
{
    // Name/country come from the QML lookup, a moment after the callsign.
    if (!callsign.trimmed().isEmpty()) {
        m_laNameFor = callsign.trimmed();
        m_laName = name.trimmed();
        m_laCountry = country.trimmed();
        live_activity_sync();
    }
#ifdef Q_OS_IOS
    setAudioRXState(callsign.toUtf8().constData(), 
                    name.toUtf8().constData(), 
                    country.toUtf8().constData());
#else
    Q_UNUSED(callsign);
    Q_UNUSED(name);
    Q_UNUSED(country);
#endif
}

// Saved channel lists (talkgroups and private-call contacts) are stored as
// "id|name" strings so the order survives and QSettings stays human-readable.
// Both lists share these helpers; only the settings key differs.
static const char *kFavoriteTGKey = "FavoriteTGs/list";
static const char *kFavoritePCKey = "FavoritePCs/list";

static QStringList favoriteEntries(const char *key)
{
    QSettings settings;
    return settings.value(key).toStringList();
}

static void saveFavoriteEntries(const char *key, const QStringList &entries)
{
    QSettings settings;
    settings.setValue(key, entries);
}

static int favoriteIndex(const QStringList &entries, const QString &id)
{
    for (int i = 0; i < entries.size(); ++i) {
        if (entries.at(i).section('|', 0, 0) == id) return i;
    }
    return -1;
}

static bool validFavoriteId(const QString &id)
{
    bool ok = false;
    const uint v = id.toUInt(&ok);
    return ok && v > 0;
}

static QString cleanFavoriteName(const QString &name)
{
    QString label = name.simplified();
    label.replace('|', ' ');
    return label;
}

static QVariantList loadFavorites(const char *key, const char *idField)
{
    QVariantList out;
    for (const QString &e : favoriteEntries(key)) {
        QVariantMap m;
        m[idField] = e.section('|', 0, 0);
        m["name"] = e.section('|', 1);
        out.append(m);
    }
    return out;
}

static void addFavorite(const char *key, const QString &rawId, const QString &name)
{
    const QString id = rawId.simplified();
    if (!validFavoriteId(id)) return;
    const QString label = cleanFavoriteName(name);
    QStringList entries = favoriteEntries(key);
    const int i = favoriteIndex(entries, id);
    if (i >= 0) {
        entries[i] = id + "|" + label;   // update name in place, keep position
    } else {
        entries.append(id + "|" + label);
    }
    saveFavoriteEntries(key, entries);
}

// Rename and/or renumber an entry, keeping its position. If the new number is
// already saved elsewhere, that other entry is dropped so ids stay unique.
static bool updateFavorite(const char *key, const QString &rawOldId, const QString &rawNewId, const QString &name)
{
    const QString oldId = rawOldId.simplified();
    const QString newId = rawNewId.simplified();
    if (!validFavoriteId(newId)) return false;
    const QString label = cleanFavoriteName(name);
    QStringList entries = favoriteEntries(key);
    int i = favoriteIndex(entries, oldId);
    if (i < 0) {
        addFavorite(key, newId, label);
        return true;
    }
    if (newId != oldId) {
        const int dup = favoriteIndex(entries, newId);
        if (dup >= 0) {
            entries.removeAt(dup);
            if (dup < i) --i;
        }
    }
    entries[i] = newId + "|" + label;
    saveFavoriteEntries(key, entries);
    return true;
}

static void removeFavorite(const char *key, const QString &id)
{
    QStringList entries = favoriteEntries(key);
    const int i = favoriteIndex(entries, id.simplified());
    if (i < 0) return;
    entries.removeAt(i);
    saveFavoriteEntries(key, entries);
}

static void moveFavorite(const char *key, int from, int to)
{
    QStringList entries = favoriteEntries(key);
    if (from < 0 || from >= entries.size() || to < 0 || to >= entries.size() || from == to) return;
    entries.move(from, to);
    saveFavoriteEntries(key, entries);
}

static bool isFavorite(const char *key, const QString &id)
{
    return favoriteIndex(favoriteEntries(key), id.simplified()) >= 0;
}

QVariantList DroidStar::loadFavoriteTGs() const { return loadFavorites(kFavoriteTGKey, "tg"); }
void DroidStar::addFavoriteTG(const QString &tg, const QString &name) { addFavorite(kFavoriteTGKey, tg, name); }
bool DroidStar::updateFavoriteTG(const QString &oldTg, const QString &newTg, const QString &name) { return updateFavorite(kFavoriteTGKey, oldTg, newTg, name); }
void DroidStar::removeFavoriteTG(const QString &tg) { removeFavorite(kFavoriteTGKey, tg); }
void DroidStar::moveFavoriteTG(int from, int to) { moveFavorite(kFavoriteTGKey, from, to); }
bool DroidStar::isFavoriteTG(const QString &tg) const { return isFavorite(kFavoriteTGKey, tg); }

QVariantList DroidStar::loadFavoritePCs() const { return loadFavorites(kFavoritePCKey, "id"); }
void DroidStar::addFavoritePC(const QString &id, const QString &name) { addFavorite(kFavoritePCKey, id, name); }
bool DroidStar::updateFavoritePC(const QString &oldId, const QString &newId, const QString &name) { return updateFavorite(kFavoritePCKey, oldId, newId, name); }
void DroidStar::removeFavoritePC(const QString &id) { removeFavorite(kFavoritePCKey, id); }
void DroidStar::moveFavoritePC(int from, int to) { moveFavorite(kFavoritePCKey, from, to); }
bool DroidStar::isFavoritePC(const QString &id) const { return isFavorite(kFavoritePCKey, id); }

QVariantList DroidStar::loadRecordings() const {
    QVariantList out;
    QDir dir(RxRecorder::recordingsDir());
    const QFileInfoList files = dir.entryInfoList(QStringList() << "*.wav", QDir::Files, QDir::Name | QDir::Reversed);
    for (const QFileInfo &fi : files) {
        // <yyyyMMdd-HHmmss-zzz>_<src>_<dst>.wav
        const QStringList parts = fi.completeBaseName().split('_');
        if (parts.size() != 3) continue;
        const QDateTime ts = QDateTime::fromString(parts.at(0), "yyyyMMdd-HHmmss-zzz");
        const uint32_t src = parts.at(1).toUInt();
        QVariantMap m;
        m["url"] = QUrl::fromLocalFile(fi.absoluteFilePath()).toString();
        m["file"] = fi.fileName();
        m["src"] = src;
        m["dst"] = parts.at(2).toUInt();
        m["callsign"] = m_dmrids.contains(src) ? m_dmrids.value(src) : QString::number(src);
        m["own"] = (src == m_dmrid);
        m["time"] = ts.isValid() ? ts.toMSecsSinceEpoch() : fi.lastModified().toMSecsSinceEpoch();
        m["seconds"] = qMax<qint64>(0, (fi.size() - 44) / (RxRecorder::kSampleRate * 2));
        out.append(m);
    }
    return out;
}

void DroidStar::deleteRecording(const QString &file) {
    // Only bare file names from loadRecordings() are accepted.
    if (file.contains('/') || !file.endsWith(".wav")) return;
    if (QDir(RxRecorder::recordingsDir()).remove(file)) emit recordings_changed();
}

QString DroidStar::lookupDmrId(uint id) const {
    return m_dmrids.value(id);
}

QStringList DroidStar::loadRecentTGIDs() const {
    QSettings settings;
    settings.beginGroup("RecentTGIDs");
    QStringList tgids = settings.value("tgids").toStringList();
    settings.endGroup();
    return tgids;
}

void DroidStar::clearRecentTGIDs() {
    QSettings settings;
    settings.beginGroup("RecentTGIDs");
    settings.remove("");
    settings.endGroup();
}

void DroidStar::on_network_state_changed(QNetworkInformation::Reachability reachability) {
    if (reachability == QNetworkInformation::Reachability::Online) {
        qDebug() << "Network is online. Checking connection status...";
        // Network is back: don't wait out the backoff.
        if ((connect_status == Mode::DISCONNECTED) && m_autoReconnect) {
            m_reconnectTimer->stop();
            attempt_reconnect();
        }
    } else {
        qDebug() << "Network is offline. Stopping keep-alive messages.";
        m_keepAliveTimer->stop();
    }
}


// Wi-Fi <-> cellular: the local IP changes and the old UDP flow is dead even though the
// master has not noticed yet. Re-register right away instead of waiting for the watchdog.
void DroidStar::on_transport_medium_changed(QNetworkInformation::TransportMedium medium) {
    qDebug() << "Network transport medium changed:" << medium;
    if (connect_status == Mode::CONNECTED_RW) {
        m_keepPttChannel = true;
        process_connect();
        m_keepPttChannel = false;
        m_autoReconnect = true;
        schedule_reconnect("Network changed", 1000);
    }
}

// Function to handle entering the background
void DroidStar::handle_background_state() {
    qDebug() << "App has entered background.";
    if (connect_status == Mode::CONNECTED_RW) {
        m_keepAliveTimer->stop();
#ifdef Q_OS_IOS
        // Critical: set up audio session for background playback and start a background task
        // so iOS doesn't suspend us while audio is playing.
        setupBackgroundAudio();
        renewBackgroundTask();
#endif
    }
}


/*void DroidStar::setPlaybackDevice(const QString &deviceName) {
    if (m_audioEngine) {
        m_audioEngine->setOutputDevice(deviceName);
    } else {
        qDebug() << "AudioEngine not initialized!";
    }
}

void DroidStar::setCaptureDevice(const QString &deviceName) {
    if (m_audioEngine) {
        m_audioEngine->setInputDevice(deviceName);
    } else {
        qDebug() << "AudioEngine not initialized!";
    }
}*/

QStringList DroidStar::get_playbacks() {
    QStringList playbacks = m_audioEngine->discover_audio_devices(1); // Fetch raw output devices
    QStringList friendlyPlaybacks;
    for (const QString &device : playbacks) {
        friendlyPlaybacks << m_audioEngine->getFriendlyName(device); // Convert to friendly names
    }
    return friendlyPlaybacks; // Return the list of friendly names
}

QStringList DroidStar::get_captures() {
    QStringList captures = m_audioEngine->discover_audio_devices(0); // Fetch raw input devices
    QStringList friendlyCaptures;
    for (const QString &device : captures) {
        friendlyCaptures << m_audioEngine->getFriendlyName(device); // Convert to friendly names
    }
    return friendlyCaptures; // Return the list of friendly names
}


void DroidStar::setPlaybackDevice(const QString &deviceName) {
    QString internalDeviceName = m_audioEngine->mapFriendlyNameToDevice(deviceName);
    m_audioEngine->setOutputDevice(internalDeviceName); // Set the selected playback device
}

void DroidStar::setCaptureDevice(const QString &deviceName) {
    QString internalDeviceName = m_audioEngine->mapFriendlyNameToDevice(deviceName);
    m_audioEngine->setInputDevice(internalDeviceName); // Set the selected capture device
}


// Function to handle returning to the foreground
void DroidStar::handle_foreground_state() {
    qDebug() << "App has returned to foreground.";
#ifdef Q_OS_IOS
    // Re-setup audio session to ensure correct routing after returning from background.
    setupAVAudioSession();
#endif
    if (connect_status == Mode::CONNECTED_RW) {
        // Restart keep-alive timer if still connected
        m_keepAliveTimer->start();
    }
    else if ((connect_status == Mode::DISCONNECTED) && m_autoReconnect && m_reconnectTimer->isActive()) {
        // Timers may have been frozen while suspended; retry now.
        m_reconnectTimer->stop();
        attempt_reconnect();
    }
}

void DroidStar::setup_state_change_listeners() {
#ifdef Q_OS_IOS
    connect(qApp, &QGuiApplication::applicationStateChanged, this, [=](Qt::ApplicationState state){
        if (state == Qt::ApplicationInactive || state == Qt::ApplicationSuspended) {
            handle_background_state();
        } else if (state == Qt::ApplicationActive) {
            handle_foreground_state();
        }
    });
#endif
}

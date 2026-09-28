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

#ifndef DROIDSTAR_H
#define DROIDSTAR_H

#include <QObject>
#include "mode.h"
#include "audioengine.h"  // Make sure AudioEngine is included
#include "phonegps.h"

class DroidStar : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QStringList playbackDevices READ getPlaybackDevices NOTIFY playbackDevicesChanged)
    Q_PROPERTY(QStringList captureDevices READ getCaptureDevices NOTIFY captureDevicesChanged)
    //Q_PROPERTY(AudioEngine* audioEngine READ getAudioEngine NOTIFY audioEngineChanged)


  
public:
    explicit DroidStar(QObject *parent = nullptr);
    QStringList getPlaybackDevices() const { return m_playbackDevices; }
       QStringList getCaptureDevices() const { return m_captureDevices; }
    AudioEngine* getAudioEngine() const { return m_audioEngine; }
    ~DroidStar();
    
    Q_INVOKABLE void addRecentTGID(const QString& tgid);
    Q_INVOKABLE QStringList loadRecentTGIDs() const;
    Q_INVOKABLE void clearRecentTGIDs();
    // Favorite talkgroups: ordered list of {tg, name}
    Q_INVOKABLE QVariantList loadFavoriteTGs() const;
    Q_INVOKABLE void addFavoriteTG(const QString &tg, const QString &name);
    Q_INVOKABLE void removeFavoriteTG(const QString &tg);
    Q_INVOKABLE void moveFavoriteTG(int from, int to);
    Q_INVOKABLE bool isFavoriteTG(const QString &tg) const;
    // Local DMR ID database lookup: "CALL - Name" (or "CALL"), empty when unknown/not loaded.
    Q_INVOKABLE QString lookupDmrId(uint id) const;
    // Received transmissions saved for replay, newest first:
    // {url, file, src, dst, callsign, time (ms), seconds}
    Q_INVOKABLE QVariantList loadRecordings() const;
    Q_INVOKABLE void deleteRecording(const QString &file);
    // Apple PushToTalk (iOS 16+): system PTT button on lock screen / Dynamic Island.
    Q_INVOKABLE bool ptt_framework_available() const;
    Q_INVOKABLE bool get_ptt_framework() const { return m_pttFramework; }
    Q_INVOKABLE void set_ptt_framework(bool on);
    // Headphone / lock-screen play-pause keys TX. Off by default: a tap on AirPods must not key up.
    Q_INVOKABLE bool get_headphone_ptt() const { return m_headphonePtt; }
    Q_INVOKABLE void set_headphone_ptt(bool on);
    // Roger beep over the air: 0 off, 1 end only, 2 start and end, 3 five-tone ANI (ZVEI-1) start and end
    Q_INVOKABLE int get_roger_beep() const { return m_rogerBeep; }
    Q_INVOKABLE void set_roger_beep(int mode);
    // TX voice tone: 0 natural, 1 thin (300 Hz high-pass), 2 very thin (500 Hz)
    Q_INVOKABLE int get_tx_tone() const { return m_txTone; }
    Q_INVOKABLE void set_tx_tone(int tone);
    // Phone position as DMR hotspot location (BrandMeister map / aprs.fi) instead of the manual
    // latitude/longitude. Persisted as USEPHONEGPS, off by default.
    Q_INVOKABLE bool get_use_phone_gps() const { return m_usePhoneGps; }
    Q_INVOKABLE void set_use_phone_gps(bool on);
    // Connect to the last server/TG when the app opens. Persisted as AUTOCONNECT, on by default.
    Q_INVOKABLE bool get_auto_connect() const { return m_autoConnect; }
    Q_INVOKABLE void set_auto_connect(bool on);
    // True once per launch if auto-connect should run now: the setting is on, we are idle and
    // nothing (a manual connect, cancel or disconnect) has touched the link yet. Consumes it.
    Q_INVOKABLE bool take_launch_auto_connect();
    // Launch auto-connect; the UI has already pushed the connection settings like for Connect.
    Q_INVOKABLE void process_auto_connect();
    // Short English status, e.g. "41.0082, 28.9784 (±12 m)", "Waiting for location",
    // "Location permission denied", "Off". Changes are signalled by gps_status_changed().
    Q_INVOKABLE QString get_gps_status() const;
    // DMR link quality ("signal bars"): {bars, rtt, rttAvg, pingLoss, rxLoss, jitter}.
    // bars: -1 unknown (no pong yet), 0 lost .. 4 excellent; ms / percent, -1 = not measured.
    // Changes are signalled by link_quality_changed() (at most about once a second).
    Q_INVOKABLE QVariantMap get_link_quality() const;
    Q_INVOKABLE void updateNowPlayingRX(const QString& callsign, const QString& name, const QString& country);
    void setup_state_change_listeners();
    

signals:
    void gps_status_changed();
    void link_quality_changed();
    void dmr_position_changed(QString lat, QString lon);   // to DMR::send_position (mode thread)
    void recordings_changed();
    void restart_capture_requested();
    void roger_beep_changed(int mode);
    void tx_tone_changed(int tone);
    // TX started/stopped outside the app UI (system PTT button, handsfree accessory).
    void system_tx_changed(bool on);
    void playbackDevicesChanged();
        void captureDevicesChanged();

    void input_source_changed(int, QString);
    void tgidsUpdated(const QStringList& newTgids);
    void recentTgidsUpdated();
    void mode_changed();
    void module_changed(char);
    void slot_changed(int);
    void cc_changed(int);
    void update_data();
    void update_log(QString);
    void open_vocoder_dialog();
    void update_settings();
    void connect_status_changed(int c);
    void in_audio_vol_changed(qreal);
    void tx_pressed();
    void tx_released();
    void tx_clicked(bool);
    void dmrpc_state_changed(int);
    void dmr_tgid_changed(int);
    void m17_rate_changed(int);
    void m17_can_changed(int);
    void send_dtmf(QByteArray);
    void swtx_state_changed(int);
    void swrx_state_changed(int);
    void swtx_state(int);
    void swrx_state(int);
    void agc_state(int);
    void agc_state_changed(int);
    void rptr1_changed(QString);
    void rptr2_changed(QString);
    void mycall_changed(QString);
    void urcall_changed(QString);
    void usrtxt_changed(QString);
    void dst_changed(QString);
    void debug_changed(bool);
    void update_devices();
public slots:
    void handle_background_state();
    void handle_foreground_state();
    void updateDeviceListInQML();
    

    void set_callsign(const QString &callsign) {  m_callsign = callsign.simplified(); save_settings(); }
    void set_dmrtgid(const QString &dmrtgid) { m_dmr_destid = dmrtgid.simplified().toUInt(); save_settings(); if (m_pttFramework) ptt_sync_channel(); }
    void set_slot(const int slot) {emit slot_changed(slot); }
    void set_cc(const int cc) {emit cc_changed(cc); }
    void tgid_text_changed(QString s){emit dmr_tgid_changed(s.toUInt());}
    void set_dmrid(const QString &dmrid) { m_dmrid = dmrid.simplified().toUInt(); save_settings(); }
    void set_essid(const QString &essid)
    {
        if (essid != "None") {
            m_essid = essid.simplified().toUInt() + 1;
            save_settings();
        }
        else{
            m_essid = 0;
        }
    }
    void set_bm_password(const QString &bmpwd) { m_bm_password = bmpwd; save_settings(); }
    void set_tgif_password(const QString &tgifpwd) { m_tgif_password = tgifpwd; save_settings(); }
    void set_latitude(const QString &lat){ m_latitude = lat; save_settings(); }
    void set_longitude(const QString &lon){ m_longitude = lon; save_settings(); }
    void set_location(const QString &loc){ m_location = loc; save_settings(); }
    void set_description(const QString &desc){ m_description = desc; save_settings(); }
    void set_freq(const QString &freq){ m_freq = freq; save_settings(); }
    void set_url(const QString &url){ m_url = url; save_settings(); }
    void set_swid(const QString &swid){ m_swid = swid; save_settings(); }
    void set_pkgid(const QString &pkgid){ m_pkgid = pkgid; save_settings(); }
    void set_dmr_options(const QString &dmropts) { m_dmropts = dmropts; save_settings(); }
    void set_dmr_pc(int pc) { m_pc = pc; emit dmrpc_state_changed(m_pc); }
    void set_module(const QString &module) { m_module = module.toStdString()[0]; save_settings(); emit module_changed(m_module);}
    void set_protocol(const QString &protocol) { m_protocol = protocol; save_settings(); }
    void set_input_volume(qreal v);
    void set_modelchange(bool t){ m_modelchange = t; }
    void set_mycall(const QString &mycall) { m_mycall = mycall; save_settings(); emit mycall_changed(mycall); }
    void set_urcall(const QString &urcall) { m_urcall = urcall; save_settings(); emit urcall_changed(urcall); }
    void set_rptr1(const QString &rptr1) { m_rptr1 = rptr1; save_settings(); emit rptr1_changed(rptr1); qDebug() << "rpt1 == " << m_rptr1; }
    void set_rptr2(const QString &rptr2) { m_rptr2 = rptr2; save_settings(); emit rptr2_changed(rptr2); qDebug() << "rpt2 == " << m_rptr2; }
    void set_usrtxt(const QString &usrtxt) { m_dstarusertxt = usrtxt; save_settings(); emit usrtxt_changed(usrtxt); }
    void set_txtimeout(const QString &t) { m_txtimeout = t.simplified().toUInt(); save_settings();}
    void set_toggletx(bool x) { m_toggletx = x; save_settings(); }
    void set_xrf2ref(bool x) { m_xrf2ref = x; save_settings(); }
    void set_ipv6(bool ipv6) { m_ipv6 = ipv6; save_settings(); }
    void set_vocoder(QString vocoder) { m_vocoder = vocoder; }
    void set_modem(QString modem) { m_modem = modem; }
    void set_playback(QString playback) { m_playback = playback; }
    void set_capture(QString capture) { m_capture = capture; }
    void set_swtx(bool swtx) { emit swtx_state_changed(swtx); }
    void set_swrx(bool swrx) { emit swrx_state_changed(swrx); }
    void set_agc(bool agc) { emit agc_state_changed(agc); }
    void set_mmdvm_direct(bool mmdvm) { m_mdirect = mmdvm; process_mode_change(m_protocol); }
    void set_iaxport(const QString &port){ m_iaxport = port.simplified().toUInt(); save_settings(); }
    void set_dst(QString dst){emit dst_changed(dst);}
    void set_debug(bool debug){emit debug_changed(debug);}

    void set_modemRxFreq(QString m) { m_modemRxFreq = m; save_settings(); }
    void set_modemTxFreq(QString m) { m_modemTxFreq = m; save_settings(); }
    void set_modemRxOffset(QString m) { m_modemRxOffset = m; save_settings(); }
    void set_modemTxOffset(QString m) { m_modemTxOffset = m; save_settings(); }
    void set_modemRxDCOffset(QString m) { m_modemRxDCOffset = m; save_settings(); }
    void set_modemTxDCOffset(QString m) { m_modemTxDCOffset = m; save_settings(); }
    void set_modemRxLevel(QString m) { m_modemRxLevel = m; save_settings(); }
    void set_modemTxLevel(QString m) { m_modemTxLevel = m; save_settings(); }
    void set_modemRFLevel(QString m) { m_modemRFLevel = m; save_settings(); }
    void set_modemTxDelay(QString m) { m_modemTxDelay = m; save_settings(); }
    void set_modemCWIdTxLevel(QString m) { m_modemCWIdTxLevel = m; save_settings(); }
    void set_modemDstarTxLevel(QString m) { m_modemDstarTxLevel = m; save_settings(); }
    void set_modemDMRTxLevel(QString m) { m_modemDMRTxLevel = m; save_settings(); }
    void set_modemYSFTxLevel(QString m) { m_modemYSFTxLevel = m; save_settings(); }
    void set_modemP25TxLevel(QString m) { m_modemP25TxLevel = m; save_settings(); }
    void set_modemNXDNTxLevel(QString m) { m_modemNXDNTxLevel = m; save_settings(); }
    void set_modemBaud(QString m) { m_modemBaud = m; save_settings(); }
    void set_modemM17CAN(QString m) { emit m17_can_changed(m.toInt()); }

    void m17_rate_changed(bool r) { emit m17_rate_changed((int)r); }
    void process_connect();
    void press_tx();
    void release_tx();
    void click_tx(bool);
    void process_settings();
    void check_host_files();
    void update_host_files();
    void update_custom_hosts(QString);
    void update_dmr_ids();
    void update_nxdn_ids();
    void process_mode_change(const QString &m);
    void process_host_change(const QString &h);
    void dtmf_send_clicked(QString);
    bool get_modelchange(){ return m_modelchange; }
    QString get_label1() { return m_label1; }
    QString get_label2() { return m_label2; }
    QString get_label3() { return m_label3; }
    QString get_label4() { return m_label4; }
    QString get_label5() { return m_label5; }
    QString get_label6() { return m_label6; }
    QString get_data1() { return m_data1; }
    QString get_data2() { return m_data2; }
    QString get_data3() { return m_data3; }
    QString get_data4() { return m_data4; }
    QString get_data5() { return m_data5; }
    QString get_data6() { return m_data6; }
    QString get_ambestatustxt() { return m_ambestatustxt; }
    QString get_mmdvmstatustxt() { return m_mmdvmstatustxt; }
    QString get_netstatustxt() { return m_netstatustxt; }
    QString get_mode() { return m_protocol; }
    QString get_host() { return m_host; }
    QString get_module() { return QString(m_module); }
    QString get_callsign() { return m_callsign; }
    QString get_dmrid() { return m_dmrid ? QString::number(m_dmrid) : ""; }
    QString get_essid() { return m_essid ? QString("%1").arg(m_essid - 1, 2, 10, QChar('0')) : "None"; }
    QString get_bm_password() { return m_bm_password; }
    QString get_tgif_password() { return m_tgif_password; }
    QString get_latitude() { return m_latitude; }
    QString get_longitude() { return m_longitude; }
    QString get_location() { return m_location; }
    QString get_description() { return m_description; }
    QString get_freq() { return m_freq; }
    QString get_url() { return m_url; }
    QString get_swid() { return m_swid; }
    QString get_pkgid() { return m_pkgid; }
    QString get_dmr_options() { return m_dmropts; }
    QString get_dmrtgid() { return m_dmr_destid ? QString::number(m_dmr_destid) : ""; }
    QStringList get_hosts() { return m_hostsmodel; }
    QString get_ref_host() { return m_saved_refhost; }
    QString get_dcs_host() { return m_saved_dcshost; }
    QString get_xrf_host() { return m_saved_xrfhost; }
    QString get_ysf_host() { return m_saved_ysfhost; }
    QString get_fcs_host() { return m_saved_fcshost; }
    QString get_dmr_host() { return m_saved_dmrhost; }
    QString get_p25_host() { return m_saved_p25host; }
    QString get_nxdn_host() { return m_saved_nxdnhost; }
    QString get_m17_host() { return m_saved_m17host; }
    QString get_iax_host() { return m_saved_iaxhost; }
    QString get_mycall() { return m_mycall; }
    QString get_urcall() { return m_urcall; }
    QString get_rptr1() { return m_rptr1; }
    QString get_rptr2() { return m_rptr2; }
    QString get_txtimeout() { return QString::number(m_txtimeout); }
    QString get_error_text() { return m_errortxt; }
    bool get_toggletx() { return m_toggletx; }
    bool get_ipv6() { return m_ipv6; }
    bool get_xrf2ref() { return m_xrf2ref; }
    QString get_local_hosts(){ return m_localhosts; }
    QStringList get_vocoders() { return m_vocoders; }
    QStringList get_modems() { return m_modems; }
    //QStringList get_playbacks() { return m_playbacks; }
    //QStringList get_captures() { return m_captures; }
    QString get_modemRxFreq() { return m_modemRxFreq; }
    QString get_modemTxFreq() { return m_modemTxFreq; }
    QString get_modemRxOffset() { return m_modemRxOffset; }
    QString get_modemTxOffset() { return m_modemTxOffset; }
    QString get_modemRxDCOffset() { return m_modemRxDCOffset; }
    QString get_modemTxDCOffset() { return m_modemTxDCOffset; }
    QString get_modemRxLevel() { return m_modemRxLevel; }
    QString get_modemTxLevel() { return m_modemTxLevel; }
    QString get_modemRFLevel() { return m_modemRFLevel; }
    QString get_modemTxDelay() { return m_modemTxDelay; }
    QString get_modemCWIdTxLevel() { return m_modemCWIdTxLevel; }
    QString get_modemDstarTxLevel() { return m_modemDstarTxLevel; }
    QString get_modemDMRTxLevel() { return m_modemDMRTxLevel; }
    QString get_modemYSFTxLevel() { return m_modemYSFTxLevel; }
    QString get_modemP25TxLevel() { return m_modemP25TxLevel; }
    QString get_modemNXDNTxLevel() { return m_modemNXDNTxLevel; }
    QString get_modemBaud() { return m_modemBaud; }
    QString get_modemM17CAN() { return m_modemM17CAN; }
 
    void setPlaybackDevice(const QString &deviceName);
    void setCaptureDevice(const QString &deviceName);
    QStringList get_playbacks();
    QStringList get_captures();

    

#if defined(Q_OS_ANDROID)
    QString get_platform() { return QSysInfo::productType(); }
    void reset_connect_status();
    QString get_monofont() { return "Droid Sans Mono"; }
#elif defined(Q_OS_WIN)
    QString get_platform() { return QSysInfo::kernelType(); }
    void reset_connect_status() {}
    QString get_monofont() { return "Courier"; }
#else
    QString get_platform() { return QSysInfo::kernelType(); }
    void reset_connect_status() {}
    QString get_monofont() { return "monospace"; }
#endif
    QString get_arch() { return QSysInfo::currentCpuArchitecture(); }
    QString get_build_abi() { return QSysInfo::buildAbi(); }
    QString get_software_build() { return VERSION_NUMBER; }
    


    void download_file(QString, bool u = false);
    void file_downloaded(QString);
    void url_downloaded(QString);
    unsigned short get_output_level(){ return m_outlevel; }
    void set_output_level(unsigned short l){ m_outlevel = l; }
    void tts_changed(QString);
    void tts_text_changed(QString);
    void attempt_reconnect();
       void start_keep_alive();
       void stop_keep_alive();
       void send_keep_alive();
       void on_network_state_changed(QNetworkInformation::Reachability reachability);
    void handle_connection_lost(QString reason);
    void on_connect_timeout();
    void on_transport_medium_changed(QNetworkInformation::TransportMedium medium);
    void ptt_system_begin_tx();
    void ptt_system_end_tx();
    void ptt_audio_activated();
    
private:
    AudioEngine *m_audioEngine;
    QStringList m_playbackDevices;
       QStringList m_captureDevices;
    int connect_status;
    bool m_update_host_files;
    QSettings *m_settings;
    QStringList recentTGIDs;
    QString config_path;
    QString hosts_filename;
    QString m_callsign;
    QString m_host;
    QString m_refname;
    QString m_protocol;
    QString m_bm_password;
    QString m_tgif_password;
    QString m_latitude;
    QString m_longitude;
    QString m_location;
    QString m_description;
    QString m_freq;
    QString m_url;
    QString m_swid;
    QString m_pkgid;
    QString m_dmropts;
    int m_pc;
    QString m_saved_refhost;
    QString m_saved_dcshost;
    QString m_saved_xrfhost;
    QString m_saved_ysfhost;
    QString m_saved_fcshost;
    QString m_saved_dmrhost;
    QString m_saved_p25host;
    QString m_saved_nxdnhost;
    QString m_saved_m17host;
    QString m_saved_iaxhost;
    uint32_t m_dmrid;
    uint8_t m_essid;
    uint32_t m_dmr_srcid;
    uint32_t m_dmr_destid;
    QMap<uint32_t, QString> m_dmrids;
    QMap<uint16_t, QString> m_nxdnids;
    char m_module;
    int m_port;
    QString m_label1;
    QString m_label2;
    QString m_label3;
    QString m_label4;
    QString m_label5;
    QString m_label6;
    QString m_data1;
    QString m_data2;
    QString m_data3;
    QString m_data4;
    QString m_data5;
    QString m_data6;
    QString m_ambestatustxt;
    QString m_mmdvmstatustxt;
    QString m_netstatustxt;
    QString m_mycall;
    QString m_urcall;
    QString m_rptr1;
    QString m_rptr2;
    int m_txtimeout;
    bool m_toggletx;
    QString m_dstarusertxt;
    QStringList m_hostsmodel;
    QMap<QString, QString> m_hostmap;
    QStringList m_customhosts;
    QThread *m_modethread;
    Mode *m_mode;
    QByteArray user_data;
    QString m_localhosts;
    int m_iaxport;
    bool m_settings_processed;
    bool m_modelchange;
    const uint8_t header[5] = {0x80,0x44,0x53,0x56,0x54}; //DVSI packet header
    uint16_t m_outlevel;
    QString m_errortxt;
    // Latest DMR link quality from the mode thread, see get_link_quality().
    int m_lqBars = -1;
    int m_lqRtt = -1;
    int m_lqRttAvg = -1;
    int m_lqPingLoss = -1;
    int m_lqRxLoss = -1;
    int m_lqJitter = -1;
    bool m_xrf2ref;
    bool m_ipv6;
    QString m_vocoder;
    QString m_modem;
    QString m_playback;
    QString m_capture;
    QStringList m_vocoders;
    QStringList m_modems;
    QStringList m_playbacks;
    QStringList m_captures;
    bool m_mdirect;

    int m_tts;
    QString m_ttstxt;

    QString m_modemRxFreq;
    QString m_modemTxFreq;
    QString m_modemRxOffset;
    QString m_modemTxOffset;
    QString m_modemRxDCOffset;
    QString m_modemTxDCOffset;
    QString m_modemRxLevel;
    QString m_modemTxLevel;
    QString m_modemRFLevel;
    QString m_modemTxDelay;
    QString m_modemCWIdTxLevel;
    QString m_modemDstarTxLevel;
    QString m_modemDMRTxLevel;
    QString m_modemYSFTxLevel;
    QString m_modemP25TxLevel;
    QString m_modemNXDNTxLevel;
    QString m_modemBaud;
    QString m_modemM17CAN;
    bool m_modemTxInvert;
    bool m_modemRxInvert;
    bool m_modemPTTInvert;
    QTimer *m_reconnectTimer;
     QTimer *m_keepAliveTimer;
    // Auto-reconnect: armed when the user connects, disarmed when the user disconnects.
    QTimer *m_connectTimeoutTimer;
    bool m_autoReconnect = false;
    int m_reconnectAttempt = 0;
    static const int kMaxReconnectAttempts = 15;   // 5+10+20+40+60*11 s = ~12 min, then give up
    void schedule_reconnect(const QString &reason, int delayMs = -1);
    void connect_failed(const QString &reason);
    bool m_pttFramework = false;
    bool m_headphonePtt = false;
    // Phone GPS as hotspot position. Live updates (RPTG) go to BrandMeister only, at most
    // every kGpsUpdateMinMs and only after moving more than kGpsUpdateMinMeters.
    PhoneGps *m_phoneGps = nullptr;
    bool m_usePhoneGps = false;
    QTimer *m_gpsThrottleTimer = nullptr;
    double m_gpsSentLat = 0.0;
    double m_gpsSentLon = 0.0;
    qint64 m_gpsSentMs = 0;
    bool m_gpsSentFromPhone = false;
    QString m_rptgRejectedHost;
    static const qint64 kGpsUpdateMinMs = 5 * 60 * 1000;
    static constexpr double kGpsUpdateMinMeters = 200.0;
    void apply_phone_gps();
    void dmr_login_position(QString &lat, QString &lon);
    int m_rogerBeep = 2;
    int m_txTone = 1;
    bool m_autoConnect = true;
    bool m_launchAutoConnectUsed = false;   // any connect/disconnect this session disables it
    bool m_keepPttChannel = false;   // teardown for an automatic reconnect keeps the PTT channel
    QString m_pttTalker;
    // iOS Live Activity (lock screen / Dynamic Island card). DroidStar drives it directly so
    // it follows the link even while the UI is suspended.
    void live_activity_sync(bool force = false);
    void live_activity_set_tx(bool tx);
    QTimer *m_laRefreshTimer = nullptr;
    QString m_laMode;           // mode of the running activity; empty = none
    QString m_laKey;            // last pushed content, so per-frame update_data calls are free
    QString m_laTalker;         // current (or last heard) talker
    QString m_laName;
    QString m_laCountry;
    QString m_laNameFor;        // talker the name/country above belong to
    QString m_laTg;
    bool m_laRxActive = false;
    bool m_laTx = false;
    qint64 m_laSinceMs = 0;
    QString ptt_channel_name() const;
    void ptt_sync_channel();
 
#ifdef Q_OS_ANDROID
    AndroidSerialPort *m_USBmonitor;
#endif

private slots:
#ifdef Q_OS_ANDROID
    void keepScreenOn();
#endif
    void on_phone_position();
    void on_rptg_rejected();
    void discover_devices();
    void process_dstar_hosts(QString);
    void process_ysf_hosts();
    void process_fcs_rooms();
    void process_dmr_hosts();
    void process_p25_hosts();
    void process_nxdn_hosts();
    void process_m17_hosts();
    void process_iax_hosts();
    void process_dmr_ids();
    void process_nxdn_ids();
    void update_data(Mode::MODEINFO);
    void updatelog(QString);
    void save_settings();
    void update_output_level(unsigned short l){ m_outlevel = l;}
    void update_link_quality(int bars, int rtt, int rttAvg, int pingLoss, int rxLoss, int jitter);
    //void load_md380_fw();
};

extern "C" void callProcessConnect();
#endif

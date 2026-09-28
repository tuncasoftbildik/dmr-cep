/*
    Copyright (C) 2026 DroidStar-DMR contributors

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

#ifndef LANGUAGEMANAGER_H
#define LANGUAGEMANAGER_H

#include <QCoreApplication>
#include <QObject>
#include <QQmlEngine>
#include <QSettings>
#include <QTranslator>

// UI language switch. Turkish is the default on first launch; the choice is kept in
// QSettings ("UI/LANGUAGE") and applied live via QQmlEngine::retranslate().
// Source strings are English, so "en" simply means "no translator installed".
class LanguageManager : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString language READ language NOTIFY languageChanged)

public:
    explicit LanguageManager(QObject *parent = nullptr) : QObject(parent)
    {
        QSettings s;
        m_language = s.value("UI/LANGUAGE", "tr").toString();
        apply();
    }

    void setEngine(QQmlEngine *engine) { m_engine = engine; }

    QString language() const { return m_language; }

    Q_INVOKABLE void setLanguage(const QString &code)
    {
        if (code == m_language) return;
        m_language = code;
        QSettings s;
        s.setValue("UI/LANGUAGE", code);
        apply();
        if (m_engine) m_engine->retranslate();
        emit languageChanged();
    }

signals:
    void languageChanged();

private:
    void apply()
    {
        QCoreApplication::removeTranslator(&m_translator);
        if (m_language == "tr" && m_translator.load(":/DroidStar/translations/droidstar_tr.qm")) {
            QCoreApplication::installTranslator(&m_translator);
        }
    }

    QString m_language;
    QTranslator m_translator;
    QQmlEngine *m_engine = nullptr;
};

#endif // LANGUAGEMANAGER_H

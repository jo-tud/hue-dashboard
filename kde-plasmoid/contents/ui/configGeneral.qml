import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_bridgeIp: ipField.text
    property string cfg_apiKey
    property string cfg_bridgeIpDefault
    property string cfg_apiKeyDefault

    Kirigami.FormLayout {
        QQC2.TextField {
            id: ipField
            Kirigami.FormData.label: i18n("Bridge IP address:")
            placeholderText: "192.168.1.100"
        }

        QQC2.Label {
            Kirigami.FormData.label: i18n("Pairing:")
            text: cfg_apiKey !== "" ? i18n("Paired") : i18n("Not paired")
        }

        QQC2.Button {
            text: i18n("Forget Pairing")
            icon.name: "edit-clear"
            enabled: cfg_apiKey !== ""
            onClicked: cfg_apiKey = ""
        }

        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
            wrapMode: Text.Wrap
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            text: i18n("After Apply the widget shows the setup assistant again and you have to press the button on the bridge.")
        }
    }
}

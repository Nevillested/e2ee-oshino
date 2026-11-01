pragma Singleton
import QtQuick
import Oshinobu.Core

// Строки и цвета для всех экранов. t() читает App.lang — привязки пересчитываются при смене языка.
QtObject {
    readonly property var c: App.theme
    readonly property int radius: 12

    function t(key, args) {
        App.lang
        return App.t(key, args ? args : [])
    }
    function err(key) {
        App.lang
        return App.errorText(key)
    }
    function avatar(accountId) {
        App.avatarRevision
        return accountId ? App.avatarFor(accountId) : ""
    }
    function initials(name) {
        return name && name.length ? name.charAt(0).toUpperCase() : "?"
    }
}

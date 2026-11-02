# Приложение: Qt Quick поверх ядра.
find_package(Qt6 6.2 REQUIRED COMPONENTS Gui Widgets Quick QuickControls2 Multimedia DBus)

qt_add_executable(oshinobu
    src/main.cpp
    src/AppModel.cpp
    src/Models.cpp
    src/Desktop.cpp
    src/VideoView.cpp
    src/VideoView.h
)

set(OSHINOBU_QML Ui Main AuthFlow HomeView ChatPane MessageBubble StickerPanel StickerView TgsView SettingsDialog SettingsItem ChoiceSheet WallpaperPreview ThemedCheck SheetButtons Ticks StickerGrid StickerPreview TransfersSheet Pill PlayGlyph PeerProfile FadeText AppMenu AppMenuItem AppMenuSeparator LockScreen CallOverlay Avatar Field FlatButton IconButton Toast Sheet)
# файлы — в корень модуля (рядом с qmldir): иначе синглтон Ui не виден соседним файлам
foreach(name ${OSHINOBU_QML})
    set_source_files_properties(qml/${name}.qml PROPERTIES QT_RESOURCE_ALIAS ${name}.qml)
endforeach()
set_source_files_properties(qml/Ui.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(oshinobu
    URI Oshinobu
    VERSION 1.0
    RESOURCE_PREFIX /qt/qml
    QML_FILES
        qml/Ui.qml
        qml/Main.qml
        qml/AuthFlow.qml
        qml/HomeView.qml
        qml/ChatPane.qml
        qml/MessageBubble.qml
        qml/StickerPanel.qml
        qml/StickerView.qml
        qml/TgsView.qml
        qml/SettingsDialog.qml
        qml/SettingsItem.qml
        qml/ChoiceSheet.qml
        qml/WallpaperPreview.qml
        qml/ThemedCheck.qml
        qml/SheetButtons.qml
        qml/Ticks.qml
        qml/StickerGrid.qml
        qml/StickerPreview.qml
        qml/TransfersSheet.qml
        qml/Pill.qml
        qml/PlayGlyph.qml
        qml/PeerProfile.qml
        qml/FadeText.qml
        qml/AppMenu.qml
        qml/AppMenuItem.qml
        qml/AppMenuSeparator.qml
        qml/LockScreen.qml
        qml/CallOverlay.qml
        qml/Avatar.qml
        qml/Field.qml
        qml/FlatButton.qml
        qml/IconButton.qml
        qml/Toast.qml
        qml/Sheet.qml
    RESOURCES
        i18n/en.json
        i18n/ru.json
        i18n/linux_en.json
        i18n/linux_ru.json
        icons/oshinobu.png
        emoji.json
        sounds/msg_sound.wav
        sounds/ringtone.mp3
        sounds/ringback.mp3
)

# анимированные стикеры TGS — rlottie (если установлен)
pkg_check_modules(RLOTTIE QUIET IMPORTED_TARGET rlottie)
if(RLOTTIE_FOUND)
    target_sources(oshinobu PRIVATE src/TgsItem.cpp src/TgsItem.h)
    target_link_libraries(oshinobu PRIVATE PkgConfig::RLOTTIE ZLIB::ZLIB)
    target_compile_definitions(oshinobu PRIVATE OSHINOBU_HAVE_RLOTTIE)
endif()

target_compile_definitions(oshinobu PRIVATE OSHINOBU_VERSION="${PROJECT_VERSION}")
target_compile_options(oshinobu PRIVATE -Wall -Wextra)
target_link_libraries(oshinobu PRIVATE oshinobu_core Qt6::Gui Qt6::Widgets Qt6::Quick Qt6::QuickControls2 Qt6::Multimedia Qt6::DBus)

install(TARGETS oshinobu RUNTIME DESTINATION bin)
install(FILES icons/oshinobu.png DESTINATION share/icons/hicolor/192x192/apps RENAME space.oshino.Oshinobu.png)
configure_file(space.oshino.Oshinobu.desktop.in ${CMAKE_CURRENT_BINARY_DIR}/space.oshino.Oshinobu.desktop @ONLY)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/space.oshino.Oshinobu.desktop DESTINATION share/applications)

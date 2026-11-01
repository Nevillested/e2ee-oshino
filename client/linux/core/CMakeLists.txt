# Ядро без UI: криптография, протокол (дальше — сеть, хранилища, сервисы).
add_library(oshinobu_core STATIC
    src/crypto/Primitives.cpp
    src/crypto/MessageCipher.cpp
    src/crypto/X3dh.cpp
    src/crypto/RatchetState.cpp
    src/crypto/FileCiphers.cpp
    src/crypto/StoredIdentity.cpp
    src/protocol/InnerMessage.cpp
    src/protocol/PeerCipher.cpp
    src/support/Log.cpp
    src/net/ApiClient.cpp
    src/net/WebSocketClient.cpp
    src/storage/Stores.cpp
    src/storage/StoredMessage.cpp
    src/storage/ChatStore.cpp
    src/service/Infra.cpp
    src/service/Messaging.cpp
    src/service/MessageRouter.cpp
    src/service/Media.cpp
    src/service/Extras.cpp
    src/service/Calls.cpp
    src/support/Zip.cpp
    src/Core.cpp
)
# медиа звонков — GStreamer webrtcbin (если установлены dev-пакеты), иначе звонки недоступны
pkg_check_modules(GST QUIET IMPORTED_TARGET gstreamer-1.0 gstreamer-sdp-1.0 gstreamer-webrtc-1.0)
if(GST_FOUND)
    target_sources(oshinobu_core PRIVATE src/media/GstRtcEngine.cpp src/media/GstRecorder.cpp src/media/GstRecorder.h)
    target_link_libraries(oshinobu_core PUBLIC PkgConfig::GST)
    target_compile_definitions(oshinobu_core PUBLIC OSHINOBU_HAVE_GSTREAMER)
    message(STATUS "Звонки: GStreamer webrtcbin")
    # не в ctest: нужны настоящие микрофон и вывод звука
    add_executable(gst_loopback_test tests/GstLoopbackTest.cpp)
    target_link_libraries(gst_loopback_test PRIVATE oshinobu_core Qt6::Test)
    add_executable(gst_recorder_test tests/GstRecorderTest.cpp)
    target_link_libraries(gst_recorder_test PRIVATE oshinobu_core Qt6::Test)
else()
    message(STATUS "Звонки: GStreamer не найден — сборка без медиа звонков")
endif()

target_include_directories(oshinobu_core PUBLIC src)
target_link_libraries(oshinobu_core PUBLIC Qt6::Core Qt6::Network Qt6::WebSockets Qt6::Sql OpenSSL::Crypto PkgConfig::LIBSECRET ZLIB::ZLIB)
target_compile_options(oshinobu_core PRIVATE -Wall -Wextra -Wpedantic)
target_compile_definitions(oshinobu_core PUBLIC QT_NO_KEYWORDS)

add_executable(protocol_vectors_test tests/ProtocolVectorsTest.cpp)
target_link_libraries(protocol_vectors_test PRIVATE oshinobu_core Qt6::Test)
target_compile_definitions(protocol_vectors_test PRIVATE VECTORS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/vectors")
add_test(NAME protocol_vectors COMMAND protocol_vectors_test)

add_executable(storage_test tests/StorageTest.cpp)
target_link_libraries(storage_test PRIVATE oshinobu_core Qt6::Test)
add_test(NAME storage COMMAND storage_test)

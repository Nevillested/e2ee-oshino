# Linux-клиент Oshinobu: ядро (core/) и тесты. Сборка:
#   cmake -S client/linux -B client/linux/build -G Ninja && cmake --build client/linux/build
#   ctest --test-dir client/linux/build --output-on-failure
cmake_minimum_required(VERSION 3.22)
project(Oshinobu VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_AUTOMOC ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

find_package(Qt6 6.2 REQUIRED COMPONENTS Core Network WebSockets Sql Test)
find_package(OpenSSL 3.0 REQUIRED)
find_package(ZLIB REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBSECRET REQUIRED IMPORTED_TARGET libsecret-1)

enable_testing()
add_subdirectory(core)
add_subdirectory(app)

add_executable(oshinobu-cli tools/cli.cpp)
target_link_libraries(oshinobu-cli PRIVATE oshinobu_core)

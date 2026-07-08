cmake_minimum_required(VERSION 3.20)
project(PipMpv LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Quick Qml)
find_package(MpvQt REQUIRED)

qt_standard_project_setup(REQUIRES 6.5)

# Emit the QML module into <scripts>/quickshell/pip/qml/PipMpv so Quickshell can find
# it via QML_IMPORT_PATH=<scripts>/quickshell/pip/qml.
set(QT_QML_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../qml")

qt_add_qml_module(pipmpv
    URI PipMpv
    VERSION 1.0
    SOURCES MpvItem.h MpvItem.cpp
)

target_link_libraries(pipmpv PRIVATE Qt6::Quick MpvQt::MpvQt)

# Put the backing library alongside the plugin in the module dir, and use an
# $ORIGIN rpath so the plugin finds it at runtime (no system install needed).
set_target_properties(pipmpv PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${QT_QML_OUTPUT_DIRECTORY}/PipMpv"
    INSTALL_RPATH "$ORIGIN"
    BUILD_WITH_INSTALL_RPATH ON)
set_target_properties(pipmpvplugin PROPERTIES
    INSTALL_RPATH "$ORIGIN"
    BUILD_WITH_INSTALL_RPATH ON)

cmake_minimum_required(VERSION 3.16)
project(obsidian-shell LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Quick WebEngineQuick)
find_package(LayerShellQt REQUIRED)

add_executable(obsidian-shell main.cpp)
target_compile_definitions(obsidian-shell PRIVATE
    SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(obsidian-shell PRIVATE
    Qt6::Core Qt6::Gui Qt6::Quick Qt6::WebEngineQuick
    LayerShellQt::Interface)

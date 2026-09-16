cmake_minimum_required(VERSION 3.14)
project(NimRlnConsumerPlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found. LOGOS_MODULE_BUILDER_ROOT is not set.")
endif()

configure_file(${CMAKE_CURRENT_SOURCE_DIR}/metadata.json
               ${CMAKE_CURRENT_BINARY_DIR}/metadata.json COPYONLY)

logos_module(
    NAME nim_rln_consumer
    SOURCES
        src/rln_consumer_plugin.h
        src/rln_consumer_plugin.cpp
        src/rln_module_client.cpp
        src/rln_seam_bridge.cpp
    EXTERNAL_LIBS rlnconsumer
)

# logos::LpClient (the Qt-free consumer client the seam bridge uses to call
# liblogos_rln_module) needs logos-protocol's lp_* at link time. Same private
# statically-linked copy per plugin as the RLN module plugins themselves use.
target_link_libraries(nim_rln_consumer_module_plugin PRIVATE
    logos-protocol::logos_protocol
)

# Copyright (c) 2016 PaddlePaddle Authors. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

if (NOT EMSCRIPTEN)
INCLUDE(ExternalProject)
# Always invoke `FIND_PACKAGE(Protobuf)` for importing function protobuf_generate_cpp
IF(NOT WIN32)
FIND_PACKAGE(Protobuf QUIET)
ENDIF(NOT WIN32)
macro(UNSET_VAR VAR_NAME)
    UNSET(${VAR_NAME} CACHE)
    UNSET(${VAR_NAME})
endmacro()

UNSET_VAR(PROTOBUF_INCLUDE_DIR)
UNSET_VAR(PROTOBUF_FOUND)
UNSET_VAR(PROTOBUF_PROTOC_EXECUTABLE)
UNSET_VAR(PROTOBUF_PROTOC_LIBRARY)
UNSET_VAR(PROTOBUF_LITE_LIBRARY)
UNSET_VAR(PROTOBUF_LIBRARY)
UNSET_VAR(PROTOBUF_INCLUDE_DIR)
UNSET_VAR(Protobuf_PROTOC_EXECUTABLE)
function(protobuf_generate_python SRCS)
    # shameless copy from https://github.com/Kitware/CMake/blob/master/Modules/FindProtobuf.cmake
    if(NOT ARGN)
        message(SEND_ERROR "Error: PROTOBUF_GENERATE_PYTHON() called without any proto files")
        return()
    endif()

    if(PROTOBUF_GENERATE_CPP_APPEND_PATH)
        # Create an include path for each file specified
        foreach(FIL ${ARGN})
            get_filename_component(ABS_FIL ${FIL} ABSOLUTE)
            get_filename_component(ABS_PATH ${ABS_FIL} PATH)
            list(FIND _protobuf_include_path ${ABS_PATH} _contains_already)
            if(${_contains_already} EQUAL -1)
                list(APPEND _protobuf_include_path -I ${ABS_PATH})
            endif()
        endforeach()
    else()
        set(_protobuf_include_path -I ${CMAKE_CURRENT_SOURCE_DIR})
    endif()
    if(DEFINED PROTOBUF_IMPORT_DIRS AND NOT DEFINED Protobuf_IMPORT_DIRS)
        set(Protobuf_IMPORT_DIRS "${PROTOBUF_IMPORT_DIRS}")
    endif()

    if(DEFINED Protobuf_IMPORT_DIRS)
        foreach(DIR ${Protobuf_IMPORT_DIRS})
            get_filename_component(ABS_PATH ${DIR} ABSOLUTE)
            list(FIND _protobuf_include_path ${ABS_PATH} _contains_already)
            if(${_contains_already} EQUAL -1)
                list(APPEND _protobuf_include_path -I ${ABS_PATH})
            endif()
        endforeach()
    endif()

    set(${SRCS})
    foreach(FIL ${ARGN})
        get_filename_component(ABS_FIL ${FIL} ABSOLUTE)
        get_filename_component(FIL_WE ${FIL} NAME_WE)
        if(NOT PROTOBUF_GENERATE_CPP_APPEND_PATH)
            get_filename_component(FIL_DIR ${FIL} DIRECTORY)
            if(FIL_DIR)
                set(FIL_WE "${FIL_DIR}/${FIL_WE}")
            endif()
        endif()
        list(APPEND ${SRCS} "${CMAKE_CURRENT_BINARY_DIR}/${FIL_WE}_pb2.py")
        add_custom_command(
                OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/${FIL_WE}_pb2.py"
                COMMAND  ${PROTOBUF_PROTOC_EXECUTABLE} --python_out ${CMAKE_CURRENT_BINARY_DIR} ${_protobuf_include_path} ${ABS_FIL}
                DEPENDS ${ABS_FIL} ${PROTOBUF_PROTOC_EXECUTABLE}
                COMMENT "Running Python protocol buffer compiler on ${FIL}"
                VERBATIM )
    endforeach()

    set(${SRCS} ${${SRCS}} PARENT_SCOPE)
endfunction()

# Print and set the protobuf library information,
# finish this cmake process and exit from this file.
macro(PROMPT_PROTOBUF_LIB)
    SET(protobuf_DEPS ${ARGN})

    MESSAGE(STATUS "Protobuf protoc executable: ${PROTOBUF_PROTOC_EXECUTABLE}")
    MESSAGE(STATUS "Protobuf-lite library: ${PROTOBUF_LITE_LIBRARY}")
    MESSAGE(STATUS "Protobuf library: ${PROTOBUF_LIBRARY}")
    MESSAGE(STATUS "Protoc library: ${PROTOBUF_PROTOC_LIBRARY}")
    MESSAGE(STATUS "Protobuf version: ${PROTOBUF_VERSION}")
    INCLUDE_DIRECTORIES(${PROTOBUF_INCLUDE_DIR})

    # Assuming that all the protobuf libraries are of the same type.
    IF(${PROTOBUF_LIBRARY} MATCHES ${CMAKE_STATIC_LIBRARY_SUFFIX})
        SET(protobuf_LIBTYPE STATIC)
    ELSEIF(${PROTOBUF_LIBRARY} MATCHES "${CMAKE_SHARED_LIBRARY_SUFFIX}$")
        SET(protobuf_LIBTYPE SHARED)
    ELSE()
        MESSAGE(FATAL_ERROR "Unknown library type: ${PROTOBUF_LIBRARY}")
    ENDIF()

    ADD_LIBRARY(protobuf ${protobuf_LIBTYPE} IMPORTED GLOBAL)
    SET_PROPERTY(TARGET protobuf PROPERTY IMPORTED_LOCATION ${PROTOBUF_LIBRARY})
ADD_LIBRARY(protobuf_lite ${protobuf_LIBTYPE} IMPORTED GLOBAL)
    SET_PROPERTY(TARGET protobuf_lite PROPERTY IMPORTED_LOCATION ${PROTOBUF_LITE_LIBRARY})

    ADD_LIBRARY(libprotoc ${protobuf_LIBTYPE} IMPORTED GLOBAL)
    SET_PROPERTY(TARGET libprotoc PROPERTY IMPORTED_LOCATION ${PROTOC_LIBRARY})

    ADD_EXECUTABLE(protoc IMPORTED GLOBAL)
    SET_PROPERTY(TARGET protoc PROPERTY IMPORTED_LOCATION ${PROTOBUF_PROTOC_EXECUTABLE})
    # FIND_Protobuf.cmake uses `Protobuf_PROTOC_EXECUTABLE`.
    # make `protobuf_generate_cpp` happy.
    SET(Protobuf_PROTOC_EXECUTABLE ${PROTOBUF_PROTOC_EXECUTABLE})

    FOREACH(dep ${protobuf_DEPS})
        ADD_DEPENDENCIES(protobuf ${dep})
        ADD_DEPENDENCIES(protobuf_lite ${dep})
        ADD_DEPENDENCIES(libprotoc ${dep})
        ADD_DEPENDENCIES(protoc ${dep})
    ENDFOREACH()

    RETURN()
endmacro()
macro(SET_PROTOBUF_VERSION)
    EXEC_PROGRAM(${PROTOBUF_PROTOC_EXECUTABLE} ARGS --version OUTPUT_VARIABLE PROTOBUF_VERSION)
    STRING(REGEX MATCH "[0-9]+.[0-9]+" PROTOBUF_VERSION "${PROTOBUF_VERSION}")
endmacro()

set(PROTOBUF_ROOT "" CACHE PATH "Folder contains protobuf")
IF (WIN32)
    SET(PROTOBUF_ROOT ${THIRD_PARTY_PATH}/install/protobuf)
ENDIF(WIN32)

if (NOT "${PROTOBUF_ROOT}" STREQUAL "")
    find_path(PROTOBUF_INCLUDE_DIR google/protobuf/message.h PATHS ${PROTOBUF_ROOT}/include NO_DEFAULT_PATH)
    find_library(PROTOBUF_LIBRARY protobuf libprotobuf.lib PATHS ${PROTOBUF_ROOT}/lib NO_DEFAULT_PATH)
    find_library(PROTOBUF_LITE_LIBRARY protobuf-lite libprotobuf-lite.lib PATHS ${PROTOBUF_ROOT}/lib NO_DEFAULT_PATH)
    find_library(PROTOBUF_PROTOC_LIBRARY protoc libprotoc.lib PATHS ${PROTOBUF_ROOT}/lib NO_DEFAULT_PATH)
    find_program(PROTOBUF_PROTOC_EXECUTABLE protoc PATHS ${PROTOBUF_ROOT}/bin NO_DEFAULT_PATH)
    if (PROTOBUF_INCLUDE_DIR AND PROTOBUF_LIBRARY AND PROTOBUF_LITE_LIBRARY AND PROTOBUF_PROTOC_LIBRARY AND PROTOBUF_PROTOC_EXECUTABLE)
        message(STATUS "Using custom protobuf library in ${PROTOBUF_ROOT}.")
        SET(PROTOBUF_FOUND true)
        SET_PROTOBUF_VERSION()
        PROMPT_PROTOBUF_LIB()
    else()
        message(WARNING "Cannot find protobuf library in ${PROTOBUF_ROOT}")
    endif()
endif()

FUNCTION(build_protobuf TARGET_NAME BUILD_FOR_HOST)
    STRING(REPLACE "extern_" "" TARGET_DIR_NAME "${TARGET_NAME}")
    SET(PROTOBUF_SOURCES_DIR ${THIRD_PARTY_PATH}/${TARGET_DIR_NAME})
    SET(PROTOBUF_INSTALL_DIR ${THIRD_PARTY_PATH}/install/${TARGET_DIR_NAME})

    SET(${TARGET_NAME}_INCLUDE_DIR "${PROTOBUF_INSTALL_DIR}/include" PARENT_SCOPE)
    SET(PROTOBUF_INCLUDE_DIR "${PROTOBUF_INSTALL_DIR}/include" PARENT_SCOPE)
    SET(${TARGET_NAME}_LITE_LIBRARY
        "${PROTOBUF_INSTALL_DIR}/lib/libprotobuf-lite${CMAKE_STATIC_LIBRARY_SUFFIX}"
         PARENT_SCOPE)
    SET(${TARGET_NAME}_LIBRARY
        "${PROTOBUF_INSTALL_DIR}/lib/libprotobuf${CMAKE_STATIC_LIBRARY_SUFFIX}"
         PARENT_SCOPE)
    SET(${TARGET_NAME}_PROTOC_LIBRARY
        "${PROTOBUF_INSTALL_DIR}/lib/libprotoc${CMAKE_STATIC_LIBRARY_SUFFIX}"
         PARENT_SCOPE)
    SET(${TARGET_NAME}_PROTOC_EXECUTABLE
        "${PROTOBUF_INSTALL_DIR}/bin/protoc${CMAKE_EXECUTABLE_SUFFIX}"
         PARENT_SCOPE)

    # https://github.com/protocolbuffers/protobuf.git
    SET(PROTOBUF_REPO "")
    SET(PROTOBUF_TAG "9f75c5aa851cd877fb0d93ccc31b8567a6706546")
    SET(OPTIONAL_CACHE_ARGS "")
    SET(OPTIONAL_ARGS "")
    SET(SOURCE_DIR "${PADDLE_SOURCE_DIR}/third-party/protobuf-host")

    IF(BUILD_FOR_HOST)
        # set for server compile.
        if(NOT LITE_WITH_ARM)
          set(HOST_C_COMPILER "${CMAKE_C_COMPILER}")
          set(HOST_CXX_COMPILER "${CMAKE_CXX_COMPILER}")
        endif()

        SET(OPTIONAL_ARGS
            "-DCMAKE_C_COMPILER=${HOST_C_COMPILER}"
            "-DCMAKE_CXX_COMPILER=${HOST_CXX_COMPILER}"
            "-Dprotobuf_WITH_ZLIB=OFF"
            "-DZLIB_ROOT:FILEPATH=${ZLIB_ROOT}")
        SET(OPTIONAL_CACHE_ARGS "-DZLIB_ROOT:STRING=${ZLIB_ROOT}")
    ELSE()
        # protobuf have compile issue when use android stl c++_static
        # https://github.com/tensor-tang/protobuf.git
        SET(PROTOBUF_REPO "")
        SET(PROTOBUF_TAG "mobile")
        SET(SOURCE_DIR "${PADDLE_SOURCE_DIR}/third-party/protobuf-mobile")
        SET(OPTIONAL_ARGS "-Dprotobuf_WITH_ZLIB=OFF"
                ${CROSS_COMPILE_CMAKE_ARGS}
                "-DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER}"
                "-DCMAKE_C_COMPILER=${CMAKE_C_COMPILER}"
                "-DCMAKE_C_FLAGS=${CMAKE_C_FLAGS}"
                "-DCMAKE_C_FLAGS_DEBUG=${CMAKE_C_FLAGS_DEBUG}"
                "-DCMAKE_C_FLAGS_RELEASE=${CMAKE_C_FLAGS_RELEASE}"
                "-DCMAKE_CXX_FLAGS=${CMAKE_CXX_FLAGS}"
                "-DCMAKE_CXX_FLAGS_RELEASE=${CMAKE_CXX_FLAGS_RELEASE}"
                "-DCMAKE_CXX_FLAGS_DEBUG=${CMAKE_CXX_FLAGS_DEBUG}")
    ENDIF()
    IF(WIN32)
        SET(OPTIONAL_ARGS ${OPTIONAL_ARGS} 
            "-DCMAKE_GENERATOR=${CMAKE_GENERATOR}"
            "-DCMAKE_GENERATOR_PLATFORM=${CMAKE_GENERATOR_PLATFORM}"
            "-Dprotobuf_MSVC_STATIC_RUNTIME=${MSVC_STATIC_CRT}")
    ENDIF()

    if(LITE_WITH_ARM)
        ExternalProject_Add(
            ${TARGET_NAME}
            ${EXTERNAL_PROJECT_LOG_ARGS}
            PREFIX          ${PROTOBUF_SOURCES_DIR}
            SOURCE_SUBDIR   cmake
            UPDATE_COMMAND  ""
            GIT_REPOSITORY  ""
            GIT_TAG         ${PROTOBUF_TAG}
            SOURCE_DIR      ${SOURCE_DIR}
            CMAKE_ARGS
                ${OPTIONAL_ARGS}
                -Dprotobuf_BUILD_TESTS=OFF
                -DCMAKE_SKIP_RPATH=ON
                -DCMAKE_POSITION_INDEPENDENT_CODE=ON
                -DCMAKE_BUILD_TYPE=${THIRD_PARTY_BUILD_TYPE}
                -DCMAKE_INSTALL_PREFIX=${PROTOBUF_INSTALL_DIR}
                -DCMAKE_INSTALL_LIBDIR=lib
                -DBUILD_SHARED_LIBS=OFF
            CMAKE_CACHE_ARGS
                -DCMAKE_INSTALL_PREFIX:PATH=${PROTOBUF_INSTALL_DIR}
                -DCMAKE_BUILD_TYPE:STRING=${THIRD_PARTY_BUILD_TYPE}
                -DCMAKE_VERBOSE_MAKEFILE:BOOL=OFF
                -DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON
                ${OPTIONAL_CACHE_ARGS}
        )
    else()
        ExternalProject_Add(
            ${TARGET_NAME}
            ${EXTERNAL_PROJECT_LOG_ARGS}
            PREFIX          ${SOURCE_DIR}
            UPDATE_COMMAND  ""
            GIT_REPOSITORY  ""
            GIT_TAG         ${PROTOBUF_TAG}
            SOURCE_DIR      ${SOURCE_DIR}
            BUILD_ALWAYS 1
            CONFIGURE_COMMAND ${CMAKE_COMMAND} ${SOURCE_DIR}/cmake
                ${OPTIONAL_ARGS}
                -Dprotobuf_BUILD_TESTS=OFF
                -DCMAKE_SKIP_RPATH=ON
                -DCMAKE_POSITION_INDEPENDENT_CODE=ON
                -DCMAKE_BUILD_TYPE=${THIRD_PARTY_BUILD_TYPE}
                -DCMAKE_INSTALL_PREFIX=${PROTOBUF_INSTALL_DIR}
                -DCMAKE_INSTALL_LIBDIR=lib
                -DBUILD_SHARED_LIBS=OFF
            CMAKE_CACHE_ARGS
                -DCMAKE_INSTALL_PREFIX:PATH=${PROTOBUF_INSTALL_DIR}
                -DCMAKE_BUILD_TYPE:STRING=${THIRD_PARTY_BUILD_TYPE}
                -DCMAKE_VERBOSE_MAKEFILE:BOOL=OFF
                -DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON
                ${OPTIONAL_CACHE_ARGS}
        )
    endif()
ENDFUNCTION()

SET(PROTOBUF_VERSION 3.3.0)

IF(LITE_WITH_ARM)
    build_protobuf(protobuf_host TRUE)
    LIST(APPEND external_project_dependencies protobuf_host)
    SET(PROTOBUF_PROTOC_EXECUTABLE ${protobuf_host_PROTOC_EXECUTABLE}
        CACHE FILEPATH "protobuf executable." FORCE)
ENDIF()

IF(NOT PROTOBUF_FOUND)
    if (LITE_WITH_ARM)
      build_protobuf(extern_protobuf FALSE)
    else()
      build_protobuf(extern_protobuf TRUE)
    endif()

    SET(PROTOBUF_INCLUDE_DIR ${extern_protobuf_INCLUDE_DIR}
        CACHE PATH "protobuf include directory." FORCE)
    SET(PROTOBUF_LITE_LIBRARY ${extern_protobuf_LITE_LIBRARY}
        CACHE FILEPATH "protobuf lite library." FORCE)
    SET(PROTOBUF_LIBRARY ${extern_protobuf_LIBRARY}
        CACHE FILEPATH "protobuf library." FORCE)
    SET(PROTOBUF_PROTOC_LIBRARY ${extern_protobuf_PROTOC_LIBRARY}
        CACHE FILEPATH "protoc library." FORCE)

    IF(LITE_WITH_ARM)
        PROMPT_PROTOBUF_LIB(protobuf_host extern_protobuf)
    ELSE()
        SET(PROTOBUF_PROTOC_EXECUTABLE ${extern_protobuf_PROTOC_EXECUTABLE}
            CACHE FILEPATH "protobuf executable." FORCE)
        PROMPT_PROTOBUF_LIB(extern_protobuf)
    ENDIF()

ENDIF(NOT PROTOBUF_FOUND)

else()
option(protobuf_BUILD_TESTS "" OFF)
option(protobuf_WITH_ZLIB "" OFF)
option(protobuf_BUILD_LIBPROTOC "" OFF)
option(protobuf_BUILD_PROTOC_BINARIES "" OFF)
add_subdirectory(${PROJECT_SOURCE_DIR}/third-party/protobuf-host/cmake)
add_library(protobuf ALIAS libprotobuf)
endif(NOT EMSCRIPTEN)

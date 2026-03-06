cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

apply_standard_settings(${BINARY_NAME})

target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

add_dependencies(${BINARY_NAME} flutter_assemble)

# --- БЛОК «МНЕ ПЛЕВАТЬ НА ОШИБКИ INSTALL» ---

# Пути к исходникам
set(FLUTTER_EPHEMERAL "${CMAKE_CURRENT_SOURCE_DIR}/../flutter/ephemeral")

# Прямое копирование ЖИЗНЕННО ВАЖНЫХ файлов через CMD (чтобы не падал MSBuild)
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
    COMMAND cmd /c "copy /Y \"${FLUTTER_EPHEMERAL}\\icudtl.dat\" \"$<TARGET_FILE_DIR:${BINARY_NAME}>\\icudtl.dat\""
    COMMAND cmd /c "copy /Y \"${FLUTTER_EPHEMERAL}\\flutter_windows.dll\" \"$<TARGET_FILE_DIR:${BINARY_NAME}>\\flutter_windows.dll\""
    COMMENT "Forcing critical files copy..."
)

# Копируем твои DLL
set(NEBULA_DLLS 
    "C:/td/tdlib_install/bin/tdjson.dll"
    "C:/td/tdlib_install/bin/libcrypto-3-x64.dll"
    "C:/td/tdlib_install/bin/libssl-3-x64.dll"
    "C:/vcpkg/installed/x64-windows/bin/sqlcipher.dll"
    "C:/td/tdlib_install/bin/zlib1.dll"
)

foreach(dll ${NEBULA_DLLS})
    add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
        COMMAND cmd /c "copy /Y \"${dll}\" \"$<TARGET_FILE_DIR:${BINARY_NAME}>\\\""
    )
endforeach()

# Создаем data и льем ассеты + app.so
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:${BINARY_NAME}>/data/flutter_assets"
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_BINARY_DIR}/../../flutter_assets" "$<TARGET_FILE_DIR:${BINARY_NAME}>/data/flutter_assets"
    COMMAND cmd /c "if exist \"${CMAKE_BINARY_DIR}\\..\\app.so\" copy /Y \"${CMAKE_BINARY_DIR}\\..\\app.so\" \"$<TARGET_FILE_DIR:${BINARY_NAME}>\\data\\app.so\""
    COMMENT "Finalizing data folder..."
)
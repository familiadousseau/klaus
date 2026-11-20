# Biblioteca nativa do Klaus: prepara o áudio para o modelo da palavra "Klaus".
# É o mesmo código usado no treino (TFLite Micro audio frontend + kissfft de 16 bits).
cmake_minimum_required(VERSION 3.18)
project(klaus_wake CXX)

set(CMAKE_CXX_STANDARD 14)
set(MF ${CMAKE_CURRENT_SOURCE_DIR}/microfrontend)
set(MFL ${MF}/tensorflow/lite/experimental/microfrontend/lib)

add_library(klaus_wake SHARED
  klaus_wake.cc
  ${MFL}/kiss_fft_int16.cc
  ${MFL}/fft.cc
  ${MFL}/fft_util.cc
  ${MFL}/filterbank.cc
  ${MFL}/filterbank_util.cc
  ${MFL}/frontend.cc
  ${MFL}/frontend_util.cc
  ${MFL}/log_lut.cc
  ${MFL}/log_scale.cc
  ${MFL}/log_scale_util.cc
  ${MFL}/noise_reduction.cc
  ${MFL}/noise_reduction_util.cc
  ${MFL}/pcan_gain_control.cc
  ${MFL}/pcan_gain_control_util.cc
  ${MFL}/window.cc
  ${MFL}/window_util.cc
)

target_include_directories(klaus_wake PRIVATE ${MF} ${MF}/kissfft)
target_compile_definitions(klaus_wake PRIVATE FIXED_POINT=16)
target_compile_options(klaus_wake PRIVATE -O2 -fvisibility=hidden -w)
# Páginas de 16 KB (Android 15+).
target_link_options(klaus_wake PRIVATE "-Wl,-z,max-page-size=16384")

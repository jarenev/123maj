@echo off
rem Build Majestic APK on Windows: Rust core (arm64) + Java shell + assets.
rem Usage (cmd):  set MAJESTIC_API_KEY=your_key  then  build.bat
rem Needs: Rust (rustup) with target aarch64-linux-android, Android NDK,
rem        Android SDK build-tools + platforms\android-30, JDK 17 (keytool, javac).
rem Optional env: ANDROID_HOME, ANDROID_NDK_HOME, BUILD_TOOLS, PLATFORM_JAR, NATIVE_LIB

setlocal
cd /d "%~dp0"

if "%MAJESTIC_API_KEY%"=="" (
  echo ERROR: set MAJESTIC_API_KEY first, e.g.  set MAJESTIC_API_KEY=your_key
  exit /b 1
)

set MIN_SDK=23
set TARGET_SDK=30
set ABI=arm64-v8a
set TRIPLE=aarch64-linux-android
set KS_PASS=android
set KS_ALIAS=majestic

if "%ANDROID_HOME%"=="" set ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk

if "%ANDROID_NDK_HOME%"=="" (
  for /f "delims=" %%d in ('dir /b /ad /o-n "%ANDROID_HOME%\ndk" 2^>nul') do if "%ANDROID_NDK_HOME%"=="" set ANDROID_NDK_HOME=%ANDROID_HOME%\ndk\%%d
)
if "%BUILD_TOOLS%"=="" (
  for /f "delims=" %%d in ('dir /b /ad /o-n "%ANDROID_HOME%\build-tools" 2^>nul') do if "%BUILD_TOOLS%"=="" set BUILD_TOOLS=%ANDROID_HOME%\build-tools\%%d
)
if "%PLATFORM_JAR%"=="" set PLATFORM_JAR=%ANDROID_HOME%\platforms\android-%TARGET_SDK%\android.jar

if not exist "%BUILD_TOOLS%\aapt.exe" (
  echo ERROR: build-tools not found at "%BUILD_TOOLS%". Set BUILD_TOOLS.
  exit /b 1
)
if not exist "%PLATFORM_JAR%" (
  echo ERROR: android.jar not found at "%PLATFORM_JAR%". Set PLATFORM_JAR.
  exit /b 1
)

if exist build rmdir /s /q build
mkdir build\classes build\dex build\apk\lib\%ABI% dist 2>nul

rem ---- 1. Rust core ----
if not "%NATIVE_LIB%"=="" (
  echo [1/6] using prebuilt %NATIVE_LIB%
  copy /y "%NATIVE_LIB%" build\apk\lib\%ABI%\libmajestic.so >nul || exit /b 1
) else (
  if not exist "%ANDROID_NDK_HOME%\toolchains\llvm\prebuilt\windows-x86_64\bin" (
    echo ERROR: Android NDK not found. Set ANDROID_NDK_HOME.
    exit /b 1
  )
  echo [1/6] building Rust core
  rustup target add %TRIPLE% || exit /b 1
  set TC=%ANDROID_NDK_HOME%\toolchains\llvm\prebuilt\windows-x86_64\bin
  set CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=%TC%\aarch64-linux-android%MIN_SDK%-clang.cmd
  set CC_aarch64_linux_android=%TC%\aarch64-linux-android%MIN_SDK%-clang.cmd
  set AR_aarch64_linux_android=%TC%\llvm-ar.exe
  copy /b src\api.rs +,, >nul
  cargo build --release --lib --target %TRIPLE% || exit /b 1
  copy /y target\%TRIPLE%\release\libmajestic.so build\apk\lib\%ABI%\libmajestic.so >nul || exit /b 1
)

rem ---- 2. Java shell ----
echo [2/6] compiling Java
dir /s /b android\src\*.java > build\sources.txt
javac -encoding UTF-8 -source 8 -target 8 -bootclasspath "%PLATFORM_JAR%" -Xlint:-options -d build\classes @build\sources.txt || exit /b 1

rem ---- 3. dex ----
echo [3/6] dex
dir /s /b build\classes\*.class > build\classes.txt
call "%BUILD_TOOLS%\d8.bat" --release --min-api %MIN_SDK% --lib "%PLATFORM_JAR%" --output build\dex @build\classes.txt || exit /b 1

rem ---- 4. package ----
echo [4/6] packaging APK
call "%BUILD_TOOLS%\aapt.exe" package -f -M android\AndroidManifest.xml -A assets -I "%PLATFORM_JAR%" --min-sdk-version %MIN_SDK% --target-sdk-version %TARGET_SDK% -F build\app.unsigned.apk || exit /b 1
pushd build\dex
"%BUILD_TOOLS%\aapt.exe" add ..\app.unsigned.apk classes.dex >nul || (popd & exit /b 1)
popd
pushd build\apk
"%BUILD_TOOLS%\aapt.exe" add ..\app.unsigned.apk lib\%ABI%\libmajestic.so >nul || (popd & exit /b 1)
popd

rem ---- 5. align ----
echo [5/6] aligning
"%BUILD_TOOLS%\zipalign.exe" -f -p 4 build\app.unsigned.apk build\app.aligned.apk || exit /b 1

rem ---- 6. sign ----
echo [6/6] signing
if not exist majestic-debug.jks (
  keytool -genkeypair -keystore majestic-debug.jks -storepass %KS_PASS% -keypass %KS_PASS% -alias %KS_ALIAS% -keyalg RSA -keysize 2048 -validity 20000 -dname "CN=Majestic" >nul || exit /b 1
)
call "%BUILD_TOOLS%\apksigner.bat" sign --ks majestic-debug.jks --ks-pass pass:%KS_PASS% --key-pass pass:%KS_PASS% --ks-key-alias %KS_ALIAS% --out dist\majestic.apk build\app.aligned.apk || exit /b 1
call "%BUILD_TOOLS%\apksigner.bat" verify --min-sdk-version %MIN_SDK% dist\majestic.apk >nul || exit /b 1

echo DONE: dist\majestic.apk
endlocal

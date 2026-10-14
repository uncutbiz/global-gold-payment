@echo off
setlocal enabledelayedexpansion
title Global Gold - push the build to GitHub

rem ===================================================================
rem   Double-click this. It puts globalgold-build.tar.gz on GitHub,
rem   on the main branch, at the exact name the server update command
rem   looks for:
rem
rem     https://raw.githubusercontent.com/uncutbiz/global-gold-payment/main/globalgold-build.tar.gz
rem
rem   It uses git with YOUR GitHub sign-in (the one GitHub Desktop set
rem   up). No password is typed here, and nothing is sent to anyone
rem   but GitHub.
rem ===================================================================

set "REPO=https://github.com/uncutbiz/global-gold-payment.git"
set "BUILD=%USERPROFILE%\Downloads\globalgold-build.tar.gz"
set "WORK=%TEMP%\ggp-push"

echo.
echo ===================================================================
echo   Push the current build to GitHub
echo ===================================================================
echo.
echo   repo  : uncutbiz/global-gold-payment  (branch main)
echo   build : %BUILD%
echo.

rem --- 1. find git -------------------------------------------------
set "GIT="
for /f "delims=" %%G in ('where git 2^>nul') do if not defined GIT set "GIT=%%G"
if not defined GIT (
  rem GitHub Desktop ships its own git; look for it.
  for /f "delims=" %%G in ('dir /b /s "%LOCALAPPDATA%\GitHubDesktop\git.exe" 2^>nul') do if not defined GIT set "GIT=%%G"
)
if not defined GIT (
  echo   [X] Could not find git on this machine.
  echo.
  echo       Open GitHub Desktop once (it installs git), or install Git
  echo       for Windows, then run this again. If you would rather not,
  echo       see the "upload by hand" steps I sent in the chat - four
  echo       clicks on github.com, no git needed.
  echo.
  pause
  exit /b 1
)
echo   using git: !GIT!
echo.

if not exist "%BUILD%" (
  echo   [X] Build not found: %BUILD%
  echo       Nothing to push.
  pause
  exit /b 1
)

rem --- 2. fresh clone (avoids touching any working copy) -----------
echo == 1 of 4   Getting the latest repo
if exist "%WORK%" rmdir /s /q "%WORK%"
"!GIT!" clone --depth 1 "%REPO%" "%WORK%"
if errorlevel 1 (
  echo.
  echo   [X] Could not clone the repo. The usual cause is that git is
  echo       not signed in to GitHub yet. Open GitHub Desktop, make sure
  echo       you are signed in, then run this again.
  echo.
  pause
  exit /b 1
)
echo.

rem --- 3. drop the build in and commit ----------------------------
echo == 2 of 4   Adding the build
copy /y "%BUILD%" "%WORK%\globalgold-build.tar.gz" >nul
cd /d "%WORK%"
"!GIT!" add globalgold-build.tar.gz
rem Identity, in case this machine's git has none set.
"!GIT!" config user.name  >nul 2>nul || "!GIT!" config user.name  "Global Gold deploy"
"!GIT!" config user.email >nul 2>nul || "!GIT!" config user.email "uncutbiz@gmail.com"

for /f "tokens=2 delims==" %%S in ('wmic os get localdatetime /value ^| find "="') do set "NOW=%%S"
set "STAMP=!NOW:~0,4!-!NOW:~4,2!-!NOW:~6,2! !NOW:~8,2!:!NOW:~10,2!"
echo == 3 of 4   Committing
"!GIT!" commit -m "Build !STAMP! - profile/logo, items & orders, loyalty, admin activity" >nul
if errorlevel 1 (
  echo   Nothing changed - this exact build is already on GitHub. That is fine.
) else (
  echo   committed
)
echo.

rem --- 4. push ----------------------------------------------------
echo == 4 of 4   Pushing to main
"!GIT!" push origin HEAD:main
if errorlevel 1 (
  echo.
  echo   [X] The push failed. Two usual reasons:
  echo       1. git is not signed in to GitHub - open GitHub Desktop and
  echo          sign in, then run this again.
  echo       2. the branch is protected - then upload by hand instead
  echo          (the four-click steps I sent in the chat).
  echo.
  pause
  exit /b 1
)

echo.
echo ===================================================================
echo   Done. The build is on GitHub, on main.
echo.
echo   From now on the server can update itself with just:
echo       sudo globalgold-update
echo   (no URL needed - it pulls this file from main).
echo.
echo   To put it on the server right now, double-click
echo   DEPLOY-TO-SERVER.cmd.
echo ===================================================================
echo.
pause
exit /b 0

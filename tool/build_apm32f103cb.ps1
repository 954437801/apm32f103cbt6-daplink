#
# DAPLink Interface Firmware
# Copyright (c) 2009-2016, ARM Limited, All Rights Reserved
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# APM32F103CB DAPLink build script
# Build with progen_compile.py and GCC ARM toolchain
# Usage: powershell -ExecutionPolicy Bypass -File tools\build_apm32f103cb.ps1

# Get script directory and change to project root
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$daplinkDir = Split-Path -Parent $scriptPath
Set-Location $daplinkDir
Write-Host "Working directory: $daplinkDir"

# Set GCC ARM toolchain path
$gccArmPath = "C:\Users\WJF\.eide\tools\gcc_arm"
$env:GCC_ARM_PATH = $gccArmPath

# Python virtual environment (use venv python directly, no activation needed)
$venvPath = Join-Path $daplinkDir "env"
$venvPython = Join-Path $venvPath "Scripts\python.exe"
$venvScripts = Join-Path $venvPath "Scripts"
if (-not (Test-Path $venvPython)) {
    Write-Host "Creating Python virtual environment..."
    python -m venv $venvPath
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Error: failed to create virtual environment"
        exit 1
    }
}

# Add make tool path (msys2)
$msysPath = "C:\msys64\usr\bin"
if (-not (Test-Path "$msysPath\make.exe")) {
    Write-Error "Error: make not found at $msysPath, please install msys64"
    exit 1
}
$makeVersion = & "$msysPath\make.exe" --version | Select-Object -First 1
Write-Host "make: $makeVersion"

# IMPORTANT: PATH order matters for msys2 make compatibility.
# venv Scripts directory MUST come before msys64/usr/bin so that
# msys2 make can find Windows python.exe when running $(shell python ...)
$env:Path = "$gccArmPath\bin;$venvScripts;$msysPath;C:\Windows\System32;$env:Path"

Write-Host "GCC_ARM_PATH = $env:GCC_ARM_PATH"

# Check arm-none-eabi-gcc
$gccTest = Get-Command "arm-none-eabi-gcc" -ErrorAction SilentlyContinue
if (-not $gccTest) {
    Write-Error "Error: arm-none-eabi-gcc not found, check GCC toolchain path: $gccArmPath"
    exit 1
}
$gccVersion = & arm-none-eabi-gcc --version | Select-Object -First 1
Write-Host "GCC: $gccVersion"

# Check make is accessible
$makeTest = Get-Command "make" -ErrorAction SilentlyContinue
if (-not $makeTest) {
    Write-Error "Error: make not found in PATH after setup"
    exit 1
}

Write-Host "Using venv python: $venvPython"

# Install Python dependencies
Write-Host "Installing Python dependencies..."
& $venvPython -m pip install --upgrade pip --quiet
& $venvPython -m pip install -r requirements.txt
if ($LASTEXITCODE -ne 0) {
    Write-Error "Error: dependency installation failed"
    exit 1
}

# Build projects
Write-Host ""
Write-Host "===== Building APM32F103CB DAPLink ====="
Write-Host ""

# Build bootloader and interface firmware
# Note: stm32f103xb HIC is compatible with APM32F103CB (Cortex-M3, same memory map)
$projects = @(
    "stm32f103xb_bl",
    "stm32f103xb_stm32f103rb_if"
)

$buildSuccess = $true
foreach ($proj in $projects) {
    Write-Host "----- Building project: $proj -----"
    & $venvPython tools/progen_compile.py --toolchain make_gcc_arm --clean $proj
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Warning: project $proj build failed!"
        $buildSuccess = $false
    } else {
        Write-Host "OK: project $proj build completed"
    }
    Write-Host ""
}

Write-Host "===== Build completed ====="
Write-Host "Output directory: $daplinkDir\projectfiles\make_gcc_arm\"

if (-not $buildSuccess) {
    Write-Warning "Some projects failed to build, please check errors above"
}

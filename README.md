# Windows 11 Upgrade Script

## Overview
This repository contains scripts to perform an **in-place upgrade** to Windows 11.  
The upgrade is designed to run silently (or with minimal prompts) and can be used in automation or IT-managed rollouts.  

## Requirements
- Administrator privileges
- Sufficient free disk space
- Internet access to download updates (if `DynamicUpdate=Enable`)
- Windows 10 system that meets Windows 11 hardware requirements
- Download all the files ( .iso, .ps1, .bat ) onto "C:\ProgramData\W11\"; create the folder if necessary.

## ISO File
The Windows 11 ISO required for this upgrade is **not included** here.  
It must be downloaded directly from Microsoft to ensure authenticity and the latest build.

👉 You can obtain the ISO here, as of 08/29/2025:  
[Download Windows 11 ISO (Microsoft Official Link)](https://www.microsoft.com/en-us/software-download/windows11?msockid=1d8a98eddfe469bb36768d53de7d6813)

## Usage
1. Download the Windows 11 ISO from the link above.  
2. Save it to:  

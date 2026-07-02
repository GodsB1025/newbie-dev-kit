<#
====================================================================
 신입 개발자 개발환경 자동 세팅 스크립트 (Windows) / Developer environment auto-setup (Windows)
 - 신입이 직접 더블클릭/실행하는 용도
 - 실행하면 '설치할 항목 선택 창'이 먼저 뜨고, 고른 것만 설치한다.
 - 관리자 권한 자동 상승(UAC), 이미 설치된 항목은 건너뜀(멱등성)
 - 로그는 %USERPROFILE%\dev-setup-logs 에 저장
 - 한국어/English 2개 언어 지원: 선택 창 우상단 드롭다운으로 즉시 전환, -Lang ko|en 로도 지정
 실행 방법:
   1) 이 파일 우클릭 > "PowerShell로 실행"  (또는)
   2) 터미널에서:  powershell -ExecutionPolicy Bypass -File .\Setup-DevEnv.ps1
   옵션:  -DryRun (실제 설치 없이 계획만)   -All (선택창 없이 전체 설치)   -Lang ko|en (언어 강제)
====================================================================
#>

#Requires -Version 5.1

param(
    # 실제 설치 없이 "무엇을 할지"만 출력 (테스트용, 관리자 권한 불필요)
    [switch]$DryRun,
    # 선택 창을 띄우지 않고 전체(미설치분)를 설치 (무인/CI용)
    [switch]$All,
    # UI/로그 언어. 미지정 시 OS 로케일로 자동 감지(한국어면 ko, 그 외 en)
    [ValidateSet('ko','en')][string]$Lang
)
$script:DryRun = $DryRun.IsPresent
$script:All    = $All.IsPresent

# ====================== 설치 버전 설정 (여기만 고치면 됨) ======================
$Config = @{
    NodeId        = 'OpenJS.NodeJS.LTS';        NodeVersion   = ''             # LTS 채널: 항상 최신 LTS 설치 (현재 24.16.0)
    PythonId      = 'Python.Python.3.14';       PythonVersion = '3.14.2'       # 로컬과 동일
    DotnetId      = 'Microsoft.DotNet.SDK.10';  DotnetVersion = '10.0.102'     # 로컬과 동일

    # --- winget 대신 '공식 설치 스크립트'로 설치하는 도구 ---
    #  winget 으로 깔면 도구의 자체 자동 업데이트가 막혀 구버전에 고착되므로, 공식 방법으로 설치한다.
    #   Claude Code : ~/.local/bin 에 단일 바이너리 + 백그라운드 자동 업데이트
    #   Codex CLI   : 네이티브(Rust) 바이너리, 재실행/자체 업데이트
    #   uv          : winget 설치본은 'uv self update' 가 비활성 -> 공식 스크립트라야 self-update 동작
    ClaudeCodeUrl = 'https://claude.ai/install.ps1'
    CodexUrl      = 'https://chatgpt.com/codex/install.ps1'
    UvUrl         = 'https://astral.sh/uv/install.ps1'

    # --- Flutter / Android (Android Studio 없이 CLI 툴체인으로 구성, 실기기 전용) ---
    # JDK 다버전(17/21/25). winget 우선, 해시 불일치 등 실패 시 공식 MSI 폴백.
    #  17/21 = Microsoft Build of OpenJDK, 25 = Eclipse Temurin(Adoptium; MS는 25 미제공).
    #  android 항목은 Gradle/AGP 호환을 위해 jdk17 을 선행 요구. JAVA_HOME 은 설치된 것 중 가장 낮은(=호환성 높은) 버전.
    JdkSources       = @{
        '17' = @{ Id = 'Microsoft.OpenJDK.17';           Msi = 'https://aka.ms/download-jdk/microsoft-jdk-17-windows-x64.msi' }
        '21' = @{ Id = 'Microsoft.OpenJDK.21';           Msi = 'https://aka.ms/download-jdk/microsoft-jdk-21-windows-x64.msi' }
        '25' = @{ Id = 'EclipseAdoptium.Temurin.25.JDK'; Msi = 'https://api.adoptium.net/v3/installer/latest/25/ga/windows/x64/jdk/hotspot/normal/eclipse?project=jdk' }
    }
    AndroidSdkRoot   = 'C:\Android'                                            # ANDROID_HOME 위치
    # cmdline-tools 최신 URL은 Google SDK 매니페스트에서 자동 조회 (아래 base/manifest 사용).
    SdkRepoBase      = 'https://dl.google.com/android/repository/'
    SdkRepoManifest  = 'https://dl.google.com/android/repository/repository2-3.xml'
    CmdlineToolsUrl  = ''                                                       # 비워두면 자동 최신. 자동 조회 실패 시 폴백용으로 직접 URL 지정 가능
    # SDK 버전: 비워두면 sdkmanager에서 '최신 안정 버전'을 자동 선택.
    # 특정 버전으로 고정하려면 'platforms;android-36' / 'build-tools;36.0.0' 형태로 채우면 됨.
    AndroidPlatform  = ''
    AndroidBuildTool = ''
}

# ====================== 0. i18n (언어 자원) ======================
# 콘솔 한글 출력을 위해 출력 인코딩을 UTF-8 로 (권한 상승 안내 메시지 전에 설정)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 모든 사용자 노출 문자열(ko/en). {0},{1} 은 -f 포맷 자리표시자.
# 항목/카테고리 이름은 $Lineup / $GroupNames 에서 별도 관리.
$T = @{
    ko = @{
        # 권한 상승
        elevateNeeded     = '[!] 관리자 권한이 필요합니다. UAC 창에서 ''예''를 눌러주세요...'
        elevateCancelled  = '[X] 권한 상승이 취소되었습니다. 설치를 중단합니다.'
        # 배너
        bannerTitle       = '신입 개발자 개발환경 자동 세팅 시작'
        bannerDryRun      = '*** DRY-RUN 모드: 실제 설치 없이 계획만 출력합니다 ***'
        bannerLog         = '로그: {0}'
        # winget 확인
        wingetCheckStep   = 'winget(앱 설치 관리자) 확인'
        wingetMissing     = 'winget이 없습니다. Microsoft Store에서 ''앱 설치 관리자(App Installer)''를 설치한 뒤 다시 실행하세요.'
        wingetMissingDetail = '없음 - 설치 중단'
        wingetOk          = 'winget 사용 가능'
        # 공통 프롬프트
        pressEnterExit    = '엔터를 누르면 종료합니다'
        pressEnterClose   = '엔터를 누르면 창을 닫습니다'
        # winget 설치
        stepInstall       = '{0} 설치 ({1})'
        skipAlready       = '{0} : 이미 설치됨'
        detailAlready     = '이미 설치됨'
        dryInstallWinget  = '설치 예정 -> winget {0}'
        detailLatest      = '최신'
        detailVersionTry  = 'v{0} 시도'
        warnVersionRetry  = '{0} {1} 설치 실패(코드 {2}). 최신 버전으로 재시도합니다.'
        okInstalled       = '{0} 설치 완료'
        errInstallWinget  = '{0} 설치 실패 (winget 코드 {1})'
        detailWingetCode  = 'winget 코드 {0}'
        # 공식 설치 스크립트 (irm <url> | iex)
        stepInstallScript = '{0} 설치 (공식 설치 스크립트)'
        dryInstallScript  = '설치 예정 -> irm {0} | iex'
        detailScript      = '공식 스크립트'
        warnScriptNoDetect = '{0} 설치 스크립트는 실행됐지만 아직 탐지되지 않습니다. 새 터미널을 열면 인식됩니다.'
        errInstallScript  = '{0} 설치 실패 (공식 스크립트): {1}'
        # choco 설치
        stepInstallChoco  = '{0} 설치 (choco {1})'
        dryInstallChoco   = '설치 예정 -> choco install {0} -y'
        warnChocoSkip     = 'Chocolatey 설치 실패로 {0} 을(를) 건너뜁니다.'
        detailNoChoco     = 'choco 없음'
        errInstallChoco   = '{0} 설치 실패 (choco 코드 {1})'
        # Chocolatey 본체
        stepInstallChocolatey = 'Chocolatey 설치'
        dryChocolatey     = '설치 예정 -> community.chocolatey.org/install.ps1 실행'
        okChocolatey      = 'Chocolatey 설치 완료'
        errChocolatey     = 'Chocolatey 설치 실패: {0}'
        warnNeedChoco     = '이 항목은 Chocolatey가 필요합니다. Chocolatey를 먼저 설치합니다.'
        # Docker
        stepWsl2          = 'WSL2 활성화 (Docker Desktop 사전 요구사항)'
        dryWsl2           = '실행 예정 -> wsl --install --no-distribution'
        detailDockerPre   = 'Docker 사전요건'
        okWsl2            = 'WSL2 활성화 시도 완료 (재부팅 후 적용될 수 있음)'
        warnWsl2          = 'WSL2 활성화 중 경고: {0}'
        stepDocker        = 'Docker Desktop 설치 (Docker.DockerDesktop)'
        dryDocker         = 'winget 설치 시도 -> 실패(해시불일치 등) 시 공식 설치파일 직접 다운로드 폴백'
        detailDockerDry   = 'winget + 직접다운로드 폴백'
        okDockerWinget    = 'Docker Desktop 설치 완료 (winget)'
        warnDockerFallback = 'winget 설치 실패(코드 {0}). 공식 설치파일을 직접 받아 설치합니다.'
        okDockerDirect    = 'Docker Desktop 설치 완료 (직접 다운로드)'
        detailDirectFallback = '직접 다운로드 폴백'
        errDockerDirect   = 'Docker Desktop 직접 설치 실패 (코드 {0})'
        detailInstallerCode = 'installer 코드 {0}'
        errDocker         = 'Docker Desktop 설치 실패: {0}'
        # OpenJDK
        stepJdk           = 'OpenJDK {0} 설치 ({1})'
        dryJdkMsi         = 'winget 설치 시도 -> 실패(해시불일치 등) 시 공식 MSI 직접 다운로드 폴백'
        detailJdkDry      = 'winget + MSI 폴백'
        okJdkWinget       = 'OpenJDK {0} 설치 완료 (winget)'
        warnJdkFallback   = 'winget 설치 실패(코드 {0}). 공식 MSI를 직접 받아 설치합니다.'
        okJdkMsi          = 'OpenJDK {0} 설치 완료 (직접 MSI)'
        detailMsiFallback = '직접 MSI 폴백'
        errJdkMsi         = 'OpenJDK {0} 직접 설치 실패 (msiexec 코드 {1})'
        detailMsiexecCode = 'msiexec 코드 {0}'
        errJdk            = 'OpenJDK {0} 설치 실패: {1}'
        warnNoJdkPath     = '설치된 JDK를 찾지 못해 JAVA_HOME 설정을 건너뜁니다.'
        # Flutter
        stepFlutter       = 'Flutter SDK 설치'
        dryFlutter        = '설치 예정 -> choco install flutter -y'
        # Android SDK
        stepAndroidCmdline = 'Android SDK (cmdline-tools) 구성'
        skipAndroidCmdline = 'Android cmdline-tools : 이미 있음 ({0})'
        dryAndroidCmdline = '{0} 다운로드 -> {1}\cmdline-tools\latest 압축해제'
        manifestAuto      = '(매니페스트 자동 조회)'
        errCmdlineUrl     = 'cmdline-tools 최신 URL을 매니페스트에서 찾지 못함 (Config.CmdlineToolsUrl로 수동 지정 가능)'
        okCmdlinePlaced   = 'cmdline-tools 배치 완료: {0}'
        errCmdline        = 'cmdline-tools 설치 실패: {0}'
        stepAndroidPkg    = 'Android SDK 패키지 설치 + 라이선스 동의'
        dryAndroidPkgPinned = '최신 안정 버전 자동 선택'
        dryAndroidPkg2    = 'sdkmanager --licenses 자동 동의(y)'
        errSdkResolve     = 'sdkmanager --list에서 최신 platform/build-tools를 찾지 못함'
        warnSdkListRetry  = 'sdkmanager 패키지 목록을 받지 못했습니다. 다시 시도합니다 ({0}/{1})...'
        errSdkInstallVerify = 'SDK 설치 검증 실패: 다음 패키지가 설치되지 않았습니다 - {0} (존재하지 않는 버전일 수 있음)'
        okSdkSelected     = '선택된 SDK: {0} / {1}'
        okAndroidPkg      = 'Android SDK 패키지 설치 + 라이선스 동의 완료'
        errAndroidPkg     = 'Android SDK 패키지 설치 실패: {0}'
        warnNoSdkmanager  = 'sdkmanager를 찾을 수 없어 SDK 패키지 설치를 건너뜁니다.'
        detailNoSdkmanager = 'sdkmanager 없음'
        resAndroidPkg     = 'Android SDK 패키지'
        # Git 설정
        stepGitId         = 'Git 사용자 정보 설정'
        warnGitMissing    = 'git 명령을 아직 찾을 수 없습니다. 터미널을 새로 연 뒤 이 단계만 수동으로 진행하세요.'
        detailGitPath     = 'git PATH 미반영 - 재실행 필요'
        skipGitId         = '이미 설정됨: {0} <{1}>'
        dryGitId          = 'git user.name/user.email 을 입력받아 git config --global 설정 예정'
        detailGitPrompt   = '이름/이메일 프롬프트'
        promptGitName     = '  git user.name  (예: 홍길동)'
        promptGitEmail    = '  git user.email (예: id@company.com)'
        okGitId           = 'Git 사용자 설정 완료: {0} <{1}>'
        resGit            = 'Git 설정'
        # SSH 키
        stepSshKey        = 'SSH 키 생성 / 확인'
        skipSshExists     = 'SSH 키가 이미 있습니다: {0}.pub'
        drySshKey         = 'ssh-keygen -t ed25519 로 SSH 키 생성 예정: {0}'
        okSshKey          = 'SSH 키 생성 완료'
        sshRegisterHeader = '  ---- 아래 공개키를 GitHub/GitLab 등에 등록하세요 ----'
        resSsh            = 'SSH 키'
        # 선택 창 (GUI)
        childInstalled    = '  ✓ 설치됨'
        devSetup          = '개발환경 세팅'
        langLabel         = '언어'
        selectTitle       = '설치할 항목을 선택하세요'
        selectSubtitle    = '설치할 항목을 체크하세요. 이미 설치된 항목은 회색·기본 해제이며, 카테고리 제목을 누르면 그룹 전체를 켜고 끌 수 있어요.'
        btnSelectAll      = '전체 선택'
        btnDeselectAll    = '전체 해제'
        btnInstall        = '설치 시작'
        btnCancel         = '취소'
        # 상태 확인 / 선택 / 설치 진행
        stepCheckStatus   = '현재 설치 상태 확인 중 (winget 조회로 잠시 걸립니다)'
        progressCheckActivity = '설치 상태 확인'
        okAllSelected     = '-All 지정: 전체 항목 설치 (이미 설치된 것은 자동 SKIP)'
        cancelled         = '[취소] 사용자가 설치를 취소했습니다.'
        warnAutoDeps      = '선행 의존으로 다음 항목이 자동 포함됩니다: {0}'
        noSelection       = '[알림] 선택된 항목이 없습니다. 설치할 것이 없습니다.'
        installStart      = '설치 시작 ({0}개): {1}'
        # 임시파일 정리
        stepCleanup       = '임시 다운로드 파일 정리'
        dryDelete         = '삭제 예정 -> {0}'
        okDeleted         = '삭제: {0}'
        warnDeleteFail    = '삭제 실패(무시): {0} - {1}'
        detailCleanupDry  = '스크립트 다운로드분만 삭제'
        okCleanup         = '임시 파일 정리 완료 (약 {0}MB 회수)'
        detailReclaimed   = '{0}MB 회수'
        resCleanup        = '임시파일 정리'
        # 결과 요약
        summaryTitle      = '설치 결과 요약'
        someFailed        = '[!] 실패한 항목이 있습니다. 위 표와 로그를 확인하세요: {0}'
        allDone           = '[OK] 모든 단계가 완료되었습니다.'
        postHeader        = '[중요] 다음 사항을 확인하세요:'
        postReboot        = '  - Docker Desktop은 WSL2 적용/엔진 기동을 위해 ''재부팅''이 필요합니다.'
        postPath          = '  - 설치된 명령(node, python 등)은 ''새 터미널''을 열어야 PATH에 잡힙니다.'
        postLog           = '  - 로그 파일: {0}'
    }
    en = @{
        # Elevation
        elevateNeeded     = '[!] Administrator rights are required. Click ''Yes'' in the UAC prompt...'
        elevateCancelled  = '[X] Elevation was cancelled. Installation aborted.'
        # Banner
        bannerTitle       = 'Developer Environment Auto-Setup'
        bannerDryRun      = '*** DRY-RUN MODE: prints the plan only, nothing is installed ***'
        bannerLog         = 'Log: {0}'
        # winget check
        wingetCheckStep   = 'Checking winget (App Installer)'
        wingetMissing     = 'winget was not found. Install ''App Installer'' from the Microsoft Store, then run this again.'
        wingetMissingDetail = 'missing - aborting'
        wingetOk          = 'winget is available'
        # Common prompts
        pressEnterExit    = 'Press Enter to exit'
        pressEnterClose   = 'Press Enter to close this window'
        # winget install
        stepInstall       = 'Installing {0} ({1})'
        skipAlready       = '{0} : already installed'
        detailAlready     = 'already installed'
        dryInstallWinget  = 'will install -> winget {0}'
        detailLatest      = 'latest'
        detailVersionTry  = 'v{0} (attempted)'
        warnVersionRetry  = '{0} {1} install failed (code {2}). Retrying with the latest version.'
        okInstalled       = '{0} installed successfully'
        errInstallWinget  = '{0} install failed (winget code {1})'
        detailWingetCode  = 'winget code {0}'
        # Official installer script (irm <url> | iex)
        stepInstallScript = 'Installing {0} (official installer script)'
        dryInstallScript  = 'will install -> irm {0} | iex'
        detailScript      = 'official script'
        warnScriptNoDetect = '{0} installer ran but is not detected yet. Open a new terminal to pick it up.'
        errInstallScript  = '{0} install failed (official script): {1}'
        # choco install
        stepInstallChoco  = 'Installing {0} (choco {1})'
        dryInstallChoco   = 'will install -> choco install {0} -y'
        warnChocoSkip     = 'Skipping {0} because Chocolatey could not be installed.'
        detailNoChoco     = 'no choco'
        errInstallChoco   = '{0} install failed (choco code {1})'
        # Chocolatey itself
        stepInstallChocolatey = 'Installing Chocolatey'
        dryChocolatey     = 'will run -> community.chocolatey.org/install.ps1'
        okChocolatey      = 'Chocolatey installed'
        errChocolatey     = 'Chocolatey install failed: {0}'
        warnNeedChoco     = 'This item requires Chocolatey. Installing Chocolatey first.'
        # Docker
        stepWsl2          = 'Enabling WSL2 (Docker Desktop prerequisite)'
        dryWsl2           = 'will run -> wsl --install --no-distribution'
        detailDockerPre   = 'Docker prerequisite'
        okWsl2            = 'WSL2 enable attempted (may need a reboot to take effect)'
        warnWsl2          = 'Warning while enabling WSL2: {0}'
        stepDocker        = 'Installing Docker Desktop (Docker.DockerDesktop)'
        dryDocker         = 'try winget -> on failure (e.g. hash mismatch) fall back to downloading the official installer directly'
        detailDockerDry   = 'winget + direct-download fallback'
        okDockerWinget    = 'Docker Desktop installed (winget)'
        warnDockerFallback = 'winget install failed (code {0}). Downloading the official installer directly.'
        okDockerDirect    = 'Docker Desktop installed (direct download)'
        detailDirectFallback = 'direct-download fallback'
        errDockerDirect   = 'Docker Desktop direct install failed (code {0})'
        detailInstallerCode = 'installer code {0}'
        errDocker         = 'Docker Desktop install failed: {0}'
        # OpenJDK
        stepJdk           = 'Installing OpenJDK {0} ({1})'
        dryJdkMsi         = 'try winget -> on failure (e.g. hash mismatch) fall back to downloading the official MSI directly'
        detailJdkDry      = 'winget + MSI fallback'
        okJdkWinget       = 'OpenJDK {0} installed (winget)'
        warnJdkFallback   = 'winget install failed (code {0}). Downloading the official MSI directly.'
        okJdkMsi          = 'OpenJDK {0} installed (direct MSI)'
        detailMsiFallback = 'direct MSI fallback'
        errJdkMsi         = 'OpenJDK {0} direct install failed (msiexec code {1})'
        detailMsiexecCode = 'msiexec code {0}'
        errJdk            = 'OpenJDK {0} install failed: {1}'
        warnNoJdkPath     = 'Could not find an installed JDK; skipping JAVA_HOME setup.'
        # Flutter
        stepFlutter       = 'Installing Flutter SDK'
        dryFlutter        = 'will install -> choco install flutter -y'
        # Android SDK
        stepAndroidCmdline = 'Setting up Android SDK (cmdline-tools)'
        skipAndroidCmdline = 'Android cmdline-tools : already present ({0})'
        dryAndroidCmdline = 'download {0} -> extract to {1}\cmdline-tools\latest'
        manifestAuto      = '(auto-resolved from manifest)'
        errCmdlineUrl     = 'Could not resolve the latest cmdline-tools URL from the manifest (set Config.CmdlineToolsUrl manually)'
        okCmdlinePlaced   = 'cmdline-tools placed: {0}'
        errCmdline        = 'cmdline-tools install failed: {0}'
        stepAndroidPkg    = 'Installing Android SDK packages + accepting licenses'
        dryAndroidPkgPinned = 'auto-select latest stable'
        dryAndroidPkg2    = 'sdkmanager --licenses auto-accept (y)'
        errSdkResolve     = 'Could not find the latest platform/build-tools from sdkmanager --list'
        warnSdkListRetry  = 'Could not fetch the sdkmanager package list; retrying ({0}/{1})...'
        errSdkInstallVerify = 'SDK install verification failed: these packages were not installed - {0} (they may be non-existent versions)'
        okSdkSelected     = 'Selected SDK: {0} / {1}'
        okAndroidPkg      = 'Android SDK packages installed + licenses accepted'
        errAndroidPkg     = 'Android SDK package install failed: {0}'
        warnNoSdkmanager  = 'sdkmanager not found; skipping SDK package installation.'
        detailNoSdkmanager = 'sdkmanager missing'
        resAndroidPkg     = 'Android SDK packages'
        # Git config
        stepGitId         = 'Configuring Git user info'
        warnGitMissing    = 'git command not found yet. Open a new terminal and run just this step manually.'
        detailGitPath     = 'git not on PATH - rerun needed'
        skipGitId         = 'Already configured: {0} <{1}>'
        dryGitId          = 'will prompt for git user.name/user.email and run git config --global'
        detailGitPrompt   = 'name/email prompt'
        promptGitName     = '  git user.name  (e.g. Jane Doe)'
        promptGitEmail    = '  git user.email (e.g. id@company.com)'
        okGitId           = 'Git user configured: {0} <{1}>'
        resGit            = 'Git config'
        # SSH key
        stepSshKey        = 'Generating / checking SSH key'
        skipSshExists     = 'SSH key already exists: {0}.pub'
        drySshKey         = 'will generate an SSH key via ssh-keygen -t ed25519: {0}'
        okSshKey          = 'SSH key generated'
        sshRegisterHeader = '  ---- Register the public key below on GitHub/GitLab, etc. ----'
        resSsh            = 'SSH key'
        # Selection window (GUI)
        childInstalled    = '  ✓ installed'
        devSetup          = 'Dev Environment Setup'
        langLabel         = 'Language'
        selectTitle       = 'Select items to install'
        selectSubtitle    = 'Check the items to install. Already-installed items are greyed out and unchecked; click a category title to toggle the whole group.'
        btnSelectAll      = 'Select all'
        btnDeselectAll    = 'Deselect all'
        btnInstall        = 'Install'
        btnCancel         = 'Cancel'
        # Status / selection / install progress
        stepCheckStatus   = 'Checking current install status (winget lookups may take a moment)'
        progressCheckActivity = 'Checking install status'
        okAllSelected     = '-All specified: installing everything (already-installed items are auto-skipped)'
        cancelled         = '[Cancelled] Installation cancelled by the user.'
        warnAutoDeps      = 'The following items are auto-included as prerequisites: {0}'
        noSelection       = '[Notice] No items selected. Nothing to install.'
        installStart      = 'Starting installation ({0}): {1}'
        # Temp cleanup
        stepCleanup       = 'Cleaning up temporary download files'
        dryDelete         = 'will delete -> {0}'
        okDeleted         = 'Deleted: {0}'
        warnDeleteFail    = 'Delete failed (ignored): {0} - {1}'
        detailCleanupDry  = 'deletes only script-downloaded files'
        okCleanup         = 'Temp cleanup done (~{0}MB reclaimed)'
        detailReclaimed   = '{0}MB reclaimed'
        resCleanup        = 'Temp cleanup'
        # Summary
        summaryTitle      = 'Installation Summary'
        someFailed        = '[!] Some items failed. Check the table above and the log: {0}'
        allDone           = '[OK] All steps completed.'
        postHeader        = '[Important] Please check the following:'
        postReboot        = '  - Docker Desktop needs a reboot to apply WSL2 and start its engine.'
        postPath          = '  - Installed commands (node, python, etc.) appear on PATH only in a new terminal.'
        postLog           = '  - Log file: {0}'
    }
}

# 카테고리(그룹) 이름: $Lineup 의 Group 키 -> 표시 이름(ko/en)
$GroupNames = @{
    lang           = @{ ko = '언어·런타임·VCS';  en = 'Languages · Runtimes · VCS' }
    editor         = @{ ko = '에디터·IDE';       en = 'Editors · IDEs' }
    aiEditor       = @{ ko = 'AI 에디터';        en = 'AI Editors' }
    aiAgent        = @{ ko = 'AI 코딩 에이전트'; en = 'AI Coding Agents' }
    terminal       = @{ ko = '터미널';           en = 'Terminals' }
    buildCli       = @{ ko = '빌드·CLI 유틸';    en = 'Build · CLI Utilities' }
    cliTools       = @{ ko = '모던 CLI 도구';    en = 'Modern CLI Tools' }
    util           = @{ ko = '유틸리티';         en = 'Utilities' }
    browser        = @{ ko = '브라우저';         en = 'Browsers' }
    collab         = @{ ko = '협업';             en = 'Collaboration' }
    dbApi          = @{ ko = '데이터베이스·API'; en = 'Databases · API' }
    sshFile        = @{ ko = 'SSH·파일전송';     en = 'SSH · File Transfer' }
    pkgMgr         = @{ ko = '패키지매니저';     en = 'Package Managers' }
    container      = @{ ko = '컨테이너';         en = 'Containers' }
    cloud          = @{ ko = '클라우드·인프라';  en = 'Cloud · Infrastructure' }
    flutterAndroid = @{ ko = 'Flutter·Android';  en = 'Flutter · Android' }
    config         = @{ ko = '설정';             en = 'Configuration' }
}

# 문자열 조회: 현재 언어 -> 없으면 en -> 없으면 키 그대로
function L([string]$Key) {
    $tbl = $T[$script:Lang]
    if ($tbl -and $tbl.ContainsKey($Key)) { return $tbl[$Key] }
    if ($T.en.ContainsKey($Key)) { return $T.en[$Key] }
    return $Key
}

# 항목/그룹 이름 지역화: 문자열이면 그대로, @{ko=;en=} 면 현재 언어 값
function Loc($Value) {
    if ($Value -is [hashtable]) {
        if ($Value.ContainsKey($script:Lang)) { return [string]$Value[$script:Lang] }
        if ($Value.ContainsKey('en'))         { return [string]$Value['en'] }
        foreach ($v in $Value.Values) { return [string]$v }
        return ''
    }
    return [string]$Value
}

# 언어 결정: -Lang 우선 > (대화형이면) 시작 시 K/E 선택 > OS 로케일 자동감지
$ui = try { (Get-UICulture).TwoLetterISOLanguageName } catch { '' }
$cu = try { (Get-Culture).TwoLetterISOLanguageName }   catch { '' }
$autoLang = if ($ui -eq 'ko' -or $cu -eq 'ko') { 'ko' } else { 'en' }

if ($Lang) {
    # 명령행 -Lang 지정(권한 상승 후 재실행 포함) -> 그대로 사용 (재질문 안 함)
    $script:Lang = $Lang
} elseif ($script:All) {
    # 무인(-All) -> 자동감지 사용
    $script:Lang = $autoLang
} else {
    # 배너/winget 확인 전에 언어를 먼저 물어본다 (K/E). Enter 는 자동감지 기본값.
    $defLabel = if ($autoLang -eq 'ko') { 'K' } else { 'E' }
    Write-Host ''
    Write-Host '========================================================' -ForegroundColor Magenta
    Write-Host '  Choose language / 언어 선택' -ForegroundColor Cyan
    Write-Host '    [K] 한국어        [E] English'
    Write-Host '========================================================' -ForegroundColor Magenta
    $script:Lang = $autoLang
    while ($true) {
        $ans = (Read-Host ("  Select / 선택  (K/E)  [Enter = $defLabel]")).Trim()
        if     ($ans -eq '')         { $script:Lang = $autoLang; break }
        elseif ($ans -match '^[kK]') { $script:Lang = 'ko'; break }
        elseif ($ans -match '^[eE]') { $script:Lang = 'en'; break }
        else { Write-Host '    ! Please enter K or E / K 또는 E 를 입력하세요' -ForegroundColor Yellow }
    }
}

# ====================== 1. 관리자 권한 자동 상승 (DryRun이면 생략) ======================
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $script:DryRun -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ("[!] " + (L 'elevateNeeded')) -ForegroundColor Yellow
    try {
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($script:All) { $argList += ' -All' }
        $argList += " -Lang $script:Lang"   # 상승된 프로세스에 선택 언어 전달
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Host ("[X] " + (L 'elevateCancelled')) -ForegroundColor Red
    }
    exit
}

# ====================== 2. 로그/공통 준비 ======================
$ErrorActionPreference = 'Continue'
# Invoke-WebRequest 진행률 막대를 끄면 다운로드가 수십 배 빨라짐 (PS5.1 알려진 이슈)
$ProgressPreference    = 'SilentlyContinue'

$LogDir = Join-Path $env:USERPROFILE 'dev-setup-logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir ("setup-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $LogFile -Append | Out-Null

$script:Results = [System.Collections.Generic.List[object]]::new()
function Add-Result($Name, $Status, $Detail = '') {
    $script:Results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
}
function Write-Step($Msg)  { Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-Ok($Msg)    { Write-Host "    [OK]   $Msg" -ForegroundColor Green }
function Write-Skip($Msg)  { Write-Host "    [SKIP] $Msg" -ForegroundColor DarkGray }
function Write-Warn2($Msg) { Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }
function Write-Err($Msg)   { Write-Host "    [ERR]  $Msg" -ForegroundColor Red }

# 설치 직후 PATH 갱신 (현재 세션에 반영)
function Update-SessionPath {
    $m = [Environment]::GetEnvironmentVariable('Path','Machine')
    $u = [Environment]::GetEnvironmentVariable('Path','User')
    $env:Path = "$m;$u"
}

# Machine PATH 에 디렉터리 추가
#  - 원본(확장 안 된) PATH 를 직접 읽어 %SystemRoot% 등 확장형 항목과 REG_EXPAND_SZ 타입을 보존
#  - 대소문자 무시 중복 방지
function Add-MachinePath {
    param([Parameter(Mandatory)][string[]]$Dir)
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $raw = (Get-Item $key).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    $parts = @($raw -split ';' | Where-Object { $_ -ne '' })
    $added = $false
    foreach ($d in $Dir) {
        if ($parts -notcontains $d) { $parts += $d; $added = $true }
    }
    if ($added) {
        Set-ItemProperty -Path $key -Name 'Path' -Value ($parts -join ';') -Type ExpandString
    }
}

Write-Host "========================================================" -ForegroundColor Magenta
Write-Host ("   " + (L 'bannerTitle')) -ForegroundColor Magenta
if ($script:DryRun) {
    Write-Host ("   " + (L 'bannerDryRun')) -ForegroundColor Magenta
}
Write-Host ("   " + ((L 'bannerLog') -f $LogFile)) -ForegroundColor DarkGray
Write-Host "========================================================" -ForegroundColor Magenta

# ====================== 3. winget 사용 가능 확인 ======================
Write-Step (L 'wingetCheckStep')
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Err (L 'wingetMissing')
    Add-Result 'winget' 'FAIL' (L 'wingetMissingDetail')
    Stop-Transcript | Out-Null
    Read-Host ("`n" + (L 'pressEnterExit'))
    exit 1
}
# 소스 약관 자동 동의 (특정 ID만 조회 -> 전체 패키지 열거를 피해 VS 셋업엔진을 깨우지 않음)
winget list --id Git.Git -e --accept-source-agreements 2>$null | Out-Null
Write-Ok (L 'wingetOk')

# ====================== 4. 설치 헬퍼 ======================
# ---------- 설치 탐지 (설치 경로 무관) ----------
# 명령어 / 알려진 경로 / 설치프로그램목록(ARP) / 스토어앱(Appx) 중 하나라도 맞으면 설치로 본다.
# => winget/choco/scoop/npm/공식 installer/MSI/portable/Store 어떤 방법이든 정확히 탐지.

# ARP(프로그램 추가/제거) DisplayName 스냅샷 — 스캔 시작 시 1회만 읽어 캐시 (52회 반복 방지)
$script:ArpCache = $null
function Get-ArpNames {
    if ($null -ne $script:ArpCache) { return $script:ArpCache }
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $names = foreach ($k in $keys) {
        Get-ItemProperty $k -ErrorAction SilentlyContinue | ForEach-Object { $_.DisplayName }
    }
    $script:ArpCache = @($names | Where-Object { $_ })
    return $script:ArpCache
}

# 명령어가 PATH에 실재하는지 (윈도우 스토어 0바이트 더미 alias는 미설치로 간주 -> python 등 오탐 방지)
function Test-CommandReal([string]$Cmd) {
    $c = Get-Command $Cmd -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $c) { return $false }
    $src = $c.Source
    if ($src -and ($src -like '*\WindowsApps\*')) {
        try { if ((Get-Item $src -ErrorAction SilentlyContinue).Length -eq 0) { return $false } } catch {}
    }
    return $true
}

# 스토어/MSIX 앱 설치 여부 (Windows Terminal 등)
function Test-Appx([string]$Name) {
    try { return [bool](Get-AppxPackage -Name $Name -ErrorAction SilentlyContinue) } catch { return $false }
}

# 통합 탐지: 명령어/경로/ARP/Appx 중 하나라도 맞으면 $true
function Test-AnyInstalled {
    param([string[]]$Command, [string[]]$Path, [string[]]$Arp, [string[]]$Appx)
    foreach ($x in $Command) { if (Test-CommandReal $x) { return $true } }
    foreach ($x in $Path)    { if (Test-Path $x -ErrorAction SilentlyContinue) { return $true } }
    if ($Arp) {
        $names = Get-ArpNames
        foreach ($pat in $Arp) { foreach ($n in $names) { if ($n -like $pat) { return $true } } }
    }
    foreach ($x in $Appx) { if (Test-Appx $x) { return $true } }
    return $false
}

# 특정 winget ID가 이미 설치돼 있는지 확인 (설치 단계의 멱등성 체크용 — 탐지 스캔엔 사용 안 함)
function Test-WingetInstalled([string]$Id) {
    $out = winget list --id $Id -e --accept-source-agreements 2>$null | Out-String
    return ($out -match [regex]::Escape($Id))
}

# Android SDK 탐지: 우리 설치경로(C:\Android)뿐 아니라 환경변수·Android Studio 기본경로(%LOCALAPPDATA%\Android\Sdk)
# 어디든 cmdline-tools(sdkmanager) 또는 platform-tools(adb) 가 있으면 '이미 사용 가능한 SDK' 로 본다.
function Test-AndroidSdkInstalled {
    $roots = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT,
               (Join-Path $env:LOCALAPPDATA 'Android\Sdk'), $Config.AndroidSdkRoot) |
             Where-Object { $_ } | Select-Object -Unique
    foreach ($r in $roots) {
        if (Test-Path (Join-Path $r 'cmdline-tools\latest\bin\sdkmanager.bat')) { return $true }
        if (Test-Path (Join-Path $r 'platform-tools\adb.exe'))                  { return $true }
    }
    return $false
}

# JDK(버전별) 설치 탐지 — 벤더(MS/Temurin/Oracle) 무관, ARP + 설치경로로 판정.
#  Install-OpenJdk 의 멱등성 체크와 $Lineup 항목이 이 함수를 공유해 두 판정이 어긋나지 않게 한다.
#  winget list --id 로는 판정하지 않는다: 낮은 버전(예: 17)이 깔린 상태에서 상위 버전 id(예: .21)를
#  조회하면 winget 이 설치된 17을 21의 '업그레이드 대상'으로 오연결해(Version 17 / Available 21)
#  오탐하기 때문 — 그러면 21이 SKIP 되어 영영 설치되지 않는다(CLAUDE.md 규칙 #3: winget list 단독 금지).
function Test-JdkInstalled([ValidateSet('17','21','25')][string]$Version) {
    Test-AnyInstalled `
        -Arp "Microsoft Build of OpenJDK*$Version*","Eclipse Temurin*$Version*","Eclipse Adoptium*$Version*" `
        -Path "C:\Program Files\Microsoft\jdk-$Version*","C:\Program Files\Eclipse Adoptium\jdk-$Version*","C:\Program Files\Java\jdk-$Version*"
}

# winget 패키지 설치 (멱등성 + 버전 핀, 핀 실패 시 최신으로 폴백)
function Install-WingetPackage {
    param(
        [Parameter(Mandatory)] [string]$Id,
        [Parameter(Mandatory)] [string]$Name,
        [string]$Version,
        [string[]]$ExtraArgs
    )
    Write-Step ((L 'stepInstall') -f $Name, $Id)
    if (Test-WingetInstalled $Id) {
        Write-Skip ((L 'skipAlready') -f $Name)
        Add-Result $Name 'SKIP' (L 'detailAlready')
        return
    }
    $baseArgs = @('install','--id',$Id,'-e',
                  '--accept-package-agreements','--accept-source-agreements',
                  '--silent','--disable-interactivity')
    if ($ExtraArgs) { $baseArgs += $ExtraArgs }

    $tryArgs = $baseArgs
    if ($Version) { $tryArgs = $baseArgs + @('--version',$Version) }

    if ($script:DryRun) {
        Write-Host ("    [DRY]  " + ((L 'dryInstallWinget') -f ($tryArgs -join ' '))) -ForegroundColor Magenta
        $detail = if ($Version) { "v$Version" } else { L 'detailLatest' }
        Add-Result $Name 'DRY' $detail
        return
    }

    & winget @tryArgs
    $code = $LASTEXITCODE

    # 버전 핀 실패(해당 버전 없음 등) 시 최신 버전으로 재시도
    if ($code -ne 0 -and $Version) {
        Write-Warn2 ((L 'warnVersionRetry') -f $Name, $Version, $code)
        & winget @baseArgs
        $code = $LASTEXITCODE
    }

    if ($code -eq 0) {
        Write-Ok ((L 'okInstalled') -f $Name)
        $detail = if ($Version) { (L 'detailVersionTry') -f $Version } else { L 'detailLatest' }
        Add-Result $Name 'OK' $detail
    } else {
        Write-Err ((L 'errInstallWinget') -f $Name, $code)
        Add-Result $Name 'FAIL' ((L 'detailWingetCode') -f $code)
    }
    Update-SessionPath
}

# Chocolatey 패키지 설치 (winget에 없는 것 - FileZilla 등)
function Install-ChocoPackage {
    param(
        [Parameter(Mandatory)][string]$Pkg,
        [Parameter(Mandatory)][string]$Name,
        [scriptblock]$InstalledCheck
    )
    Write-Step ((L 'stepInstallChoco') -f $Name, $Pkg)
    if ($InstalledCheck -and (& $InstalledCheck)) {
        Write-Skip ((L 'skipAlready') -f $Name); Add-Result $Name 'SKIP' (L 'detailAlready'); return
    }
    if ($script:DryRun) {
        Write-Host ("    [DRY]  " + ((L 'dryInstallChoco') -f $Pkg)) -ForegroundColor Magenta
        Add-Result $Name 'DRY' 'choco'; return
    }
    if (-not (Ensure-Chocolatey)) {
        Write-Warn2 ((L 'warnChocoSkip') -f $Name)
        Add-Result $Name 'WARN' (L 'detailNoChoco'); return
    }
    choco install $Pkg -y
    if ($LASTEXITCODE -eq 0) { Write-Ok ((L 'okInstalled') -f $Name); Add-Result $Name 'OK' 'choco' }
    else { Write-Err ((L 'errInstallChoco') -f $Name, $LASTEXITCODE); Add-Result $Name 'FAIL' ("choco " + $LASTEXITCODE) }
    Update-SessionPath
}

# 공식 설치 스크립트(irm <url> | iex) 기반 설치 (Install-Chocolatey 와 동일한 다운로드+iex 패턴).
#  winget 으로 깔면 자체 자동 업데이트가 막히는 도구(Claude Code/Codex/uv)를 공식 방법으로 설치해
#  도구의 백그라운드/self-update 가 정상 동작하게 한다. 멱등성·DryRun·로그는 winget 설치와 동일하게 처리.
function Install-ViaScript {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][scriptblock]$InstalledCheck
    )
    Write-Step ((L 'stepInstallScript') -f $Name)
    if (& $InstalledCheck) {
        Write-Skip ((L 'skipAlready') -f $Name); Add-Result $Name 'SKIP' (L 'detailAlready'); return
    }
    if ($script:DryRun) {
        Write-Host ("    [DRY]  " + ((L 'dryInstallScript') -f $Url)) -ForegroundColor Magenta
        Add-Result $Name 'DRY' (L 'detailScript'); return
    }
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = 3072  # TLS 1.2
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString($Url))
        Update-SessionPath
        if (& $InstalledCheck) {
            Write-Ok ((L 'okInstalled') -f $Name); Add-Result $Name 'OK' (L 'detailScript')
        } else {
            # 스크립트는 성공했지만 PATH 미반영 등으로 아직 탐지 안 됨 -> 실패가 아니라 경고로 처리
            Write-Warn2 ((L 'warnScriptNoDetect') -f $Name); Add-Result $Name 'WARN' (L 'detailScript')
        }
    } catch {
        Write-Err ((L 'errInstallScript') -f $Name, $_.Exception.Message)
        Add-Result $Name 'FAIL' $_.Exception.Message
    }
}

# ====================== 5. 개별 설치 함수 ======================

function Install-Chocolatey {
    Write-Step (L 'stepInstallChocolatey')
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Skip ((L 'skipAlready') -f 'Chocolatey'); Add-Result 'Chocolatey' 'SKIP' (L 'detailAlready'); return
    }
    if ($script:DryRun) {
        Write-Host ("    [DRY]  " + (L 'dryChocolatey')) -ForegroundColor Magenta
        Add-Result 'Chocolatey' 'DRY' ''; return
    }
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = 3072  # TLS 1.2
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        Update-SessionPath
        Write-Ok (L 'okChocolatey'); Add-Result 'Chocolatey' 'OK' ''
    } catch {
        Write-Err ((L 'errChocolatey') -f $_.Exception.Message); Add-Result 'Chocolatey' 'FAIL' $_.Exception.Message
    }
}

# choco가 필요한 설치 직전에 호출: 없으면 그 자리에서 설치(self-heal). 선택/순서와 무관하게 보장.
function Ensure-Chocolatey {
    if (Get-Command choco -ErrorAction SilentlyContinue) { return $true }
    if ($script:DryRun) { return $true }   # DryRun은 실제 설치 안 하므로 통과로 간주
    Write-Warn2 (L 'warnNeedChoco')
    Install-Chocolatey
    Update-SessionPath
    return [bool](Get-Command choco -ErrorAction SilentlyContinue)
}

function Install-DockerDesktop {
    # WSL2 (Docker Desktop 사전 요구사항)
    Write-Step (L 'stepWsl2')
    if ($script:DryRun) {
        Write-Host ("    [DRY]  " + (L 'dryWsl2')) -ForegroundColor Magenta
        Add-Result 'WSL2' 'DRY' (L 'detailDockerPre')
    } else {
        try {
            wsl --install --no-distribution
            Write-Ok (L 'okWsl2'); Add-Result 'WSL2' 'OK' (L 'detailDockerPre')
        } catch {
            Write-Warn2 ((L 'warnWsl2') -f $_.Exception.Message); Add-Result 'WSL2' 'WARN' $_.Exception.Message
        }
    }
    # Docker Desktop : winget 매니페스트 해시가 자주 어긋남(동일 URL에 최신 설치파일 덮어씀).
    # 관리자 실행 시 해시 무시 불가 -> winget 실패 시 공식 설치파일 직접 다운로드 폴백.
    Write-Step (L 'stepDocker')
    if (Test-WingetInstalled 'Docker.DockerDesktop') {
        Write-Skip ((L 'skipAlready') -f 'Docker Desktop'); Add-Result 'Docker Desktop' 'SKIP' (L 'detailAlready'); return
    }
    if ($script:DryRun) {
        Write-Host ("    [DRY]  " + (L 'dryDocker')) -ForegroundColor Magenta
        Add-Result 'Docker Desktop' 'DRY' (L 'detailDockerDry'); return
    }
    & winget install --id Docker.DockerDesktop -e `
        --accept-package-agreements --accept-source-agreements --silent --disable-interactivity
    $dockerCode = $LASTEXITCODE
    if ($dockerCode -eq 0) {
        Write-Ok (L 'okDockerWinget'); Add-Result 'Docker Desktop' 'OK' 'winget'
    } else {
        Write-Warn2 ((L 'warnDockerFallback') -f $dockerCode)
        try {
            $dockerUrl = 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe'
            $dockerExe = Join-Path $env:TEMP 'DockerDesktopInstaller.exe'
            Invoke-WebRequest -Uri $dockerUrl -OutFile $dockerExe -UseBasicParsing
            $p = Start-Process -FilePath $dockerExe -ArgumentList 'install','--quiet','--accept-license' -Wait -PassThru
            if ($p.ExitCode -eq 0) { Write-Ok (L 'okDockerDirect'); Add-Result 'Docker Desktop' 'OK' (L 'detailDirectFallback') }
            else { Write-Err ((L 'errDockerDirect') -f $p.ExitCode); Add-Result 'Docker Desktop' 'FAIL' ((L 'detailInstallerCode') -f $p.ExitCode) }
        } catch {
            Write-Err ((L 'errDocker') -f $_.Exception.Message); Add-Result 'Docker Desktop' 'FAIL' $_.Exception.Message
        }
    }
    Update-SessionPath
}

# 여러 JDK가 깔려도 JAVA_HOME 은 하나 → 벤더 무관하게 스캔해 '가장 낮은(=호환성 높은) major' 로 고정.
#  새 LTS 일수록 Gradle/AGP/Maven 등 하위호환이 깨질 위험이 커서 보수적으로 선택(17 > 21 > 25).
#  android 가 jdk17 을 선행 요구하므로, Android 를 고른 경우 항상 17 이 JAVA_HOME 이 됨.
function Set-JavaHomeCompatible {
    $bases = @(
        'C:\Program Files\Microsoft',          # Microsoft Build of OpenJDK
        'C:\Program Files\Eclipse Adoptium',   # Temurin
        'C:\Program Files\Java'                # 일반 Java
    )
    $jdks = foreach ($b in $bases) {
        Get-ChildItem $b -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)^jdk[-_]?\d' }
    }
    $jdks = @($jdks)
    if (-not $jdks) { Write-Warn2 (L 'warnNoJdkPath'); return }
    $best = $jdks | Sort-Object @{ Expression = { if ($_.Name -match 'jdk[-_]?(\d+)') { [int]$Matches[1] } else { 9999 } } } |
            Select-Object -First 1
    [Environment]::SetEnvironmentVariable('JAVA_HOME', $best.FullName, 'Machine')
    $env:JAVA_HOME = $best.FullName
    Add-MachinePath (Join-Path $best.FullName 'bin')   # java/javac 를 PATH 에 보장
    Update-SessionPath
    Write-Ok "JAVA_HOME = $($best.FullName)"
}

function Install-OpenJdk {
    # winget 해시 불일치(관리자 실행 시 무시 불가)에 대비해 실패 시 공식 MSI 직접 설치로 폴백.
    param([Parameter(Mandatory)][ValidateSet('17','21','25')][string]$Version)
    $src  = $Config.JdkSources[$Version]
    $name = "OpenJDK $Version"
    Write-Step ((L 'stepJdk') -f $Version, $src.Id)
    if (Test-JdkInstalled $Version) {
        Write-Skip ((L 'skipAlready') -f $name); Add-Result $name 'SKIP' (L 'detailAlready')
    } elseif ($script:DryRun) {
        Write-Host ("    [DRY]  " + (L 'dryJdkMsi')) -ForegroundColor Magenta
        Add-Result $name 'DRY' (L 'detailJdkDry')
    } else {
        & winget install --id $src.Id -e `
            --accept-package-agreements --accept-source-agreements --silent --disable-interactivity
        $jdkCode = $LASTEXITCODE
        if ($jdkCode -eq 0) {
            Write-Ok ((L 'okJdkWinget') -f $Version); Add-Result $name 'OK' 'winget'
        } else {
            Write-Warn2 ((L 'warnJdkFallback') -f $jdkCode)
            try {
                $jdkMsi = Join-Path $env:TEMP "openjdk-$Version.msi"
                Invoke-WebRequest -Uri $src.Msi -OutFile $jdkMsi -UseBasicParsing
                $p = Start-Process msiexec.exe -ArgumentList '/i', "`"$jdkMsi`"", '/qn', '/norestart' -Wait -PassThru
                if ($p.ExitCode -eq 0) { Write-Ok ((L 'okJdkMsi') -f $Version); Add-Result $name 'OK' (L 'detailMsiFallback') }
                else { Write-Err ((L 'errJdkMsi') -f $Version, $p.ExitCode); Add-Result $name 'FAIL' ((L 'detailMsiexecCode') -f $p.ExitCode) }
            } catch {
                Write-Err ((L 'errJdk') -f $Version, $_.Exception.Message); Add-Result $name 'FAIL' $_.Exception.Message
            }
        }
        Update-SessionPath
    }
    # JAVA_HOME 보정 (Gradle 이 JAVA_HOME 우선 참조). 설치된 JDK 중 가장 호환성 높은 버전으로.
    if (-not $script:DryRun) { Set-JavaHomeCompatible }
}

function Install-Flutter {
    Write-Step (L 'stepFlutter')
    if (Get-Command flutter -ErrorAction SilentlyContinue) {
        Write-Skip ((L 'skipAlready') -f 'Flutter'); Add-Result 'Flutter' 'SKIP' (L 'detailAlready'); return
    }
    if ($script:DryRun) {
        Write-Host ("    [DRY]  " + (L 'dryFlutter')) -ForegroundColor Magenta
        Add-Result 'Flutter' 'DRY' 'choco'; return
    }
    if (-not (Ensure-Chocolatey)) {
        Write-Warn2 ((L 'warnChocoSkip') -f 'Flutter'); Add-Result 'Flutter' 'WARN' (L 'detailNoChoco'); return
    }
    choco install flutter -y
    if ($LASTEXITCODE -eq 0) { Write-Ok ((L 'okInstalled') -f 'Flutter'); Add-Result 'Flutter' 'OK' 'choco' }
    else { Write-Err ((L 'errInstallChoco') -f 'Flutter', $LASTEXITCODE); Add-Result 'Flutter' 'FAIL' ("choco " + $LASTEXITCODE) }
    Update-SessionPath
}

# Google SDK 매니페스트에서 'cmdline-tools;latest'의 Windows용 zip URL을 자동 조회
function Resolve-LatestCmdlineToolsUrl {
    param([string]$ManifestUrl, [string]$Base, [string]$Override)
    if ($Override) { return $Override }   # config에 직접 지정한 값이 있으면 우선
    try {
        $xml = [xml](Invoke-WebRequest -Uri $ManifestUrl -UseBasicParsing).Content
        $pkg = $xml.'sdk-repository'.remotePackage | Where-Object { $_.path -eq 'cmdline-tools;latest' } | Select-Object -First 1
        if (-not $pkg) { return $null }
        $win = $pkg.archives.archive | Where-Object { $_.'host-os' -eq 'windows' } | Select-Object -First 1
        if (-not $win) { return $null }
        return ($Base + $win.complete.url)
    } catch { return $null }
}

# sdkmanager --list 출력에서 최신 안정 platform / build-tools 선택
# 첫 실행 시 원격 레포 동기화가 덜 되어 목록이 비거나 잘린 채 돌아오면 낮은 버전을
# '최신'으로 오인할 수 있다(예: Flutter가 android-36을 요구하는데 android-34만 설치됨).
# 따라서 platform/build-tools가 하나도 안 잡히면 원격을 다시 받아 재시도한다.
function Resolve-LatestSdkPackages {
    param([string]$SdkManager, [int]$MaxAttempts = 3)
    $platform = $null; $buildTool = $null
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        $listOut = (& $SdkManager --list 2>$null) -join "`n"   # 매 호출마다 원격 레포를 새로 받음

        # --list 에 나온 '실제 패키지 토큰'을 그대로 쓴다(정수로 재구성 금지).
        # 'platforms;android-37.0' 처럼 마이너가 붙는 경우 'platforms;android-37' 로 재구성하면
        # 존재하지 않는 패키지가 되어 'Failed to find package' 로 설치가 조용히 실패한다.
        # 확장 SDK(android-36-ext18 등)와 rc 빌드는 정식 플랫폼/빌드툴이 아니므로 제외한다.
        $platform = [regex]::Matches($listOut, 'platforms;android-[\w.\-]+') |
                    ForEach-Object { $_.Value } | Sort-Object -Unique |
                    Where-Object { $_ -match '^platforms;android-\d+(?:\.\d+)?$' } |
                    Sort-Object { [version]((($_ -split '-')[-1]) -replace '^\d+$', '$0.0') } -Descending |
                    Select-Object -First 1
        $buildTool = [regex]::Matches($listOut, 'build-tools;[\w.\-]+') |
                     ForEach-Object { $_.Value } | Sort-Object -Unique |
                     Where-Object { $_ -match '^build-tools;\d+\.\d+\.\d+$' } |
                     Sort-Object { [version](($_ -split ';')[-1]) } -Descending |
                     Select-Object -First 1
        if ($platform -and $buildTool) { break }   # 둘 다 잡혔으면 정상 목록 -> 종료
        if ($i -lt $MaxAttempts) {
            Write-Warn2 ((L 'warnSdkListRetry') -f $i, $MaxAttempts)
            Start-Sleep -Seconds 2
        }
    }
    return @{ Platform = $platform; BuildTool = $buildTool }
}

function Install-AndroidSdk {
    Write-Step (L 'stepAndroidCmdline')
    $sdkRoot    = $Config.AndroidSdkRoot
    $cmdlineBin = Join-Path $sdkRoot 'cmdline-tools\latest\bin'
    $sdkmgr     = Join-Path $cmdlineBin 'sdkmanager.bat'

    if (Test-Path $sdkmgr) {
        Write-Skip ((L 'skipAndroidCmdline') -f $sdkRoot); Add-Result 'Android cmdline-tools' 'SKIP' $sdkRoot
    } elseif ($script:DryRun) {
        $toolsUrl = Resolve-LatestCmdlineToolsUrl -ManifestUrl $Config.SdkRepoManifest -Base $Config.SdkRepoBase -Override $Config.CmdlineToolsUrl
        $shown = if ($toolsUrl) { $toolsUrl } else { L 'manifestAuto' }
        Write-Host ("    [DRY]  " + ((L 'dryAndroidCmdline') -f $shown, $sdkRoot)) -ForegroundColor Magenta
        Add-Result 'Android cmdline-tools' 'DRY' $shown
    } else {
        try {
            $toolsUrl = Resolve-LatestCmdlineToolsUrl -ManifestUrl $Config.SdkRepoManifest -Base $Config.SdkRepoBase -Override $Config.CmdlineToolsUrl
            if (-not $toolsUrl) { throw (L 'errCmdlineUrl') }
            Write-Ok "cmdline-tools URL: $toolsUrl"
            $tmpZip     = Join-Path $env:TEMP 'android-cmdline-tools.zip'
            $extractTmp = Join-Path $env:TEMP 'android-cmdline-extract'
            Invoke-WebRequest -Uri $toolsUrl -OutFile $tmpZip -UseBasicParsing
            if (Test-Path $extractTmp) { Remove-Item $extractTmp -Recurse -Force }
            Expand-Archive -Path $tmpZip -DestinationPath $extractTmp -Force
            # zip 내부 구조는 cmdline-tools\... -> 이를 <sdkRoot>\cmdline-tools\latest 로 재배치
            $latestDir = Join-Path $sdkRoot 'cmdline-tools\latest'
            New-Item -ItemType Directory -Path $latestDir -Force | Out-Null
            Copy-Item -Path (Join-Path $extractTmp 'cmdline-tools\*') -Destination $latestDir -Recurse -Force
            Write-Ok ((L 'okCmdlinePlaced') -f $latestDir); Add-Result 'Android cmdline-tools' 'OK' $latestDir
        } catch {
            Write-Err ((L 'errCmdline') -f $_.Exception.Message); Add-Result 'Android cmdline-tools' 'FAIL' $_.Exception.Message
        }
    }

    # ANDROID_HOME / PATH 환경변수
    if (-not $script:DryRun -and (Test-Path $sdkmgr)) {
        [Environment]::SetEnvironmentVariable('ANDROID_HOME',     $sdkRoot, 'Machine')
        [Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT', $sdkRoot, 'Machine')
        Add-MachinePath @($cmdlineBin, (Join-Path $sdkRoot 'platform-tools'))
        $env:ANDROID_HOME     = $sdkRoot
        $env:ANDROID_SDK_ROOT = $sdkRoot
        Update-SessionPath
    }

    # SDK 패키지 설치 + 라이선스 동의
    Write-Step (L 'stepAndroidPkg')
    if ($script:DryRun) {
        $pinned = if ($Config.AndroidPlatform) { "$($Config.AndroidPlatform), $($Config.AndroidBuildTool)" } else { L 'dryAndroidPkgPinned' }
        Write-Host ("    [DRY]  sdkmanager platform-tools + " + $pinned) -ForegroundColor Magenta
        Write-Host ("    [DRY]  " + (L 'dryAndroidPkg2')) -ForegroundColor Magenta
        Add-Result (L 'resAndroidPkg') 'DRY' $pinned
    } elseif (Test-Path $sdkmgr) {
        try {
            $platform  = $Config.AndroidPlatform
            $buildTool = $Config.AndroidBuildTool
            if (-not $platform -or -not $buildTool) {
                $latest = Resolve-LatestSdkPackages -SdkManager $sdkmgr
                if (-not $platform)  { $platform  = $latest.Platform }
                if (-not $buildTool) { $buildTool = $latest.BuildTool }
            }
            if (-not $platform -or -not $buildTool) { throw (L 'errSdkResolve') }
            Write-Ok ((L 'okSdkSelected') -f $platform, $buildTool)
            $yes = ("y`n" * 50)
            $yes | & $sdkmgr 'platform-tools' $platform $buildTool   # 설치 중 약관 프롬프트 y 자동응답
            $yes | & $sdkmgr --licenses                             # 남은 라이선스 일괄 동의
            # 설치 검증: sdkmanager 는 존재하지 않는 패키지를 만나도 경고만 찍고 exit 0 으로 끝나므로
            # (예: 'platforms;android-37' 처럼 잘못된 토큰 -> 'Failed to find package'),
            # 플랫폼/빌드툴 폴더가 실제로 생겼는지 확인해 '조용한 실패'를 잡아 FAIL 로 보고한다.
            $platDir = Join-Path $sdkRoot ($platform  -replace ';', '\')
            $btDir   = Join-Path $sdkRoot ($buildTool -replace ';', '\')
            if (-not (Test-Path $platDir) -or -not (Test-Path $btDir)) {
                $missing = @(); if (-not (Test-Path $platDir)) { $missing += $platform }; if (-not (Test-Path $btDir)) { $missing += $buildTool }
                throw ((L 'errSdkInstallVerify') -f ($missing -join ', '))
            }
            if (Get-Command flutter -ErrorAction SilentlyContinue) {
                flutter config --android-sdk $sdkRoot 2>$null
            }
            Write-Ok (L 'okAndroidPkg'); Add-Result (L 'resAndroidPkg') 'OK' "$platform, $buildTool"
        } catch {
            Write-Err ((L 'errAndroidPkg') -f $_.Exception.Message); Add-Result (L 'resAndroidPkg') 'FAIL' $_.Exception.Message
        }
    } else {
        Write-Warn2 (L 'warnNoSdkmanager'); Add-Result (L 'resAndroidPkg') 'WARN' (L 'detailNoSdkmanager')
    }
}

function Set-GitIdentity {
    Write-Step (L 'stepGitId')
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Warn2 (L 'warnGitMissing')
        Add-Result (L 'resGit') 'WARN' (L 'detailGitPath'); return
    }
    $existingName  = (git config --global user.name)  2>$null
    $existingEmail = (git config --global user.email) 2>$null
    if ($existingName -and $existingEmail) {
        Write-Skip ((L 'skipGitId') -f $existingName, $existingEmail)
        Add-Result (L 'resGit') 'SKIP' "$existingName <$existingEmail>"
        $script:GitEmail = $existingEmail
    } elseif ($script:DryRun) {
        Write-Host ("    [DRY]  " + (L 'dryGitId')) -ForegroundColor Magenta
        Add-Result (L 'resGit') 'DRY' (L 'detailGitPrompt')
    } else {
        do { $gitName  = Read-Host (L 'promptGitName') }  while ([string]::IsNullOrWhiteSpace($gitName))
        do { $gitEmail = Read-Host (L 'promptGitEmail') } while ([string]::IsNullOrWhiteSpace($gitEmail))
        git config --global user.name  $gitName
        git config --global user.email $gitEmail
        git config --global init.defaultBranch main
        git config --global core.autocrlf true
        git config --global core.longpaths true
        git config --global pull.rebase false
        Write-Ok ((L 'okGitId') -f $gitName, $gitEmail); Add-Result (L 'resGit') 'OK' "$gitName <$gitEmail>"
        $script:GitEmail = $gitEmail
    }
}

function New-SshKey {
    Write-Step (L 'stepSshKey')
    $sshDir  = Join-Path $env:USERPROFILE '.ssh'
    $keyPath = Join-Path $sshDir 'id_ed25519'
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
    if (Test-Path "$keyPath.pub") {
        Write-Skip ((L 'skipSshExists') -f $keyPath); Add-Result (L 'resSsh') 'SKIP' $keyPath
    } elseif ($script:DryRun) {
        Write-Host ("    [DRY]  " + ((L 'drySshKey') -f $keyPath)) -ForegroundColor Magenta
        Add-Result (L 'resSsh') 'DRY' $keyPath
    } else {
        $cmt = if ($script:GitEmail) { $script:GitEmail } else { "$env:USERNAME@$env:COMPUTERNAME" }
        ssh-keygen -t ed25519 -C $cmt -f $keyPath -N '""'
        Write-Ok (L 'okSshKey'); Add-Result (L 'resSsh') 'OK' $keyPath
    }
    if (Test-Path "$keyPath.pub") {
        Write-Host ("`n" + (L 'sshRegisterHeader')) -ForegroundColor Yellow
        Write-Host (Get-Content "$keyPath.pub" -Raw) -ForegroundColor White
        Write-Host "  ----------------------------------------------------`n" -ForegroundColor Yellow
    }
}

# ====================== 6. 설치 라인업 정의 ======================
# 각 항목: Key(내부키) / Name(표시) / Group(카테고리 키) / Installed(설치여부 검사) / Action(설치) / Requires(선행항목)
#  - Name: 양 언어 동일하면 문자열, 다르면 @{ ko='...'; en='...' }
#  - Group: $GroupNames 의 키 (표시 이름은 거기서 번역)
$Lineup = @(
    @{ Key='git';        Name='Git';                         Group='lang';
       Installed={ Test-AnyInstalled -Command 'git' -Arp 'Git','Git version*' };
       Action={ Install-WingetPackage -Id 'Git.Git' -Name 'Git' } }
    @{ Key='gh';         Name='GitHub CLI';                  Group='lang';
       Installed={ Test-AnyInstalled -Command 'gh' -Arp 'GitHub CLI*' };
       Action={ Install-WingetPackage -Id 'GitHub.cli' -Name 'GitHub CLI' } }
    @{ Key='ghdesktop';  Name='GitHub Desktop';              Group='lang';
       Installed={ Test-AnyInstalled -Arp 'GitHub Desktop*' -Path "$env:LOCALAPPDATA\GitHubDesktop\GitHubDesktop.exe" };
       Action={ Install-WingetPackage -Id 'GitHub.GitHubDesktop' -Name 'GitHub Desktop' } }
    @{ Key='node';       Name='Node.js (LTS)';               Group='lang';
       # nvm/공식 installer/비-LTS로 깐 node도 인식 -> 중복설치(1603 충돌) 예방
       Installed={ Test-AnyInstalled -Command 'node' -Arp 'Node.js*' };
       Action={ Install-WingetPackage -Id $Config.NodeId -Version $Config.NodeVersion -Name 'Node.js' } }
    @{ Key='python';     Name='Python 3.14';                 Group='lang';
       # 'python' 은 스토어 더미 오탐 위험 -> 'py' 런처 + ARP + 스토어앱으로 감지
       Installed={ Test-AnyInstalled -Command 'py' -Arp 'Python 3.*' -Appx 'PythonSoftwareFoundation.Python.3*' `
                       -Path "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe","C:\Python3*\python.exe" };
       Action={ Install-WingetPackage -Id $Config.PythonId -Version $Config.PythonVersion -Name 'Python' } }
    @{ Key='python2';    Name='Python 2.7';                  Group='lang'; DefaultOff=$true;
       # 2020 EOL — 레거시 유지보수용 옵션(기본 해제). 'python' 명령은 py3과 충돌·스토어 더미 오탐 위험이라 미사용.
       Installed={ Test-AnyInstalled -Arp 'Python 2.7*','Python 2 *' `
                       -Path 'C:\Python27\python.exe',"$env:LOCALAPPDATA\Programs\Python\Python27\python.exe" };
       Action={ Install-WingetPackage -Id 'Python.Python.2' -Name 'Python 2.7' } }
    @{ Key='dotnet';     Name='.NET SDK 10';                 Group='lang';
       # 'dotnet' 명령은 런타임만 있어도 잡혀서, SDK 전용 신호(ARP/SDK 폴더)로 감지
       Installed={ Test-AnyInstalled -Arp 'Microsoft .NET SDK*' -Path "$env:ProgramFiles\dotnet\sdk\*" };
       Action={ Install-WingetPackage -Id $Config.DotnetId -Version $Config.DotnetVersion -Name '.NET SDK' } }
    @{ Key='go';         Name='Go';                          Group='lang';
       Installed={ Test-AnyInstalled -Command 'go' -Arp 'Go Programming Language*' };
       Action={ Install-WingetPackage -Id 'GoLang.Go' -Name 'Go' } }
    @{ Key='rust';       Name='Rust';               Group='lang';
       Installed={ Test-AnyInstalled -Command 'cargo','rustup' -Path "$env:USERPROFILE\.cargo\bin\cargo.exe" };
       Action={ Install-WingetPackage -Id 'Rustlang.Rustup' -Name 'Rust' } }
    @{ Key='bun';        Name='Bun';             Group='lang';
       Installed={ Test-AnyInstalled -Command 'bun' -Path "$env:USERPROFILE\.bun\bin\bun.exe" };
       Action={ Install-WingetPackage -Id 'Oven-sh.Bun' -Name 'Bun' } }
    @{ Key='deno';       Name='Deno';      Group='lang';
       Installed={ Test-AnyInstalled -Command 'deno' -Path "$env:USERPROFILE\.deno\bin\deno.exe" };
       Action={ Install-WingetPackage -Id 'DenoLand.Deno' -Name 'Deno' } }
    @{ Key='pnpm';       Name='pnpm';                        Group='lang';
       Installed={ Test-AnyInstalled -Command 'pnpm' -Path "$env:LOCALAPPDATA\pnpm\pnpm.exe" };
       Action={ Install-WingetPackage -Id 'pnpm.pnpm' -Name 'pnpm' } }
    @{ Key='yarn';       Name='Yarn';                        Group='lang';
       # corepack/npm 으로도 흔히 깔리므로 MSI ARP 뿐 아니라 PATH 의 yarn 명령도 인정
       Installed={ Test-AnyInstalled -Command 'yarn' -Arp 'Yarn*' };
       Action={ Install-WingetPackage -Id 'Yarn.Yarn' -Name 'Yarn' } }
    @{ Key='fnm';        Name='fnm';                         Group='lang';
       Installed={ Test-AnyInstalled -Command 'fnm' };
       Action={ Install-WingetPackage -Id 'Schniz.fnm' -Name 'fnm' } }
    @{ Key='pyenv';      Name='pyenv';                       Group='lang';
       # winget 미제공 -> choco pyenv-win. exe 가 아니라 pyenv.bat(명령 'pyenv'), ARP 미등록 -> 경로로도 감지
       Installed={ Test-AnyInstalled -Command 'pyenv' -Path "$env:USERPROFILE\.pyenv\pyenv-win\bin\pyenv.bat" };
       Action={ Install-ChocoPackage -Pkg 'pyenv-win' -Name 'pyenv' `
                    -InstalledCheck { Test-Path "$env:USERPROFILE\.pyenv\pyenv-win\bin\pyenv.bat" } };
       Requires=@('choco') }
    @{ Key='jdk17';      Name='OpenJDK 17';                  Group='lang';
       # JDK 는 벤더 무관·버전별로 감지 (Android 가 선행 요구하는 호환 기준선). Install-OpenJdk 와 동일 판정 공유.
       Installed={ Test-JdkInstalled '17' };
       Action={ Install-OpenJdk -Version '17' } }
    @{ Key='jdk21';      Name='OpenJDK 21';                  Group='lang'; DefaultOff=$true;
       # 17 이 Android 호환 기준선이라 기본 체크. 21/25 는 필요한 사람만 직접 체크(opt-in)
       Installed={ Test-JdkInstalled '21' };
       Action={ Install-OpenJdk -Version '21' } }
    @{ Key='jdk25';      Name='OpenJDK 25';                  Group='lang'; DefaultOff=$true;
       Installed={ Test-JdkInstalled '25' };
       Action={ Install-OpenJdk -Version '25' } }

    @{ Key='vscode';     Name='VS Code';                     Group='editor';
       Installed={ Test-AnyInstalled -Command 'code' -Arp '*Visual Studio Code*' };
       Action={ Install-WingetPackage -Id 'Microsoft.VisualStudioCode' -Name 'VS Code' } }
    @{ Key='vs';         Name='Visual Studio Community 2026'; Group='editor';
       # winget 조회는 VS Installer 엔진을 깨워 멈출 수 있어 폴더/ARP로만 감지
       Installed={ Test-AnyInstalled -Arp 'Visual Studio Community*' `
                       -Path 'C:\Program Files\Microsoft Visual Studio\*\Community','C:\Program Files (x86)\Microsoft Visual Studio\*\Community' };
       Action={ Install-WingetPackage -Id 'Microsoft.VisualStudio.Community' -Name 'Visual Studio Community 2026' } }
    @{ Key='buildtools'; Name='VS Build Tools';        Group='editor';
       Installed={ Test-AnyInstalled -Arp 'Visual Studio Build Tools*' `
                       -Path 'C:\Program Files\Microsoft Visual Studio\*\BuildTools','C:\Program Files (x86)\Microsoft Visual Studio\*\BuildTools' };
       Action={ Install-WingetPackage -Id 'Microsoft.VisualStudio.2022.BuildTools' -Name 'VS Build Tools' `
                    -ExtraArgs @('--override','--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended') } }
    @{ Key='notepadpp';  Name='Notepad++';                   Group='editor';
       Installed={ Test-AnyInstalled -Arp 'Notepad++*' -Path "$env:ProgramFiles\Notepad++\notepad++.exe","${env:ProgramFiles(x86)}\Notepad++\notepad++.exe" };
       Action={ Install-WingetPackage -Id 'Notepad++.Notepad++' -Name 'Notepad++' } }

    @{ Key='cursor';     Name='Cursor';          Group='aiEditor';
       Installed={ Test-AnyInstalled -Command 'cursor' -Arp 'Cursor*' -Path "$env:LOCALAPPDATA\Programs\cursor\Cursor.exe" };
       Action={ Install-WingetPackage -Id 'Anysphere.Cursor' -Name 'Cursor' } }
    @{ Key='windsurf';   Name='Windsurf';        Group='aiEditor';
       Installed={ Test-AnyInstalled -Command 'windsurf' -Arp 'Windsurf*' -Path "$env:LOCALAPPDATA\Programs\Windsurf\Windsurf.exe" };
       Action={ Install-WingetPackage -Id 'Codeium.Windsurf' -Name 'Windsurf' } }
    @{ Key='zed';        Name='Zed';             Group='aiEditor';
       Installed={ Test-AnyInstalled -Command 'zed' -Arp 'Zed','Zed Editor*' -Path "$env:LOCALAPPDATA\Programs\Zed\Zed.exe" };
       Action={ Install-WingetPackage -Id 'ZedIndustries.Zed' -Name 'Zed' } }

    @{ Key='claudecode'; Name='Claude Code';                 Group='aiAgent';
       # winget 버전은 자체 업데이트가 막혀 구버전 고착 -> 공식 네이티브 설치(~/.local/bin + 백그라운드 자동 업데이트)
       Installed={ Test-AnyInstalled -Command 'claude' -Path "$env:USERPROFILE\.local\bin\claude.exe","$env:APPDATA\npm\claude.cmd" };
       Action={ Install-ViaScript -Name 'Claude Code' -Url $Config.ClaudeCodeUrl `
                    -InstalledCheck { Test-AnyInstalled -Command 'claude' -Path "$env:USERPROFILE\.local\bin\claude.exe","$env:APPDATA\npm\claude.cmd" } } }
    @{ Key='codex';      Name='Codex CLI';                   Group='aiAgent';
       # 네이티브 설치 경로(~/.local/bin)·~/.codex/bin·npm 전역 어디든 탐지
       Installed={ Test-AnyInstalled -Command 'codex' -Path "$env:USERPROFILE\.local\bin\codex.exe","$env:USERPROFILE\.codex\bin\codex.exe","$env:APPDATA\npm\codex.cmd" };
       Action={ Install-ViaScript -Name 'Codex CLI' -Url $Config.CodexUrl `
                    -InstalledCheck { Test-AnyInstalled -Command 'codex' -Path "$env:USERPROFILE\.local\bin\codex.exe","$env:USERPROFILE\.codex\bin\codex.exe","$env:APPDATA\npm\codex.cmd" } } }

    @{ Key='terminal';   Name='Windows Terminal';            Group='terminal';
       Installed={ Test-AnyInstalled -Appx 'Microsoft.WindowsTerminal' -Arp 'Windows Terminal*' };
       Action={ Install-WingetPackage -Id 'Microsoft.WindowsTerminal' -Name 'Windows Terminal' } }
    @{ Key='cmder';      Name='Cmder';      Group='terminal';
       Installed={ Test-AnyInstalled -Path 'C:\tools\Cmder\Cmder.exe' -Arp 'Cmder*' };
       Action={ Install-ChocoPackage -Pkg 'Cmder' -Name 'Cmder' `
                    -InstalledCheck { Test-Path 'C:\tools\Cmder\Cmder.exe' } };
       Requires=@('choco') }
    @{ Key='wezterm';    Name='WezTerm';                     Group='terminal';
       Installed={ Test-AnyInstalled -Command 'wezterm' -Arp 'WezTerm*' };
       Action={ Install-WingetPackage -Id 'wez.wezterm' -Name 'WezTerm' } }
    @{ Key='tabby';      Name='Tabby';                       Group='terminal';
       Installed={ Test-AnyInstalled -Command 'tabby' -Arp 'Tabby*' -Path "$env:LOCALAPPDATA\Programs\Tabby\Tabby.exe" };
       Action={ Install-WingetPackage -Id 'Eugeny.Tabby' -Name 'Tabby' } }
    @{ Key='warp';       Name='Warp';                        Group='terminal'; DefaultOff=$true;
       # 기본 해제(opt-in): winget 패키지(Warp.Warp)의 app.warp.dev 다운로드가 막판(~115/125MB)에서
       # 반복적으로 정체돼 설치가 자주 실패한다(2026-07 여러 환경에서 확인). CDN이 안정화되면 DefaultOff 를 지워 기본 체크로 되돌린다.
       # Cloudflare 'WARP' VPN(ARP 'Cloudflare WARP')과 다른 제품 — 'Warp*' 글롭은 그쪽을 안 잡는다
       Installed={ Test-AnyInstalled -Arp 'Warp*' -Path "$env:LOCALAPPDATA\Programs\Warp\warp.exe" };
       Action={ Install-WingetPackage -Id 'Warp.Warp' -Name 'Warp' } }

    @{ Key='pwsh7';      Name='PowerShell 7';                Group='buildCli';
       Installed={ Test-AnyInstalled -Command 'pwsh' -Arp 'PowerShell 7*' };
       Action={ Install-WingetPackage -Id 'Microsoft.PowerShell' -Name 'PowerShell 7' } }
    @{ Key='cmake';      Name='CMake';                       Group='buildCli';
       Installed={ Test-AnyInstalled -Command 'cmake' -Arp 'CMake*' };
       Action={ Install-WingetPackage -Id 'Kitware.CMake' -Name 'CMake' } }
    @{ Key='jq';         Name='jq';               Group='buildCli';
       Installed={ Test-AnyInstalled -Command 'jq' };
       Action={ Install-WingetPackage -Id 'jqlang.jq' -Name 'jq' } }
    @{ Key='ripgrep';    Name='ripgrep';         Group='buildCli';
       Installed={ Test-AnyInstalled -Command 'rg' -Arp 'ripgrep*' };
       Action={ Install-WingetPackage -Id 'BurntSushi.ripgrep.MSVC' -Name 'ripgrep' } }

    @{ Key='bat';        Name='bat';                         Group='cliTools';
       Installed={ Test-AnyInstalled -Command 'bat' };
       Action={ Install-WingetPackage -Id 'sharkdp.bat' -Name 'bat' } }
    @{ Key='fd';         Name='fd';                          Group='cliTools';
       Installed={ Test-AnyInstalled -Command 'fd' };
       Action={ Install-WingetPackage -Id 'sharkdp.fd' -Name 'fd' } }
    @{ Key='fzf';        Name='fzf';                         Group='cliTools';
       Installed={ Test-AnyInstalled -Command 'fzf' };
       Action={ Install-WingetPackage -Id 'junegunn.fzf' -Name 'fzf' } }
    @{ Key='eza';        Name='eza';                         Group='cliTools';
       # 포터블 zip 설치라 ARP 미등록이 흔함 -> 명령으로 감지
       Installed={ Test-AnyInstalled -Command 'eza' };
       Action={ Install-WingetPackage -Id 'eza-community.eza' -Name 'eza' } }
    @{ Key='neovim';     Name='Neovim';                      Group='cliTools';
       Installed={ Test-AnyInstalled -Command 'nvim' -Arp 'Neovim*' };
       Action={ Install-WingetPackage -Id 'Neovim.Neovim' -Name 'Neovim' } }
    @{ Key='tldr';       Name='tldr';                        Group='cliTools';
       # winget 패키지명은 tlrc(Rust 클라이언트)이지만 제공 명령은 'tldr'
       Installed={ Test-AnyInstalled -Command 'tldr' };
       Action={ Install-WingetPackage -Id 'tldr-pages.tlrc' -Name 'tldr' } }
    @{ Key='lazygit';    Name='lazygit';                     Group='cliTools';
       Installed={ Test-AnyInstalled -Command 'lazygit' };
       Action={ Install-WingetPackage -Id 'JesseDuffield.lazygit' -Name 'lazygit' } }
    @{ Key='mkcert';     Name='mkcert';                      Group='cliTools';
       Installed={ Test-AnyInstalled -Command 'mkcert' };
       Action={ Install-WingetPackage -Id 'FiloSottile.mkcert' -Name 'mkcert' } }
    @{ Key='direnv';     Name='direnv';                      Group='cliTools';
       Installed={ Test-AnyInstalled -Command 'direnv' };
       Action={ Install-WingetPackage -Id 'direnv.direnv' -Name 'direnv' } }
    @{ Key='httpie';     Name='HTTPie';                      Group='cliTools';
       # httpie 의 명령은 http/https (httpie 명령 없음). 'http' 충돌 대비로 ARP 도 본다
       Installed={ Test-AnyInstalled -Command 'http','https' -Arp 'HTTPie*' };
       Action={ Install-WingetPackage -Id 'HTTPie.HTTPie' -Name 'HTTPie' } }
    @{ Key='watchman';   Name='Watchman';                    Group='cliTools';
       Installed={ Test-AnyInstalled -Command 'watchman' };
       Action={ Install-WingetPackage -Id 'facebook.watchman' -Name 'Watchman' } }

    @{ Key='chrome';     Name='Google Chrome';               Group='browser';
       # 설치 ID는 .EXE 로 통일(winget 'Google.Chrome'와 별개), 감지는 실제 경로/ARP로
       Installed={ Test-AnyInstalled -Arp 'Google Chrome*' `
                       -Path "$env:ProgramFiles\Google\Chrome\Application\chrome.exe","${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe","$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe" };
       Action={ Install-WingetPackage -Id 'Google.Chrome.EXE' -Name 'Google Chrome' } }
    @{ Key='firefox';    Name='Firefox';                     Group='browser';
       Installed={ Test-AnyInstalled -Arp 'Mozilla Firefox*' -Path "$env:ProgramFiles\Mozilla Firefox\firefox.exe","${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe" };
       Action={ Install-WingetPackage -Id 'Mozilla.Firefox' -Name 'Firefox' } }
    @{ Key='brave';      Name='Brave';                       Group='browser';
       Installed={ Test-AnyInstalled -Arp 'Brave*' -Path "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe","${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe","$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe" };
       Action={ Install-WingetPackage -Id 'Brave.Brave' -Name 'Brave' } }

    @{ Key='powertoys';  Name='PowerToys';                   Group='util';
       Installed={ Test-AnyInstalled -Arp 'PowerToys*','Microsoft PowerToys*' -Appx 'Microsoft.PowerToys' };
       Action={ Install-WingetPackage -Id 'Microsoft.PowerToys' -Name 'PowerToys' } }
    @{ Key='7zip';       Name='7-Zip';                       Group='util';
       Installed={ Test-AnyInstalled -Arp '7-Zip*' -Path "$env:ProgramFiles\7-Zip\7z.exe","${env:ProgramFiles(x86)}\7-Zip\7z.exe" };
       Action={ Install-WingetPackage -Id '7zip.7zip' -Name '7-Zip' } }
    @{ Key='uv';         Name='uv';     Group='util';
       # winget 설치본은 'uv self update' 가 비활성 -> 공식 스크립트로 설치해야 self-update 동작
       Installed={ Test-AnyInstalled -Command 'uv' -Path "$env:USERPROFILE\.local\bin\uv.exe" };
       Action={ Install-ViaScript -Name 'uv' -Url $Config.UvUrl `
                    -InstalledCheck { Test-AnyInstalled -Command 'uv' -Path "$env:USERPROFILE\.local\bin\uv.exe" } } }
    @{ Key='winmerge';   Name='WinMerge';                    Group='util';
       Installed={ Test-AnyInstalled -Arp 'WinMerge*' -Path "$env:ProgramFiles\WinMerge\WinMergeU.exe","${env:ProgramFiles(x86)}\WinMerge\WinMergeU.exe" };
       Action={ Install-WingetPackage -Id 'WinMerge.WinMerge' -Name 'WinMerge' } }
    @{ Key='everything'; Name='Everything';                  Group='util';
       Installed={ Test-AnyInstalled -Arp 'Everything*' -Path "$env:ProgramFiles\Everything\Everything.exe","${env:ProgramFiles(x86)}\Everything\Everything.exe" };
       Action={ Install-WingetPackage -Id 'voidtools.Everything' -Name 'Everything' } }
    @{ Key='sharex';     Name='ShareX';                      Group='util';
       Installed={ Test-AnyInstalled -Arp 'ShareX*' -Path "$env:ProgramFiles\ShareX\ShareX.exe","$env:LOCALAPPDATA\Programs\ShareX\ShareX.exe" };
       Action={ Install-WingetPackage -Id 'ShareX.ShareX' -Name 'ShareX' } }
    @{ Key='gpg4win';    Name='Gpg4win';                     Group='util';
       Installed={ Test-AnyInstalled -Command 'gpg' -Arp 'Gpg4win*','GnuPG*' -Path "${env:ProgramFiles(x86)}\GnuPG\bin\gpg.exe","$env:ProgramFiles\GnuPG\bin\gpg.exe" };
       Action={ Install-WingetPackage -Id 'GnuPG.Gpg4win' -Name 'Gpg4win' } }
    @{ Key='ohmyposh';   Name='oh-my-posh';                  Group='util';
       # winget 은 MSIX(Appx)로 설치될 수 있어 ARP/Programs 경로가 안 잡힘 -> Appx 신호를 함께 본다
       Installed={ Test-AnyInstalled -Command 'oh-my-posh' -Arp 'Oh My Posh*' -Appx 'JanDeDobbeleer.OhMyPosh' -Path "$env:LOCALAPPDATA\Programs\oh-my-posh\bin\oh-my-posh.exe" };
       Action={ Install-WingetPackage -Id 'JanDeDobbeleer.OhMyPosh' -Name 'oh-my-posh' } }

    @{ Key='slack';      Name='Slack';                       Group='collab';
       Installed={ Test-AnyInstalled -Arp 'Slack*' -Path "$env:LOCALAPPDATA\slack\slack.exe" };
       Action={ Install-WingetPackage -Id 'SlackTechnologies.Slack' -Name 'Slack' } }
    @{ Key='discord';    Name='Discord';                     Group='collab';
       Installed={ Test-AnyInstalled -Arp 'Discord*' -Path "$env:LOCALAPPDATA\Discord\Update.exe" };
       Action={ Install-WingetPackage -Id 'Discord.Discord' -Name 'Discord' } }
    @{ Key='zoom';       Name='Zoom';                        Group='collab';
       Installed={ Test-AnyInstalled -Arp 'Zoom*','Zoom Workplace*' -Path "$env:APPDATA\Zoom\bin\Zoom.exe","$env:ProgramFiles\Zoom\bin\Zoom.exe","${env:ProgramFiles(x86)}\Zoom\bin\Zoom.exe" };
       Action={ Install-WingetPackage -Id 'Zoom.Zoom' -Name 'Zoom' } }
    @{ Key='notion';     Name='Notion';                      Group='collab';
       Installed={ Test-AnyInstalled -Arp 'Notion*' -Path "$env:LOCALAPPDATA\Programs\Notion\Notion.exe" };
       Action={ Install-WingetPackage -Id 'Notion.Notion' -Name 'Notion' } }
    @{ Key='obsidian';   Name='Obsidian';                    Group='collab';
       # Obsidian NSIS 설치 경로는 %LOCALAPPDATA%\Obsidian (Programs\ 하위 아님) — 두 경로 모두 확인
       Installed={ Test-AnyInstalled -Arp 'Obsidian*' -Path "$env:LOCALAPPDATA\Obsidian\Obsidian.exe","$env:LOCALAPPDATA\Programs\obsidian\Obsidian.exe" };
       Action={ Install-WingetPackage -Id 'Obsidian.Obsidian' -Name 'Obsidian' } }

    @{ Key='dbeaver';    Name='DBeaver'; Group='dbApi';
       Installed={ Test-AnyInstalled -Arp 'DBeaver*' -Path "$env:ProgramFiles\DBeaver\dbeaver.exe","$env:LOCALAPPDATA\DBeaver\dbeaver.exe" };
       Action={ Install-WingetPackage -Id 'DBeaver.DBeaver.Community' -Name 'DBeaver' } }
    @{ Key='sqlyog';     Name='SQLyog Community'; Group='dbApi';
       # SQLyog 는 표준 ARP 등록을 안 해서 ARP만으론 못 잡음 -> 실제 exe 경로로 감지
       Installed={ Test-AnyInstalled -Arp 'SQLyog*' `
                       -Path "$env:ProgramFiles\SQLyog Community\SQLyogCommunity.exe","${env:ProgramFiles(x86)}\SQLyog Community\SQLyogCommunity.exe","$env:ProgramFiles\SQLyog\SQLyog.exe","${env:ProgramFiles(x86)}\SQLyog\SQLyog.exe" };
       Action={ Install-WingetPackage -Id 'Webyog.SQLyogCommunity' -Name 'SQLyog Community' } }
    @{ Key='postgresql'; Name='PostgreSQL 18';     Group='dbApi';
       Installed={ Test-AnyInstalled -Command 'psql' -Arp 'PostgreSQL*' };
       Action={ Install-WingetPackage -Id 'PostgreSQL.PostgreSQL.18' -Name 'PostgreSQL 18' } }
    @{ Key='mysql';      Name='MySQL';             Group='dbApi';
       Installed={ Test-AnyInstalled -Command 'mysql' -Arp 'MySQL Server*','MySQL Installer*' };
       Action={ Install-WingetPackage -Id 'Oracle.MySQL' -Name 'MySQL' } }
    @{ Key='mongocompass'; Name='MongoDB Compass'; Group='dbApi';
       Installed={ Test-AnyInstalled -Arp 'MongoDB Compass*' -Path "$env:LOCALAPPDATA\MongoDBCompass\MongoDBCompass.exe" };
       Action={ Install-WingetPackage -Id 'MongoDB.Compass.Full' -Name 'MongoDB Compass' } }
    @{ Key='postman';    Name='Postman';        Group='dbApi';
       Installed={ Test-AnyInstalled -Arp 'Postman*' -Path "$env:LOCALAPPDATA\Postman\Postman.exe" };
       Action={ Install-WingetPackage -Id 'Postman.Postman' -Name 'Postman' } }
    @{ Key='bruno';      Name='Bruno';          Group='dbApi';
       Installed={ Test-AnyInstalled -Command 'bru' -Arp 'Bruno*' -Path "$env:LOCALAPPDATA\Programs\Bruno\Bruno.exe" };
       Action={ Install-WingetPackage -Id 'Bruno.Bruno' -Name 'Bruno' } }
    @{ Key='insomnia';   Name='Insomnia';       Group='dbApi';
       Installed={ Test-AnyInstalled -Arp 'Insomnia*' -Path "$env:LOCALAPPDATA\Programs\Insomnia\Insomnia.exe" };
       Action={ Install-WingetPackage -Id 'Insomnia.Insomnia' -Name 'Insomnia' } }
    @{ Key='tableplus';  Name='TablePlus';      Group='dbApi';
       Installed={ Test-AnyInstalled -Arp 'TablePlus*' -Path "$env:LOCALAPPDATA\Programs\TablePlus\TablePlus.exe" };
       Action={ Install-WingetPackage -Id 'TablePlus.TablePlus' -Name 'TablePlus' } }
    @{ Key='dbsqlite';   Name='DB Browser for SQLite'; Group='dbApi';
       Installed={ Test-AnyInstalled -Arp 'DB Browser for SQLite*' -Path "$env:ProgramFiles\DB Browser for SQLite\DB Browser for SQLite.exe" };
       Action={ Install-WingetPackage -Id 'DBBrowserForSQLite.DBBrowserForSQLite' -Name 'DB Browser for SQLite' } }
    @{ Key='redisinsight'; Name='Redis Insight'; Group='dbApi';
       # ARP DisplayName 도 'Redis Insight'(공백, 단일어 id 와 다름). 스토어(Appx)로도 설치 가능.
       Installed={ Test-AnyInstalled -Arp 'Redis Insight*' -Path "$env:LOCALAPPDATA\Programs\redisinsight\RedisInsight.exe" -Appx 'RedisInsight*' };
       Action={ Install-WingetPackage -Id 'RedisInsight.RedisInsight' -Name 'Redis Insight' } }

    @{ Key='putty';      Name='PuTTY';       Group='sshFile';
       Installed={ Test-AnyInstalled -Command 'putty' -Arp 'PuTTY*' };
       Action={ Install-WingetPackage -Id 'PuTTY.PuTTY' -Name 'PuTTY' } }
    @{ Key='winscp';     Name='WinSCP';        Group='sshFile';
       Installed={ Test-AnyInstalled -Command 'winscp' -Arp 'WinSCP*' };
       Action={ Install-WingetPackage -Id 'WinSCP.WinSCP' -Name 'WinSCP' } }
    @{ Key='filezilla';  Name='FileZilla';     Group='sshFile';
       Installed={ Test-AnyInstalled -Arp 'FileZilla*' -Path 'C:\Program Files\FileZilla FTP Client\filezilla.exe' };
       Action={ Install-ChocoPackage -Pkg 'filezilla' -Name 'FileZilla' `
                    -InstalledCheck { Test-Path 'C:\Program Files\FileZilla FTP Client\filezilla.exe' } };
       Requires=@('choco') }

    @{ Key='choco';      Name='Chocolatey';    Group='pkgMgr';
       Installed={ [bool](Get-Command choco -ErrorAction SilentlyContinue) };
       Action={ Install-Chocolatey } }

    @{ Key='docker';     Name='Docker Desktop';       Group='container';
       Installed={ Test-AnyInstalled -Command 'docker' -Arp 'Docker Desktop*' };
       Action={ Install-DockerDesktop } }

    @{ Key='awscli';     Name='AWS CLI';                     Group='cloud';
       Installed={ Test-AnyInstalled -Command 'aws' -Arp 'AWS Command Line Interface*' };
       Action={ Install-WingetPackage -Id 'Amazon.AWSCLI' -Name 'AWS CLI' } }
    @{ Key='azurecli';   Name='Azure CLI';                   Group='cloud';
       Installed={ Test-AnyInstalled -Command 'az' -Arp 'Microsoft Azure CLI*' };
       Action={ Install-WingetPackage -Id 'Microsoft.AzureCLI' -Name 'Azure CLI' } }
    @{ Key='gcloud';     Name='Google Cloud SDK';   Group='cloud';
       Installed={ Test-AnyInstalled -Command 'gcloud' -Arp 'Google Cloud*' -Path "$env:LOCALAPPDATA\Google\Cloud SDK" };
       Action={ Install-WingetPackage -Id 'Google.CloudSDK' -Name 'Google Cloud SDK' } }
    @{ Key='kubectl';    Name='kubectl';    Group='cloud';
       Installed={ Test-AnyInstalled -Command 'kubectl' };
       Action={ Install-WingetPackage -Id 'Kubernetes.kubectl' -Name 'kubectl' } }
    @{ Key='terraform';  Name='Terraform';                   Group='cloud';
       Installed={ Test-AnyInstalled -Command 'terraform' };
       Action={ Install-WingetPackage -Id 'Hashicorp.Terraform' -Name 'Terraform' } }
    @{ Key='helm';       Name='Helm';                        Group='cloud';
       Installed={ Test-AnyInstalled -Command 'helm' };
       Action={ Install-WingetPackage -Id 'Helm.Helm' -Name 'Helm' } }
    @{ Key='k9s';        Name='k9s';                         Group='cloud';
       Installed={ Test-AnyInstalled -Command 'k9s' };
       Action={ Install-WingetPackage -Id 'Derailed.k9s' -Name 'k9s' } }
    @{ Key='kubectx';    Name='kubectx';                     Group='cloud';
       # winget 에서 kubectx/kubens 는 별개 패키지 -> 둘 다 설치, 둘 중 하나라도 있으면 설치된 것으로 본다
       Installed={ Test-AnyInstalled -Command 'kubectx','kubens' };
       Action={ Install-WingetPackage -Id 'ahmetb.kubectx' -Name 'kubectx'; Install-WingetPackage -Id 'ahmetb.kubens' -Name 'kubens' } }

    @{ Key='flutter';    Name='Flutter SDK';                  Group='flutterAndroid';
       Installed={ Test-AnyInstalled -Command 'flutter' -Path 'C:\tools\flutter\bin\flutter.bat','C:\flutter\bin\flutter.bat' };
       Action={ Install-Flutter };  Requires=@('choco') }
    @{ Key='android';    Name='Android SDK';  Group='flutterAndroid';
       # C:\Android 뿐 아니라 Android Studio 기본경로(%LOCALAPPDATA%\Android\Sdk)·환경변수까지 확인
       Installed={ Test-AndroidSdkInstalled };
       Action={ Install-AndroidSdk };  Requires=@('jdk17') }

    @{ Key='gitcfg';     Name=@{ ko='Git 사용자 설정 + 권장 옵션'; en='Git config + recommended options' };  Group='config';
       Installed={ [bool](git config --global user.name 2>$null) -and [bool](git config --global user.email 2>$null) };
       Action={ Set-GitIdentity };  Requires=@('git') }
    @{ Key='sshkey';     Name=@{ ko='SSH 키 생성'; en='SSH key generation' };         Group='config';
       Installed={ Test-Path (Join-Path $env:USERPROFILE '.ssh\id_ed25519.pub') };
       Action={ New-SshKey } }
)

# ====================== 7. 설치 상태 조회 + 선택 창 ======================
# Ninite 스타일 선택 창: 카테고리를 접는 트리 대신, 한눈에 보이는 카테고리 그리드.
#  - 각 카테고리 = 굵은 제목 + 밑줄 + 그 아래 체크박스 항목들. 제목 클릭 시 그룹 전체 토글.
#  - 이미 설치된 항목은 회색·'✓ 설치됨' 표시 + 기본 해제. 하단 '전체 선택/해제' 버튼.
#  - 우상단 언어 드롭다운(한국어/English): 구조는 고정, 텍스트만 교체하므로 체크 상태가 그대로 유지됨.
#  - 반응형: 열 개수·창 크기를 화면 작업영역과 항목 수에서 계산(기본 4열). 항목이 늘면 창이 커지다
#    화면을 넘기면 열을 늘리고, 그래도 넘치면 본문 세로 스크롤로 흡수 → 어떤 화면/항목 수에서도 안 잘림.
function Show-InstallSelection {
    param([object[]]$Items)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $accent = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $muted  = [System.Drawing.Color]::FromArgb(140, 140, 140)
    $line   = [System.Drawing.Color]::FromArgb(225, 225, 225)
    $dark   = [System.Drawing.Color]::FromArgb(28, 28, 28)
    $hdrCol = [System.Drawing.Color]::FromArgb(33, 37, 43)

    # --- 화면/항목 수에 맞춘 반응형 지오메트리 (열 폭·간격은 상수, 열 수·창 크기는 계산) ---
    $pad = 24; $colW = 262; $colGap = 18; $scrollW = 18
    $headerH = 32; $itemH = 25; $blockGap = 14
    $bodyTop = 82; $footerReserve = 74
    $colSlot = $colW + $colGap

    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $maxColsFit = [int][Math]::Max(1, [Math]::Floor(($wa.Width - 2 * $pad - $scrollW + $colGap) / $colSlot))
    $maxClientH = $wa.Height - 64                        # 타이틀바·테두리·여백 대략 예약
    $maxBodyH   = $maxClientH - $bodyTop - $footerReserve
    $rowsCap    = [int][Math]::Max(8, [Math]::Floor($maxBodyH / $itemH))   # 스크롤 없이 한 열에 담기는 대략 행 수

    # 그룹(첫 등장 순서) + 가중치(헤더 1 + 항목 수)
    $groups = @()
    foreach ($it in $Items) { if ($groups -notcontains $it.GroupKey) { $groups += $it.GroupKey } }
    $weights = @{}
    foreach ($g in $groups) { $weights[$g] = 1 + (@($Items | Where-Object { $_.GroupKey -eq $g }).Count) }
    $total = 0; foreach ($g in $groups) { $total += $weights[$g] }

    # 기본 4열. 화면이 좁으면 줄이고(maxColsFit), 항목이 많아 한 열이 너무 길어지면 폭이 허용하는 한 열을 늘림.
    $nCols = [int][Math]::Min(4, $maxColsFit)
    while ($nCols -lt $maxColsFit -and ($total / $nCols) -gt $rowsCap) { $nCols++ }
    $nCols = [int][Math]::Max(1, [Math]::Min($nCols, $groups.Count))      # 그룹 수보다 많은 빈 열 방지

    $gridW   = $nCols * $colW + ($nCols - 1) * $colGap
    $bodyW   = $gridW + $scrollW
    $clientW = 2 * $pad + $bodyW

    # 카테고리를 순서대로 채우되 열 높이가 균형을 이루도록 분배 (누적이 목표를 넘기려 하면 다음 열로).
    $target = $total / $nCols
    $colIndexOf = @{}
    $ci = 0; $cur = 0
    foreach ($g in $groups) {
        if ($ci -lt ($nCols - 1) -and $cur -gt 0 -and ($cur + $weights[$g] / 2) -gt $target) { $ci++; $cur = 0 }
        $colIndexOf[$g] = $ci
        $cur += $weights[$g]
    }
    $colX = @(); for ($i = 0; $i -lt $nCols; $i++) { $colX += ($i * $colSlot) }   # 본문 패널 기준 로컬 X
    $colY = @(); for ($i = 0; $i -lt $nCols; $i++) { $colY += 8 }

    $childFont = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Regular)
    $hdrFont   = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)

    $form = New-Object System.Windows.Forms.Form
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MinimizeBox = $false; $form.MaximizeBox = $false
    $form.TopMost = $true
    $form.BackColor = [System.Drawing.Color]::White
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    # --- 헤더 (제목 / 부제 / 언어 드롭다운) ---
    $title = New-Object System.Windows.Forms.Label
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $dark
    $title.Location = New-Object System.Drawing.Point($pad, 15)
    $title.AutoSize = $true
    $form.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.ForeColor = $muted
    $subtitle.Location = New-Object System.Drawing.Point(($pad + 2), 47)
    $subtitle.AutoSize = $true
    $form.Controls.Add($subtitle)

    $cmbLang = New-Object System.Windows.Forms.ComboBox
    $cmbLang.DropDownStyle = 'DropDownList'
    $cmbLang.Location = New-Object System.Drawing.Point(($clientW - $pad - 120), 17)
    $cmbLang.Size = New-Object System.Drawing.Size(120, 24)
    [void]$cmbLang.Items.Add('한국어')
    [void]$cmbLang.Items.Add('English')
    $cmbLang.SelectedIndex = $(if ($script:Lang -eq 'ko') { 0 } else { 1 })
    $form.Controls.Add($cmbLang)

    $lblLang = New-Object System.Windows.Forms.Label
    $lblLang.AutoSize = $true
    $lblLang.ForeColor = $muted
    $lblLang.Location = New-Object System.Drawing.Point(($clientW - $pad - 120 - 66), 21)
    $form.Controls.Add($lblLang)

    # 헤더/본문 구분선
    $sep1 = New-Object System.Windows.Forms.Panel
    $sep1.Location = New-Object System.Drawing.Point($pad, 76)
    $sep1.Size = New-Object System.Drawing.Size($bodyW, 1)
    $sep1.BackColor = $line
    $form.Controls.Add($sep1)

    # --- 본문: 스크롤 가능한 카테고리 그리드 (높이는 빌드 후 콘텐츠에 맞춰 확정) ---
    $body = New-Object System.Windows.Forms.Panel
    $body.Location = New-Object System.Drawing.Point($pad, $bodyTop)
    $body.Size = New-Object System.Drawing.Size($bodyW, $maxBodyH)
    $body.AutoScroll = $true
    $body.BackColor = [System.Drawing.Color]::White
    $form.Controls.Add($body)
    $body.SuspendLayout()

    # 언어 전환 시 텍스트만 다시 칠하기 위해 컨트롤 참조를 보관 (구조는 재생성하지 않음)
    $headerControls = New-Object System.Collections.Generic.List[object]
    $itemControls   = New-Object System.Collections.Generic.List[object]

    foreach ($g in $groups) {
        $cix = $colIndexOf[$g]
        $x = $colX[$cix]
        $members = @($Items | Where-Object { $_.GroupKey -eq $g })

        # 카테고리 헤더 (클릭하면 그룹 전체 토글)
        $hdr = New-Object System.Windows.Forms.Label
        $hdr.Font = $hdrFont
        $hdr.ForeColor = $hdrCol
        $hdr.AutoSize = $false
        $hdr.Location = New-Object System.Drawing.Point($x, $colY[$cix])
        $hdr.Size = New-Object System.Drawing.Size($colW, 22)
        $hdr.TextAlign = 'MiddleLeft'
        $hdr.Cursor = [System.Windows.Forms.Cursors]::Hand
        $body.Controls.Add($hdr)
        $headerControls.Add([pscustomobject]@{ Label = $hdr; Key = $g })

        # 헤더 밑줄
        $ul = New-Object System.Windows.Forms.Panel
        $ul.Location = New-Object System.Drawing.Point($x, ($colY[$cix] + 24))
        $ul.Size = New-Object System.Drawing.Size($colW, 1)
        $ul.BackColor = $line
        $body.Controls.Add($ul)

        $colY[$cix] += $headerH

        $grpCtrls = New-Object System.Collections.Generic.List[object]
        foreach ($m in $members) {
            $cb = New-Object System.Windows.Forms.CheckBox
            $cb.Font = $childFont
            $cb.AutoSize = $false
            $cb.Location = New-Object System.Drawing.Point($x, $colY[$cix])
            $cb.Size = New-Object System.Drawing.Size($colW, 22)
            $cb.TextAlign = 'MiddleLeft'
            $cb.Checked = (-not $m.IsInstalled) -and (-not $m.DefaultOff)   # 미설치 항목만 기본 체크 (DefaultOff 항목은 제외)
            if ($m.IsInstalled) { $cb.ForeColor = $muted }   # 설치된 항목은 회색으로 흐리게
            $body.Controls.Add($cb)
            $rec = [pscustomobject]@{ Cb = $cb; Installed = [bool]$m.IsInstalled; Key = [string]$m.Key; NameRaw = $m.NameRaw }
            $itemControls.Add($rec)
            $grpCtrls.Add($rec)
            $colY[$cix] += $itemH
        }
        $colY[$cix] += $blockGap

        # 그룹 제목 클릭: 미설치 항목이 모두 체크돼 있으면 그룹 전체 해제, 아니면 미설치 전체 체크.
        # GetNewClosure 로 이 그룹의 체크박스 목록($grpCtrls)을 캡처 (반복문 변수 스냅샷). $script:Lang 는 건드리지 않음.
        $hdr.Add_Click({
            $allOn = $true
            foreach ($r in $grpCtrls) { if (-not $r.Installed -and -not $r.Cb.Checked) { $allOn = $false; break } }
            foreach ($r in $grpCtrls) {
                if ($allOn) { $r.Cb.Checked = $false }
                elseif (-not $r.Installed) { $r.Cb.Checked = $true }
            }
        }.GetNewClosure())
    }

    $body.ResumeLayout()

    # --- 콘텐츠 높이에 맞춰 본문/창 크기 확정 (화면 작업영역을 넘지 않게 클램프, 넘치면 본문 스크롤) ---
    $contentH = [int]((($colY | Measure-Object -Maximum).Maximum) + 4)
    $bodyH = [int][Math]::Min($contentH, $maxBodyH)
    if ($bodyH -lt 120) { $bodyH = 120 }
    $body.Size = New-Object System.Drawing.Size($bodyW, $bodyH)

    $bodyBottom = $bodyTop + $bodyH
    $btnY    = $bodyBottom + 16
    $clientH = $btnY + 38 + 12

    # 본문/하단 구분선
    $sep2 = New-Object System.Windows.Forms.Panel
    $sep2.Location = New-Object System.Drawing.Point($pad, ($bodyBottom + 8))
    $sep2.Size = New-Object System.Drawing.Size($bodyW, 1)
    $sep2.BackColor = $line
    $form.Controls.Add($sep2)

    # --- 하단: 전체 선택/해제(왼쪽) + 취소/설치(오른쪽) ---
    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.FlatStyle = 'Flat'
    $btnSelectAll.FlatAppearance.BorderColor = $line
    $btnSelectAll.Location = New-Object System.Drawing.Point($pad, ($btnY + 3)); $btnSelectAll.Size = New-Object System.Drawing.Size(100, 32)
    $btnSelectAll.Add_Click({ foreach ($r in $itemControls) { if (-not $r.Installed) { $r.Cb.Checked = $true } } })
    $form.Controls.Add($btnSelectAll)

    $btnDeselectAll = New-Object System.Windows.Forms.Button
    $btnDeselectAll.FlatStyle = 'Flat'
    $btnDeselectAll.FlatAppearance.BorderColor = $line
    $btnDeselectAll.Location = New-Object System.Drawing.Point(($pad + 104), ($btnY + 3)); $btnDeselectAll.Size = New-Object System.Drawing.Size(100, 32)
    $btnDeselectAll.Add_Click({ foreach ($r in $itemControls) { $r.Cb.Checked = $false } })
    $form.Controls.Add($btnDeselectAll)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Location = New-Object System.Drawing.Point(($clientW - $pad - 132), $btnY); $btnOk.Size = New-Object System.Drawing.Size(132, 38)
    $btnOk.FlatStyle = 'Flat'; $btnOk.FlatAppearance.BorderSize = 0
    $btnOk.BackColor = $accent; $btnOk.ForeColor = [System.Drawing.Color]::White
    $btnOk.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnOk); $form.AcceptButton = $btnOk

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Location = New-Object System.Drawing.Point(($clientW - $pad - 132 - 8 - 92), $btnY); $btnCancel.Size = New-Object System.Drawing.Size(92, 38)
    $btnCancel.FlatStyle = 'Flat'; $btnCancel.FlatAppearance.BorderColor = $line
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel); $form.CancelButton = $btnCancel

    $form.ClientSize = New-Object System.Drawing.Size($clientW, $clientH)

    # 정적/동적 라벨을 현재 언어로 적용. 구조는 고정이라 텍스트만 교체 → 체크 상태 유지.
    # 주의: 이 블록은 .GetNewClosure() 를 쓰지 않는다 (모달 ShowDialog 동안 함수 지역변수에 그대로 접근).
    $relocalize = {
        $form.Text           = L 'devSetup'
        $lblLang.Text        = L 'langLabel'
        $title.Text          = L 'selectTitle'
        $subtitle.Text       = L 'selectSubtitle'
        $btnSelectAll.Text   = L 'btnSelectAll'
        $btnDeselectAll.Text = L 'btnDeselectAll'
        $btnOk.Text          = L 'btnInstall'
        $btnCancel.Text      = L 'btnCancel'
        foreach ($h in $headerControls) { $h.Label.Text = Loc ($GroupNames[$h.Key]) }
        foreach ($c in $itemControls) {
            $suffix = if ($c.Installed) { L 'childInstalled' } else { '' }
            $c.Cb.Text = (Loc $c.NameRaw) + $suffix
        }
    }
    & $relocalize

    # 언어 전환: 텍스트만 다시 칠한다 (체크 상태는 컨트롤에 그대로 남아있음)
    $cmbLang.Add_SelectedIndexChanged({
        $newLang = if ($cmbLang.SelectedIndex -eq 0) { 'ko' } else { 'en' }
        if ($newLang -eq $script:Lang) { return }
        $script:Lang = $newLang
        & $relocalize
    })

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    # 체크된 항목 키 수집
    $keys = @()
    foreach ($c in $itemControls) { if ($c.Cb.Checked) { $keys += [string]$c.Key } }
    return ,$keys
}

# --- 설치 상태 조회 ---
Write-Step (L 'stepCheckStatus')
$statusItems = @()
$idx = 0
foreach ($it in $Lineup) {
    $idx++
    Write-Progress -Activity (L 'progressCheckActivity') -Status (Loc ($it.Name)) -PercentComplete (($idx / $Lineup.Count) * 100)
    $inst = $false
    try { $inst = [bool](& $it.Installed) } catch { $inst = $false }
    $statusItems += [pscustomobject]@{ Key=$it.Key; NameRaw=$it.Name; GroupKey=$it.Group; IsInstalled=$inst; DefaultOff=[bool]$it.DefaultOff }
}
Write-Progress -Activity (L 'progressCheckActivity') -Completed

# --- 선택 ---
if ($script:All) {
    $selectedKeys = $Lineup | ForEach-Object { $_.Key }    # -All: 전체 선택
    Write-Ok (L 'okAllSelected')
} else {
    $selectedKeys = Show-InstallSelection -Items $statusItems
    if ($null -eq $selectedKeys) {
        Write-Host ("`n" + (L 'cancelled')) -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        Read-Host ("`n" + (L 'pressEnterExit'))
        exit 0
    }
}

# --- 선행 의존(Requires) 자동 포함 ---
$selSet = New-Object System.Collections.Generic.HashSet[string]
foreach ($k in $selectedKeys) { [void]$selSet.Add($k) }
$autoAdded = @()
$changed = $true
while ($changed) {
    $changed = $false
    foreach ($it in $Lineup) {
        if ($selSet.Contains($it.Key) -and $it.Requires) {
            foreach ($r in $it.Requires) {
                if (-not $selSet.Contains($r)) { [void]$selSet.Add($r); $autoAdded += $r; $changed = $true }
            }
        }
    }
}
if ($autoAdded.Count -gt 0) {
    $names = ($Lineup | Where-Object { $autoAdded -contains $_.Key } | ForEach-Object { Loc ($_.Name) }) -join ', '
    Write-Warn2 ((L 'warnAutoDeps') -f $names)
}

if ($selSet.Count -eq 0) {
    Write-Host ("`n" + (L 'noSelection')) -ForegroundColor Yellow
} else {
    $selNames = ($Lineup | Where-Object { $selSet.Contains($_.Key) } | ForEach-Object { Loc ($_.Name) }) -join ', '
    Write-Host ("`n==> " + ((L 'installStart') -f $selSet.Count, $selNames)) -ForegroundColor Cyan

    # ====================== 8. 선택 항목 설치 (라인업 순서대로) ======================
    foreach ($it in $Lineup) {
        if ($selSet.Contains($it.Key)) { & $it.Action }
    }
}

# ====================== 9. 임시 다운로드 파일 정리 ======================
# 스크립트가 직접 받은 임시 파일만 삭제 (winget/choco 캐시, VS 패키지 캐시, 로그는 건드리지 않음)
Write-Step (L 'stepCleanup')
$tempArtifacts = @(
    (Join-Path $env:TEMP 'DockerDesktopInstaller.exe'),   # ~624MB
    (Join-Path $env:TEMP 'openjdk-17.msi'),               # ~160MB (winget 폴백 시)
    (Join-Path $env:TEMP 'openjdk-21.msi'),
    (Join-Path $env:TEMP 'openjdk-25.msi'),
    (Join-Path $env:TEMP 'android-cmdline-tools.zip'),    # ~143MB
    (Join-Path $env:TEMP 'android-cmdline-extract')       # 추출 임시 폴더
)
$freed = 0
foreach ($a in $tempArtifacts) {
    if (Test-Path $a) {
        try {
            $size = (Get-ChildItem $a -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            if ($script:DryRun) {
                Write-Host ("    [DRY]  " + ((L 'dryDelete') -f $a)) -ForegroundColor Magenta
            } else {
                Remove-Item $a -Recurse -Force -ErrorAction Stop
                $freed += [long]$size
                Write-Ok ((L 'okDeleted') -f $a)
            }
        } catch {
            Write-Warn2 ((L 'warnDeleteFail') -f $a, $_.Exception.Message)
        }
    }
}
if ($script:DryRun) {
    Add-Result (L 'resCleanup') 'DRY' (L 'detailCleanupDry')
} else {
    $mb = [math]::Round($freed / 1MB, 0)
    Write-Ok ((L 'okCleanup') -f $mb)
    Add-Result (L 'resCleanup') 'OK' ((L 'detailReclaimed') -f $mb)
}

# ====================== 10. 결과 요약 ======================
Write-Host "`n========================================================" -ForegroundColor Magenta
Write-Host ("   " + (L 'summaryTitle')) -ForegroundColor Magenta
Write-Host "========================================================" -ForegroundColor Magenta
$Results | Format-Table -AutoSize Name, Status, Detail | Out-String | Write-Host

$failed = $Results | Where-Object Status -eq 'FAIL'
if ($failed) {
    Write-Host ((L 'someFailed') -f $LogFile) -ForegroundColor Red
} else {
    Write-Host (L 'allDone') -ForegroundColor Green
}

Write-Host ("`n" + (L 'postHeader')) -ForegroundColor Yellow
Write-Host (L 'postReboot') -ForegroundColor Yellow
Write-Host (L 'postPath') -ForegroundColor Yellow
Write-Host ((L 'postLog') -f $LogFile) -ForegroundColor DarkGray

Stop-Transcript | Out-Null
Read-Host ("`n" + (L 'pressEnterClose'))

#!/bin/zsh
set -euo pipefail

readonly scriptdir="${0:A:h}"

# Builds and ad-hoc signs the local SMAppService application bundle.
function buildapp() {
    local rootdir="${scriptdir:h}"
    local swiftbin
    local bindir
    local appdir="${rootdir}/dist/MacDashboard.app"
    # Review builds do not replace the currently installed or running bundle.
    if [[ "${PANEL_REVIEW_BUILD:-0}" == "1" ]]; then
        appdir="${rootdir}/dist/service-bridge-review/MacDashboard.app"
    fi
    local macosdir="${appdir}/Contents/MacOS"
    local plistdir="${appdir}/Contents/Library/LaunchDaemons"
    local daemonplist="${plistdir}/com.iwmei.macdashboard.monitor-helper.native.plist"
    local webdir="${appdir}/Contents/Resources/WebUI"
    local product
    local signid="${PANEL_SIGN_IDENTITY:--}"
    swiftbin="$(command -v swift)"

    # 构建同源管理页面。
    (cd "${rootdir}/WebUI" && npm run build)

    "${swiftbin}" build -c release
    bindir="$("${swiftbin}" build -c release --show-bin-path)"

    if ! /bin/rm -rf -- "${appdir}"; then
        print -u2 -r -- "Unable to replace ${appdir}; check its ownership."
        return 73
    fi
    /bin/mkdir -p "${macosdir}" "${plistdir}" "${webdir}"
    /bin/cp -R "${rootdir}/WebUI/dist/." "${webdir}/"
    /bin/cp "${rootdir}/Packaging/Info.plist" "${appdir}/Contents/Info.plist"
    /bin/cp "${rootdir}/Packaging/AppIcon.icns" "${appdir}/Contents/Resources/AppIcon.icns"
    # 保留声明文件。
    /bin/cp "${rootdir}/LICENSE" "${appdir}/Contents/Resources/"
    /bin/cp "${rootdir}/Packaging/com.iwmei.macdashboard.monitor-helper.native.plist" "${daemonplist}"
    /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:PANEL_ALLOWED_UID $(/usr/bin/id -u)" "${daemonplist}"

    for product in PanelHost PanelMonitorHelper PanelService PanelAuthorize; do
        /bin/cp "${bindir}/${product}" "${macosdir}/${product}"
    done

    /usr/bin/codesign --force --sign "${signid}" --identifier com.iwmei.macdashboard.monitor-helper.native "${macosdir}/PanelMonitorHelper"
    /usr/bin/codesign --force --sign "${signid}" --identifier com.iwmei.macdashboard.panel-service "${macosdir}/PanelService"
    /usr/bin/codesign --force --sign "${signid}" --identifier com.iwmei.macdashboard.panel-authorize "${macosdir}/PanelAuthorize"
    /usr/bin/codesign --force --sign "${signid}" --identifier com.iwmei.macdashboard "${appdir}"
    /usr/bin/plutil -lint "${appdir}/Contents/Info.plist" "${daemonplist}"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "${appdir}"
    print -r -- "${appdir}"
}

buildapp

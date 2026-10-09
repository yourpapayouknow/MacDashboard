#!/bin/zsh
set -euo pipefail

readonly scriptdir="${0:A:h}"

# Builds a local Installer package around the Apple-signed app bundle.
function buildpkg() {
    local rootdir="${scriptdir:h}"
    local appdir="${rootdir}/dist/MacDashboard.app"
    local pkgfile="${rootdir}/dist/MacDashboard.pkg"
    # 审阅打包复用应用构建的独立输出目录。
    if [[ "${PANEL_REVIEW_BUILD:-0}" == "1" ]]; then
        appdir="${rootdir}/dist/service-bridge-review/MacDashboard.app"
        pkgfile="${rootdir}/dist/service-bridge-review/MacDashboard.pkg"
    fi
    local tmpdir
    local payloaddir
    local installdir
    local components
    local teamid
    tmpdir="$(mktemp -d /tmp/macdashboard-pkg.XXXXXX)"
    trap "/bin/rm -rf -- ${(q)tmpdir}" EXIT
    payloaddir="${tmpdir}/payload"
    installdir="${payloaddir}/Library/Application Support/iwmei"
    components="${tmpdir}/components.plist"

    /usr/bin/codesign --verify --deep --strict "${appdir}"
    teamid="$(/usr/bin/codesign -dv --verbose=4 "${appdir}" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
    if [[ -z "${teamid}" || "${teamid}" == "not set" ]]; then
        print -u2 -r -- "MacDashboard.app must be signed with an Apple-issued identity before packaging."
        return 65
    fi

    /bin/mkdir -p "${installdir}"
    COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr --noqtn "${appdir}" "${installdir}/MacDashboard.app"
    # Removes Finder metadata from only the temporary package payload.
    /usr/bin/find "${payloaddir}" -exec /usr/bin/xattr -c {} +
    /usr/bin/pkgbuild --analyze --root "${payloaddir}" "${components}"
    /usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "${components}"
    COPYFILE_DISABLE=1 /usr/bin/pkgbuild \
        --root "${payloaddir}" \
        --scripts "${rootdir}/Packaging/pkg" \
        --component-plist "${components}" \
        --identifier com.iwmei.macdashboard.pkg \
        --version 0.1.0 \
        --install-location / \
        "${pkgfile}"
    if ! /usr/sbin/pkgutil --check-signature "${pkgfile}"; then
        print -u2 -r -- "MacDashboard.pkg is unsigned; acceptable for local Installer use."
    fi
    print -r -- "${pkgfile}"
}

buildpkg

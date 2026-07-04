#!/bin/bash
#
# 饥荒服务器管理可视化面板 DMP 一键安装/管理脚本
# 仓库: https://github.com/RuiCoffee/DMP-ARM64
#
###########################################
#            可修改的全局变量             #
###########################################

GITHUB_REPO="RuiCoffee/DMP-ARM64"
ASSET_NAME="dmp-linux-arm64.tgz"

INSTALL_DIR="/opt/dmp-arm"
EXE_FILE="${INSTALL_DIR}/dmp"
DATA_DIR="${INSTALL_DIR}/data"
CONF_FILE="${INSTALL_DIR}/.dmp-arm64.conf"
# nohup 原生输出兜底日志（早期崩溃/未走到应用自身日志初始化之前的输出）
LOG_FILE="${INSTALL_DIR}/dmp.log"
GLOBAL_CMD="/usr/local/bin/dmp-i"

# 注入全局环境变量：彻底禁止 Debian/Ubuntu 底层的任何交互式弹窗
# （这几个变量只影响 apt/dpkg/needrestart 行为，不涉及路径解析，全局设置没有副作用）
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPT="-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

###########################################
#               输出与通用函数            #
###########################################

function echo_red()    { echo -e "\033[0;31m$*\033[0m" >&2; }
function echo_green()  { echo -e "\033[0;32m$*\033[0m" >&2; }
function echo_yellow() { echo -e "\033[0;33m$*\033[0m" >&2; }
function echo_cyan()   { echo -e "\033[0;36m$*\033[0m" >&2; }

function error_exit() {
    echo_red "$1"
    exit 1
}

function require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            echo_yellow "检测到未使用 root 权限运行，自动切换为 sudo 重新执行..."
            exec sudo -E bash "$0" "$@"
        else
            error_exit "请使用 root 用户运行本脚本，或先安装 sudo。"
        fi
    fi
}

function require_arm64() {
    MACHINE_ARCH=$(uname -m)
    case "${MACHINE_ARCH}" in
        aarch64 | arm64) ;;
        *)
            echo_red "检测到当前 CPU 架构为 ${MACHINE_ARCH}"
            echo_red "本程序仅支持 ARM64 架构，终止操作。"
            exit 1
            ;;
    esac
}

function require_installed() {
    if [[ ! -e "${EXE_FILE}" ]]; then
        echo_red "未检测到已安装的 DMP 面板，请先执行 [1. 安装] 操作。"
        return 1
    fi
    return 0
}

###########################################
#          APT 死锁自动处理机制           #
###########################################

function fix_apt_lock() {
    if fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        echo_yellow "检测到后台存在占用的 apt 进程，正在尝试自动解锁..."
        local i=0
        while fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
            sleep 1
            ((i++))
            if [[ $i -ge 5 ]]; then
                echo_yellow "自动强制释放 apt 死锁..."
                killall -9 apt apt-get dpkg 2>/dev/null || true
                rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock
                dpkg --configure -a 2>/dev/null || true
                break
            fi
        done
        echo_green "APT 锁已清理完毕。"
    fi
}

###########################################
#            配置读写与状态检测           #
###########################################

function load_config() {
    if [[ -f "${CONF_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${CONF_FILE}"
    fi
    PORT=${PORT:-}
    SSL_CERT=${SSL_CERT:-}
    SSL_KEY=${SSL_KEY:-}
}

function save_config() {
    echo "PORT=${PORT}" > "${CONF_FILE}"
    [[ -n "${SSL_CERT}" ]] && echo "SSL_CERT=${SSL_CERT}" >> "${CONF_FILE}"
    [[ -n "${SSL_KEY}" ]] && echo "SSL_KEY=${SSL_KEY}" >> "${CONF_FILE}"
}

function port_in_use() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$" && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$" && return 0
    fi
    return 1
}

function generate_random_port() {
    local p
    while true; do
        p=$(shuf -i 5000-9999 -n 1)
        if ! port_in_use "${p}"; then
            echo "${p}"
            return 0
        fi
    done
}

function is_dmp_running() {
    pgrep -x dmp >/dev/null 2>&1
}

function get_server_ip() {
    curl -s -4 --max-time 3 ifconfig.me 2>/dev/null || echo "<你的服务器IP>"
}

function get_domain_from_cert() {
    local cert_file="$1"
    if command -v openssl >/dev/null 2>&1 && [[ -f "${cert_file}" ]]; then
        local cn
        cn=$(openssl x509 -in "${cert_file}" -noout -subject -nameopt multiline 2>/dev/null | grep "commonName" | head -n1 | awk -F'= ' '{print $2}')
        cn=$(echo "${cn}" | xargs 2>/dev/null)
        cn="${cn//\*\./}"
        if [[ -n "${cn}" ]]; then
            echo "${cn}"
            return 0
        fi
    fi
    return 1
}

# 检测系统真实 HOME（通常是 /root）下面是否残留了本该属于 INSTALL_DIR 的游戏数据。
# 出现这种情况通常是因为曾经不通过本脚本（不带 HOME= 覆盖）手动启动过 dmp 进程，
# 导致那一次触发的 steamcmd/dst 安装跑去了系统真实 HOME 下，
# 与 DMP 自身写的 .klei 配置（走脚本正常流程，落在 INSTALL_DIR 下）路径对不上，
# 引发"面板天数/季节识别不到"、"cluster_token.txt 找不到"这类问题。
function check_stale_home_data() {
    local real_home
    real_home=$(getent passwd root 2>/dev/null | cut -d: -f6)
    [[ -z "${real_home}" ]] && real_home="/root"

    [[ "${real_home}" == "${INSTALL_DIR}" ]] && return 0

    local stale_found=0
    local d
    for d in steamcmd dst .klei; do
        if [[ -e "${real_home}/${d}" ]]; then
            echo_red "检测到 ${real_home}/${d} 存在，这不是 DMP 当前安装目录 (${INSTALL_DIR})！"
            stale_found=1
        fi
    done

    if [[ ${stale_found} -eq 1 ]]; then
        echo_yellow "这通常是曾经不通过本脚本（不带 HOME= 环境变量覆盖）手动启动过 dmp 导致的，"
        echo_yellow "会造成游戏存档路径与面板配置路径不一致（天数/季节识别不到、token 文件找不到等问题）。"
        echo_yellow "建议将上述残留目录迁移到 ${INSTALL_DIR} 下（数据已下载，无需重新下载），例如："
        echo_yellow "  mv ${real_home}/steamcmd ${INSTALL_DIR}/steamcmd"
        echo_yellow "  mv ${real_home}/dst ${INSTALL_DIR}/dst"
        echo_yellow "之后请始终通过 dmp-i 菜单启动/停止面板，不要手动直接执行 ./dmp。"
    fi
}

###########################################
#            生命周期管理功能             #
###########################################

function do_install() {
    require_arm64
    mkdir -p "${INSTALL_DIR}" 2>/dev/null || true

    if [[ -e "${EXE_FILE}" ]]; then
        echo_yellow "检测到 DMP 似乎已安装在 ${INSTALL_DIR}。"
        read -r -p "是否要强制重新安装？(y/N): " confirm
        [[ "${confirm,,}" != "y" ]] && return 0
        is_dmp_running && do_stop
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        error_exit "本脚本目前仅支持基于 apt 的系统（Ubuntu/Debian），未检测到 apt-get。"
    fi

    echo_cyan "正在准备环境，处理可能存在的底层冲突..."
    fix_apt_lock

    echo_cyan "正在更新软件包索引并安装基础依赖 (screen curl wget gnupg tar)..."
    apt-get update -y >/dev/null 2>&1
    apt-get ${APT_OPT} install screen curl wget gnupg tar ca-certificates >/dev/null 2>&1

    do_install_box

    load_config
    if [[ -n "${PORT}" ]] && ! port_in_use "${PORT}"; then
        echo_cyan "检测到已有端口配置 ${PORT} 且未被占用，沿用该端口"
    else
        PORT=$(generate_random_port)
        echo_cyan "分配随机空闲端口: ${PORT}"
    fi

    echo_cyan "正在获取 ${GITHUB_REPO} 最新版本信息..."
    local release_json download_url
    release_json=$(curl -s -L "https://api.github.com/repos/${GITHUB_REPO}/releases/latest")
    download_url=$(echo "${release_json}" | grep -o "\"browser_download_url\": *\"[^\"]*${ASSET_NAME}\"" | sed -E 's/.*"(https:[^"]+)"/\1/')

    if [[ -z "${download_url}" ]]; then
        error_exit "未在最新 Release 中找到 ${ASSET_NAME}，请确认仓库是否已发布 ARM64 版本"
    fi

    echo_cyan "正在从 Github 下载核心程序..."
    local tmp_tgz="/tmp/${ASSET_NAME}"
    curl -L --progress-bar -o "${tmp_tgz}" "${download_url}" || error_exit "下载失败，请检查网络"

    echo_cyan "正在解压部署..."
    local extract_tmp_dir
    extract_tmp_dir=$(mktemp -d)
    tar zxf "${tmp_tgz}" -C "${extract_tmp_dir}"
    rm -f "${tmp_tgz}"

    local found_bin
    found_bin=$(find "${extract_tmp_dir}" -type f -name "dmp" | head -n1)
    [[ -z "${found_bin}" ]] && found_bin=$(find "${extract_tmp_dir}" -type f -name "dmp-arm" | head -n1)
    [[ -z "${found_bin}" ]] && found_bin=$(find "${extract_tmp_dir}" -type f -perm -u+x | head -n1)

    if [[ -z "${found_bin}" ]]; then
        rm -rf "${extract_tmp_dir}"
        error_exit "解压后未找到 dmp 可执行文件"
    fi

    mv -f "${found_bin}" "${EXE_FILE}"
    rm -rf "${extract_tmp_dir}"
    chmod +x "${EXE_FILE}"
    mkdir -p "${DATA_DIR}"

    save_config

    echo_cyan "正在注册全局命令 ${GLOBAL_CMD} ..."
    local self_path
    self_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
    cp -f "${self_path}" "${GLOBAL_CMD}"
    chmod +x "${GLOBAL_CMD}"

    do_start

    local server_ip
    server_ip=$(get_server_ip)

    echo_yellow "============================================================"
    echo_green "安装完成！"
    echo_green "请打开 http://${server_ip}:${PORT} 完成首次注册"
    echo_green "（面板首次访问会自动进入注册页，注册账号自动成为管理员）"
    echo_green "以后随时输入 dmp-i 即可重新打开本管理菜单。"
    echo_yellow "------------------------------------------------------------"
    echo_yellow "依赖说明：脚本已自动为您检测并配置好 box64/box86 环境，您可以直接开服使用。"
    echo_yellow "重要：以后请始终通过 dmp-i 菜单启动/停止面板，不要手动直接执行 ./dmp，"
    echo_yellow "否则游戏存档路径会和面板配置路径对不上，导致天数/季节等信息识别不到。"
    echo_yellow "============================================================"

    check_stale_home_data
}

function do_update() {
    require_installed || return 1

    echo_cyan "准备更新 DMP 主程序，这不会影响您的存档和游戏数据..."
    local was_running=0
    if is_dmp_running; then
        was_running=1
        do_stop
    fi

    echo_cyan "正在获取最新 Release..."
    local release_json download_url tmp_tgz extract_tmp_dir found_bin
    release_json=$(curl -s -L "https://api.github.com/repos/${GITHUB_REPO}/releases/latest")
    download_url=$(echo "${release_json}" | grep -o "\"browser_download_url\": *\"[^\"]*${ASSET_NAME}\"" | sed -E 's/.*"(https:[^"]+)"/\1/')

    if [[ -z "${download_url}" ]]; then
        error_exit "未在最新 Release 中找到 ${ASSET_NAME} 资源包"
    fi

    tmp_tgz="/tmp/${ASSET_NAME}"
    curl -L --progress-bar -o "${tmp_tgz}" "${download_url}" || error_exit "下载失败"

    extract_tmp_dir=$(mktemp -d)
    tar zxf "${tmp_tgz}" -C "${extract_tmp_dir}"
    rm -f "${tmp_tgz}"

    found_bin=$(find "${extract_tmp_dir}" -type f -name "dmp" | head -n1)
    [[ -z "${found_bin}" ]] && found_bin=$(find "${extract_tmp_dir}" -type f -name "dmp-arm" | head -n1)
    [[ -z "${found_bin}" ]] && found_bin=$(find "${extract_tmp_dir}" -type f -perm -u+x | head -n1)

    if [[ -z "${found_bin}" ]]; then
        rm -rf "${extract_tmp_dir}"
        error_exit "解压失败，未找到二进制文件。"
    fi

    echo_cyan "正在替换二进制文件..."
    mv -f "${found_bin}" "${EXE_FILE}"
    rm -rf "${extract_tmp_dir}"
    chmod +x "${EXE_FILE}"
    echo_green "更新部署完成！（数据库、游戏存档、steamcmd、dst 目录均未改动）"

    if [[ ${was_running} -eq 1 ]]; then
        do_start
    fi
}

function do_uninstall() {
    if [[ ! -e "${EXE_FILE}" ]]; then
        echo_yellow "未检测到已安装的 DMP-ARM64，无需卸载。"
        return 0
    fi

    echo_red "即将卸载 DMP-ARM64 主程序。"
    echo_red "⚠️ 提示：卸载只会删除面板本身和面板数据库配置。"
    echo_red "⚠️ 您的游戏世界存档 (.klei)、steamcmd 以及 dst 目录将被安全保留！"
    read -r -p "确认卸载？输入 y 继续，其他键取消: " confirm
    [[ "${confirm,,}" != "y" ]] && return 0

    is_dmp_running && do_stop

    if crontab -l 2>/dev/null | grep -q "${GLOBAL_CMD} autostart"; then
        crontab -l 2>/dev/null | grep -v "${GLOBAL_CMD} autostart" | crontab -
    fi

    rm -f "${EXE_FILE}"
    rm -rf "${DATA_DIR}"
    rm -f "${CONF_FILE}"
    rm -f "${LOG_FILE}"
    rm -f "${GLOBAL_CMD}"

    echo_green "DMP-ARM64 面板卸载完成！"
}

# 安装/更新饥荒服务器本体（steamcmd + DST 服务端），改编自 DMP 内置的 manual_install.sh，
# 主要优化点：
#   1. 路径统一使用 ${INSTALL_DIR} 而不是 $HOME，避免和面板配置路径不一致
#      （历史上出现过的"天数/季节识别不到、cluster_token.txt 找不到"就是这类问题）
#   2. wget 增加重试和超时，安装前检测 box64 是否就绪，给出更明确的失败提示
#   3. 精简输出（tar 不再逐个文件打印），减少无意义刷屏
function do_install_game() {
    require_arm64
    mkdir -p "${INSTALL_DIR}" 2>/dev/null || true

    local steam_dir="${INSTALL_DIR}/steamcmd"
    local dst_dir="${INSTALL_DIR}/dst"

    if ! command -v box64 >/dev/null 2>&1; then
        echo_red "未检测到 box64，ARM 架构下无法运行游戏服务端及 steamcmd。"
        echo_yellow "请先执行菜单 [6. 安装 / 检测 box64/box86] 安装依赖后再来安装游戏。"
        return 1
    fi

    if [[ -d "${dst_dir}" && -n "$(ls -A "${dst_dir}" 2>/dev/null)" ]]; then
        echo_yellow "检测到 ${dst_dir} 已存在游戏文件。"
        read -r -p "是否重新安装/更新（steamcmd 会重新拉取，dst 会被校验覆盖，不影响 .klei 存档）？(y/N): " confirm
        [[ "${confirm,,}" != "y" ]] && return 0
    fi

    fix_apt_lock
    echo_cyan "正在安装基础依赖 (screen wget curl)..."
    apt-get update -y >/dev/null 2>&1
    apt-get ${APT_OPT} install screen wget curl >/dev/null 2>&1

    echo_cyan "正在下载 steamcmd 安装包..."
    cd "${INSTALL_DIR}" || return 1
    rm -f steamcmd_linux.tar.gz
    if ! wget -q --tries=3 --timeout=20 https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz; then
        error_exit "steamcmd 安装包下载失败，请检查网络"
    fi

    rm -rf "${steam_dir}"
    mkdir -p "${steam_dir}"
    tar -zxf steamcmd_linux.tar.gz -C "${steam_dir}"
    rm -f steamcmd_linux.tar.gz

    echo_cyan "正在通过 steamcmd 安装/更新饥荒服务端（首次安装耗时较长，请耐心等待）..."
    cd "${steam_dir}" || return 1
    # 首次运行 steamcmd.sh 常常会因为自更新而失败一次，属正常现象，重试一次即可
    HOME="${INSTALL_DIR}" box64 ./steamcmd.sh +force_install_dir "${dst_dir}" +login anonymous +app_update 343050 validate +quit || true
    if ! HOME="${INSTALL_DIR}" box64 ./steamcmd.sh +force_install_dir "${dst_dir}" +login anonymous +app_update 343050 validate +quit; then
        error_exit "饥荒服务端安装失败，请检查上方 steamcmd 输出的错误信息"
    fi

    rm -rf "${dst_dir}/steamapps/appmanifest_343050.acf"

    cd "${INSTALL_DIR}" || return 1
    mkdir -p "${dst_dir}/bin/lib32" "${dst_dir}/bin64/lib64"
    [[ -f "${steam_dir}/linux32/libstdc++.so.6" ]] && cp -f "${steam_dir}/linux32/libstdc++.so.6" "${dst_dir}/bin/lib32/"

    echo_yellow "提示：ARM 架构下没有原生 x86 版本的 libcurl-gnutls.so.4，"
    echo_yellow "如果游戏启动日志报缺少该库，请自行放置 x86 版本文件到："
    echo_yellow "  ${dst_dir}/bin/lib32/libcurl-gnutls.so.4"
    echo_yellow "  ${dst_dir}/bin64/lib64/libcurl-gnutls.so.4"

    # luajit 包装脚本；dmp_files/luajit 资源由 DMP 主程序首次启动时自动释放，
    # 如果还没启动过面板（菜单 1 通常会自动启动一次），这里会先跳过，不影响默认 64 位模式
    if [[ -f "${INSTALL_DIR}/dmp_files/luajit/libpreload.so" ]]; then
        cp -f "${INSTALL_DIR}"/dmp_files/luajit/* "${dst_dir}/bin64/" 2>/dev/null || true
        cat > "${dst_dir}/bin64/dontstarve_dedicated_server_nullrenderer_x64_luajit" <<-'EOF'
export LD_PRELOAD=./libpreload.so
box64 ./dontstarve_dedicated_server_nullrenderer_x64 "$@"
unset LD_PRELOAD
EOF
        chmod --reference="${dst_dir}/bin64/dontstarve_dedicated_server_nullrenderer_x64" \
            "${dst_dir}/bin64/dontstarve_dedicated_server_nullrenderer_x64_luajit" 2>/dev/null || \
            chmod +x "${dst_dir}/bin64/dontstarve_dedicated_server_nullrenderer_x64_luajit"
    else
        echo_yellow "未找到 dmp_files/luajit 资源（随 DMP 主程序首次启动释放），已跳过 luajit 模式配置，"
        echo_yellow "不影响默认 64 位模式；如需 luajit 模式，请先执行一次 [11. 启用DMP] 后重新执行本操作。"
    fi

    echo_green "饥荒服务端安装/更新完成！"
    echo_yellow "接下来请打开面板网页，在创建/编辑房间时填写你自己的 Klei Cluster Token："
    echo_yellow "  https://accounts.klei.com/account/game/servers?game=DontStarveTogether"

    check_stale_home_data
}

# 卸载游戏本体并清理环境：删除 steamcmd、dst 服务端、以及 .klei 下的全部世界存档。
# 这是破坏性操作，会先停掉所有正在运行的游戏世界（screen 会话），
# 不影响 DMP 面板本体、账号数据库（这些由 [3. 卸载] 单独管理）。
function do_uninstall_game() {
    local dst_dir="${INSTALL_DIR}/dst"
    local steam_dir="${INSTALL_DIR}/steamcmd"
    local klei_dir="${INSTALL_DIR}/.klei"

    if [[ ! -d "${dst_dir}" && ! -d "${steam_dir}" && ! -d "${klei_dir}" ]]; then
        echo_yellow "未检测到已安装的饥荒服务器相关文件，无需清理。"
        return 0
    fi

    echo_red "============================================================"
    echo_red "危险操作：即将永久删除以下内容："
    echo_red "  ${dst_dir}   （游戏服务端本体）"
    echo_red "  ${steam_dir} （steamcmd）"
    echo_red "  ${klei_dir}  （所有世界存档，包括所有房间的地图和游戏进度！）"
    echo_red "此操作不可恢复！如果还有想保留的存档，请先手动备份 ${klei_dir} 目录再继续！"
    echo_red "============================================================"

    read -r -p "确认继续吗？请输入大写 YES 继续，其他任意键取消: " confirm
    if [[ "${confirm}" != "YES" ]]; then
        echo_yellow "已取消。"
        return 0
    fi

    echo_cyan "正在停止所有正在运行的游戏世界..."
    screen -ls 2>/dev/null | grep -oP '\d+\.DMP_\S+' | while read -r s; do
        screen -X -S "${s}" quit 2>/dev/null || true
    done
    sleep 1
    pkill -9 -f dontstarve_dedicated_server 2>/dev/null || true

    echo_cyan "正在删除游戏相关文件..."
    rm -rf "${dst_dir}" "${steam_dir}" "${klei_dir}"
    rm -f "${INSTALL_DIR}/manual_install.sh" "${INSTALL_DIR}/manual_update.sh"

    echo_green "饥荒服务器及其存档已清理完成。"
    echo_yellow "提示：DMP 面板本体、账号数据库未受影响，重新执行 [4. 安装饥荒服务器] 即可重新安装游戏。"
}

function do_install_box() {
    require_arm64

    echo_cyan "正在检查并自动安装 box64/box86 运行环境..."
    local has_err=0

    fix_apt_lock

    if command -v box64 >/dev/null 2>&1; then
        echo_green "box64 已安装，跳过。"
    else
        echo_cyan " -> 正在下载 box64 源配置 (超时限制 10 秒)..."
        wget -q --timeout=10 --tries=3 https://ryanfortner.github.io/box64-debs/box64.list -O /etc/apt/sources.list.d/box64.list || has_err=1
        wget -qO- --timeout=10 --tries=3 https://ryanfortner.github.io/box64-debs/KEY.gpg | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/box64-debs-archive-keyring.gpg 2>/dev/null || has_err=1

        echo_cyan " -> 正在更新 apt 缓存..."
        apt-get update -y >/dev/null 2>&1 || true

        echo_cyan " -> 正在执行无交互自动安装 box64..."
        if apt-get ${APT_OPT} install box64; then
            echo_green "box64 安装成功！"
        else
            has_err=1
            echo_red "box64 安装失败。"
        fi
    fi

    if command -v box86 >/dev/null 2>&1; then
        echo_green "box86 已安装，跳过。"
    else
        echo_yellow "注意：box86 依赖 CPU/内核支持 AArch32 兼容模式，部分较新 ARM64 芯片可能不支持，"
        echo_yellow "装不上不影响 DST 64 位模式（含 luajit）正常运行。"
        dpkg --add-architecture armhf 2>/dev/null || true

        echo_cyan " -> 正在下载 box86 源配置 (超时限制 10 秒)..."
        wget -q --timeout=10 --tries=3 https://ryanfortner.github.io/box86-debs/box86.list -O /etc/apt/sources.list.d/box86.list || has_err=1
        wget -qO- --timeout=10 --tries=3 https://ryanfortner.github.io/box86-debs/KEY.gpg | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/box86-debs-archive-keyring.gpg 2>/dev/null || has_err=1

        echo_cyan " -> 正在更新 apt 缓存..."
        apt-get update -y >/dev/null 2>&1 || true

        echo_cyan " -> 正在执行无交互自动安装 box86..."
        if apt-get ${APT_OPT} install box86:armhf || apt-get ${APT_OPT} install box86-generic-arm:armhf; then
            echo_green "box86 安装成功！"
        else
            has_err=1
            echo_red "box86 安装失败（大概率是当前 CPU 不支持 AArch32，可忽略）。"
        fi
    fi

    if [[ ${has_err} -eq 1 ]]; then
        echo_yellow "自动安装遇到问题。如果是网络问题导致下载源失败（ryanfortner.github.io 在国内可能被阻断），"
        echo_yellow "建议参考官方文档自行手动安装后再使用面板。"
    fi
}

function do_uninstall_box() {
    local has_box=0
    if command -v box64 >/dev/null 2>&1 || command -v box86 >/dev/null 2>&1; then
        has_box=1
    elif dpkg -l 2>/dev/null | grep -qE '^ii  (box64|box86)'; then
        has_box=1
    fi

    if [[ ${has_box} -eq 0 ]]; then
        echo_yellow "本机未检测到已安装的 box64 或 box86，无需卸载已跳过。"
        return 0
    fi

    echo_cyan "即将彻底卸载本机上的 box64 和 box86..."
    read -r -p "确认卸载？(y/N): " confirm
    [[ "${confirm,,}" != "y" ]] && return 0

    if is_dmp_running; then
        echo_yellow "提示：面板正在运行，卸载 box64/box86 后如果游戏世界正在运行，游戏进程会因为找不到运行环境而异常退出。"
        read -r -p "确认继续吗？(y/N): " confirm2
        [[ "${confirm2,,}" != "y" ]] && return 0
    fi

    echo_cyan "正在执行深度清理..."
    fix_apt_lock

    apt-get ${APT_OPT} remove --purge '^box64.*' '^box86.*' 2>/dev/null || true
    apt-get ${APT_OPT} autoremove 2>/dev/null || true

    rm -f /usr/local/bin/box64 /usr/bin/box64 /bin/box64
    rm -f /usr/local/bin/box86 /usr/bin/box86 /bin/box86

    rm -f /etc/binfmt.d/box64.conf /etc/binfmt.d/box86.conf
    systemctl restart systemd-binfmt 2>/dev/null || true

    rm -f /etc/apt/sources.list.d/box64.list /etc/apt/sources.list.d/box86.list
    rm -f /etc/apt/trusted.gpg.d/box64-debs-archive-keyring.gpg /etc/apt/trusted.gpg.d/box86-debs-archive-keyring.gpg
    apt-get update -y >/dev/null 2>&1

    hash -r 2>/dev/null || true

    echo_green "box64 / box86 及其配置源已彻底清理完成。"
}

###########################################
#            账号与设置功能               #
###########################################

function do_reset_pwd() {
    require_installed || return 1

    local was_running=0
    if is_dmp_running; then
        was_running=1
        echo_yellow "检测到面板正在运行，重置密码前需要先停止面板。"
        do_stop
    fi

    echo_cyan "调用 DMP 控制台指令重置管理员密码（根据提示操作）..."
    cd "${INSTALL_DIR}" || return
    "${EXE_FILE}" -console reset_password -dbpath "${DATA_DIR}"
    echo_green "密码重置指令执行完毕。"

    if [[ ${was_running} -eq 1 ]]; then
        echo_cyan "正在重新启动面板..."
        do_start
    fi
}

function do_change_port() {
    require_installed || return 1

    load_config
    echo_cyan "当前面板端口为: ${PORT:-未设置}"
    read -r -p "请输入新的端口 (1-65535，留空取消): " new_port
    [[ -z "${new_port}" ]] && return 0

    if ! [[ "${new_port}" =~ ^[0-9]+$ ]] || [[ "${new_port}" -lt 1 ]] || [[ "${new_port}" -gt 65535 ]]; then
        echo_red "端口格式非法。"
        return 1
    fi

    if port_in_use "${new_port}"; then
        echo_red "端口 ${new_port} 已被占用，请更换其它端口。"
        return 1
    fi

    PORT="${new_port}"
    save_config
    echo_green "端口设置已更新为 ${PORT}。"

    if is_dmp_running; then
        read -r -p "面板当前正在运行，是否立即重启以生效？(y/N): " restart_conf
        if [[ "${restart_conf,,}" == "y" ]]; then
            do_restart
        fi
    fi
}

function do_ssl_manage() {
    require_installed || return 1

    load_config
    echo_yellow "提示：本面板不负责自动申请证书，请自行通过 acme.sh 等工具申请好证书后再来这里配置路径。"
    echo_cyan "当前已配置证书路径："
    echo_cyan "公钥 (Cert): ${SSL_CERT:-未设置}"
    echo_cyan "私钥 (Key) : ${SSL_KEY:-未设置}"

    read -r -p "请输入 Fullchain / 公钥文件的绝对路径 (留空取消并清除原有配置): " new_cert
    if [[ -z "${new_cert}" ]]; then
        SSL_CERT=""
        SSL_KEY=""
        save_config
        echo_yellow "已清除 SSL 配置，面板将回退为 HTTP 模式。"
    else
        if [[ ! -f "${new_cert}" ]]; then
            echo_red "找不到对应的证书文件！"
            return 1
        fi
        read -r -p "请输入 Privkey / 私钥文件的绝对路径: " new_key
        if [[ ! -f "${new_key}" ]]; then
            echo_red "找不到对应的私钥文件！"
            return 1
        fi
        SSL_CERT="${new_cert}"
        SSL_KEY="${new_key}"
        save_config
        echo_green "HTTPS (SSL) 配置已保存。"
    fi

    if is_dmp_running; then
        read -r -p "面板当前正在运行，是否立即重启以生效？(y/N): " restart_conf
        if [[ "${restart_conf,,}" == "y" ]]; then
            do_restart
        fi
    fi
}

###########################################
#            DMP 进程管理功能             #
###########################################

function do_start() {
    require_installed || return 1

    if is_dmp_running; then
        echo_yellow "DMP 面板已在运行中，PID: $(pgrep -x dmp)"
        return 0
    fi

    load_config
    if [[ -z "${PORT}" ]]; then
        PORT=$(generate_random_port)
        save_config
    fi

    if port_in_use "${PORT}"; then
        echo_red "目标端口 ${PORT} 已被占用，启动失败。"
        return 1
    fi

    echo_cyan "正在启动 DMP 面板..."
    cd "${INSTALL_DIR}" || return

    local start_cmd=("${EXE_FILE}" -bind "${PORT}" -dbpath "${DATA_DIR}" -level info)
    local protocol="http"

    if [[ -n "${SSL_CERT}" && -n "${SSL_KEY}" && -f "${SSL_CERT}" && -f "${SSL_KEY}" ]]; then
        start_cmd+=("-cert" "${SSL_CERT}" "-key" "${SSL_KEY}")
        protocol="https"
    fi

    # 关键：只在启动 dmp 这一行临时覆盖 HOME，让 DST/steamcmd 存档路径与面板配置路径对齐；
    # 不要全局 export HOME，否则会影响 apt/gpg/curl/crontab 等无关操作。
    # 同样也不要脱离本脚本手动执行 "./dmp"，那样 HOME 会是系统真实的 /root，
    # 导致游戏文件装到 /root 而不是 INSTALL_DIR，参见 check_stale_home_data 的说明。
    HOME="${INSTALL_DIR}" nohup "${start_cmd[@]}" >> "${LOG_FILE}" 2>&1 &
    disown

    local i ready=0
    for i in $(seq 1 15); do
        if curl -sk -o /dev/null "${protocol}://127.0.0.1:${PORT}/v3/user/register"; then
            ready=1
            break
        fi
        sleep 1
    done

    if is_dmp_running && [[ "${ready}" -eq 1 ]]; then
        local display_host
        display_host=$(get_server_ip)

        if [[ "${protocol}" == "https" && -f "${SSL_CERT}" ]]; then
            local domain
            domain=$(get_domain_from_cert "${SSL_CERT}")
            [[ -n "${domain}" ]] && display_host="${domain}"
        fi

        echo_green "面板启动成功！"
        echo_green "访问地址: ${protocol}://${display_host}:${PORT}"
    elif is_dmp_running; then
        echo_yellow "进程已启动，但暂未检测到 HTTP(S) 服务就绪，可能还在初始化，请稍后手动访问确认。"
    else
        echo_red "启动失败！请通过选项 [15. 查看DMP日志] 排查原因。"
    fi
}

function do_stop() {
    if ! is_dmp_running; then
        echo_yellow "DMP 当前未在运行。"
        return 0
    fi
    echo_cyan "正在关闭 DMP 面板..."
    pkill -x dmp 2>/dev/null || true
    sleep 1
    pkill -9 -x dmp 2>/dev/null || true
    echo_green "面板已关闭。(注意：后台存在的饥荒服务端世界不会受影响)"
}

function do_restart() {
    require_installed || return 1
    do_stop
    sleep 1
    do_start
}

function do_status() {
    require_installed || return 1

    load_config
    if is_dmp_running; then
        local pid
        pid=$(pgrep -x dmp)
        local protocol="HTTP"
        [[ -n "${SSL_CERT}" ]] && protocol="HTTPS"

        echo_green "=== DMP 面板运行状态: 运行中 ==="
        echo_cyan "进程 PID : ${pid}"

        local display_host
        display_host=$(get_server_ip)
        if [[ "${protocol}" == "HTTPS" && -f "${SSL_CERT}" ]]; then
            local domain
            domain=$(get_domain_from_cert "${SSL_CERT}")
            [[ -n "${domain}" ]] && display_host="${domain}"
        fi

        echo_cyan "访问地址 : ${protocol,,}://${display_host}:${PORT}"
        echo_cyan "运行目录 : ${INSTALL_DIR}"

        local actual_home
        actual_home=$(tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null | grep '^HOME=' | cut -d= -f2-)
        if [[ -n "${actual_home}" && "${actual_home}" != "${INSTALL_DIR}" ]]; then
            echo_red "警告：当前运行中的 dmp 进程 HOME=${actual_home}，与安装目录 ${INSTALL_DIR} 不一致！"
            echo_red "这说明它不是通过本脚本启动的，游戏存档路径可能会错位，建议用 [13. 重启DMP] 重新拉起。"
        fi
    else
        echo_red "=== DMP 面板运行状态: 已停止 ==="
    fi

    check_stale_home_data
}

function do_logs() {
    require_installed || return 1

    local target_log="${INSTALL_DIR}/logs/runtime.log"

    if [[ ! -f "${target_log}" ]]; then
        echo_yellow "日志文件尚未生成 (${target_log})，请先在面板进行操作。"
        echo_yellow "另外可以看看启动早期日志: ${LOG_FILE}"
        return 0
    fi
    echo_cyan "正在读取实时运行日志 (${target_log}) (按 Ctrl+C 退出查看):"
    echo_yellow "------------------------------------------------------"
    tail -f "${target_log}"
}

function do_enable_autostart() {
    require_installed || return 1
    echo_cyan "正在将 DMP 添加至 crontab 开机自启任务..."
    (crontab -l 2>/dev/null | grep -v "${GLOBAL_CMD} autostart"; echo "@reboot ${GLOBAL_CMD} autostart") | crontab -
    echo_green "开启成功！服务器重启后 DMP 将自动拉起。"
}

function do_disable_autostart() {
    echo_cyan "正在从 crontab 移除 DMP 开机自启任务..."
    crontab -l 2>/dev/null | grep -v "${GLOBAL_CMD} autostart" | crontab -
    echo_green "关闭成功！"
}

###########################################
#               主循环菜单                #
###########################################

function show_menu() {
    clear
    echo_cyan "GitHub: https://github.com/${GITHUB_REPO}"
    echo_green "============== 饥荒服务器管理可视化面板 DMP =============="
    echo_yellow "—————————————— 生命周期管理 ——————————————"
    echo_cyan "  1. 安装"
    echo_cyan "  2. 更新"
    echo_cyan "  3. 卸载"
    echo_cyan "  4. 安装饥荒服务器"
    echo_cyan "  5. 卸载饥荒服务器并清理环境"
    echo_cyan "  6. 安装 / 检测 box64/box86"
    echo_cyan "  7. 卸载 box64/box86"
    echo_yellow "—————————————— 账号与设置 ——————————————"
    echo_cyan "  8.  修改账号密码"
    echo_cyan "  9.  修改面板端口设置"
    echo_cyan "  10. SSL证书管理"
    echo_yellow "—————————————— DMP 进程管理 ——————————————"
    echo_cyan "  11. 启用DMP"
    echo_cyan "  12. 停止DMP"
    echo_cyan "  13. 重启DMP"
    echo_cyan "  14. 查看DMP状态"
    echo_cyan "  15. 查看DMP日志"
    echo_cyan "  16. 启用DMP开机自启"
    echo_cyan "  17. 关闭DMP开机自启"
    echo_yellow "————————————————————————————————————————"
    echo_cyan "  0. 退出"
}

function main() {
    require_root "$@"

    # 供 crontab 开机自启静默调用: dmp-i autostart
    if [[ "$1" == "autostart" ]]; then
        do_start >/dev/null 2>&1
        exit 0
    fi

    while true; do
        show_menu
        read -r -p "请输入功能序号 [0-17]: " choice
        case "${choice}" in
            1)  do_install ;;
            2)  do_update ;;
            3)  do_uninstall ;;
            4)  do_install_game ;;
            5)  do_uninstall_game ;;
            6)  do_install_box ;;
            7)  do_uninstall_box ;;
            8)  do_reset_pwd ;;
            9)  do_change_port ;;
            10) do_ssl_manage ;;
            11) do_start ;;
            12) do_stop ;;
            13) do_restart ;;
            14) do_status ;;
            15) do_logs ;;
            16) do_enable_autostart ;;
            17) do_disable_autostart ;;
            0)
                echo_green "已退出，感谢使用。"
                exit 0
                ;;
            *)
                echo_red "输入错误，请输入 0-17 之间的数字"
                ;;
        esac
        echo ""
        read -r -p "按回车键返回菜单..." _
    done
}

main "$@"
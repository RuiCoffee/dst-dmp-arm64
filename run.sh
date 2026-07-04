#!/bin/bash

###########################################
# 用户自定义设置请修改下方变量，其他变量请不要修改 #
###########################################

# --------------- ↓可修改↓ --------------- #
# dmp暴露端口，即网页打开时所用的端口
PORT=8052

# 数据库文件所在目录，例如：./config
CONFIG_DIR="./data"

# 虚拟内存大小，例如 1G 4G等
SWAPSIZE=2G

# 日志等级，例如：debug info warn error
LEVEL="info"

# 证书文件，如果为空则启动http服务 例如：./fullchain.pem
CERT_FILE=""

# 私钥文件，如果为空则启动http服务 例如：./privkey.pem
KEY_FILE=""
# --------------- ↑可修改↓ --------------- #

###########################################
#     下方变量请不要修改，否则可能会出现异常     #
###########################################

USER=$(whoami)
ExeFile="$HOME/dmp"
RUN_SH_CMD="$0 $1"
DMP_GITHUB_HOME_URL="https://github.com/RuiCoffee/DMP-ARM64"

cd "$HOME" || exit

function echo_red() {
    echo -e "\033[0;31m$*\033[0m"
}

function echo_green() {
    echo -e "\033[0;32m$*\033[0m"
}

function echo_yellow() {
    echo -e "\033[0;33m$*\033[0m"
}

function echo_cyan() {
    echo -e "\033[0;36m$*\033[0m"
}

# 检查是否以 no-root 模式运行
if [[ "$1" == "no-root" ]]; then
    SUDO="sudo"
    shift
    echo_yellow "以非root模式运行，需要root权限的操作将使用sudo"
else
    SUDO=""
    # 检查用户，只能使用root执行
    if [[ "${USER}" != "root" ]]; then
        echo_red "请使用root用户执行此脚本，或使用 ./run.sh no-root 以非root模式运行"
        exit 1
    fi
fi

# 设置全局stderr为红色并添加固定格式
function set_tty() {
    exec 3>&2
    exec 2> >(while read -r line; do echo_red "[$(date +'%F %T')] [ERROR] ${line}" >&2; done)
}

# 恢复stderr颜色
function unset_tty() {
    exec 2>&3
    exec 3>&-
}

# 定义一个函数来提示用户输入（已精简联网选项）
function prompt_user() {
    clear
    echo_green "饥荒管理平台(DMP) - 本地ARM64版"
    echo_green "--- ${DMP_GITHUB_HOME_URL} ---"
    echo_yellow "————————————————————————————————————————————————————————————"
    echo_green "[1]: 启动饥荒管理平台"
    echo_green "[2]: 关闭饥荒管理平台"
    echo_green "[3]: 重启饥荒管理平台"
    echo_yellow "————————————————————————————————————————————————————————————"
    echo_green "[4]: 设置虚拟内存"
    echo_green "[5]: 设置开机自启"
    echo_green "[6]: 退出脚本"
    echo_yellow "————————————————————————————————————————————————————————————"
    echo_yellow "请输入要执行的操作 [1-6]: "
}

# 检查进程状态
function check_dmp() {
    sleep 1
    if pgrep dmp >/dev/null; then
        echo_green "启动成功"
    else
        echo_red "启动失败，请检查程序是否具备执行权限或查看日志"
        exit 1
    fi
}

# 启动主程序
function start_dmp() {
    # 检查端口是否被占用,如果被占用则退出
    port=$(${SUDO} ss -ltnp | awk -v port=${PORT} '$4 ~ ":"port"$" {print $4}')

    if [ -n "$port" ]; then
        echo_red "端口 $PORT 已被占用: $port, 修改 run.sh 中的 PORT 变量后重新运行"
        exit 1
    fi

    if [ -e "$ExeFile" ]; then
        chmod +x "$ExeFile"
        nohup "$ExeFile" -bind ${PORT} -dbpath ${CONFIG_DIR} -level ${LEVEL} -cert "${CERT_FILE}" -key "${KEY_FILE}" >/dev/null 2>&1 &
    else
        echo_red "未找到本地编译好的程序文件：$ExeFile"
        echo_yellow "请将你编译出的 ARM64 纯二进制文件重命名为 dmp，并放入 $HOME 目录下！"
        exit 1
    fi
}

# 关闭主程序
function stop_dmp() {
    pkill dmp 2>/dev/null
    sleep 1
    pkill -9 dmp 2>/dev/null
    echo_green "关闭成功"
    sleep 1
}

# 设置虚拟内存
function set_swap() {
    SWAPFILE=/swapfile

    # 检查是否已经存在交换文件
    if [ -f $SWAPFILE ]; then
        echo_green "交换文件已存在，跳过创建步骤"
    else
        echo_cyan "创建交换文件..."
        ${SUDO} fallocate -l $SWAPSIZE $SWAPFILE
        ${SUDO} chmod 600 $SWAPFILE
        ${SUDO} mkswap $SWAPFILE
        ${SUDO} swapon $SWAPFILE
        echo_green "交换文件创建并启用成功"
    fi

    # 添加到 /etc/fstab 以便开机启动
    if ! grep -q "$SWAPFILE" /etc/fstab; then
        echo_cyan "将交换文件添加到 /etc/fstab "
        echo "$SWAPFILE none swap sw 0 0" | ${SUDO} tee -a /etc/fstab > /dev/null
        echo_green "交换文件已添加到开机启动"
    else
        echo_green "交换文件已在 /etc/fstab 中，跳过添加步骤"
    fi

    # 更改swap配置并持久化
    ${SUDO} sysctl -w vm.swappiness=20
    ${SUDO} sysctl -w vm.min_free_kbytes=100000
    echo -e 'vm.swappiness = 20\nvm.min_free_kbytes = 100000\n' | ${SUDO} tee /etc/sysctl.d/dmp_swap.conf > /dev/null

    echo_green "系统虚拟内存设置成功"
}

# 设置开机自启
function auto_start_dmp() {
    CRON_JOB="@reboot /bin/bash -c 'source /etc/profile && cd ${HOME} && echo 1 | ${RUN_SH_CMD}'"

    # 检查 crontab 中是否已存在该命令
    if crontab -l 2>/dev/null | grep -Fq "$CRON_JOB"; then
        echo_yellow "已发现开机自启配置，请勿重复添加"
    else
        # 如果不存在，则添加到 crontab
        (
            crontab -l 2>/dev/null
            echo "$CRON_JOB"
        ) | crontab -
        echo_green "已成功设置开机自启"
    fi
}

# 使用无限循环让用户输入命令
while true; do
    # 提示用户输入
    prompt_user
    # 读取用户输入
    read -r command
    # 使用 case 语句判断输入的命令
    case $command in
    1)
        set_tty
        start_dmp
        check_dmp
        unset_tty
        break
        ;;
    2)
        set_tty
        stop_dmp
        unset_tty
        break
        ;;
    3)
        set_tty
        stop_dmp
        start_dmp
        check_dmp
        echo_green "重启成功"
        unset_tty
        break
        ;;
    4)
        set_tty
        set_swap
        unset_tty
        break
        ;;
    5)
        set_tty
        auto_start_dmp
        unset_tty
        break
        ;;
    6)
        exit 0
        ;;
    *)
        echo_red "请输入正确的数字 [1-6]"
        continue
        ;;
    esac
done
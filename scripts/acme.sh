#!/bin/bash
export LANG=en_US.UTF-8
red='\033[0;31m'
bblue='\033[0;34m'
plain='\033[0m'
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" $2;}
[[ $EUID -ne 0 ]] && yellow "请以root模式运行脚本" && exit

# Load lazily: sourcing maintenance never runs the installer or menu.
sbyg_load(){
    declare -F sbyg_main >/dev/null && return 0
    local base helper tmp
    base=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
    for helper in "$base/scripts/maintenance.sh" "$base/maintenance.sh" /usr/local/lib/sing-box-yg/maintenance.sh; do
        if [[ -f $helper ]]; then source "$helper"; return $?; fi
    done
    tmp=$(mktemp) || return 1
    if curl -fsSL --retry 2 https://raw.githubusercontent.com/fadeawaylove/sing-box-yg/main/scripts/maintenance.sh -o "$tmp" && bash -n "$tmp"; then
        source "$tmp"
        sbyg_install_runtime
        local result=$?
        rm -f "$tmp"
        (( result == 0 )) || return "$result"
        source "$SBYG_RUNTIME"
    else
        rm -f "$tmp"
        red "维护脚本下载失败，未修改定时任务"
        return 1
    fi
}

sbyg_load || exit 1
#[[ -e /etc/hosts ]] && grep -qE '^ *172.65.251.78 gitlab.com' /etc/hosts || echo -e '\n172.65.251.78 gitlab.com' >> /etc/hosts
if [[ -f /etc/redhat-release ]]; then
release="Centos"
elif cat /etc/issue | grep -q -E -i "alpine"; then
release="alpine"
elif cat /etc/issue | grep -q -E -i "debian"; then
release="Debian"
elif cat /etc/issue | grep -q -E -i "ubuntu"; then
release="Ubuntu"
elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
release="Centos"
elif cat /proc/version | grep -q -E -i "debian"; then
release="Debian"
elif cat /proc/version | grep -q -E -i "ubuntu"; then
release="Ubuntu"
elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
release="Centos"
else
red "不支持当前的系统，请选择使用Ubuntu,Debian,Centos系统" && exit
fi
vsid=$(grep -i version_id /etc/os-release | cut -d \" -f2 | cut -d . -f1)
op=$(cat /etc/redhat-release 2>/dev/null || cat /etc/os-release 2>/dev/null | grep -i pretty_name | cut -d \" -f2)
if [[ $(echo "$op" | grep -i -E "arch") ]]; then
red "脚本不支持当前的 $op 系统，请选择使用Ubuntu,Debian,Centos系统。" && exit
fi

v4v6(){
v4=$(curl -s4m5 icanhazip.com -k)
v6=$(curl -s6m5 icanhazip.com -k)
}

if [ ! -f acyg_update ]; then
green "首次安装Acme-yg脚本必要的依赖……"
if [[ x"${release}" == x"alpine" ]]; then
apk add wget curl tar jq tzdata openssl expect git socat iproute2 virt-what
else
if [ -x "$(command -v apt-get)" ]; then
apt update -y
apt install socat -y
apt install cron -y
elif [ -x "$(command -v yum)" ]; then
yum update -y && yum install epel-release -y
yum install socat -y
elif [ -x "$(command -v dnf)" ]; then
dnf update -y
dnf install socat -y
fi
if [[ $release = Centos && ${vsid} =~ 8 ]]; then
cd /etc/yum.repos.d/ && mkdir backup && mv *repo backup/
curl -o /etc/yum.repos.d/CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-8.repo
sed -i -e "s|mirrors.cloud.aliyuncs.com|mirrors.aliyun.com|g " /etc/yum.repos.d/CentOS-*
sed -i -e "s|releasever|releasever-stream|g" /etc/yum.repos.d/CentOS-*
yum clean all && yum makecache
cd
fi
if [ -x "$(command -v yum)" ] || [ -x "$(command -v dnf)" ]; then
if ! command -v "cronie" &> /dev/null; then
if [ -x "$(command -v yum)" ]; then
yum install -y cronie
elif [ -x "$(command -v dnf)" ]; then
dnf install -y cronie
fi
fi
if ! command -v "dig" &> /dev/null; then
if [ -x "$(command -v yum)" ]; then
yum install -y bind-utils
elif [ -x "$(command -v dnf)" ]; then
dnf install -y bind-utils
fi
fi
fi

packages=("curl" "openssl" "lsof" "socat" "dig" "tar" "wget")
inspackages=("curl" "openssl" "lsof" "socat" "dnsutils" "tar" "wget")
for i in "${!packages[@]}"; do
package="${packages[$i]}"
inspackage="${inspackages[$i]}"
if ! command -v "$package" &> /dev/null; then
if [ -x "$(command -v apt-get)" ]; then
apt-get install -y "$inspackage"
elif [ -x "$(command -v yum)" ]; then
yum install -y "$inspackage"
elif [ -x "$(command -v dnf)" ]; then
dnf install -y "$inspackage"
fi
fi
done
fi
touch acyg_update
fi

if [[ -z $(curl -s4m5 icanhazip.com -k) ]]; then
yellow "检测到VPS为纯IPV6，添加dns64"
echo -e "nameserver 2a00:1098:2b::1\nnameserver 2a00:1098:2c::1\nnameserver 2a01:4f8:c2c:123f::1" > /etc/resolv.conf
sleep 2
fi

acme2(){
if [[ -n $(lsof -i :80 | grep -v "PID") ]]; then
    red "80端口被占用，请自行释放或选择DNS验证；未终止任何程序"
    return 1
fi
}

acme3(){
if [[ -s "$SBYG_ACME" ]]; then
    green "复用现有ACME客户端、账户和验证配置"
    return 0
fi
readp "请输入注册所需的邮箱:" Aemail
[[ -n $Aemail ]] || { red "邮箱不能为空"; return 1; }
local installer
installer=$(mktemp) || return 1
if curl -fsSL https://get.acme.sh -o "$installer" && sh "$installer" email="$Aemail"; then
    rm -f "$installer"
    [[ -s "$SBYG_ACME" ]] || return 1
else
    rm -f "$installer"
    red "安装ACME客户端失败，保留现有文件"
    return 1
fi
}

checktls(){
sbyg_ids && sbyg_validate "$SBYG_CERT_DIR/cert.crt" "$SBYG_CERT_DIR/private.key" "${SBYG_IDS[@]}" || {
    red "证书校验失败，已保留账户、证书及日志"
    return 1
}
cronac || return 1
green "证书校验通过，自动维护任务已配置；申请/续期结果见维护日志"
green "证书：$SBYG_CERT_DIR/cert.crt；私钥：$SBYG_CERT_DIR/private.key"
}

checkip(){
v4v6
if [[ -z $v4 ]]; then
vpsip=$v6
elif [[ -n $v4 && -n $v6 ]]; then
vpsip="$v6 或者 $v4"
else
vpsip=$v4
fi
domainIP=$(dig @8.8.8.8 +time=2 +short "$ym" 2>/dev/null | grep -m1 '^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+$')
if echo $domainIP | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]]; then
domainIP=$(dig @2001:4860:4860::8888 +time=2 aaaa +short "$ym" 2>/dev/null | grep -m1 ':')
fi
if echo $domainIP | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]] ; then
red "未解析出IP，请检查域名是否输入有误"
yellow "是否尝试手动输入强行匹配？"
yellow "1：是！输入域名解析的IP"
yellow "2：否！退出脚本"
readp "请选择：" menu
if [ "$menu" = "1" ] ; then
green "VPS本地的IP：$vpsip"
readp "请输入域名解析的IP，与VPS本地IP($vpsip)保持一致：" domainIP
else
return 1
fi
elif [[ -n $(echo $domainIP | grep ":") ]]; then
green "当前域名解析到的IPV6地址：$domainIP"
else
green "当前域名解析到的IPV4地址：$domainIP"
fi
if [[ ! $domainIP =~ $v4 ]] && [[ ! $domainIP =~ $v6 ]]; then
yellow "当前VPS本地的IP：$vpsip"
red "当前域名解析的IP与当前VPS本地的IP不匹配！！！"
green "建议如下："
if [[ "$v6" == "2a09"* || "$v4" == "104.28"* ]]; then
yellow "WARP未能自动关闭，请手动关闭！或者使用支持自动关闭与开启的甬哥WARP脚本"
else
yellow "1、请确保CDN小黄云关闭状态(仅限DNS)，其他域名解析网站设置同理"
yellow "2、请检查域名解析网站设置的IP是否正确"
fi
return 1
else
green "IP匹配正确，申请证书开始…………"
fi
}

checkacmeca(){
if [[ "${ym}" == *ip6.arpa* ]]; then
red "目前不支持ip6.arpa域名申请证书" && return 1
fi
# Let the official client decide whether the existing certificate is due.
# Existing accounts/certificates are never deleted to force an issuance.
}

ACMEstandaloneIP(){
v4v6
if [[ -z $v4 ]]; then
vpsip=$v6
elif [[ -n $v4 && -n $v6 ]]; then
vpsip="$v4 或者 $v6"
else
vpsip=$v4
fi
green "VPS本地的IP：$vpsip"
if [[ "$v6" == "2a09"* || "$v4" == "104.28"* ]]; then
red "经检测，你申请了WARP的IP。请关闭WARP后再申请IP证书" && exit
fi
readp "请输入申请IP证书的IP【格式：IPV4或者IPV6或者IPV4 IPV6，回车跳过使用${vpsip%% *}】:" ym
if [[ -z $ym ]]; then
ym=${vpsip%% *}
fi
checkacmeca || return 1
ip1=$(echo $ym | awk '{print $1}')
if [[ "$ym" == *" "* && "$ym" == *":"* ]]; then
ip2=$(echo $ym | awk '{print $2}')
sbyg_issue --issue -d "$ip1" -d "$ip2" --standalone -k ec-256 --server letsencrypt --cert-profile shortlived --days 3 --insecure || return 1
else
sbyg_issue --issue -d "$ym" --standalone -k ec-256 --server letsencrypt --cert-profile shortlived --days 3 --insecure || return 1
fi
# Installation and validation performed by sbyg_issue.
checktls
}

ACMEstandaloneDNS(){
v4v6
#vpsip=${v4:-$v6}
readp "请输入解析完成的域名:" ym
#if [ -z "$ym" ]; then
#case "$vpsip" in *:*) ym="${vpsip//:/-}.nip.io" ;; *) ym="${vpsip//./-}.nip.io" ;; esac
#fi
green "已输入的域名:$ym" && sleep 1
checkacmeca || return 1
checkip || return 1
[[ -n $domainIP && ( $domainIP == "$v4" || $domainIP == "$v6" ) ]] || return 1
if [[ $domainIP = $v4 ]]; then
sbyg_issue --issue -d "${ym}" --standalone -k ec-256 --server letsencrypt --insecure || return 1
fi
if [[ $domainIP = $v6 ]]; then
sbyg_issue --issue -d "${ym}" --standalone -k ec-256 --server letsencrypt --listen-v6 --insecure || return 1
fi
# Installation and validation performed by sbyg_issue.
checktls
}

ACMEDNS(){
readp "请输入解析完成的域名:" ym
green "已输入的域名:$ym" && sleep 1
checkacmeca || return 1
if [[ -n $(echo $ym | grep \*) ]]; then
green "经检测，当前为泛域名证书申请，" && sleep 2
else
green "经检测，当前为单域名证书申请，" && sleep 2
fi
checkacmeca || return 1
echo
ab="请选择托管域名解析服务商：\n1.Cloudflare\n2.腾讯云DNSPod\n3.阿里云Aliyun\n 请选择："
readp "$ab" cd
case "$cd" in
#1 )
#readp "请复制Cloudflare的Global API Key：" GAK
#export CF_Key="$GAK"
#readp "请输入登录Cloudflare的注册邮箱地址：" CFemail
#export CF_Email="$CFemail"
#if [[ $domainIP = $v4 ]]; then
#bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${ym} -k ec-256 --server letsencrypt --insecure
#fi
#if [[ $domainIP = $v6 ]]; then
#bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${ym} -k ec-256 --server letsencrypt --listen-v6 --insecure
#fi
1 )
yellow "请选择 Cloudflare DNS API 验证方式："
yellow "1. API Token (推荐)"
yellow "2. Global API Key"
readp "请选择【1-2】：" cf_choice
if [ "$cf_choice" = "1" ]; then
    readp "请输入 Cloudflare Account ID (账户ID)：" CFAccountID
    export CF_Account_ID="$CFAccountID"
    readp "请输入 Cloudflare DNS API Token (API令牌)：" CFToken
    export CF_Token="$CFToken"
else
    readp "请输入登录Cloudflare的注册邮箱地址：" CFemail
    export CF_Email="$CFemail"
    readp "请复制Cloudflare的Global API Key：" GAK
    export CF_Key="$GAK"
fi
sbyg_issue --issue --dns dns_cf -d "${ym}" -k ec-256 --server letsencrypt --insecure || return 1
;;
2 )
readp "请复制腾讯云DNSPod的DP_Id：" DPID
export DP_Id="$DPID"
readp "请复制腾讯云DNSPod的DP_Key：" DPKEY
export DP_Key="$DPKEY"
sbyg_issue --issue --dns dns_dp -d "${ym}" -k ec-256 --server letsencrypt --insecure || return 1
;;
3 )
readp "请复制阿里云Aliyun的Ali_Key：" ALKEY
export Ali_Key="$ALKEY"
readp "请复制阿里云Aliyun的Ali_Secret：" ALSER
export Ali_Secret="$ALSER"
sbyg_issue --issue --dns dns_ali -d "${ym}" -k ec-256 --server letsencrypt --insecure || return 1
;;
*) red "无效的DNS服务商选项"; return 1;;
esac
# Installation and validation performed by sbyg_issue.
checktls
}

ACMEDNScheck(){
wgcfv6=$(curl -s6m6 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
wgcfv4=$(curl -s4m6 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
if [[ ! $wgcfv4 =~ on|plus && ! $wgcfv6 =~ on|plus ]]; then
ACMEDNS
else
systemctl stop wg-quick@wgcf >/dev/null 2>&1
kill -15 $(pgrep warp-go) >/dev/null 2>&1 && sleep 2
local operation_rc=0
ACMEDNS || operation_rc=$?
systemctl start wg-quick@wgcf >/dev/null 2>&1
systemctl restart warp-go >/dev/null 2>&1
systemctl enable warp-go >/dev/null 2>&1
systemctl start warp-go >/dev/null 2>&1
return "$operation_rc"
fi
}

ACMEstandaloneDNScheck(){
wgcfv6=$(curl -s6m6 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
wgcfv4=$(curl -s4m6 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
if [[ ! $wgcfv4 =~ on|plus && ! $wgcfv6 =~ on|plus ]]; then
ACMEstandaloneDNS
else
systemctl stop wg-quick@wgcf >/dev/null 2>&1
kill -15 $(pgrep warp-go) >/dev/null 2>&1 && sleep 2
local operation_rc=0
ACMEstandaloneDNS || operation_rc=$?
systemctl start wg-quick@wgcf >/dev/null 2>&1
systemctl restart warp-go >/dev/null 2>&1
systemctl enable warp-go >/dev/null 2>&1
systemctl start warp-go >/dev/null 2>&1
return "$operation_rc"
fi
}

ACMEstandaloneIPcheck(){
wgcfv6=$(curl -s6m6 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
wgcfv4=$(curl -s4m6 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
if [[ ! $wgcfv4 =~ on|plus && ! $wgcfv6 =~ on|plus ]]; then
ACMEstandaloneIP
else
systemctl stop wg-quick@wgcf >/dev/null 2>&1
kill -15 $(pgrep warp-go) >/dev/null 2>&1 && sleep 2
local operation_rc=0
ACMEstandaloneIP || operation_rc=$?
systemctl start wg-quick@wgcf >/dev/null 2>&1
systemctl restart warp-go >/dev/null 2>&1
systemctl enable warp-go >/dev/null 2>&1
systemctl start warp-go >/dev/null 2>&1
return "$operation_rc"
fi
}

acme(){
mkdir -p /root/ygkkkca
ab="1.选择独立80端口模式申请IP证书（无需域名，小白推荐）\n2.选择独立80端口模式申请域名证书（需域名）\n3.选择DNS API模式申请证书（需域名、ID、Key），自动识别单域名与泛域名\n 请选择："
readp "$ab" cd
case "$cd" in
1 ) acme2 && acme3 && ACMEstandaloneIPcheck;;
2 ) acme2 && acme3 && ACMEstandaloneDNScheck;;
3 ) acme3 && ACMEDNScheck;;
esac
}

Certificate(){
[[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && yellow "未安装acme.sh证书申请，无法执行" && exit
green "Main_Domainc下显示的域名就是已申请成功的域名证书，Renew下显示对应域名证书的自动续期时间点"
bash ~/.acme.sh/acme.sh --list
#readp "请输入要撤销并删除的域名证书（复制Main_Domain下显示的域名，退出请按Ctrl+c）:" ym
#if [[ -n $(bash ~/.acme.sh/acme.sh --list | grep $ym) ]]; then
#bash ~/.acme.sh/acme.sh --revoke -d ${ym} --ecc
#bash ~/.acme.sh/acme.sh --remove -d ${ym} --ecc
#rm -rf /root/ygkkkca
#green "撤销并删除${ym}域名证书成功"
#else
#red "未找到你输入的${ym}域名证书，请自行核实！" && exit
#fi
}

acmeshow(){
caacme='未找到通过校验的托管证书'
local identity
identity=$(cat "$SBYG_CERT_DIR/ca.log" 2>/dev/null)
if [[ -n $identity ]] && sbyg_validate "$SBYG_CERT_DIR/cert.crt" "$SBYG_CERT_DIR/private.key" "$identity"; then
    caacme=$identity
fi
}

cronac(){
sbyg_main install-cron renew
}
uncronac(){
sbyg_main remove-cron renew
}
acmerenew(){
[[ -s "$SBYG_ACME" ]] || { red "未安装ACME客户端"; return 1; }
if [[ ! -s "$SBYG_STATE/identities" ]]; then
    red "旧安装尚未迁移，请按迁移文档绑定明确的证书标识"
    return 1
fi
if sbyg_main renew; then
    green "维护检查完成（未到续期时间时不会强制申请），详见维护日志"
else
    red "维护失败或证书临期，请检查错误摘要和维护日志"
    return 1
fi
}

uninstall(){
[[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && yellow "未安装acme.sh证书申请，无法执行" && exit
curl https://get.acme.sh | sh
bash ~/.acme.sh/acme.sh --uninstall
rm -rf /root/ygkkkca
rm -rf ~/.acme.sh acme.sh
sed -i '/acme.sh.env/d' ~/.bashrc
source ~/.bashrc
uncronac
[[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && green "acme.sh卸载完毕" || red "acme.sh卸载失败"
}

clear
green "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo -e "${bblue} ░██     ░██      ░██ ██ ██         ░█${plain}█   ░██     ░██   ░██     ░█${red}█   ░██${plain}  "
echo -e "${bblue}  ░██   ░██      ░██    ░░██${plain}        ░██  ░██      ░██  ░██${red}      ░██  ░██${plain}   "
echo -e "${bblue}   ░██ ░██      ░██ ${plain}                ░██ ██        ░██ █${red}█        ░██ ██  ${plain}   "
echo -e "${bblue}     ░██        ░${plain}██    ░██ ██       ░██ ██        ░█${red}█ ██        ░██ ██  ${plain}  "
echo -e "${bblue}     ░██ ${plain}        ░██    ░░██        ░██ ░██       ░${red}██ ░██       ░██ ░██ ${plain}  "
echo -e "${bblue}     ░█${plain}█          ░██ ██ ██         ░██  ░░${red}██     ░██  ░░██     ░██  ░░██ ${plain}  "
green "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
white "甬哥Github项目  ：github.com/yonggekkk"
white "甬哥blogger博客 ：ygkkk.blogspot.com"
white "甬哥YouTube频道 ：www.youtube.com/@ygkkk"
yellow "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
green "Acme-yg脚本版本号 V26.6.17"
yellow "提示："
yellow "1、SSH登录的IP与VPS本地IP必须一致"
yellow "2、80端口模式仅支持单域名证书申请，在80端口不被占用的情况下支持自动续期"
yellow "3、DNS API模式不支持freenom免费域名申请，支持单域名与泛域名证书申请，自动续期需要有效的DNS API权限和网络连接"
yellow "4、泛域名申请前须在服务商解析处设置一个名称为 * 字符的解析记录 (输入格式：*.一级或者二级主域)"
yellow "公钥文件crt保存路径：/root/ygkkkca/cert.crt"
yellow "密钥文件key保存路径：/root/ygkkkca/private.key"
echo
red "========================================================================="
acmeshow
blue "当前已申请成功的证书（域名形式）："
yellow "$caacme"
echo
red "========================================================================="
green " 1. acme.sh申请letsencrypt ECC证书（支持IP证书模式、域名证书模式、DNS API模式） "
green " 2. 查询已申请成功的域名及自动续期时间点 "
green " 3. 手动一键证书续期 "
green " 4. 删除证书并卸载一键ACME证书申请脚本 "
green " 0. 退出 "
echo
readp "请输入数字:" NumberInput
case "$NumberInput" in
1 ) acme;;
2 ) Certificate;;
3 ) acmerenew;;
4 ) uninstall;;
* ) exit
esac

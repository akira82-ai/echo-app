#!/usr/bin/env bash
# 检测本地是否已配置可用的代码签名身份（用于固定 App 身份，避免 TCC 权限反复失效）。
#
# 背景：macOS 14+ 下纯命令行创建自签代码签名证书有钥匙串信任坑（policy 不刷新、
# 信任循环），所以改用「钥匙串访问 GUI → 证书助理」创建。本脚本只做检测和引导，
# 不再尝试命令行创建。
#
# 用法：
#   ./setup-codesign.sh          # 检测；找不到则打印 GUI 操作指引
#   ./setup-codesign.sh --check  # 静默检测，仅用于 build-app.sh 内部判断
set -euo pipefail

CERT_NAME="Echo Self-Sign"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# 已有可用身份（valid + codesigning policy）？
if security find-identity -v -p codesigning 2>/dev/null | grep -q "${CERT_NAME}"; then
    if [ "$CHECK_ONLY" -eq 0 ]; then
        echo "✅ 已有可用签名身份："
        security find-identity -v -p codesigning | grep "${CERT_NAME}"
        echo ""
        echo "build-app.sh 会自动使用它。无需再做任何操作。"
    fi
    exit 0
fi

# --check 模式静默退出
[ "$CHECK_ONLY" -eq 1 ] && exit 1

# 检测残留私钥（之前命令行方案可能留下的，会干扰新证书）
LEFTOVER_KEYS=$(security find-key "${KEYCHAIN}" 2>/dev/null | grep -c "Echo Self-Sign" || true)

cat <<EOF
❌ 未找到可用的代码签名身份「${CERT_NAME}」。

请按以下 GUI 步骤创建（约 2 分钟）。这是 macOS 14+ 下最可靠的方式：

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

if [ "${LEFTOVER_KEYS}" -gt 0 ]; then
cat <<EOF
【第 0 步：清理残留私钥】（检测到 ${LEFTOVER_KEYS} 条残留，必须先删）
  1. 打开「钥匙串访问」App（Spotlight 搜 Keychain Access）
  2. 左栏选「登录」钥匙串
  3. 上方分类标签选「密钥」(Keys)
  4. 找到名为「Echo Self-Sign」的私钥（可能有多个），全部右键 → 删除
  5. 输入登录密码确认

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
fi

cat <<EOF
【第 1 步：创建代码签名证书】
  1. 钥匙串访问仍打开，菜单栏 →「钥匙串访问」→「证书助理」→「创建证书…」
  2. 填写：
       名称：        ${CERT_NAME}          ← 必须完全一致
       身份类型：     自签名根证书
       证书类型：     代码签名              ← 关键，别选错
  3. 点「创建」（后续弹窗一路点「继续」，警告也可继续）
  4. 如有「指定位置」选项，选「登录」钥匙串

【第 2 步：设置信任（让 codesign 能识别为 valid identity）】
  1. 在「登录」钥匙串 →「证书」分类，找到「${CERT_NAME}」
  2. 双击打开它 → 展开「信任」一栏
  3. 「使用此证书时」改为「始终信任」
  4. 关闭窗口，输入登录密码确认

【第 3 步：验证】
  回到终端再跑一次：
       ./setup-codesign.sh

  看到上面那个 ✅ 就成了。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
exit 1

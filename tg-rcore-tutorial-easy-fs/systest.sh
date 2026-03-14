#!/bin/bash
# 系统测试脚本：验证 tg-rcore-tutorial-sbi 的修改不影响 ch2~ch8 内核正常运行

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEST_DIR="${SCRIPT_DIR}/systest"
SYSTEST_TXT="${SCRIPT_DIR}/systest.txt"
TIMEOUT_SEC="160"   # 每个 test.sh 的超时秒数（首次含依赖编译+运行约需160秒）
USE_LOCAL_SBI=0    # 是否使用本地 SBI 的标志

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ------------------------------------------------
# 显示帮助信息
# ------------------------------------------------
show_help() {
    cat << 'EOF'
系统测试脚本：验证 tg-rcore-tutorial-sbi 的修改不影响 ch2~ch8 内核正常运行

用法:
  ./systest.sh [选项] [crate名称...]

选项:
  -l          使用本地 tg-rcore-tutorial-sbi（修改 Cargo.toml 指向本地路径）
  -h, --help  显示此帮助信息并退出

参数:
  crate名称   要测试的 crate 名称，可指定多个。如不指定则测试 systest.txt 中的所有 crate。

示例:
  ./systest.sh                              # 测试所有 crate，使用 crates.io 的 SBI
  ./systest.sh -l                           # 测试所有 crate，使用本地 SBI
  ./systest.sh tg-rcore-tutorial-ch2        # 测试 ch2，使用 crates.io 的 SBI
  ./systest.sh -l tg-rcore-tutorial-ch2     # 测试 ch2，使用本地 SBI
  ./systest.sh tg-rcore-tutorial-ch3 ch5    # 测试 ch3 和 ch5，使用 crates.io 的 SBI
  ./systest.sh -l ch2 ch3 ch4               # 测试 ch2、ch3、ch4，使用本地 SBI

支持的 crate 名称:
  tg-rcore-tutorial-ch2
  tg-rcore-tutorial-ch3
  tg-rcore-tutorial-ch4
  tg-rcore-tutorial-ch5
  tg-rcore-tutorial-ch6
  tg-rcore-tutorial-ch7
  tg-rcore-tutorial-ch8

配置文件:
  systest.txt   定义测试配置，格式为："crate名称" "测试命令" "期望输出"
  sysdeps.txt   定义本地依赖配置（配合 -l 使用），格式为："依赖包名" "相对路径"

示例 sysdeps.txt:
  "tg-rcore-tutorial-sbi" "../.."
  "tg-rcore-tutorial-syscall" "../../tg-rcore-tutorial-syscall"
EOF
    exit 0
}

# ------------------------------------------------
# 检查是否请求帮助
# ------------------------------------------------
for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        show_help
    fi
done

# ------------------------------------------------
# 读取 systest.txt，构建全量数据数组
# ------------------------------------------------
if [[ ! -f "${SYSTEST_TXT}" ]]; then
    echo "错误：找不到 ${SYSTEST_TXT}" >&2
    exit 1
fi

declare -a ALL_CRATE_NAMES=()
declare -a ALL_TEST_CMDS=()
declare -a ALL_EXPECTED_OUTPUTS=()

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    # 去除可能的 Windows CRLF 行尾中的 \r 字符
    line=$(echo "$line" | tr -d '\r')
    
    # 提取双引号包围的三个字段（正确处理字段内部的空格）
    fields=()
    temp="$line"
    while [[ "$temp" =~ \"([^\"]*)\" ]]; do
        fields+=("${BASH_REMATCH[1]}")
        temp="${temp#*\"}"
        temp="${temp#*\"}"
    done
    
    COL1="${fields[0]}"
    COL2="${fields[1]}"
    COL3="${fields[2]}"
    
    ALL_CRATE_NAMES+=("$COL1")
    ALL_TEST_CMDS+=("$COL2")
    ALL_EXPECTED_OUTPUTS+=("$COL3")
done < "${SYSTEST_TXT}"

# ------------------------------------------------
# 参数解析与校验
# ------------------------------------------------
declare -a SELECTED_INDICES=()

# 解析参数，识别 -l 选项和 crate 名称
declare -a CRATE_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "-l" ]]; then
        USE_LOCAL_SBI=1
    else
        CRATE_ARGS+=("$arg")
    fi
done

if [[ ${#CRATE_ARGS[@]} -eq 0 ]]; then
    for i in "${!ALL_CRATE_NAMES[@]}"; do
        SELECTED_INDICES+=("$i")
    done
else
    declare -a INVALID_ARGS=()
    for arg in "${CRATE_ARGS[@]}"; do
        found=0
        for i in "${!ALL_CRATE_NAMES[@]}"; do
            if [[ "${ALL_CRATE_NAMES[$i]}" == "$arg" ]]; then
                # 去重
                already=0
                for idx in "${SELECTED_INDICES[@]:-}"; do
                    [[ "$idx" == "$i" ]] && already=1 && break
                done
                [[ $already -eq 0 ]] && SELECTED_INDICES+=("$i")
                found=1
                break
            fi
        done
        [[ $found -eq 0 ]] && INVALID_ARGS+=("$arg")
    done

    if [[ ${#INVALID_ARGS[@]} -gt 0 ]]; then
        echo -e "${RED}错误：以下参数在 systest.txt 第一列中不存在：${NC}" >&2
        for inv in "${INVALID_ARGS[@]}"; do
            echo "  - ${inv}" >&2
        done
        echo "" >&2
        echo "合法的 crate 名称为：" >&2
        for name in "${ALL_CRATE_NAMES[@]}"; do
            echo "  - ${name}" >&2
        done
        exit 1
    fi
fi

# 根据选中索引构建本次操作数组
declare -a CRATE_NAMES=()
declare -a TEST_CMDS=()
declare -a EXPECTED_OUTPUTS=()
for i in "${SELECTED_INDICES[@]}"; do
    CRATE_NAMES+=("${ALL_CRATE_NAMES[$i]}")
    TEST_CMDS+=("${ALL_TEST_CMDS[$i]}")
    EXPECTED_OUTPUTS+=("${ALL_EXPECTED_OUTPUTS[$i]}")
done

# ------------------------------------------------
# 打印运行信息
# ------------------------------------------------
echo "========================================"
echo "  tg-rcore-tutorial-sbi 系统测试"
echo "========================================"
echo "本地 SBI 路径: ${SCRIPT_DIR}"
echo "测试目录:      ${SYSTEST_DIR}"
echo "超时限制:      ${TIMEOUT_SEC} 秒"
echo "本次测试 crate (${#CRATE_NAMES[@]} 个):"
for name in "${CRATE_NAMES[@]}"; do
    echo "  - ${name}"
done
echo ""

# 检查 cargo-clone 是否安装
if ! command -v cargo-clone &>/dev/null && ! cargo clone --version &>/dev/null 2>&1; then
    echo "cargo-clone 未安装，正在安装..."
    cargo install cargo-clone
fi

mkdir -p "${SYSTEST_DIR}"

# ------------------------------------------------
# 阶段1：删除旧目录并重新 clone crate 源码
# ------------------------------------------------
echo "========================================"
echo "阶段1：获取各章节 crate 源码"
echo "========================================"

for CRATE in "${CRATE_NAMES[@]}"; do
    TARGET_DIR="${SYSTEST_DIR}/${CRATE}"
    if [[ -d "${TARGET_DIR}" ]]; then
        echo "  [清理] 删除旧目录 ${TARGET_DIR}"
        rm -rf "${TARGET_DIR}"
    fi
    echo "  [下载] 正在 cargo clone ${CRATE} ..."
    (cd "${SYSTEST_DIR}" && cargo clone "${CRATE}")
    echo "  [完成] ${CRATE} 下载完成"
done
echo ""

# ------------------------------------------------
# 阶段2：patch Cargo.toml，使用本地依赖（仅当 -l 参数时执行）
# ------------------------------------------------
if [[ ${USE_LOCAL_SBI} -eq 1 ]]; then
    SYSDEPS_TXT="${SCRIPT_DIR}/sysdeps.txt"

    if [[ ! -f "${SYSDEPS_TXT}" ]]; then
        echo -e "${YELLOW}[警告]${NC} 找不到 ${SYSDEPS_TXT}，跳过本地依赖替换"
    else
        echo "========================================"
        echo "阶段2：patch Cargo.toml 使用本地依赖"
        echo "========================================"

        # 读取 sysdeps.txt 到数组
        declare -a DEP_NAMES=()
        declare -a DEP_PATHS=()
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            # 提取双引号包围的两个字段
            fields=()
            temp="$line"
            while [[ "$temp" =~ \"([^\"]*)\" ]]; do
                fields+=("${BASH_REMATCH[1]}")
                temp="${temp#*\"}"
                temp="${temp#*\"}"
            done
            if [[ ${#fields[@]} -ge 2 ]]; then
                DEP_NAMES+=("${fields[0]}")
                DEP_PATHS+=("${fields[1]}")
            fi
        done < "${SYSDEPS_TXT}"

        echo "  本地依赖配置 (${#DEP_NAMES[@]} 个):"
        for i in "${!DEP_NAMES[@]}"; do
            echo "    - ${DEP_NAMES[$i]} → ${DEP_PATHS[$i]}"
        done
        echo ""

        for CRATE in "${CRATE_NAMES[@]}"; do
            TARGET_DIR="${SYSTEST_DIR}/${CRATE}"
            CARGO_TOML="${TARGET_DIR}/Cargo.toml"

            if [[ ! -f "${CARGO_TOML}" ]]; then
                echo "  [警告] ${CRATE}/Cargo.toml 不存在，跳过"
                continue
            fi

            echo "  [patch] ${CRATE}/Cargo.toml"
            cp "${CARGO_TOML}" "${CARGO_TOML}.bak"

            # 构建 Python 代码中的依赖列表
            DEP_LIST="["
            for i in "${!DEP_NAMES[@]}"; do
                if [[ $i -gt 0 ]]; then DEP_LIST+=","; fi
                DEP_LIST+="('${DEP_NAMES[$i]}', '${DEP_PATHS[$i]}')"
            done
            DEP_LIST+="]"

            python3 - <<PYEOF
import re

cargo_toml = '${CARGO_TOML}'
dep_list = ${DEP_LIST}

with open(cargo_toml, 'r') as f:
    content = f.read()

for pkg_name, rel_path in dep_list:
    # 格式1: pkg_name = "x.y.z"
    content = re.sub(
        r'^(' + re.escape(pkg_name) + r'\s*=\s*)"[^"]*"',
        r'\1{ path = "' + rel_path + r'" }',
        content, flags=re.MULTILINE
    )

    # 格式2: pkg_name = { version = "x.y.z", ... }
    def make_replace_table(path):
        def replace_table(m):
            prefix = m.group(1)
            inner  = m.group(2)
            inner  = re.sub(r'\bversion\s*=\s*"[^"]*",?\s*', '', inner)
            inner  = inner.strip().rstrip(',').strip()
            body   = ('path = "' + path + '", ' + inner) if inner else ('path = "' + path + '"')
            return prefix + '{ ' + body + ' }'
        return replace_table

    content = re.sub(
        r'^(' + re.escape(pkg_name) + r'\s*=\s*)\{([^}]*)\}',
        make_replace_table(rel_path), content, flags=re.MULTILINE
    )

    # 格式3: [dependencies.xxx] 表格格式，包含 package = "pkg_name"
    def make_replace_dep_table(path, name):
        def replace_dep_table(m):
            header = m.group(1)
            body = m.group(2)
            if 'package = "' + name + '"' in body:
                body = re.sub(r'^version\s*=\s*"[^"]*"\s*\n', '', body, flags=re.MULTILINE)
                return header + 'path = "' + path + '"\n' + body
            return m.group(0)
        return replace_dep_table

    content = re.sub(
        r'(\[dependencies\.[^\]]+\]\n)(.*?)(?=\n\[|\Z)',
        make_replace_dep_table(rel_path, pkg_name), content, flags=re.DOTALL
    )

with open(cargo_toml, 'w') as f:
    f.write(content)
print('    已写入 ' + cargo_toml)
PYEOF
        done
        echo ""
    fi
fi  # USE_LOCAL_SBI 条件结束

# ------------------------------------------------
# 阶段3：执行测试并收集结果
# ------------------------------------------------
echo "========================================"
echo "阶段3：执行测试"
echo "========================================"

declare -a PASSED_LIST=()
declare -a FAILED_LIST=()
declare -a TIMEOUT_LIST=()

TOTAL="${#CRATE_NAMES[@]}"
IDX=0

for i in "${!CRATE_NAMES[@]}"; do
    CRATE="${CRATE_NAMES[$i]}"
    TEST_CMD="${TEST_CMDS[$i]}"
    EXPECTED="${EXPECTED_OUTPUTS[$i]}"
    TARGET_DIR="${SYSTEST_DIR}/${CRATE}"
    IDX=$((IDX + 1))

    echo ""
    echo "----------------------------------------"
    echo "[${IDX}/${TOTAL}] 测试 ${CRATE}"
    echo "  期望输出: ${EXPECTED}"
    echo "  命令:     cd ${TARGET_DIR} && timeout ${TIMEOUT_SEC} ${TEST_CMD}"
    echo "----------------------------------------"

    if [[ ! -d "${TARGET_DIR}" ]]; then
        echo -e "  ${RED}[错误]${NC} 目录不存在，跳过"
        FAILED_LIST+=("${CRATE} (目录不存在)")
        continue
    fi

    TEST_SCRIPT="${TARGET_DIR}/test.sh"
    if [[ ! -f "${TEST_SCRIPT}" ]]; then
        echo -e "  ${RED}[错误]${NC} test.sh 不存在，跳过"
        FAILED_LIST+=("${CRATE} (test.sh 不存在)")
        continue
    fi

    LOG_FILE="${SYSTEST_DIR}/${CRATE}.log"

    # 删除旧日志文件，避免 tail -f 读取旧内容
    rm -f "${LOG_FILE}"

    echo "  ---- test.sh 输出 ----"
    set +e
    # 使用 script 在 PTY 中运行，使 qemu 的 stdout 为终端
    # 重定向 script 的 stdout 到 /dev/null，只通过 tail -f 显示输出（避免重复）
    # setsid 使 script 无控制终端；-q 静默 -f 每写即刷 -e 传递子进程退出码
    (cd "${TARGET_DIR}" && setsid script -q -f -e -c "timeout ${TIMEOUT_SEC} ${TEST_CMD}" "${LOG_FILE}" </dev/null >/dev/null 2>/dev/null) &
    SCRIPT_PID=$!
    # 等待日志文件出现且有内容（-s 检查非空）
    while [[ ! -s "${LOG_FILE}" ]] && kill -0 "${SCRIPT_PID}" 2>/dev/null; do sleep 0.1; done
    if [[ -s "${LOG_FILE}" ]]; then
        tail -f "${LOG_FILE}" 2>/dev/null &
        TAIL_PID=$!
    fi
    wait "${SCRIPT_PID}"
    EXIT_CODE=$?
    [[ -n "${TAIL_PID:-}" ]] && kill "${TAIL_PID}" 2>/dev/null
    set -e
    echo ""
    echo "  ---- 输出结束 (exit=${EXIT_CODE}) ----"

    if [[ $EXIT_CODE -eq 124 ]]; then
        echo -e "  ${YELLOW}[超时]${NC} ${TIMEOUT_SEC} 秒内未完成"
        TIMEOUT_LIST+=("${CRATE}")
        continue
    fi

    # 提取 Test PASSED: 行，先去除 ANSI 转义码再 grep（避免颜色码分割关键字）
    # 使用 $'' 语法确保 \x1b 被正确解析为 ESC 字符
    ACTUAL_LINE=$(sed $'s/\x1b\\[[0-9;]*[a-zA-Z]//g' "${LOG_FILE}" 2>/dev/null | grep "Test PASSED:" | tail -1 | tr -d '\r' | xargs || true)
    EXPECTED_TRIMMED=$(echo "${EXPECTED}" | xargs)
    echo "  实际输出: ${ACTUAL_LINE:-（未找到 'Test PASSED:' 行）}"

    if [[ -z "$ACTUAL_LINE" ]]; then
        echo -e "  ${RED}[失败]${NC} 未找到 'Test PASSED:' 行 (退出码=${EXIT_CODE})"
        FAILED_LIST+=("${CRATE} (无 Test PASSED: 行，exit=${EXIT_CODE})")
    elif [[ "$ACTUAL_LINE" == *"$EXPECTED_TRIMMED"* ]]; then
        echo -e "  ${GREEN}[通过]${NC} 输出与期望一致"
        PASSED_LIST+=("${CRATE}")
    else
        echo -e "  ${RED}[失败]${NC} 输出与期望不一致"
        echo "    期望包含: ${EXPECTED_TRIMMED}"
        echo "    实际输出: ${ACTUAL_LINE}"
        # 调试：输出十六进制表示，帮助排查不可见字符问题
        echo "    DEBUG actual_hex: $(printf '%s' "${ACTUAL_LINE}" | od -An -tx1 | tr -d ' \n')"
        echo "    DEBUG expect_hex: $(printf '%s' "${EXPECTED_TRIMMED}" | od -An -tx1 | tr -d ' \n')"
        FAILED_LIST+=("${CRATE} (期望='${EXPECTED_TRIMMED}', 实际='${ACTUAL_LINE}')")
    fi
done

# ------------------------------------------------
# 阶段4：汇总报告
# ------------------------------------------------
echo ""
echo "========================================"
echo "  测试汇总报告"
echo "========================================"
echo ""

echo -e "${GREEN}=== 正常运行 (${#PASSED_LIST[@]}/${TOTAL}) ===${NC}"
if [[ ${#PASSED_LIST[@]} -eq 0 ]]; then
    echo "  （无）"
else
    for item in "${PASSED_LIST[@]}"; do echo "  [PASS] ${item}"; done
fi

echo ""
echo -e "${RED}=== 运行失败 (${#FAILED_LIST[@]}/${TOTAL}) ===${NC}"
if [[ ${#FAILED_LIST[@]} -eq 0 ]]; then
    echo "  （无）"
else
    for item in "${FAILED_LIST[@]}"; do echo "  [FAIL] ${item}"; done
fi

echo ""
echo -e "${YELLOW}=== 超时未完成 (${#TIMEOUT_LIST[@]}/${TOTAL}) ===${NC}"
if [[ ${#TIMEOUT_LIST[@]} -eq 0 ]]; then
    echo "  （无）"
else
    for item in "${TIMEOUT_LIST[@]}"; do echo "  [TIMEOUT] ${item} (>${TIMEOUT_SEC}s)"; done
fi

echo ""
echo "========================================"
echo "  日志目录: ${SYSTEST_DIR}/"
echo "========================================"

if [[ ${#FAILED_LIST[@]} -eq 0 && ${#TIMEOUT_LIST[@]} -eq 0 ]]; then
    echo -e "${GREEN}所有测试均通过！tg-rcore-tutorial-sbi 修改验证成功。${NC}"
    exit 0
else
    echo -e "${RED}存在失败或超时测试，请检查上述报告。${NC}"
    exit 1
fi

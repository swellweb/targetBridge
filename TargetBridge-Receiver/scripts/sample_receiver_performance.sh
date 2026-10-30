#!/bin/bash
# Read-only diagnostics for an already-running receiver. No screen capture,
# payload capture, app restart, network traffic generation, or settings changes.
set -u
set -o pipefail
umask 077

receiver_pid=""
seconds=10
output_parent="${HOME}/Desktop"
[[ -d "$output_parent" ]] || output_parent="${TMPDIR:-/tmp}"
usage() {
    printf '%s\n' 'Usage: sample_receiver_performance.sh [--pid PID] [--seconds 1..30] [--output-dir DIRECTORY]'
}
while (( $# )); do
    case "$1" in
        --pid|--seconds|--output-dir)
            if (( $# < 2 )); then usage >&2; exit 2; fi
            case "$1" in
                --pid) receiver_pid="$2" ;;
                --seconds) seconds="$2" ;;
                --output-dir) output_parent="$2" ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
case "$seconds" in ''|*[!0-9]*) usage >&2; exit 2 ;; esac
if (( ${#seconds} > 2 )); then usage >&2; exit 2; fi
seconds=$((10#$seconds))
if (( seconds < 1 || seconds > 30 )); then usage >&2; exit 2; fi
if [[ ! -d "$output_parent" ]]; then
    printf '输出目录不存在：%s\n' "$output_parent" >&2; exit 2
fi
if [[ -z "$receiver_pid" ]]; then
    candidates=()
    while IFS= read -r candidate; do
        candidates+=("$candidate")
    done < <(/usr/bin/pgrep -f '(^|/)(TargetBridgeReceiver|tbreceiver)([[:space:]]|$)' || true)
    if (( ${#candidates[@]} != 1 )); then
        printf '需要恰好一个正在运行的接收端；当前找到 %s 个。请保持视频连接后再运行。\n' "${#candidates[@]}" >&2
        printf '%s\n' '多个接收端时，可用 --pid PID 明确选择。' >&2
        exit 2
    fi
    receiver_pid="${candidates[0]}"
fi
case "$receiver_pid" in ''|*[!0-9]*) usage >&2; exit 2 ;; esac
receiver_command=$(/bin/ps -p "$receiver_pid" -o comm=) || exit 2
receiver_started=$(/bin/ps -p "$receiver_pid" -o lstart=) || exit 2
case "${receiver_command##*/}" in
    TargetBridgeReceiver|tbreceiver) ;;
    *) printf 'PID %s 不是 TargetBridge 接收端。\n' "$receiver_pid" >&2; exit 2 ;;
esac
# Check the established stream before creating any report or sampling a process.
connections=$(/usr/sbin/lsof -nP -a -p "$receiver_pid" -iTCP 2>&1)
if [[ "$connections" != *'(ESTABLISHED)'* ]]; then
    printf '%s\n' '接收端尚无已建立的 TCP 连接。请连接并播放视频后重新运行。' >&2
    exit 2
fi
report_dir=$(/usr/bin/mktemp -d "$output_parent/TargetBridge-Receiver-Sample-$(/bin/date +%Y%m%d-%H%M%S)-XXXXXX") || exit 1
queue_pid=""
network_pid=""
sample_pid=""
interrupted() {
    # These are collector children only; receiver_pid is deliberately excluded.
    for child in "$queue_pid" "$network_pid" "$sample_pid"; do
        if [[ -n "$child" ]]; then kill "$child" 2>/dev/null || true; fi
    done
    wait 2>/dev/null || true
    printf '\n采集已中断，已有报告保留在：%s\n' "$report_dir" >&2
    exit 130
}
trap interrupted INT TERM
printf '%s\n' "$connections" > "$report_dir/connections.txt"
{
    printf 'TargetBridge receiver diagnostics\nPID: %s\nExecutable: %s\nProcess started: %s\n' "$receiver_pid" "$receiver_command" "$receiver_started"
    /bin/date '+Started: %Y-%m-%d %H:%M:%S %z'
    /usr/bin/sw_vers
    /usr/sbin/sysctl hw.model hw.memsize net.inet.tcp.recvspace net.inet.tcp.sendspace net.inet.tcp.autorcvbufmax net.inet.tcp.autosndbufmax kern.ipc.maxsockbuf
    /bin/ps -p "$receiver_pid" -o pid=,etime=,%cpu=,rss=,comm=
    app_root="${receiver_command%/Contents/MacOS/*}"
    if [[ "$app_root" != "$receiver_command" && -f "$app_root/Contents/Info.plist" ]]; then
        /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_root/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_root/Contents/Info.plist"
    fi
} > "$report_dir/environment.txt" 2>&1

# Netstat is filtered before writing: only this process's TCP rows are retained.
socket_snapshot() {
    /bin/date '+%Y-%m-%d %H:%M:%S %z'
    /usr/sbin/netstat -anv -p tcp | /usr/bin/awk -v pid="$receiver_pid" '
        /^Proto/ {
            print; header=1
            normalized=$0
            gsub(/Local Address/, "Local_Address", normalized)
            gsub(/Foreign Address/, "Foreign_Address", normalized)
            count=split(normalized, columns)
            for (j=1; j<=count; j++) {
                if (columns[j] == "pid") pid_column=j
                if (columns[j] == "epid") epid_column=j
            }
            next
        }
        /^tcp/ {
            found=0
            # Recent macOS uses process:pid; older releases have pid/epid columns.
            for (j=1; j<=NF; j++) if ($j ~ (":" pid "$")) found=1
            if (pid_column && $pid_column == pid) found=1
            if (epid_column && $epid_column == pid) found=1
            if (found) { print; rows++ }
        }
        END { if (!header || !rows) exit 1 }
    '
}
printf '接收端 PID %s；请继续播放同一段视频约 %s 秒。\n' "$receiver_pid" "$((seconds * 2 + 5))"
printf '%s\n' '第一阶段：TCP 吞吐与队列。第二阶段：线程采样（可能短暂影响帧率）。'
# Queue snapshots and nettop are read-only; do them before sample to keep the
# throughput window separate from the more intrusive stack sampling window.
(
    queue_failed=0
    for ((i=0; i<=seconds; i++)); do
        socket_snapshot || queue_failed=1
        if (( i < seconds )); then /bin/sleep 1; fi
    done
    exit "$queue_failed"
) > "$report_dir/socket-queues.txt" 2>&1 &
queue_pid=$!
/bin/date '+%Y-%m-%d %H:%M:%S %z' > "$report_dir/network-window.txt"
/usr/bin/nettop -L "$((seconds + 1))" -s 1 -n -x -p "$receiver_pid" \
    -J bytes_in,bytes_out,re-tx,rtt_avg,tx_win > "$report_dir/network.csv" 2> "$report_dir/network.stderr" &
network_pid=$!
wait "$network_pid"
network_result=$?
network_pid=""
if ! /usr/bin/grep -q '^tcp' "$report_dir/network.csv"; then
    printf '%s\n' 'No TCP connection rows returned.' >> "$report_dir/network.stderr"
    network_result=1
fi
/bin/date '+%Y-%m-%d %H:%M:%S %z' >> "$report_dir/network-window.txt"
wait "$queue_pid"
queue_result=$?
queue_pid=""
# Recheck identity in case the receiver exited during the first phase.
stack_connections=$(/usr/sbin/lsof -nP -a -p "$receiver_pid" -iTCP 2>&1)
printf '%s\n' "$stack_connections" > "$report_dir/connections-before-sample.txt"
if [[ "$(/bin/ps -p "$receiver_pid" -o comm=)" == "$receiver_command" &&
      "$(/bin/ps -p "$receiver_pid" -o lstart=)" == "$receiver_started" &&
      "$stack_connections" == *'(ESTABLISHED)'* ]]; then
    /usr/bin/sample "$receiver_pid" "$seconds" 1 -file "$report_dir/receiver-sample.txt" \
        > "$report_dir/sample-command.txt" 2>&1 &
    sample_pid=$!
    wait "$sample_pid"
    sample_result=$?
    sample_pid=""
else
    printf '%s\n' 'Receiver exited or disconnected before thread sampling.' > "$report_dir/sample-command.txt"
    sample_result=1
fi
/usr/sbin/lsof -nP -a -p "$receiver_pid" -iTCP > "$report_dir/connections-after-sample.txt" 2>&1 || true
{
    printf 'network_exit=%s\nqueue_exit=%s\nsample_exit=%s\n' "$network_result" "$queue_result" "$sample_result"
    /bin/date '+Finished: %Y-%m-%d %H:%M:%S %z'
} > "$report_dir/status.txt"
cat > "$report_dir/README.txt" <<'TEXT'
只读接收端诊断。没有截屏、抓取视频/剪贴板内容、修改设置或重启应用。
报告包含接收端进程路径、本机型号/系统版本、该进程的 TCP 地址/计数/队列与线程调用栈。
network.csv 是线程采样之前的窗口；不能用 sample 阶段的 FPS 作为正常性能结论。
socket-queues.txt 的 Recv-Q 是内核中待应用读取的字节数，不是 TCP 接收窗口。
sample 中 read/sendmsg 等系统调用的栈不能单独区分 CPU 执行和内核等待。
status.txt 中非零退出码或 *.stderr 表示相应部分采集失败，需结合错误解释；不是应用性能失败。
TEXT
archive="$report_dir.zip"
if ! /usr/bin/ditto -c -k --keepParent "$report_dir" "$archive"; then
    printf '压缩失败，原始报告保留在：%s\n' "$report_dir" >&2; exit 1
fi
printf '\n采集结束，报告：\n%s\n' "$archive"
if (( network_result != 0 || queue_result != 0 || sample_result != 0 )); then
    printf '%s\n' '部分采集失败，错误信息已保存在报告中。' >&2
    exit 1
fi

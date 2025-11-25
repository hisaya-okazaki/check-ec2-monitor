#!/bin/bash

# EC2/EBS状態チェックスクリプト
# 使用方法: ./ec2_ebs_check.sh <instance-id> [region]

set -e

# 色設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 使用方法表示
usage() {
    echo "使用方法: $0 <instance-id> [region]"
    echo "例: $0 i-1234567890abcdef0 ap-northeast-1"
    exit 1
}

# 引数チェック
if [ $# -lt 1 ]; then
    usage
fi

INSTANCE_ID=$1
REGION=${2:-ap-northeast-1}

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}EC2/EBS 状態チェックスクリプト${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "インスタンスID: $INSTANCE_ID"
echo "リージョン: $REGION"
echo ""

# AWS CLI設定確認
echo -e "${YELLOW}[1/8] AWS認証情報の確認...${NC}"
if ! aws sts get-caller-identity --region $REGION &>/dev/null; then
    echo -e "${RED}エラー: AWS認証情報が設定されていません${NC}"
    echo "以下のコマンドで設定してください:"
    echo "  aws configure"
    exit 1
fi
echo -e "${GREEN}✓ 認証成功${NC}"
echo ""

# EC2インスタンス情報取得
echo -e "${YELLOW}[2/8] EC2インスタンス情報を取得中...${NC}"
INSTANCE_INFO=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --region $REGION \
    --output json 2>/dev/null || echo "ERROR")

if [ "$INSTANCE_INFO" = "ERROR" ]; then
    echo -e "${RED}エラー: インスタンス情報を取得できません${NC}"
    exit 1
fi

INSTANCE_STATE=$(echo $INSTANCE_INFO | jq -r '.Reservations[0].Instances[0].State.Name')
INSTANCE_TYPE=$(echo $INSTANCE_INFO | jq -r '.Reservations[0].Instances[0].InstanceType')
LAUNCH_TIME=$(echo $INSTANCE_INFO | jq -r '.Reservations[0].Instances[0].LaunchTime')
AZ=$(echo $INSTANCE_INFO | jq -r '.Reservations[0].Instances[0].Placement.AvailabilityZone')

echo "  状態: $INSTANCE_STATE"
echo "  インスタンスタイプ: $INSTANCE_TYPE"
echo "  起動時刻: $LAUNCH_TIME"
echo "  アベイラビリティゾーン: $AZ"
echo -e "${GREEN}✓ 完了${NC}"
echo ""

# EBSボリューム情報
echo -e "${YELLOW}[3/8] アタッチされたEBSボリューム情報を取得中...${NC}"
VOLUMES=$(echo $INSTANCE_INFO | jq -r '.Reservations[0].Instances[0].BlockDeviceMappings[] | .Ebs.VolumeId')

for VOLUME_ID in $VOLUMES; do
    echo "  ボリュームID: $VOLUME_ID"
    
    VOLUME_INFO=$(aws ec2 describe-volumes \
        --volume-ids $VOLUME_ID \
        --region $REGION \
        --output json)
    
    VOL_SIZE=$(echo $VOLUME_INFO | jq -r '.Volumes[0].Size')
    VOL_TYPE=$(echo $VOLUME_INFO | jq -r '.Volumes[0].VolumeType')
    VOL_IOPS=$(echo $VOLUME_INFO | jq -r '.Volumes[0].Iops // "N/A"')
    VOL_STATE=$(echo $VOLUME_INFO | jq -r '.Volumes[0].State')
    
    echo "    - サイズ: ${VOL_SIZE}GB"
    echo "    - タイプ: $VOL_TYPE"
    echo "    - IOPS: $VOL_IOPS"
    echo "    - 状態: $VOL_STATE"
done
echo -e "${GREEN}✓ 完了${NC}"
echo ""

# CloudWatchメトリクス取得（過去1時間）
echo -e "${YELLOW}[4/8] CPU使用率メトリクスを取得中（過去1時間）...${NC}"
END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%S")
START_TIME=$(date -u -d '1 hour ago' +"%Y-%m-%dT%H:%M:%S")

CPU_METRICS=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/EC2 \
    --metric-name CPUUtilization \
    --dimensions Name=InstanceId,Value=$INSTANCE_ID \
    --start-time $START_TIME \
    --end-time $END_TIME \
    --period 300 \
    --statistics Average Maximum \
    --region $REGION \
    --output json)

CPU_AVG=$(echo $CPU_METRICS | jq -r '.Datapoints | sort_by(.Timestamp) | .[-1].Average // "N/A"')
CPU_MAX=$(echo $CPU_METRICS | jq -r '.Datapoints | sort_by(.Timestamp) | .[-1].Maximum // "N/A"')

echo "  最新の平均CPU使用率: ${CPU_AVG}%"
echo "  最新の最大CPU使用率: ${CPU_MAX}%"

if [ "$CPU_AVG" != "N/A" ]; then
    CPU_AVG_INT=$(printf "%.0f" $CPU_AVG)
    if [ $CPU_AVG_INT -gt 80 ]; then
        echo -e "  ${RED}⚠ 警告: CPU使用率が高い状態です${NC}"
    elif [ $CPU_AVG_INT -gt 60 ]; then
        echo -e "  ${YELLOW}⚠ 注意: CPU使用率がやや高めです${NC}"
    else
        echo -e "  ${GREEN}✓ CPU使用率は正常範囲内です${NC}"
    fi
fi
echo ""

# ネットワークメトリクス
echo -e "${YELLOW}[5/8] ネットワークメトリクスを取得中...${NC}"

NET_IN=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/EC2 \
    --metric-name NetworkIn \
    --dimensions Name=InstanceId,Value=$INSTANCE_ID \
    --start-time $START_TIME \
    --end-time $END_TIME \
    --period 300 \
    --statistics Average \
    --region $REGION \
    --output json | jq -r '.Datapoints | sort_by(.Timestamp) | .[-1].Average // "N/A"')

NET_OUT=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/EC2 \
    --metric-name NetworkOut \
    --dimensions Name=InstanceId,Value=$INSTANCE_ID \
    --start-time $START_TIME \
    --end-time $END_TIME \
    --period 300 \
    --statistics Average \
    --region $REGION \
    --output json | jq -r '.Datapoints | sort_by(.Timestamp) | .[-1].Average // "N/A"')

echo "  ネットワーク受信（平均）: $NET_IN bytes"
echo "  ネットワーク送信（平均）: $NET_OUT bytes"
echo -e "${GREEN}✓ 完了${NC}"
echo ""

# EBSメトリクス
echo -e "${YELLOW}[6/8] EBSメトリクスを取得中...${NC}"

for VOLUME_ID in $VOLUMES; do
    echo "  ボリュームID: $VOLUME_ID"
    
    # Read IOPS
    READ_IOPS=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/EBS \
        --metric-name VolumeReadOps \
        --dimensions Name=VolumeId,Value=$VOLUME_ID \
        --start-time $START_TIME \
        --end-time $END_TIME \
        --period 300 \
        --statistics Average \
        --region $REGION \
        --output json | jq -r '.Datapoints | sort_by(.Timestamp) | .[-1].Average // "N/A"')
    
    # Write IOPS
    WRITE_IOPS=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/EBS \
        --metric-name VolumeWriteOps \
        --dimensions Name=VolumeId,Value=$VOLUME_ID \
        --start-time $START_TIME \
        --end-time $END_TIME \
        --period 300 \
        --statistics Average \
        --region $REGION \
        --output json | jq -r '.Datapoints | sort_by(.Timestamp) | .[-1].Average // "N/A"')
    
    # Queue Length
    QUEUE_LENGTH=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/EBS \
        --metric-name VolumeQueueLength \
        --dimensions Name=VolumeId,Value=$VOLUME_ID \
        --start-time $START_TIME \
        --end-time $END_TIME \
        --period 300 \
        --statistics Average \
        --region $REGION \
        --output json | jq -r '.Datapoints | sort_by(.Timestamp) | .[-1].Average // "N/A"')
    
    echo "    - Read IOPS: $READ_IOPS"
    echo "    - Write IOPS: $WRITE_IOPS"
    echo "    - Queue Length: $QUEUE_LENGTH"
    
    if [ "$QUEUE_LENGTH" != "N/A" ]; then
        QUEUE_INT=$(printf "%.0f" $QUEUE_LENGTH)
        if [ $QUEUE_INT -gt 10 ]; then
            echo -e "    ${RED}⚠ 警告: ディスクキューが長い状態です（I/O待ちの可能性）${NC}"
        fi
    fi
done
echo -e "${GREEN}✓ 完了${NC}"
echo ""

# ステータスチェック
echo -e "${YELLOW}[7/8] インスタンスステータスチェック...${NC}"
STATUS_CHECK=$(aws ec2 describe-instance-status \
    --instance-ids $INSTANCE_ID \
    --region $REGION \
    --output json)

SYSTEM_STATUS=$(echo $STATUS_CHECK | jq -r '.InstanceStatuses[0].SystemStatus.Status // "N/A"')
INSTANCE_STATUS=$(echo $STATUS_CHECK | jq -r '.InstanceStatuses[0].InstanceStatus.Status // "N/A"')

echo "  システムステータス: $SYSTEM_STATUS"
echo "  インスタンスステータス: $INSTANCE_STATUS"
echo -e "${GREEN}✓ 完了${NC}"
echo ""

# アクティブなCloudWatchアラーム
echo -e "${YELLOW}[8/8] CloudWatchアラームの確認...${NC}"
ALARMS=$(aws cloudwatch describe-alarms \
    --alarm-name-prefix "" \
    --state-value ALARM \
    --region $REGION \
    --output json 2>/dev/null || echo '{"MetricAlarms":[]}')

ALARM_COUNT=$(echo $ALARMS | jq '.MetricAlarms | length')

if [ "$ALARM_COUNT" -gt 0 ]; then
    echo -e "  ${RED}アクティブなアラーム: $ALARM_COUNT 件${NC}"
    echo $ALARMS | jq -r '.MetricAlarms[] | "  - \(.AlarmName): \(.StateReason)"'
else
    echo -e "  ${GREEN}✓ アクティブなアラームはありません${NC}"
fi
echo ""

# サマリー
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}チェック完了${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "📊 サマリー:"
echo "  - インスタンス状態: $INSTANCE_STATE"
echo "  - CPU使用率（平均）: ${CPU_AVG}%"
echo "  - アクティブなアラーム: $ALARM_COUNT 件"
echo ""

# 推奨事項
echo "💡 次のステップ:"
if [ "$CPU_AVG" != "N/A" ]; then
    CPU_AVG_INT=$(printf "%.0f" $CPU_AVG)
    if [ $CPU_AVG_INT -gt 80 ]; then
        echo "  1. インスタンス内でtop/htopコマンドを実行してプロセスを確認"
        echo "  2. 不要なプロセスの停止を検討"
        echo "  3. インスタンスタイプのスケールアップを検討"
    fi
fi
echo "  - 詳細なメトリクスはCloudWatchコンソールで確認可能"
echo "  - インスタンスにSSH接続して内部のリソース状況を確認"
echo ""